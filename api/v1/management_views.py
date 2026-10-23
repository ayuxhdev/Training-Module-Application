from collections.abc import Mapping

from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import IntegrityError, transaction
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import generics, serializers
from rest_framework.exceptions import PermissionDenied
from rest_framework.permissions import BasePermission, IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework_simplejwt.authentication import JWTAuthentication

from api.pagination import StandardResultsSetPagination
from api.permissions import IsMobileAccount
from audit.services import audit_snapshot, record_event
from certifications.models import Certificate
from organization.forms import may_manage_linked_user
from organization.models import Department, Employee, JobRole
from organization.views import can_manage, employee_scope
from reports.queries import (
    assignment_metrics, assignment_queryset_for_user, dashboard_role,
    incomplete_employee_rows, published_training_count, recent_attempts,
)
from training.views import assignment_scope

from .management_serializers import (
    DepartmentWriteSerializer, EmployeeCreateSerializer, EmployeeDirectoryDetailSerializer, EmployeeDirectorySerializer,
    EmployeeProfileWriteSerializer, JobRoleWriteSerializer, ManagementDashboardSerializer, OrganizationReferenceSerializer,
)


class HasOrganizationPermission(BasePermission):
    def has_permission(self, request, view):
        return request.user.has_perm(view.required_permission)


class OrganizationReadMixin:
    authentication_classes = [JWTAuthentication]
    permission_classes = [IsAuthenticated, IsMobileAccount, HasOrganizationPermission]
    pagination_class = StandardResultsSetPagination


class EmployeeDirectoryMixin(OrganizationReadMixin):
    required_permission = "organization.view_employee"

    def get_queryset(self):
        user = self.request.user
        employees = Employee.objects.select_related("department", "job_role", "reporting_manager", "user")
        if not can_manage(user):
            employees = employees.filter(pk__in=employee_scope(user).values("pk"))
        return employees.order_by("display_name", "pk")


class EmployeeDirectoryView(EmployeeDirectoryMixin, generics.ListCreateAPIView):
    http_method_names = ["get", "post", "head", "options"]
    serializer_class = EmployeeDirectorySerializer

    @property
    def required_permission(self):
        return "organization.add_employee" if self.request.method == "POST" else "organization.view_employee"

    def get_serializer_class(self):
        return EmployeeCreateSerializer if self.request.method == "POST" else self.serializer_class

    def create(self, request, *args, **kwargs):
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            with transaction.atomic():
                user = serializer.validated_data.get("user")
                if user is not None:
                    if serializer.validated_data.get("reporting_manager") is not None:
                        # Match hierarchy/deactivation ordering: Employee locks before User.
                        list(Employee.objects.order_by("pk").select_for_update().values_list("pk", flat=True))
                    user = get_user_model().objects.select_for_update().filter(pk=user.pk).first()
                    if user is None:
                        raise serializers.ValidationError({"user": ["This login account is no longer available."]})
                    if not may_manage_linked_user(request.user, user):
                        raise serializers.ValidationError({"user": ["You cannot link a privileged login account."]})
                    serializer.validated_data["user"] = user
                employee = serializer.save()  # Reuses model validation, uniqueness and hierarchy safeguards.
                record_event(request.user, "organization.employee.created", employee,
                    before={}, after={**audit_snapshot(employee), "changed_fields": list(serializer.validated_data)})
            return Response(EmployeeDirectoryDetailSerializer(employee).data, status=201)
        except DjangoValidationError as exc:
            fields = exc.message_dict if hasattr(exc, "message_dict") else {"non_field_errors": exc.messages}
            raise serializers.ValidationError({"non_field_errors" if key == "__all__" else key: value
                                               for key, value in fields.items()}) from exc
        except IntegrityError as exc:
            # Translate only verified identity/link collisions, never unrelated failures.
            conflicts = {}
            if exc.args and exc.args[0] == 1062:
                for field, message in (
                    ("employee_code", "This employee code is already in use."),
                    ("user", "This login account is already linked to an employee."),
                ):
                    value = serializer.validated_data.get(field)
                    if value is not None and Employee.objects.filter(**{field: value}).exists():
                        conflicts[field] = [message]
            if conflicts:
                raise serializers.ValidationError(conflicts) from exc
            raise


class EmployeeDirectoryDetailView(EmployeeDirectoryMixin, generics.RetrieveUpdateAPIView):
    http_method_names = ["get", "patch", "head", "options"]
    serializer_class = EmployeeDirectoryDetailSerializer

    @property
    def required_permission(self):
        return "organization.change_employee" if self.request.method == "PATCH" else "organization.view_employee"

    def get_serializer_class(self):
        return EmployeeProfileWriteSerializer if self.request.method == "PATCH" else self.serializer_class

    def get_queryset(self):
        queryset = super().get_queryset()
        # Lock only the Employee, not the joined User or reference tables.
        return queryset.select_related(None).select_for_update() if self.request.method == "PATCH" else queryset

    def partial_update(self, request, *args, **kwargs):
        data = request.data
        try:
            with transaction.atomic():
                if isinstance(data, Mapping) and data.get("reporting_manager") is not None:
                    # Employee.lock_parents() locks the hierarchy before the target.
                    # Use that same order before taking our own update lock.
                    list(Employee.objects.order_by("pk").select_for_update().values_list("pk", flat=True))
                employee = self.get_object()
                serializer = self.get_serializer(employee, data=data, partial=True)
                serializer.is_valid(raise_exception=True)
                changed = [field for field, value in serializer.validated_data.items()
                           if getattr(employee, field) != value]
                if changed:
                    before = audit_snapshot(employee)
                    employee = serializer.save()  # Includes the existing model full_clean()/cycle checks.
                    record_event(request.user, "organization.employee.updated", employee,
                        before=before, after={**audit_snapshot(employee), "changed_fields": changed})
                return Response(EmployeeDirectoryDetailSerializer(employee).data)
        except DjangoValidationError as exc:
            fields = exc.message_dict if hasattr(exc, "message_dict") else {"non_field_errors": exc.messages}
            raise serializers.ValidationError({"non_field_errors" if key == "__all__" else key: value
                                               for key, value in fields.items()}) from exc


