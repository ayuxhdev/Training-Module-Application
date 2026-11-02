"""Management metadata and explicit inputs; no learner or assignment writes here."""

from rest_framework import serializers

from .training_management_serializers import CatalogQuerySerializer, ExplicitInputSerializer


class RequirementQuerySerializer(CatalogQuerySerializer):
    job_role_id = serializers.IntegerField(min_value=1, required=False)
    training_version_id = serializers.IntegerField(min_value=1, required=False)


class RequirementCreateSerializer(ExplicitInputSerializer):
    job_role_id = serializers.IntegerField(min_value=1)
    training_version_id = serializers.IntegerField(min_value=1)
    due_in_days = serializers.IntegerField(min_value=0, max_value=4294967295, required=False, default=30)
    is_active = serializers.BooleanField(required=False, default=True)


class RequirementUpdateSerializer(ExplicitInputSerializer):
    due_in_days = serializers.IntegerField(min_value=0, max_value=4294967295, required=False)
    is_active = serializers.BooleanField(required=False)


class RequirementSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    job_role_id = serializers.IntegerField()
    job_role_code = serializers.CharField(source="job_role.code")
    job_role_name = serializers.CharField(source="job_role.name")
    training_version_id = serializers.IntegerField()
    training_id = serializers.IntegerField(source="training_version.training_id")
    training_title = serializers.CharField(source="training_version.training.catalog_title")
    version_title = serializers.CharField(source="training_version.title")
    version_number = serializers.IntegerField(source="training_version.version_number")
    version_status = serializers.CharField(source="training_version.status")
    due_in_days = serializers.IntegerField()
    is_active = serializers.BooleanField()
    created_at = serializers.DateTimeField()
    updated_at = serializers.DateTimeField()


class RoleBatchInputSerializer(ExplicitInputSerializer):
    pass
