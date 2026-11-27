from django.contrib.auth import get_user_model
from django.contrib.auth.models import update_last_login
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import transaction
from django.utils import timezone
from django.utils.crypto import constant_time_compare
from rest_framework import serializers
from rest_framework.exceptions import APIException, AuthenticationFailed
from rest_framework_simplejwt.exceptions import InvalidToken
from rest_framework_simplejwt.serializers import (
    TokenObtainPairSerializer,
    TokenObtainSerializer,
    TokenRefreshSerializer,
)
from rest_framework_simplejwt.settings import api_settings
from rest_framework_simplejwt.tokens import RefreshToken
from rest_framework_simplejwt.utils import get_md5_hash_password
from rest_framework_simplejwt.token_blacklist.models import OutstandingToken

from accounts.login_rate_limit import normalize_username
from api.capabilities import can_use_mobile


class InactiveEmployeeError(AuthenticationFailed):
    default_code = "inactive_employee"


class LoginAdmissionUnavailable(APIException):
    status_code = 503
    default_code = "service_unavailable"
    default_detail = "Sign-in is temporarily unavailable. Try again later."


def _lock_refresh_token(token):
    """Serialize consumption of a verified parent inside the caller's transaction."""
    token.outstand()
    OutstandingToken.objects.select_for_update().get(jti=token[api_settings.JTI_CLAIM])
    # Another consumer may have revoked/rotated it while we waited for the row.
    token.check_blacklist()
    token.check_exp(current_time=timezone.now())


class EmployeeTokenObtainPairSerializer(TokenObtainPairSerializer):
    def validate(self, attrs):
        try:
            username = normalize_username(attrs[self.username_field])
        except DjangoValidationError as error:
            raise serializers.ValidationError({self.username_field: error.messages}) from None
        admit = self.context.get("admit_username")
        if admit is None:
            raise LoginAdmissionUnavailable
        admit(username)
        attrs[self.username_field] = username

        # 1. Authenticate credentials and base Django user without issuing tokens
        TokenObtainSerializer.validate(self, attrs)

        # Check current account eligibility BEFORE creating OutstandingToken.
        user = self.user
        if not can_use_mobile(user):
            raise InactiveEmployeeError("Employee account is not active or missing.")

        # Tokens carry identity, never authoritative cached management permissions.
        refresh = self.get_token(self.user)
        data = {
            "refresh": str(refresh),
            "access": str(refresh.access_token),
        }
        if api_settings.UPDATE_LAST_LOGIN:
            update_last_login(None, self.user)

        return data


class EmployeeMeSerializer(serializers.Serializer):
    username = serializers.CharField(source="user.username")
    employee_code = serializers.CharField()
    display_name = serializers.CharField()
    department = serializers.CharField(source="department.name")
    department_code = serializers.CharField(source="department.code")
    job_role = serializers.CharField(source="job_role.name")
    job_role_code = serializers.CharField(source="job_role.code")
    reporting_manager = serializers.SerializerMethodField()
    is_active = serializers.BooleanField()
    date_joined = serializers.DateField()

    def get_reporting_manager(self, obj):
        if not obj.reporting_manager:
            return None
        return {
            "employee_code": obj.reporting_manager.employee_code,
            "display_name": obj.reporting_manager.display_name,
        }


class EmployeeTokenRefreshSerializer(TokenRefreshSerializer):
    @transaction.atomic
    def validate(self, attrs):
        # 1. Parse and validate the refresh token safely
        refresh = RefreshToken(attrs["refresh"])

        # 2. Extract user_id claim safely
        user_id = refresh.payload.get(api_settings.USER_ID_CLAIM)
        if not user_id:
            raise InvalidToken("Token contained no recognizable user identification.")

        # 3. Look up user safely without unhandled DoesNotExist (preventing HTTP 500)
        User = get_user_model()
        try:
            # Same User -> OutstandingToken lock order as password changes.
            user = User.objects.select_for_update().get(**{api_settings.USER_ID_FIELD: user_id})
            _lock_refresh_token(refresh)
        except (User.DoesNotExist, ValueError, TypeError):
            raise AuthenticationFailed("User not found.", code="user_not_found")

        # Preserve the existing inactive-Employee error contract (deactivation also
        # disables the linked User), then reevaluate current portal eligibility.
        employee = getattr(user, "employee", None)
        if employee is not None and not employee.is_active:
            raise InactiveEmployeeError("Employee account is not active or missing.")
        if api_settings.CHECK_USER_IS_ACTIVE and not user.is_active:
            raise AuthenticationFailed("User is inactive.", code="no_active_account")
        if not can_use_mobile(user):
            raise InactiveEmployeeError("This account no longer has mobile access.")

        # SimpleJWT's refresh serializer does not check the password claim.
        # Validate it under the User lock before issuing/rotating any child.
        if api_settings.CHECK_REVOKE_TOKEN and not constant_time_compare(
            str(refresh.payload.get(api_settings.REVOKE_TOKEN_CLAIM, "")),
            get_md5_hash_password(user.password),
        ):
            raise AuthenticationFailed("Your password changed. Sign in again.", code="password_changed")

        # 6. Proceed with standard rotation and blacklisting
        return super().validate(attrs)