class OrganizationReferenceMixin(OrganizationReadMixin):
    @property
    def required_permission(self):
        action = {"POST": "add", "PATCH": "change"}.get(self.request.method, "view")
        return f"organization.{action}_{self.queryset.model._meta.model_name}"

    def get_serializer_class(self):
        return self.write_serializer_class if self.request.method in ("POST", "PATCH") else OrganizationReferenceSerializer

    def perform_create(self, serializer):
        self._save_reference(serializer)

    def perform_update(self, serializer):
        self._save_reference(serializer)

    def _save_reference(self, serializer):
        model = self.queryset.model
        creating = serializer.instance is None
        try:
            with transaction.atomic():
                if not creating:
                    # Apply PATCH to the latest locked record, preserving unrelated
                    # attributes and taking the audit snapshot before any changes.
                    serializer.instance = get_object_or_404(
                        self.get_queryset().select_for_update(), pk=serializer.instance.pk,
                    )
                before = {} if creating else audit_snapshot(serializer.instance)
                changed = [field for field, value in serializer.validated_data.items()
                           if creating or getattr(serializer.instance, field) != value]
                instance = serializer.save()  # ValidatedModel.save() also calls full_clean().
                if creating or changed:
                    verb = "created" if creating else "updated"
                    record_event(self.request.user, f"{instance._meta.label_lower}.{verb}", instance,
                        before=before, after={**audit_snapshot(instance), "changed_fields": changed})
        except DjangoValidationError as exc:
            fields = exc.message_dict if hasattr(exc, "message_dict") else {"non_field_errors": exc.messages}
            raise serializers.ValidationError({"non_field_errors" if key == "__all__" else key: value
                                               for key, value in fields.items()}) from exc
        except IntegrityError as exc:
            # Only map an actual code collision (including a concurrent insert).
            # Other integrity failures must remain visible as operational errors.
            code = serializer.validated_data.get("code")
            conflicts = model.objects.filter(code=code)
            if serializer.instance is not None:
                conflicts = conflicts.exclude(pk=serializer.instance.pk)
            if exc.args and exc.args[0] == 1062 and code is not None and conflicts.exists():
                raise serializers.ValidationError({"code": ["This code is already in use."]}) from exc
            raise


class DepartmentReferenceView(OrganizationReferenceMixin, generics.ListCreateAPIView):
    http_method_names = ["get", "post", "head", "options"]
    write_serializer_class = DepartmentWriteSerializer
    queryset = Department.objects.order_by("name", "pk")


class JobRoleReferenceView(OrganizationReferenceMixin, generics.ListCreateAPIView):
    http_method_names = ["get", "post", "head", "options"]
    write_serializer_class = JobRoleWriteSerializer
    queryset = JobRole.objects.order_by("name", "pk")


class DepartmentReferenceUpdateView(OrganizationReferenceMixin, generics.UpdateAPIView):
    http_method_names = ["patch", "options"]
    write_serializer_class = DepartmentWriteSerializer
    queryset = Department.objects.all()


class JobRoleReferenceUpdateView(OrganizationReferenceMixin, generics.UpdateAPIView):
    http_method_names = ["patch", "options"]
    write_serializer_class = JobRoleWriteSerializer
    queryset = JobRole.objects.all()


class ManagementDashboardView(APIView):
    authentication_classes = [JWTAuthentication]
    permission_classes = [IsAuthenticated, IsMobileAccount]

    def get(self, request):
        # Match the portal: company permissions take precedence over Manager membership.
        role = dashboard_role(request.user)
        if role not in ("company", "manager"):
            raise PermissionDenied
        now = timezone.now()
        assignments = assignment_queryset_for_user(request.user)
        payload = {
            "scope": "company" if role == "company" else "team",
            "metrics": assignment_metrics(assignments, now),
            "recent_failures": recent_attempts(assignments, failures_only=True),
            "incomplete_employees": [],
        }
        if role == "company":
            payload["summary"] = {
                "active_employee_count": Employee.objects.filter(is_active=True).count(),
                "department_count": Department.objects.count(),
                "published_training_count": published_training_count(),
                "certificates_issued": Certificate.objects.count(),
            }
        else:
            employees = assignment_scope(request.user)
            payload["summary"] = {
                "employees_in_scope": employees.filter(is_active=True).count(),
                "certificates_issued": Certificate.objects.filter(assignment__in=assignments).count(),
            }
            payload["incomplete_employees"] = incomplete_employee_rows(employees, now)
        return Response(ManagementDashboardSerializer(payload).data)
