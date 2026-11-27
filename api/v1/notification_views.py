
from typing import Any, cast

from django.db.models import Q
from django.shortcuts import get_object_or_404

from rest_framework import generics, serializers
from rest_framework.permissions import IsAuthenticated
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework_simplejwt.authentication import JWTAuthentication

from api.permissions import IsActiveEmployee
from notifications.models import Notification
from notifications.services import mark_notifications_read

from .learning_views import JWTActiveEmployeeAPIView
from .notification_serializers import NotificationSerializer


VALID_READ_STATUSES = {"all", "unread", "read"}
MAX_SEARCH_LENGTH = 100


def _owned_notifications(request):
    return Notification.objects.filter(
        employee=request.user.employee
    )


def _require_empty_payload(request):
    if request.data != {}:
        raise serializers.ValidationError(
            "This action does not accept any fields."
        )


class NotificationListView(generics.ListAPIView):
    authentication_classes = [JWTAuthentication]
    permission_classes = [IsAuthenticated, IsActiveEmployee]
    serializer_class = NotificationSerializer

    def get_queryset(self) -> Any:
        request = cast(Request, self.request)
        queryset = _owned_notifications(request)

        status_param = request.query_params.get("status")
        if status_param is not None:
            if isinstance(status_param, str):
                status_param = status_param.strip().lower()
            else:
                status_param = str(status_param).strip().lower()

            if status_param not in VALID_READ_STATUSES:
                raise serializers.ValidationError(
                    {
                        "status": (
                            "Invalid notification read status filter. "
                            "Valid options are all, unread, or read."
                        )
                    }
                )
        else:
            status_param = "all"

        q_param = request.query_params.get("q")
        if q_param is not None:
            if isinstance(q_param, str):
                q_param = q_param.strip()
            else:
                q_param = str(q_param).strip()

            if len(q_param) > MAX_SEARCH_LENGTH:
                q_param = q_param[:MAX_SEARCH_LENGTH]
        else:
            q_param = ""

        if status_param == "unread":
            queryset = queryset.filter(
                read_at__isnull=True
            )

        elif status_param == "read":
            queryset = queryset.filter(
                read_at__isnull=False
            )

        if q_param:
            queryset = queryset.filter(
                Q(title__icontains=q_param)
                | Q(message__icontains=q_param)
            )

        return queryset.order_by(
            "-created_at",
            "-pk",
        )


class NotificationUnreadCountView(JWTActiveEmployeeAPIView):

    def get(self, request):
        unread_count = (
            _owned_notifications(request)
            .filter(read_at__isnull=True)
            .count()
        )

        return Response(
            {"unread_count": unread_count}
        )


class NotificationReadView(JWTActiveEmployeeAPIView):

    def post(self, request, notification_id):
        # Resolve ownership before parsing the mutation payload.
        get_object_or_404(
            _owned_notifications(request),
            pk=notification_id,
        )

        _require_empty_payload(request)

        mark_notifications_read(
            request.user.employee,
            notification_id=notification_id,
        )

        notification = get_object_or_404(
            _owned_notifications(request),
            pk=notification_id,
        )

        return Response(
            NotificationSerializer(notification).data
        )


class NotificationReadAllView(JWTActiveEmployeeAPIView):

    def post(self, request):
        _require_empty_payload(request)

        updated = mark_notifications_read(
            request.user.employee
        )

        return Response(
            {"updated_count": updated}
        )
