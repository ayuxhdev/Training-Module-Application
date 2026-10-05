from django.contrib.auth import get_user_model
from django.contrib.auth.models import update_last_login
from rest_framework import serializers
from rest_framework.exceptions import AuthenticationFailed
from rest_framework_simplejwt.exceptions import InvalidToken
from rest_framework_simplejwt.serializers import (
    TokenObtainPairSerializer,
    TokenObtainSerializer,
    TokenRefreshSerializer,
)
from rest_framework_simplejwt.settings import api_settings
from rest_framework_simplejwt.tokens import RefreshToken


class InactiveEmployeeError(AuthenticationFailed):
    default_code = "inactive_employee"


class EmployeeTokenObtainPairSerializer(TokenObtainPairSerializer):
    def validate(self, attrs):
        # 1. Authenticate credentials and base Django user without issuing tokens
        TokenObtainSerializer.validate(self, attrs)

        # 2. Verify linked active Employee status BEFORE creating OutstandingToken
        user = self.user
        if not hasattr(user, "employee") or not user.employee.is_active:
            raise InactiveEmployeeError("Employee account is not active or missing.")

        # 3. Issue tokens only for verified active employee
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
            user = User.objects.get(**{api_settings.USER_ID_FIELD: user_id})
        except (User.DoesNotExist, ValueError, TypeError):
            raise AuthenticationFailed("User not found.", code="user_not_found")

        # 4. Verify linked active Employee status
        if not hasattr(user, "employee") or not user.employee.is_active:
            raise InactiveEmployeeError("Employee account is not active or missing.")

        # 5. Verify user active status
        if api_settings.CHECK_USER_IS_ACTIVE and not user.is_active:
            raise AuthenticationFailed("User is inactive.", code="no_active_account")

        # 6. Proceed with standard rotation and blacklisting
        return super().validate(attrs)
