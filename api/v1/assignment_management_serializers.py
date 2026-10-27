"""Metadata and strict input contracts for authorized manual assignments."""

from collections.abc import Mapping

from rest_framework import serializers

from training.models import TrainingAssignment, TrainingVersion


class AssignableTrainingVersionSerializer(serializers.ModelSerializer):
    training_id = serializers.IntegerField(read_only=True)
    training_code = serializers.CharField(source="training.code", read_only=True)
    training_title = serializers.CharField(source="training.catalog_title", read_only=True)

    class Meta:
        model = TrainingVersion
        fields = ("id", "training_id", "training_code", "training_title", "title", "version_number", "published_at")
        read_only_fields = fields


class TrainingVersionSearchSerializer(serializers.Serializer):
    search = serializers.CharField(required=False, allow_blank=True, max_length=150)


class ManualAssignmentInputSerializer(serializers.Serializer):
    employee_id = serializers.IntegerField(min_value=1)
    training_version_id = serializers.IntegerField(min_value=1)
    due_date = serializers.DateField(required=False, allow_null=True, input_formats=("iso-8601",))

    def to_internal_value(self, data):
        if isinstance(data, Mapping):
            unexpected = set(data) - set(self.fields)
            if unexpected:
                raise serializers.ValidationError({field: ["This field is not writable."] for field in sorted(unexpected)})
        return super().to_internal_value(data)


class ManualAssignmentSerializer(serializers.ModelSerializer):
    employee_id = serializers.IntegerField(read_only=True)
    training_version_id = serializers.IntegerField(read_only=True)
    assigned_by_id = serializers.IntegerField(read_only=True)
    department_at_assignment_id = serializers.IntegerField(read_only=True)
    job_role_at_assignment_id = serializers.IntegerField(read_only=True)

    class Meta:
        model = TrainingAssignment
        fields = (
            "id", "employee_id", "training_version_id", "status", "source", "assigned_by_id",
            "department_at_assignment_id", "job_role_at_assignment_id", "assigned_at", "due_at",
        )
        read_only_fields = fields
