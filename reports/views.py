from django.contrib.auth.decorators import login_required
from django.core.exceptions import PermissionDenied
from django.db.models import BooleanField, Case, Value, When
from django.shortcuts import render
from django.utils import timezone

from certifications.models import Certificate
from organization.models import Department, Employee
from training.models import TrainingAssignment

from .forms import AssignmentReportFilterForm
from .queries import (
	assignment_metrics,
	assignment_queryset_for_user,
	dashboard_role,
	employee_queryset_for_user,
	incomplete_employee_rows,
	overdue_assignments,
	overdue_condition,
	published_training_count,
	recent_attempts,
)


def _assignment_rows(queryset):
	return queryset.select_related(
		"employee", "department_at_assignment", "job_role_at_assignment",
		"training_version__training", "certificate",
	)


@login_required
def dashboard(request):
	role = dashboard_role(request.user)
	if role is None:
		return render(request, "reports/dashboard.html", {"role": "unavailable"})

	now = timezone.now()
	assignments = assignment_queryset_for_user(request.user)
	context = {
		"role": role,
		"metrics": assignment_metrics(assignments, now),
		"can_view_report": role in ("company", "manager"),
	}

	if role == "company":
		context.update({
			"active_employee_count": Employee.objects.filter(is_active=True).count(),
			"department_count": Department.objects.count(),
			"published_training_count": published_training_count(),
			"certificates_issued": Certificate.objects.count(),
			"recent_attempts": recent_attempts(assignments, failures_only=True),
		})
	elif role == "manager":
		employees = employee_queryset_for_user(request.user)
		context.update({
			"employees_in_scope": employees.filter(is_active=True).count(),
			"incomplete_employees": incomplete_employee_rows(employees, now),
			"certificates_issued": Certificate.objects.filter(assignment__in=assignments).count(),
			"recent_attempts": recent_attempts(assignments, failures_only=True),
		})
	else:
		context.update({
			"assigned_training": _assignment_rows(
				assignments.filter(status=TrainingAssignment.Status.ASSIGNED).order_by("due_at", "pk")[:10]
			),
			"in_progress_training": _assignment_rows(
				assignments.filter(status=TrainingAssignment.Status.IN_PROGRESS).order_by("due_at", "pk")[:10]
			),
			"completed_training": _assignment_rows(
				assignments.filter(status=TrainingAssignment.Status.COMPLETED).order_by("-completed_at", "-pk")[:10]
			),
			"overdue_assignments": _assignment_rows(
				overdue_assignments(assignments, now).order_by("due_at", "pk")[:10]
			),
			"certificates": Certificate.objects.filter(assignment__in=assignments)
				.select_related("training_version").order_by("-issued_at", "-pk")[:10],
			"recent_attempts": recent_attempts(assignments),
		})

	return render(request, "reports/dashboard.html", context)


@login_required
def assignment_report(request):
	role = dashboard_role(request.user)
	if role not in ("company", "manager"):
		raise PermissionDenied

	base_queryset = assignment_queryset_for_user(request.user)
	now = timezone.now()
	filter_form = AssignmentReportFilterForm(
		request.GET,
		assignment_queryset=base_queryset,
	)
	assignments = base_queryset
	valid = filter_form.is_valid()
	if valid:
		filters = filter_form.cleaned_data
		if filters["status"]:
			assignments = assignments.filter(status=filters["status"])
		if filters["department"]:
			assignments = assignments.filter(department_at_assignment=filters["department"])
		if filters["job_role"]:
			assignments = assignments.filter(job_role_at_assignment=filters["job_role"])
		if filters["training"]:
			assignments = assignments.filter(training_version__training=filters["training"])
		if filters["training_version"]:
			assignments = assignments.filter(training_version=filters["training_version"])
		if filters["overdue_only"]:
			assignments = overdue_assignments(assignments, now)
	else:
		assignments = assignments.none()

	assignments = _assignment_rows(assignments).annotate(
		is_overdue=Case(
			When(overdue_condition(now), then=Value(True)),
			default=Value(False),
			output_field=BooleanField(),
		),
	).order_by("-assigned_at", "pk")
	return render(request, "reports/assignment_report.html", {
		"filter_form": filter_form,
		"assignments": assignments,
		"role": role,
	}, status=200 if valid else 400)
