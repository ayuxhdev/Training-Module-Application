"""Independent requirement permissions; global assignment authority for role batches."""

from django.core.exceptions import PermissionDenied, ValidationError as DjangoValidationError
from django.db import IntegrityError, OperationalError
from django.db.models import Q
from rest_framework import generics
from rest_framework.exceptions import APIException, PermissionDenied as APIPermissionDenied
from rest_framework.parsers import JSONParser
from rest_framework.response import Response

from training.models import RoleTrainingRequirement, TrainingAssignment

from . import role_requirement_services as services
from .role_requirement_serializers import (
    RequirementCreateSerializer, RequirementQuerySerializer, RequirementSerializer,
    RequirementUpdateSerializer, RoleBatchInputSerializer,
)
from .training_management_views import TrainingManagementMixin, _is_unique_constraint_conflict, _validation_error


class RequirementConflict(APIException):
    status_code = 409
    default_code = "conflict"
    default_detail = "Another operation conflicts with this request. Refresh before trying again."


def write_operation(operation):
    try:
        return operation()
    except DjangoValidationError as exc:
        raise _validation_error(exc) from exc
    except PermissionDenied as exc:
        raise APIPermissionDenied() from exc
    except IntegrityError as exc:
        if (_is_unique_constraint_conflict(exc, RoleTrainingRequirement, "unique_role_training_version")
                or _is_unique_constraint_conflict(exc, TrainingAssignment, "unique_employee_version")):
            raise RequirementConflict() from exc
        raise
    except OperationalError as exc:
        if exc.args and exc.args[0] in (1205, 1213):
            raise RequirementConflict() from exc
        raise


def requirement_queryset():
    return RoleTrainingRequirement.objects.select_related("job_role", "training_version__training")


class RequirementListView(TrainingManagementMixin, generics.ListAPIView):
    serializer_class = RequirementSerializer
    parser_classes = [JSONParser]
    method_permissions = {method: "training.view_roletrainingrequirement" for method in ("GET", "HEAD", "OPTIONS")}
    method_permissions["POST"] = "training.add_roletrainingrequirement"
    http_method_names = ["get", "head", "options", "post"]

    def get_queryset(self):
        # Avoid QueryDict checkbox defaults: omitted is_active means no filter.
        query = RequirementQuerySerializer(data=dict(self.request.query_params.items()))
        query.is_valid(raise_exception=True)
        values = query.validated_data
        qs = requirement_queryset()
        for field in ("job_role_id", "training_version_id", "is_active"):
            if field in values:
                qs = qs.filter(**{field: values[field]})
        if values.get("search"):
            value = values["search"]
            qs = qs.filter(Q(job_role__code__icontains=value) | Q(job_role__name__icontains=value)
                           | Q(training_version__training__catalog_title__icontains=value)
                           | Q(training_version__title__icontains=value))
        return qs.order_by("job_role__name", "training_version__training__catalog_title", "training_version__version_number", "pk")

    def post(self, request):
        serializer = RequirementCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        instance = write_operation(lambda: services.save_requirement(request.user, serializer.validated_data))
        return Response(RequirementSerializer(instance).data, status=201)


class RequirementDetailView(TrainingManagementMixin, generics.RetrieveAPIView):
    serializer_class = RequirementSerializer
    parser_classes = [JSONParser]
    queryset = requirement_queryset()
    method_permissions = {method: "training.view_roletrainingrequirement" for method in ("GET", "HEAD", "OPTIONS")}
    method_permissions["PATCH"] = "training.change_roletrainingrequirement"
    http_method_names = ["get", "head", "options", "patch"]

    def patch(self, request, pk):
        serializer = RequirementUpdateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        instance = write_operation(lambda: services.save_requirement(request.user, serializer.validated_data, pk))
        return Response(RequirementSerializer(instance).data)


class RoleBatchCreateView(TrainingManagementMixin, generics.GenericAPIView):
    serializer_class = RoleBatchInputSerializer
    parser_classes = [JSONParser]
    method_permissions = {method: "training.add_trainingassignment" for method in ("POST", "OPTIONS")}
    http_method_names = ["post", "options"]

    def post(self, request, pk):
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        result = write_operation(lambda: services.execute_role_batch(request.user, pk))
        return Response(result)
