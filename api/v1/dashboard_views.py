from django.utils import timezone
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from api.permissions import IsActiveEmployee
from certifications.models import Certificate
from reports.queries import assignment_metrics
from training.models import TrainingAssignment

from .dashboard_serializers import EmployeeDashboardSerializer


class EmployeeDashboardView(APIView):
    permission_classes = [IsAuthenticated, IsActiveEmployee]

    def get(self, request, *args, **kwargs):
        employee = request.user.employee
        now = timezone.now()

        # Base assignment queryset strictly scoped to authenticated employee
        base_assignments = TrainingAssignment.objects.filter(employee=employee)

        # Authoritative metrics calculation reusing reports.queries.assignment_metrics
        metrics_data = assignment_metrics(base_assignments, as_of=now)
        metrics_data["certificates_count"] = Certificate.objects.filter(
            assignment__employee=employee,
            revoked_at__isnull=True,
        ).count()

        # Up to 10 actionable assignments (ASSIGNED or IN_PROGRESS), ordered by due_at asc, pk asc
        action_required = (
            base_assignments.filter(
                status__in=[
                    TrainingAssignment.Status.ASSIGNED,
                    TrainingAssignment.Status.IN_PROGRESS,
                ]
            )
            .select_related("training_version__training")
            .order_by("due_at", "pk")[:10]
        )

        # Up to 5 recent active certificates (revoked_at IS NULL), ordered by issued_at desc, pk desc
        recent_certificates = (
            Certificate.objects.filter(
                assignment__employee=employee,
                revoked_at__isnull=True,
            )
            .order_by("-issued_at", "-pk")[:5]
        )

        payload = {
            "metrics": metrics_data,
            "action_required": action_required,
            "recent_certificates": recent_certificates,
        }

        serializer = EmployeeDashboardSerializer(payload, context={"now": now})
        return Response(serializer.data, status=status.HTTP_200_OK)

