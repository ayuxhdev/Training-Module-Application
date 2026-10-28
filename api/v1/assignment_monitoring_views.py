"""Permission-scoped assignment monitoring, separate from personal learning."""

from django.shortcuts import get_object_or_404
from rest_framework import generics
from rest_framework.permissions import BasePermission, IsAuthenticated
from rest_framework_simplejwt.authentication import JWTAuthentication

from api.pagination import StandardResultsSetPagination
from api.permissions import IsMobileAccount
from reports.queries import dashboard_role
from training.models import TrainingAssignment
from training.views import assignment_scope

from .assignment_monitoring_serializers import ManagedAssignmentSerializer
from .assignment_queries import with_assignment_summary


class HasAssignmentMonitoringAuthority(BasePermission):
    def has_permission(self, request, view):
        # Existing company/team reporting authority, not directory visibility or
        # the separate permission to create team assignments.
        return dashboard_role(request.user) in ("company", "manager")


class EmployeeAssignmentListView(generics.ListAPIView):
    authentication_classes = [JWTAuthentication]
    permission_classes = [IsAuthenticated, IsMobileAccount, HasAssignmentMonitoringAuthority]
    pagination_class = StandardResultsSetPagination
    serializer_class = ManagedAssignmentSerializer
    http_method_names = ["get", "head", "options"]

    def get_queryset(self):
        employees = assignment_scope(self.request.user)
        if dashboard_role(self.request.user) != "company":
            employees = employees.filter(is_active=True).exclude(user=self.request.user)
        # Resolve within monitoring scope before pagination, including for empty
        # lists. Foreign/inactive/self and nonexistent targets share a 404.
        employee = get_object_or_404(employees.only("pk"), pk=self.kwargs["employee_id"])
        assignments = TrainingAssignment.objects.filter(employee_id=employee.pk).select_related("training_version")
        return with_assignment_summary(assignments).order_by("-assigned_at", "-pk")
