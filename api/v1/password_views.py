from django.core.exceptions import PermissionDenied as DjangoPermissionDenied, ValidationError
from django.utils.decorators import method_decorator
from django.views.decorators.cache import never_cache
from django.views.decorators.debug import sensitive_post_parameters, sensitive_variables
from rest_framework import serializers, status
from rest_framework.exceptions import PermissionDenied
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework_simplejwt.authentication import JWTAuthentication

from accounts.password_services import PasswordChangeThrottle, change_own_password
from api.permissions import IsMobileAccount

from .password_serializers import PasswordChangeSerializer


@method_decorator(never_cache, name="dispatch")
@method_decorator(sensitive_post_parameters(), name="dispatch")
class PasswordChangeView(APIView):
    authentication_classes = [JWTAuthentication]
    permission_classes = [IsAuthenticated, IsMobileAccount]
    throttle_classes = [PasswordChangeThrottle]
    http_method_names = ["post", "options"]

    @sensitive_variables()
    def post(self, request):
        serializer = PasswordChangeSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        values = serializer.validated_data
        try:
            change_own_password(request.user, {
                "old_password": values["current_password"],
                "new_password1": values["new_password"],
                "new_password2": values["confirm_password"],
            }, mobile=True)
        except DjangoPermissionDenied:
            raise PermissionDenied("This account cannot change its password.") from None
        except ValidationError as error:
            names = {"old_password": "current_password", "new_password1": "new_password", "new_password2": "confirm_password"}
            raise serializers.ValidationError({
                names.get(field, "non_field_errors"): errors
                for field, errors in error.message_dict.items()
            }) from None
        # No replacement credentials in the response. All refresh tokens are
        # revoked; the client must clear its session and explicitly sign in.
        return Response(status=status.HTTP_204_NO_CONTENT)
