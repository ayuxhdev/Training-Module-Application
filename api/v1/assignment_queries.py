"""Shared authoritative lesson counts and overdue state for assignment lists."""

from django.db.models import BooleanField, Case, Count, Q, Value, When
from django.utils import timezone

from reports.queries import overdue_condition


def with_assignment_summary(queryset, *, as_of=None):
    return queryset.annotate(
        is_overdue=Case(
            When(overdue_condition(as_of or timezone.now()), then=Value(True)),
            default=Value(False),
            output_field=BooleanField(),
        ),
        required_lessons_total=Count(
            "training_version__modules__lessons",
            filter=Q(training_version__modules__lessons__is_required=True),
            distinct=True,
        ),
        required_lessons_completed=Count(
            "lesson_progress__lesson_id",
            filter=Q(
                lesson_progress__completed_at__isnull=False,
                lesson_progress__lesson__is_required=True,
            ),
            distinct=True,
        ),
    )
