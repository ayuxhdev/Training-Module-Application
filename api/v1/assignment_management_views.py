"""Mobile manual assignments reuse the website's scoped, transactional operation."""

from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import IntegrityError, transaction
from django.db.models import Q
from rest_framework import generics, serializers
from rest_framework.permissions import BasePermission, IsAuthenticated
from rest_framework.response import Response
from rest_framework_simplejwt.authentication import JWTAuthentication

from api.pagination import StandardResultsSetPagination
from api.permissions import IsMobileAccount
from audit.services import audit_snapshot, record_event
from training.forms import TrainingAssignmentForm
from training.models import TrainingAssignment, TrainingVersion
from training.permissions import can_assign_company_training, can_assign_team_training

from .assignment_management_serializers import (
    AssignableTrainingVersionSerializer, ManualAssignmentInputSerializer,
    ManualAssignmentSerializer, TrainingVersionSearchSerializer,
)


class HasAssignmentAuthority(BasePermission):
    def has_permission(self, request, view):
        return can_assign_company_training(request.user) or can_assign_team_training(request.user)


class AssignmentManagementMixin:
    authentication_classes = [JWTAuthentication]
    permission_classes = [IsAuthenticated, IsMobileAccount, HasAssignmentAuthority]


class AssignableTrainingVersionListView(AssignmentManagementMixin, generics.ListAPIView):
    http_method_names = ["get", "head", "options"]
    serializer_class = AssignableTrainingVersionSerializer
    pagination_class = StandardResultsSetPagination

    def get_queryset(self):
        search = TrainingVersionSearchSerializer(data={"search": self.request.query_params.get("search", "")})
        search.is_valid(raise_exception=True)
        versions = TrainingVersion.objects.filter(
            status=TrainingVersion.Status.PUBLISHED, training__is_active=True,
        ).select_related("training")
        value = search.validated_data.get("search")
        if value:
            versions = versions.filter(
                Q(title__icontains=value) | Q(training__catalog_title__icontains=value) | Q(training__code__icontains=value)
            )
        return versions.order_by("training__catalog_title", "training_id", "version_number", "pk")


def _form_error_fields(errors):
    names = {"employee": "employee_id", "training_version": "training_version_id", "__all__": "non_field_errors"}
    return {names.get(field, field): list(messages) for field, messages in errors.items()}


class ManualAssignmentCreateView(AssignmentManagementMixin, generics.GenericAPIView):
    http_method_names = ["post", "options"]
    serializer_class = ManualAssignmentInputSerializer

    def post(self, request, *args, **kwargs):
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        values = serializer.validated_data
        form = TrainingAssignmentForm(user=request.user, require_active_training=True, data={
            "employee": values["employee_id"], "training_version": values["training_version_id"],
            "due_date": values.get("due_date"),
        })
        if not form.is_valid():
            raise serializers.ValidationError(_form_error_fields(form.errors))
        try:
            with transaction.atomic():
                assignment = form.save(assigned_by=request.user)
                record_event(request.user, "training.trainingassignment.created", assignment,
                             after=audit_snapshot(assignment))
        except DjangoValidationError as exc:
            fields = exc.message_dict if hasattr(exc, "message_dict") else {"__all__": exc.messages}
            raise serializers.ValidationError(_form_error_fields(fields)) from exc
        except IntegrityError as exc:
            # Only the exact expected assignment uniqueness race is a user error.
            if (exc.args and exc.args[0] == 1062 and "unique_employee_version" in str(exc)
                    and TrainingAssignment.objects.filter(
                        employee_id=values["employee_id"], training_version_id=values["training_version_id"],
                    ).exists()):
                raise serializers.ValidationError({
                    "non_field_errors": ["This employee already has an assignment for that training version."],
                }) from exc
            raise
        return Response(ManualAssignmentSerializer(assignment).data, status=201)
