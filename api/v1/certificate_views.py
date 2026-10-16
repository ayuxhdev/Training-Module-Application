from django.shortcuts import get_object_or_404
from rest_framework import generics
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework_simplejwt.authentication import JWTAuthentication

from api.permissions import IsActiveEmployee
from certifications.models import Certificate

from .certificate_serializers import CertificateDetailSerializer, CertificateListSerializer
from .learning_views import JWTActiveEmployeeAPIView


class CertificateListView(generics.ListAPIView):
    """Paginated read-only list of the authenticated employee's own certificates."""

    authentication_classes = [JWTAuthentication]
    permission_classes = [IsAuthenticated, IsActiveEmployee]
    serializer_class = CertificateListSerializer

    def get_queryset(self):
        return (
            Certificate.objects.filter(
                assignment__employee=self.request.user.employee,
            )
            .order_by("-issued_at", "-pk")
        )


class CertificateDetailView(JWTActiveEmployeeAPIView):
    """Read-only detail for one certificate strictly owned by the authenticated employee."""

    def get(self, request, certificate_id):
        certificate = get_object_or_404(
            Certificate.objects.filter(
                assignment__employee=request.user.employee,
            ).select_related("assignment"),
            pk=certificate_id,
        )
        serializer = CertificateDetailSerializer(certificate)
        return Response(serializer.data)
