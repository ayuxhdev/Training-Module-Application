from django import template

from notifications.queries import owned_notifications, recipient_for_user

register = template.Library()


@register.inclusion_tag("notifications/bell.html", takes_context=True)
def notification_bell(context):
    request = context.get("request")
    employee = recipient_for_user(request.user) if request is not None else None
    if employee is None:
        return {"notifications_available": False}
    return {
        "notifications_available": True,
        # One indexed aggregate, without fetching or rendering notification history.
        "notification_unread_count": owned_notifications(employee).filter(read_at__isnull=True).count(),
        "notifications_current": request.resolver_match is not None
        and request.resolver_match.namespace == "notifications",
    }
