from rest_framework.exceptions import NotFound
from rest_framework.response import Response
from rest_framework.views import APIView

from api.permissions import IsActiveEmployee


class APIStatusView(APIView):
    """
    Minimal endpoint to prove the API foundation works.
    Returns basic connection details and verifies authentication and active employee status.
    """
    permission_classes = [IsActiveEmployee]

    def get(self, request):
        return Response({
            "status": "ok",
            "version": "v1",
            "user": request.user.username,
        })


class APINotFoundView(APIView):
    """
    Fallback view for unmatched /api/v1/ routes.
    Bypasses authentication/permissions so nonexistent routes return
    a 404 error envelope rather than an authentication challenge (401/403).
    """
    authentication_classes = []
    permission_classes = []

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        raise NotFound()

