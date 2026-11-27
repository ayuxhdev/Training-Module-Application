"""Recipient-scoped website queries; notification creation stays in services."""

from django.db.models import Q

from organization.models import Employee
from training.models import TrainingAssignment
from training.views import assignment_scope, can_manage_assignments, has_active_learner_identity

from .models import Notification


def recipient_for_user(user):
    if not user.is_authenticated or not user.is_active:
        return None
    return Employee.objects.filter(user=user, is_active=True).only("pk").first()


def owned_notifications(employee):
    return Notification.objects.filter(employee_id=employee.pk)


def filter_notifications(notifications, *, search="", read_status="all"):
    if read_status == "unread":
        notifications = notifications.filter(read_at__isnull=True)
    elif read_status == "read":
        notifications = notifications.filter(read_at__isnull=False)
    if search:
        notifications = notifications.filter(
            Q(title__icontains=search) | Q(message__icontains=search)
        )
    return notifications


def assignment_link_ids(user, employee, notifications):
    # Match the existing website detail view's access gate and scope. A notification
    # does not itself grant assignment access, even to its recipient.
    if not (
        can_manage_assignments(user)
        or user.groups.filter(name__in=["Manager", "Employee"]).exists()
        or (
            user.groups.filter(name__in=["Trainer", "Supervisor"]).exists()
            and has_active_learner_identity(user)
        )
    ):
        return set()
    return set(TrainingAssignment.objects.filter(
        pk__in=[item.assignment_id for item in notifications],
        employee_id=employee.pk,
        employee__in=assignment_scope(user),
    ).values_list("pk", flat=True))
