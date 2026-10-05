from rest_framework import status
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from rest_framework_simplejwt.views import TokenObtainPairView, TokenRefreshView
from rest_framework_simplejwt.settings import api_settings
from rest_framework_simplejwt.tokens import RefreshToken
from rest_framework_simplejwt.exceptions import TokenError, InvalidToken
from rest_framework.throttling import AnonRateThrottle, UserRateThrottle
from api.permissions import IsActiveEmployee
from .auth_serializers import EmployeeTokenObtainPairSerializer, EmployeeMeSerializer, EmployeeTokenRefreshSerializer

class LoginThrottle(AnonRateThrottle):
    rate = '5/min'

class RefreshThrottle(UserRateThrottle):
    rate = '20/min'

class EmployeeLoginView(TokenObtainPairView):
    serializer_class = EmployeeTokenObtainPairSerializer
    throttle_classes = [LoginThrottle]

class EmployeeRefreshView(TokenRefreshView):
    serializer_class = EmployeeTokenRefreshSerializer
    throttle_classes = [RefreshThrottle]

class EmployeeLogoutView(APIView):
    permission_classes = [IsAuthenticated, IsActiveEmployee]

    def post(self, request, *args, **kwargs):
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
            token.blacklist()
        except TokenError:
            pass

        return Response(status=status.HTTP_204_NO_CONTENT)

class EmployeeMeView(APIView):
    permission_classes = [IsAuthenticated, IsActiveEmployee]

    def get(self, request, *args, **kwargs):
        employee = request.user.employee
        serializer = EmployeeMeSerializer(employee)
        return Response(serializer.data)
