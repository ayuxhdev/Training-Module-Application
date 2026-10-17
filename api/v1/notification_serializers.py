from rest_framework import serializers

from notifications.models import Notification


class NotificationSerializer(serializers.ModelSerializer):
    type = serializers.CharField(source="event_type", read_only=True)
    assignment_id = serializers.IntegerField(read_only=True)
    is_read = serializers.SerializerMethodField()

    class Meta:
        model = Notification
        fields = ["id", "type", "title", "message", "assignment_id", "created_at", "is_read", "read_at"]
        read_only_fields = fields

    def get_is_read(self, notification):
        return notification.read_at is not None
