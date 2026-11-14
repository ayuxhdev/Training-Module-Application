"""Reuse the authoritative report scope and overdue predicate before pagination."""

from django.db.models import BooleanField, Case, Value, When
from django.utils import timezone

from reports.forms import AssignmentReportFilterForm
from reports.queries import assignment_queryset_for_user, overdue_assignments, overdue_condition


def assignment_report_queryset(user, values):
    assignments = assignment_queryset_for_user(user)
    for parameter, field in (
        ("status", "status"), ("department", "department_at_assignment_id"),
        ("job_role", "job_role_at_assignment_id"),
        ("training", "training_version__training_id"),
        ("training_version", "training_version_id"),
    ):
        if parameter in values:
            assignments = assignments.filter(**{field: values[parameter]})
    now = timezone.now()
    if values.get("overdue_only"):
        assignments = overdue_assignments(assignments, now)
    return assignments.select_related(
        "employee", "department_at_assignment", "job_role_at_assignment",
        "training_version__training", "certificate",
    ).annotate(is_overdue=Case(
        When(overdue_condition(now), then=Value(True)),
        default=Value(False), output_field=BooleanField(),
    )).order_by("-assigned_at", "pk")


def assignment_report_options(user):
    form = AssignmentReportFilterForm(assignment_queryset=assignment_queryset_for_user(user))
    return {
        "departments": form.fields["department"].queryset,
        "job_roles": form.fields["job_role"].queryset,
        "trainings": form.fields["training"].queryset,
        "training_versions": form.fields["training_version"].queryset.order_by(
            "training__catalog_title", "version_number", "pk",
        ),
    }
