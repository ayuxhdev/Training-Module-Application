from datetime import timezone as datetime_timezone

from django.db import models
from django.db.models import F, Q

from config.model_utils import TimestampedModel, require


class Notification(TimestampedModel):
    class EventType(models.TextChoices):
        ASSIGNED = "ASSIGNED", "Training assigned"
        APPROACHING = "APPROACHING", "Deadline approaching"
        OVERDUE = "OVERDUE", "Training overdue"
        COMPLETED = "COMPLETED", "Training completed"

    employee = models.ForeignKey(
        "organization.Employee", on_delete=models.PROTECT, related_name="notifications",
    )
    assignment = models.ForeignKey(
        "training.TrainingAssignment", on_delete=models.PROTECT, related_name="notifications",
    )
    event_type = models.CharField(max_length=12, choices=EventType.choices)
    title = models.CharField(max_length=200)
    message = models.TextField()
    read_at = models.DateTimeField(null=True, blank=True)
    deduplication_key = models.CharField(max_length=128, unique=True, editable=False)

    class Meta:
        ordering = ["-created_at", "-pk"]
        indexes = [
            models.Index(fields=["employee", "read_at", "created_at"], name="notification_owner_read_idx"),
        ]
        constraints = [
            models.CheckConstraint(
                condition=Q(event_type__in=["ASSIGNED", "APPROACHING", "OVERDUE", "COMPLETED"]),
                name="notification_valid_event",
            ),
            models.CheckConstraint(
                condition=Q(read_at__isnull=True) | Q(read_at__gte=F("created_at")),
                name="notification_read_order",
            ),
        ]

    def clean(self):
        super().clean()
        old = self.original()
        self.require_unchanged(old, [
            "employee_id", "assignment_id", "event_type", "title", "message",
            "created_at", "deduplication_key",
        ])
        if not old:
            from training.models import TrainingAssignment

            assignment = TrainingAssignment.objects.using(self._state.db).get(pk=self.assignment_id)
            require(self.employee_id == assignment.employee_id, "Notification owner must match the assignment.")
            require(
                self.deduplication_key == notification_key(assignment, self.event_type),
                "Notification key must match its assignment and event.",
            )
        if self.read_at and self.created_at:
            require(self.read_at >= self.created_at, "Read time cannot precede notification creation.")


def notification_key(assignment, event_type):
    """One immediate event per assignment; deadline events distinguish due-date changes."""
    require(assignment.pk is not None, "Save the assignment before creating a notification.")
    require(event_type in Notification.EventType.values, "Unknown notification event.")
    key = f"assignment:{assignment.pk}:{event_type}"
    if event_type in (Notification.EventType.APPROACHING, Notification.EventType.OVERDUE):
        require(assignment.due_at is not None, "Deadline notifications require a due date.")
        due_at = assignment.due_at.astimezone(datetime_timezone.utc).isoformat(timespec="microseconds")
        key += f":{due_at}"
    return key
