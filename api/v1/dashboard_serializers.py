from django.utils import timezone
from rest_framework import serializers

from certifications.models import Certificate
from training.models import TrainingAssignment


class DashboardMetricsSerializer(serializers.Serializer):
    total = serializers.IntegerField()
    assigned = serializers.IntegerField()
    in_progress = serializers.IntegerField()
    completed = serializers.IntegerField()
    cancelled = serializers.IntegerField()
    overdue = serializers.IntegerField()
    completion_percent = serializers.FloatField()
    certificates_count = serializers.IntegerField()


class DashboardAssignmentSerializer(serializers.ModelSerializer):
    training_id = serializers.IntegerField(source="training_version.training_id", read_only=True)
    training_title = serializers.CharField(source="training_version.title", read_only=True)
    version_number = serializers.IntegerField(source="training_version.version_number", read_only=True)
    is_overdue = serializers.SerializerMethodField()

    class Meta:
        model = TrainingAssignment
        fields = [
            "id",
            "training_id",
            "training_title",
            "version_number",
            "status",
            "due_at",
            "is_overdue",
            "started_at",
        ]

    def get_is_overdue(self, obj):
        if hasattr(obj, "is_overdue"):
            return bool(obj.is_overdue)
        now = self.context.get("now") or timezone.now()
        return bool(
            obj.status in (TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS)
            and obj.due_at
            and obj.due_at < now
        )


class DashboardCertificateSerializer(serializers.ModelSerializer):
    training_title = serializers.CharField(source="training_title_snapshot", read_only=True)
    version_number = serializers.IntegerField(source="version_number_snapshot", read_only=True)

    class Meta:
        model = Certificate
        fields = [
            "id",
            "certificate_number",
            "training_title",
            "version_number",
            "issued_at",
        ]


class EmployeeDashboardSerializer(serializers.Serializer):
    metrics = DashboardMetricsSerializer()
    action_required = DashboardAssignmentSerializer(many=True)
    recent_certificates = DashboardCertificateSerializer(many=True)

