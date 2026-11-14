"""Independent, company-wide effective permissions matching certificate website management."""

from django.core.exceptions import PermissionDenied, ValidationError
from django.db import OperationalError
from django.db.models import Q
from rest_framework import generics
from rest_framework.exceptions import APIException, PermissionDenied as APIPermissionDenied
from rest_framework.parsers import JSONParser
from rest_framework.response import Response

from certifications.models import Certificate

from . import certificate_management_services as services
from .certificate_management_serializers import (
    CertificateManagementDetailSerializer, CertificateManagementQuerySerializer,
    CertificateManagementSerializer, CertificateRevocationResultSerializer,
    CertificateRevocationSerializer,
)
from .training_management_views import TrainingManagementMixin, _validation_error


class CertificateRevocationConflict(APIException):
    status_code = 409
    default_code = "conflict"
    default_detail = "This certificate is already revoked."


class CertificateManagementListView(TrainingManagementMixin, generics.ListAPIView):
    serializer_class = CertificateManagementSerializer
    http_method_names = ["get", "head", "options"]
    method_permissions = {method: services.VIEW_PERMISSION for method in ("GET", "HEAD", "OPTIONS")}

    def get_queryset(self):
        query = CertificateManagementQuerySerializer(data=dict(self.request.query_params.items()))
        query.is_valid(raise_exception=True)
        values = query.validated_data
        certificates = Certificate.objects.all()
        if "is_revoked" in values:
            certificates = certificates.filter(revoked_at__isnull=not values["is_revoked"])
        if values.get("search"):
            search = values["search"]
            certificates = certificates.filter(
                Q(certificate_number__icontains=search) | Q(employee_code_snapshot__icontains=search)
                | Q(employee_name_snapshot__icontains=search) | Q(training_title_snapshot__icontains=search)
            )
        return certificates.order_by("-issued_at", "pk")


class CertificateManagementDetailView(TrainingManagementMixin, generics.RetrieveAPIView):
    serializer_class = CertificateManagementDetailSerializer
    queryset = Certificate.objects.all()
    http_method_names = ["get", "head", "options"]
    method_permissions = {method: services.VIEW_PERMISSION for method in ("GET", "HEAD", "OPTIONS")}


class CertificateRevocationView(TrainingManagementMixin, generics.GenericAPIView):
    serializer_class = CertificateRevocationSerializer
    parser_classes = [JSONParser]
    http_method_names = ["post", "options"]
    method_permissions = {method: services.CHANGE_PERMISSION for method in ("POST", "OPTIONS")}

    def post(self, request, pk):
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            certificate = services.revoke_certificate(request.user, pk, serializer.validated_data["reason"])
        except services.CertificateAlreadyRevoked as exc:
            raise CertificateRevocationConflict() from exc
        except PermissionDenied as exc:
            raise APIPermissionDenied() from exc
        except ValidationError as exc:
            raise _validation_error(exc) from exc
        except OperationalError as exc:
            if exc.args and exc.args[0] in (1205, 1213):
                raise CertificateRevocationConflict(
                    "Another operation conflicts with this request. Refresh the certificate before retrying.",
                ) from exc
            raise
        # Change-only accounts do not gain the independent global read contract.
        return Response(CertificateRevocationResultSerializer(certificate).data)
