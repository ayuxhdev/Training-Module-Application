from datetime import timedelta, timezone as datetime_timezone

from django.core.exceptions import ValidationError
from django.db import models, transaction
from django.db.models import F, Value
from django.db.models.functions import Greatest
from django.utils import timezone

from config.model_utils import require
from organization.models import Employee
from training.models import TrainingAssignment, TrainingVersion

from .models import Notification, notification_key


@transaction.atomic
def create_assignment_notification(assignment_id, event_type):
    """Insert an in-app event within the caller's business transaction, without new locks."""
    require(
        event_type in (Notification.EventType.ASSIGNED, Notification.EventType.COMPLETED),
        "This operation accepts only assignment and completion events.",
    )
    assignment = TrainingAssignment.objects.select_related("training_version").get(pk=assignment_id)
    return _create_assignment_event(assignment, event_type)


@transaction.atomic
def create_deadline_notification(assignment_id, *, activation_cutoff):
    """Recheck one reminder under the existing parent-to-assignment lock order."""
    require(timezone.is_aware(activation_cutoff), "Activation cutoff must include a timezone.")
    parents = TrainingAssignment.objects.filter(pk=assignment_id).values("employee_id", "training_version_id").first()
    if parents is None:
        return None, False
    employee = Employee.objects.select_for_update().get(pk=parents["employee_id"])
    version = TrainingVersion.objects.select_for_update().get(pk=parents["training_version_id"])
    assignment = TrainingAssignment.objects.select_for_update().filter(pk=assignment_id).first()
    now = timezone.now()
    require(activation_cutoff <= now, "Activation cutoff cannot be in the future.")
    if (
        assignment is None or not employee.is_active
        or version.status not in (TrainingVersion.Status.PUBLISHED, TrainingVersion.Status.RETIRED)
        or assignment.status not in (TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS)
        or assignment.due_at is None or assignment.due_at < activation_cutoff
    ):
        return None, False
    if assignment.due_at < now:
        event_type = Notification.EventType.OVERDUE
    elif now < assignment.due_at <= now + timedelta(hours=24):
        event_type = Notification.EventType.APPROACHING
    else:
        return None, False
    assignment.training_version = version
    return _create_assignment_event(assignment, event_type)


def _create_assignment_event(assignment, event_type):
    lookup = {
        "deduplication_key": notification_key(assignment, event_type),
        "assignment_id": assignment.pk,
        "employee_id": assignment.employee_id,
        "event_type": event_type,
    }
    if existing := Notification.objects.filter(**lookup).first():
        return existing, False

    if event_type == Notification.EventType.COMPLETED:
        require(assignment.status == TrainingAssignment.Status.COMPLETED, "Training is not completed.")
        title = "Training completed"
        action = "You have completed"
    elif event_type == Notification.EventType.ASSIGNED:
        require(
            assignment.status in (TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS),
            "Assignment notifications require an open assignment.",
        )
        title = "New training assigned"
        action = "You have been assigned"
    else:
        title = "Training due soon" if event_type == Notification.EventType.APPROACHING else "Training overdue"
    version = assignment.training_version
    if event_type in (Notification.EventType.APPROACHING, Notification.EventType.OVERDUE):
        deadline = assignment.due_at.astimezone(datetime_timezone.utc).isoformat(timespec="seconds")
        message = f'"{version.title}" (version {version.version_number}) is due at {deadline}.'
    else:
        message = f'{action} "{version.title}" (version {version.version_number}).'
    try:
        # get_or_create handles a database uniqueness race using its own savepoint.
        return Notification.objects.get_or_create(**lookup, defaults={"title": title, "message": message})
    except ValidationError as exc:
        # ValidatedModel can notice the competing insert during full_clean().
        # Do not swallow any other validation failure, even if a notification exists.
        errors = getattr(exc, "error_dict", {})
        if set(errors) != {"deduplication_key"} or any(
            error.code != "unique" for error in errors["deduplication_key"]
        ):
            raise
        existing = Notification.objects.filter(**lookup).first()
        if existing is None:
            raise
        return existing, False


def mark_notifications_read(employee, *, notification_id=None):
    """One conditional update; existing read timestamps and immutable event fields survive."""
    unread = Notification.objects.filter(employee_id=employee.pk, read_at__isnull=True)
    if notification_id is not None:
        unread = unread.filter(pk=notification_id)
    # A backwards clock adjustment must not violate the model's read/creation order.
    read_at = Greatest(F("created_at"), Value(timezone.now()))
    # The normal validated queryset forbids generic updates. This narrowly scoped
    # operation changes only read metadata, preserving its checks in one SQL statement.
    return models.QuerySet.update(unread, read_at=read_at, updated_at=read_at)
