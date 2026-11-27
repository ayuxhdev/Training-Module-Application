from urllib.parse import urlencode

from django import forms
from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.core.exceptions import PermissionDenied
from django.core.paginator import Paginator
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse
from django.views.decorators.cache import never_cache
from django.views.decorators.http import require_GET, require_POST

from .queries import (
    assignment_link_ids,
    filter_notifications,
    owned_notifications,
    recipient_for_user,
)
from .services import mark_notifications_read


class NotificationInboxFilterForm(forms.Form):
    q = forms.CharField(
        label="Search notifications",
        required=False,
        max_length=100,
        widget=forms.SearchInput(attrs={"autocomplete": "off"}),
    )
    status = forms.ChoiceField(
        label="Read status",
        choices=(("all", "All"), ("unread", "Unread"), ("read", "Read")),
    )

    def __init__(self, data=None, **kwargs):
        if data is not None:
            data = data.copy()
            data.setdefault("status", "all")
        super().__init__(data=data, **kwargs)


def _recipient(request):
    employee = recipient_for_user(request.user)
    if employee is None:
        raise PermissionDenied
    return employee


def _inbox_return_redirect(request):
    filter_form = NotificationInboxFilterForm(request.GET)
    if not filter_form.is_valid():
        return redirect("notifications:inbox")

    filters = filter_form.cleaned_data
    params = {}
    if filters["q"]:
        params["q"] = filters["q"]
    if filters["status"] != "all":
        params["status"] = filters["status"]

    raw_page = request.GET.get("page")
    if raw_page is not None:
        try:
            page_number = int(raw_page)
        except (TypeError, ValueError):
            page_number = None
        if page_number is not None and page_number > 0:
            params["page"] = page_number

    inbox_url = reverse("notifications:inbox")
    if params:
        inbox_url = f"{inbox_url}?{urlencode(params)}"
    return redirect(inbox_url)


@never_cache
@login_required
@require_GET
def inbox(request):
    employee = _recipient(request)
    notifications = owned_notifications(employee)
    filter_data = request.GET.copy()
    filter_data.setdefault("status", "all")
    filter_form = NotificationInboxFilterForm(filter_data)
    valid = filter_form.is_valid()
    if valid:
        filters = filter_form.cleaned_data
        if filters["q"] or filters["status"] != "all":
            notifications = filter_notifications(
                notifications,
                search=filters["q"],
                read_status=filters["status"],
            )
    else:
        notifications = notifications.none()

    page = Paginator(notifications.order_by("-created_at", "-pk"), 20).get_page(
        request.GET.get("page"),
    )
    items = list(page.object_list)
    link_ids = assignment_link_ids(request.user, employee, items) if items else set()
    params = {}
    has_active_filters = False
    if valid:
        filters = filter_form.cleaned_data
        if filters["q"]:
            params["q"] = filters["q"]
        if filters["status"] != "all":
            params["status"] = filters["status"]
        has_active_filters = bool(params)
    else:
        has_active_filters = True
    context = {
        "filter_form": filter_form,
        "page_obj": page,
        "page_query": urlencode(params),
        "return_query": urlencode(
            {**params, "page": page.number}
            if "page" in request.GET
            else params,
        ),
        "has_active_filters": has_active_filters,
        "notification_items": [
            {"notification": item, "can_open_assignment": item.assignment_id in link_ids}
            for item in items
        ],
    }
    return render(
        request,
        "notifications/inbox.html",
        context,
        status=200 if valid else 400,
    )


@never_cache
@login_required
@require_POST
def mark_read(request, pk):
    employee = _recipient(request)
    get_object_or_404(owned_notifications(employee), pk=pk)
    mark_notifications_read(employee, notification_id=pk)
    messages.success(request, "Notification marked as read.")
    return _inbox_return_redirect(request)


@never_cache
@login_required
@require_POST
def mark_all_read(request):
    employee = _recipient(request)
    mark_notifications_read(employee)
    messages.success(request, "All your notifications are marked as read.")
    return _inbox_return_redirect(request)
