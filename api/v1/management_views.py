from django.utils import timezone
from rest_framework import generics
from rest_framework.exceptions import PermissionDenied
from rest_framework.permissions import BasePermission, IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework_simplejwt.authentication import JWTAuthentication

from api.pagination import StandardResultsSetPagination
from api.permissions import IsMobileAccount
from certifications.models import Certificate
from organization.models import Department, Employee, JobRole
from organization.views import can_manage, employee_scope
from reports.queries import (
    assignment_metrics, assignment_queryset_for_user, dashboard_role,
    incomplete_employee_rows, published_training_count, recent_attempts,
)
from training.views import assignment_scope

from .management_serializers import (
    EmployeeDirectoryDetailSerializer, EmployeeDirectorySerializer,
    ManagementDashboardSerializer, OrganizationReferenceSerializer,
)


class HasOrganizationReadPermission(BasePermission):
    def has_permission(self, request, view):
        return request.user.has_perm(view.required_permission)


class OrganizationReadMixin:
    authentication_classes = [JWTAuthentication]
    permission_classes = [IsAuthenticated, IsMobileAccount, HasOrganizationReadPermission]
    pagination_class = StandardResultsSetPagination


class EmployeeDirectoryMixin(OrganizationReadMixin):
    required_permission = "organization.view_employee"

    def get_queryset(self):
        user = self.request.user
        employees = Employee.objects.select_related("department", "job_role", "reporting_manager", "user")
        if not can_manage(user):
            employees = employees.filter(pk__in=employee_scope(user).values("pk"))
        return employees.order_by("display_name", "pk")


class EmployeeDirectoryView(EmployeeDirectoryMixin, generics.ListAPIView):
    serializer_class = EmployeeDirectorySerializer


class EmployeeDirectoryDetailView(EmployeeDirectoryMixin, generics.RetrieveAPIView):
    serializer_class = EmployeeDirectoryDetailSerializer


class DepartmentReferenceView(OrganizationReadMixin, generics.ListAPIView):
    required_permission = "organization.view_department"
    serializer_class = OrganizationReferenceSerializer
    queryset = Department.objects.order_by("name", "pk")


class JobRoleReferenceView(OrganizationReadMixin, generics.ListAPIView):
    required_permission = "organization.view_jobrole"
    serializer_class = OrganizationReferenceSerializer
    queryset = JobRole.objects.order_by("name", "pk")


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
