import logging

from django.db import DatabaseError, connection
from django.http import JsonResponse
from django.views.decorators.http import require_safe
from rest_framework.authentication import SessionAuthentication
from rest_framework.permissions import BasePermission
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework_simplejwt.authentication import JWTAuthentication


@require_safe
def live(request):
    response = JsonResponse({"status": "ok"})
    response["Cache-Control"] = "no-store"
    return response


class IsActiveSuperuser(BasePermission):
    def has_permission(self, request, view):
        return bool(request.user and request.user.is_authenticated and request.user.is_active and request.user.is_superuser)


class ReadinessView(APIView):
    authentication_classes = [JWTAuthentication, SessionAuthentication]
    permission_classes = [IsActiveSuperuser]
    http_method_names = ["get", "head", "options"]

    def unavailable(self):
        logging.getLogger("operations").warning("readiness failed", extra={"event": "readiness_failed"}, exc_info=True)
        return Response({"status": "unavailable"}, status=503)

    def handle_exception(self, exc):
        # JWT/session identity lookup itself needs the database.
        if isinstance(exc, DatabaseError):
            return self.unavailable()
        return super().handle_exception(exc)

    def finalize_response(self, request, response, *args, **kwargs):
        response = super().finalize_response(request, response, *args, **kwargs)
        response["Cache-Control"] = "no-store"
        return response

    def get(self, request):
        try:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
                ready = cursor.fetchone() == (1,)
        except DatabaseError:
            return self.unavailable()
        response = Response({"status": "ok" if ready else "unavailable"}, status=200 if ready else 503)
        response["Cache-Control"] = "no-store"
        return response
