from django.shortcuts import get_object_or_404
from rest_framework import generics, serializers
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework_simplejwt.authentication import JWTAuthentication

from api.permissions import IsActiveEmployee
from notifications.models import Notification
from notifications.services import mark_notifications_read

from .learning_views import JWTActiveEmployeeAPIView
from .notification_serializers import NotificationSerializer


def _owned_notifications(request):
    return Notification.objects.filter(employee=request.user.employee)


def _require_empty_payload(request):
    if request.data != {}:
        raise serializers.ValidationError("This action does not accept any fields.")


class NotificationListView(generics.ListAPIView):
    authentication_classes = [JWTAuthentication]
    permission_classes = [IsAuthenticated, IsActiveEmployee]
    serializer_class = NotificationSerializer

    def get_queryset(self):
        return _owned_notifications(self.request).order_by("-created_at", "-pk")


class NotificationUnreadCountView(JWTActiveEmployeeAPIView):
    def get(self, request):
        return Response({"unread_count": _owned_notifications(request).filter(read_at__isnull=True).count()})


class NotificationReadView(JWTActiveEmployeeAPIView):
    def post(self, request, notification_id):
        # Resolve ownership before parsing a mutation payload, including malformed JSON.
        get_object_or_404(_owned_notifications(request), pk=notification_id)
        _require_empty_payload(request)
        mark_notifications_read(request.user.employee, notification_id=notification_id)
        notification = get_object_or_404(_owned_notifications(request), pk=notification_id)
        return Response(NotificationSerializer(notification).data)


class NotificationReadAllView(JWTActiveEmployeeAPIView):
    def post(self, request):
        _require_empty_payload(request)
        updated = mark_notifications_read(request.user.employee)
        return Response({"updated_count": updated})
