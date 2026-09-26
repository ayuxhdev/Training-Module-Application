from django.db.models import Count, Q
from django.utils import timezone

from assessments.models import AssessmentAttempt
from organization.models import Employee
from training.models import TrainingAssignment, TrainingVersion
from training.views import assignment_scope, can_manage_assignments


OPEN_STATUSES = (TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS)
ELIGIBLE_STATUSES = (*OPEN_STATUSES, TrainingAssignment.Status.COMPLETED)


def dashboard_role(user):
	if can_manage_assignments(user):
		return "company"
	if user.groups.filter(name="Manager").exists():
		return "manager" if Employee.objects.filter(user=user, is_active=True).exists() else None
	if user.groups.filter(name="Employee").exists():
		return "employee" if Employee.objects.filter(user=user, is_active=True).exists() else None
	return None


def assignment_queryset_for_user(user):
	return TrainingAssignment.objects.filter(employee__in=assignment_scope(user))


def employee_queryset_for_user(user):
	return assignment_scope(user)


def overdue_condition(as_of=None, prefix=""):
	return Q(**{
		f"{prefix}status__in": OPEN_STATUSES,
		f"{prefix}due_at__lt": as_of or timezone.now(),
	})


def overdue_assignments(queryset, as_of=None):
	return queryset.filter(overdue_condition(as_of))


def assignment_metrics(queryset, as_of=None):
	metrics = queryset.aggregate(
		total=Count("pk"),
		assigned=Count("pk", filter=Q(status=TrainingAssignment.Status.ASSIGNED)),
		in_progress=Count("pk", filter=Q(status=TrainingAssignment.Status.IN_PROGRESS)),
		completed=Count("pk", filter=Q(status=TrainingAssignment.Status.COMPLETED)),
		cancelled=Count("pk", filter=Q(status=TrainingAssignment.Status.CANCELLED)),
		overdue=Count("pk", filter=overdue_condition(as_of)),
		eligible=Count("pk", filter=Q(status__in=ELIGIBLE_STATUSES)),
	)
	metrics["completion_percent"] = round(
		metrics["completed"] * 100 / metrics["eligible"], 1
	) if metrics["eligible"] else 0
	return metrics


def incomplete_employee_rows(employees, as_of=None):
	return Employee.objects.filter(pk__in=employees.values("pk"), is_active=True).annotate(
		incomplete_assignment_count=Count(
			"training_assignments", filter=Q(training_assignments__status__in=OPEN_STATUSES),
		),
		overdue_assignment_count=Count(
			"training_assignments", filter=overdue_condition(as_of, "training_assignments__"),
		),
	).filter(incomplete_assignment_count__gt=0).order_by(
		"-overdue_assignment_count", "display_name", "pk",
	)[:25]


def published_training_count():
	return TrainingVersion.objects.filter(
		status=TrainingVersion.Status.PUBLISHED,
	).values("training_id").distinct().count()


def recent_attempts(assignments, failures_only=False, limit=10):
	attempts = AssessmentAttempt.objects.filter(
		assignment__in=assignments,
		status__in=(AssessmentAttempt.Status.SUBMITTED, AssessmentAttempt.Status.EXPIRED),
		submitted_at__isnull=False,
	)
	if failures_only:
		attempts = attempts.filter(passed=False)
	return attempts.select_related("assessment", "assignment__employee").order_by(
		"-submitted_at", "-pk",
	)[:limit]