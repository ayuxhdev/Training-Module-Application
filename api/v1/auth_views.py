from collections.abc import Mapping

from django.conf import settings
from django.db import DatabaseError, transaction
from django.utils.decorators import method_decorator
from rest_framework import serializers, status
from rest_framework.exceptions import Throttled
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from rest_framework_simplejwt.views import TokenObtainPairView, TokenRefreshView
from rest_framework_simplejwt.settings import api_settings
from rest_framework_simplejwt.tokens import RefreshToken
from rest_framework_simplejwt.exceptions import TokenError, InvalidToken
from rest_framework.throttling import AnonRateThrottle, UserRateThrottle
from accounts import login_rate_limit as admission
from api.capabilities import mobile_capabilities
from api.permissions import IsMobileAccount
from .auth_serializers import (
    EmployeeTokenObtainPairSerializer, EmployeeMeSerializer, EmployeeTokenRefreshSerializer,
    LoginAdmissionUnavailable, _lock_refresh_token,
)


def _login_source(request):
    try:
        return admission.client_ip(request.META, admission.trusted_proxies(
            getattr(settings, "LOGIN_LIMIT_TRUSTED_PROXIES", ""),
        ))
    except ValueError:
        admission._log_admission_event("login_admission_unavailable", 503)
        raise LoginAdmissionUnavailable from None


class LoginThrottle(AnonRateThrottle):
    # Supplemental local burst protection. MySQL gates all attempts that can
    # reach password verification across processes and login surfaces.
    rate = '5/min'

    def get_cache_key(self, request, view):
        if request.method != "POST":
            return None
        return super().get_cache_key(request, view)

    def get_ident(self, request):
        return admission.bucket_key("api-burst", _login_source(request))


class RefreshThrottle(UserRateThrottle):
    rate = '20/min'


@method_decorator(transaction.non_atomic_requests, name="dispatch")
class EmployeeLoginView(TokenObtainPairView):
    serializer_class = EmployeeTokenObtainPairSerializer
    throttle_classes = [LoginThrottle]

    def post(self, request, *args, **kwargs):
        self.login_source = _login_source(request)
        self.login_rates = admission.login_rates()
        self.require_admission(request, admission.reserve_login_source, self.login_source, self.login_rates[0])

        # DRF parses directly from the stream; bound credential payloads before
        # accessing request.data. The proxy must enforce its own upload cap.
        length = str(request.META.get("CONTENT_LENGTH") or "0")
        if not length.isascii() or not length.isdecimal() or len(length) > 10:
            raise serializers.ValidationError("Invalid sign-in request.")
        if int(length) > 16 * 1024:
            return Response({"error": {
                "code": "request_too_large", "message": "Sign-in request is too large.", "fields": {},
            }}, status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE)
        return super().post(request, *args, **kwargs)

    def get_serializer_context(self):
        context = super().get_serializer_context()
        context["admit_username"] = self.admit_username
        return context

    def admit_username(self, username):
        self.require_admission(
            self.request, admission.reserve_login_account, self.login_source, username, *self.login_rates[1:],
        )

    def require_admission(self, request, reserve, *args):
        try:
            wait = reserve(*args)
        except (admission.AdmissionUnavailable, DatabaseError):
            admission._log_admission_event("login_admission_unavailable", 503)
            raise LoginAdmissionUnavailable from None
        if wait:
            self.throttled(request, wait)

    def throttled(self, request, wait):
        admission._log_admission_event("login_admission_limited", 429)
        raise Throttled(wait=wait, detail="Too many sign-in attempts.")

    def finalize_response(self, request, response, *args, **kwargs):
        response = super().finalize_response(request, response, *args, **kwargs)
        response["Cache-Control"] = "no-store"
        return response


class EmployeeRefreshView(TokenRefreshView):
    serializer_class = EmployeeTokenRefreshSerializer
    throttle_classes = [RefreshThrottle]

class EmployeeLogoutView(APIView):
    # Revocation must remain possible after losing Employee/management eligibility.
    permission_classes = [IsAuthenticated]

    @transaction.atomic
    def post(self, request, *args, **kwargs):
        if not isinstance(request.data, Mapping):
            raise serializers.ValidationError("Request body must be an object containing a refresh token.")
        refresh_token = request.data.get("refresh")

        if not refresh_token:
            return Response(
                {"error": {"code": "validation_error", "message": "Refresh token is required.", "fields": {"refresh": ["This field is required."]}}},
                status=status.HTTP_400_BAD_REQUEST,
            )

        try:
            token = RefreshToken(refresh_token)
        except TokenError:
            # Invalid/expired tokens are treated as successfully logged out
            return Response(status=status.HTTP_204_NO_CONTENT)

        # Verify the refresh token belongs to the authenticated user
        token_user_id = token.payload.get(api_settings.USER_ID_CLAIM)
        request_user_id = getattr(request.user, api_settings.USER_ID_FIELD, None)
        if token_user_id is None or str(token_user_id) != str(request_user_id):
            return Response(
                {"error": {"code": "permission_denied", "message": "Token does not belong to this user.", "fields": {}}},
                status=status.HTTP_403_FORBIDDEN,
            )

        try:
            _lock_refresh_token(token)
            token.blacklist()
        except TokenError:
            pass

        return Response(status=status.HTTP_204_NO_CONTENT)

class EmployeeMeView(APIView):
    permission_classes = [IsAuthenticated, IsMobileAccount]

    def get(self, request, *args, **kwargs):
        user = request.user
        employee = getattr(user, "employee", None)
        employee_data = EmployeeMeSerializer(employee).data if employee else None
        # Keep the original flat Employee contract for existing learner clients.
        identity = dict(employee_data or {})
        identity.update({
            "user": {"id": user.pk, "username": user.get_username(),
                     "display_name": user.get_full_name() or user.get_username()},
            "employee": employee_data,
            "capabilities": mobile_capabilities(user),
        })
        return Response(identity)
