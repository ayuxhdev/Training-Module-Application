import csv
import unicodedata

from django.contrib.auth.decorators import login_required
from django.core.exceptions import PermissionDenied
from django.core.paginator import Paginator
from django.db.models import BooleanField, Case, Value, When
from django.http import StreamingHttpResponse
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.http import require_GET

from certifications.models import Certificate
from organization.models import Department, Employee
from training.models import TrainingAssignment
from training.views import assignment_scope

from .forms import AssignmentReportFilterForm
from .queries import (
	assignment_metrics,
	assignment_queryset_for_user,
	dashboard_role,
	incomplete_employee_rows,
	overdue_assignments,
	overdue_condition,
	published_training_count,
	recent_attempts,
)

ASSIGNMENT_REPORT_PAGE_SIZE = 50
ASSIGNMENT_REPORT_EXPORT_CHUNK_SIZE = 1000
ASSIGNMENT_REPORT_EXPORT_MAX_ROWS = 10000
ASSIGNMENT_REPORT_CSV_HEADERS = (
	"Employee",
	"Department",
	"Job role",
	"Training",
	"Version",
	"Assigned",
	"Deadline",
	"Status",
	"Overdue",
	"Completed",
	"Certificate",
)


def _assignment_rows(queryset, as_of=None):
	rows = queryset.select_related(
		"employee", "department_at_assignment", "job_role_at_assignment",
		"training_version__training", "certificate",
	)
	if as_of is None:
		return rows
	return rows.annotate(
		is_overdue=Case(
			When(overdue_condition(as_of), then=Value(True)),
			default=Value(False),
			output_field=BooleanField(),
		),
	)


def _safe_csv_cell(value):
	text = "" if value is None else str(value)
	first_value = 0
	while first_value < len(text) and (
		text[first_value].isspace()
		or unicodedata.category(text[first_value]).startswith("C")
	):
		first_value += 1
	if first_value < len(text) and text[first_value] in "=+-@":
		return f"'{text}"
	return text


class _CsvEcho:
	def write(self, value):
		return value


def _assignment_report_csv_stream(assignments):
	writer = csv.writer(_CsvEcho(), lineterminator="\r\n")
	yield writer.writerow(ASSIGNMENT_REPORT_CSV_HEADERS)
	for assignment in assignments.iterator(chunk_size=ASSIGNMENT_REPORT_EXPORT_CHUNK_SIZE):
		try:
			certificate = assignment.certificate
		except Certificate.DoesNotExist:
			certificate = None
		certificate_status = (
			"Revoked" if certificate.revoked_at else "Issued"
		) if certificate else "Not issued"
		yield writer.writerow([
			_safe_csv_cell(assignment.employee.display_name),
			_safe_csv_cell(assignment.department_at_assignment.name),
			_safe_csv_cell(assignment.job_role_at_assignment.name),
			_safe_csv_cell(assignment.training_version.training.catalog_title),
			_safe_csv_cell(
				f"{assignment.training_version.title} · Version "
				f"{assignment.training_version.version_number}"
			),
			_safe_csv_cell(assignment.assigned_at.isoformat()),
			_safe_csv_cell(assignment.due_at.isoformat() if assignment.due_at else ""),
			_safe_csv_cell(assignment.get_status_display()),
			"Yes" if assignment.is_overdue else "No",
			_safe_csv_cell(assignment.completed_at.isoformat() if assignment.completed_at else ""),
			_safe_csv_cell(certificate_status),
		])


def _filtered_assignment_report(request):
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
	return role, filter_form, assignments, valid


def _assignment_report_context(request, role, filter_form, assignments):
	paginator = Paginator(assignments, ASSIGNMENT_REPORT_PAGE_SIZE)
	page_obj = paginator.get_page(request.GET.get("page"))
	page_query = request.GET.copy()
	page_query.pop("page", None)
	return {
		"filter_form": filter_form,
		"assignments": page_obj.object_list,
		"page_obj": page_obj,
		"paginator": paginator,
		"page_query": page_query.urlencode(),
		"role": role,
	}


def _bounded_assignment_export(assignments):
	# Fix the authorized selection before the response defers row iteration.
	assignment_ids = list(assignments.values_list("pk", flat=True)[
		:ASSIGNMENT_REPORT_EXPORT_MAX_ROWS + 1
	])
	if len(assignment_ids) > ASSIGNMENT_REPORT_EXPORT_MAX_ROWS:
		return None
	return assignments.filter(pk__in=assignment_ids)


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
		employees = assignment_scope(request.user)
		context.update({
			"employees_in_scope": employees.filter(is_active=True).count(),
			"incomplete_employees": incomplete_employee_rows(employees, now),
			"certificates_issued": Certificate.objects.filter(assignment__in=assignments).count(),
			"recent_attempts": recent_attempts(assignments, failures_only=True),
		})
	else:
		context.update({
			"assigned_training": _assignment_rows(
				assignments.filter(status=TrainingAssignment.Status.ASSIGNED).order_by("due_at", "pk")[:10], now
			),
			"in_progress_training": _assignment_rows(
				assignments.filter(status=TrainingAssignment.Status.IN_PROGRESS).order_by("due_at", "pk")[:10], now
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
	role, filter_form, assignments, valid = _filtered_assignment_report(request)
	return render(request, "reports/assignment_report.html", {
		**_assignment_report_context(request, role, filter_form, assignments),
	}, status=200 if valid else 400)


@login_required
@require_GET
def assignment_report_export(request):
	role, filter_form, assignments, valid = _filtered_assignment_report(request)
	if not valid:
		return render(
			request,
			"reports/assignment_report.html",
			_assignment_report_context(request, role, filter_form, assignments),
			status=400,
		)

	export_assignments = _bounded_assignment_export(assignments)
	if export_assignments is None:
		context = _assignment_report_context(request, role, filter_form, assignments)
		context["export_limit_exceeded"] = True
		context["export_max_rows"] = ASSIGNMENT_REPORT_EXPORT_MAX_ROWS
		return render(
			request,
			"reports/assignment_report.html",
			context,
			status=413,
		)

	response = StreamingHttpResponse(
		_assignment_report_csv_stream(export_assignments),
		content_type="text/csv; charset=utf-8",
	)
	response["Content-Disposition"] = (
		f'attachment; filename="assignment-report-{timezone.localdate().isoformat()}.csv"'
	)
	response["Cache-Control"] = "private, no-store"
	response["X-Content-Type-Options"] = "nosniff"
	return response
