"""Read-only assignment metadata; never expose lesson content or learner actions."""

from rest_framework import serializers

from .learning_serializers import AssignmentListSerializer


class ManagedAssignmentSerializer(AssignmentListSerializer):
    training_version_id = serializers.IntegerField(read_only=True)

    class Meta(AssignmentListSerializer.Meta):
        fields = (
            "id", "training_id", "training_version_id", "training_title",
            "version_number", "status", "assigned_at", "due_at", "started_at",
            "completed_at", "is_overdue", "progress_summary",
        )
        read_only_fields = fields
