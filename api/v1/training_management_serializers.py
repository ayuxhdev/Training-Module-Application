"""Explicit management contracts; never serialize learner media or answer data."""

from collections.abc import Mapping

from rest_framework import serializers


class CatalogQuerySerializer(serializers.Serializer):
    search = serializers.CharField(required=False, allow_blank=True, max_length=150)
    is_active = serializers.BooleanField(required=False)
    page = serializers.IntegerField(required=False, min_value=1)
    page_size = serializers.IntegerField(required=False, min_value=1, max_value=100)


class VersionQuerySerializer(serializers.Serializer):
    page = serializers.IntegerField(required=False, min_value=1)
    page_size = serializers.IntegerField(required=False, min_value=1, max_value=100)


class VersionDiscoveryQuerySerializer(VersionQuerySerializer):
    search = serializers.CharField(required=False, allow_blank=True, max_length=150)


class TrainingVersionDiscoverySerializer(serializers.Serializer):
    id = serializers.IntegerField()
    training_id = serializers.IntegerField()
    training_title = serializers.CharField(source="training.catalog_title")
    version_number = serializers.IntegerField()
    title = serializers.CharField()
    status = serializers.CharField()


class TrainingCatalogSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    code = serializers.CharField()
    catalog_title = serializers.CharField()
    description = serializers.CharField()
    is_active = serializers.BooleanField()
    latest_version_number = serializers.IntegerField(allow_null=True)
    latest_version_status = serializers.CharField(allow_null=True)
    created_at = serializers.DateTimeField()
    updated_at = serializers.DateTimeField()


class TrainingVersionSummarySerializer(serializers.Serializer):
    id = serializers.IntegerField()
    training_id = serializers.IntegerField()
    version_number = serializers.IntegerField()
    title = serializers.CharField()
    description = serializers.CharField()
    learning_objectives = serializers.CharField()
    change_summary = serializers.CharField()
    status = serializers.CharField()
    published_at = serializers.DateTimeField(allow_null=True)
    created_at = serializers.DateTimeField()
    updated_at = serializers.DateTimeField()


class LessonManagementSummarySerializer(serializers.Serializer):
    id = serializers.IntegerField()
    title = serializers.CharField()
    lesson_type = serializers.CharField(source="content_type")
    order = serializers.IntegerField(source="position")
    is_required = serializers.BooleanField()


class ModuleManagementSummarySerializer(serializers.Serializer):
    id = serializers.IntegerField()
    title = serializers.CharField()
    description = serializers.CharField()
    order = serializers.IntegerField(source="position")
    lessons = LessonManagementSummarySerializer(many=True)


class TrainingVersionDetailSerializer(TrainingVersionSummarySerializer):
    modules = ModuleManagementSummarySerializer(many=True)


class ExplicitInputSerializer(serializers.Serializer):
    def to_internal_value(self, data):
        if isinstance(data, Mapping):
            unexpected = set(data) - set(self.fields)
            if unexpected:
                raise serializers.ValidationError({
                    field: ["This field is not writable."] for field in sorted(unexpected)
                })
        return super().to_internal_value(data)


class TrainingInputSerializer(ExplicitInputSerializer):
    code = serializers.CharField(max_length=40)
    catalog_title = serializers.CharField(max_length=200)
    description = serializers.CharField(required=False, allow_blank=True, default="")
    is_active = serializers.BooleanField(required=False, default=True)


class DraftVersionInputSerializer(ExplicitInputSerializer):
    title = serializers.CharField(max_length=200)
    description = serializers.CharField(required=False, allow_blank=True, default="")
    learning_objectives = serializers.CharField(required=False, allow_blank=True, default="")
    change_summary = serializers.CharField(required=False, allow_blank=True, default="")


class ModuleInputSerializer(ExplicitInputSerializer):
    title = serializers.CharField(max_length=200)
    description = serializers.CharField(required=False, allow_blank=True, default="")
    position = serializers.IntegerField(min_value=1, max_value=2147483647)


class TextLessonInputSerializer(ExplicitInputSerializer):
    title = serializers.CharField(max_length=200)
    position = serializers.IntegerField(min_value=1, max_value=2147483647)
    content_type = serializers.ChoiceField(choices=["TEXT"], required=False, default="TEXT")
    body = serializers.CharField()
    is_required = serializers.BooleanField(required=False, default=True)


class ModuleAuthoringSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    training_version_id = serializers.IntegerField()
    title = serializers.CharField()
    description = serializers.CharField()
    position = serializers.IntegerField()


class TextLessonAuthoringSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    module_id = serializers.IntegerField()
    training_version_id = serializers.IntegerField(source="module.training_version_id")
    title = serializers.CharField()
    content_type = serializers.CharField()
    body = serializers.CharField()
    position = serializers.IntegerField()
    is_required = serializers.BooleanField()


class VideoLessonInputSerializer(ExplicitInputSerializer):
    title = serializers.CharField(max_length=200)
    position = serializers.IntegerField(min_value=1, max_value=2147483647)
    content_type = serializers.ChoiceField(choices=["VIDEO"], required=False, default="VIDEO")
    video_file = serializers.FileField(required=False, allow_empty_file=False, max_length=255)
    is_required = serializers.BooleanField(required=False, default=True)
    minimum_watch_percent = serializers.DecimalField(
        max_digits=5, decimal_places=2, min_value=0, max_value=100,
        required=False, default="90.00",
    )

    def validate(self, attrs):
        if not self.partial and "video_file" not in attrs:
            raise serializers.ValidationError({"video_file": ["Choose a video file for this lesson."]})
        return attrs


class VideoLessonAuthoringSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    module_id = serializers.IntegerField()
    training_version_id = serializers.IntegerField(source="module.training_version_id")
    title = serializers.CharField()
    content_type = serializers.CharField()
    position = serializers.IntegerField()
    is_required = serializers.BooleanField()
    minimum_watch_percent = serializers.DecimalField(max_digits=5, decimal_places=2)
    video_duration_seconds = serializers.IntegerField()
    has_video = serializers.SerializerMethodField()

    def get_has_video(self, instance):
        return bool(instance.video_file)
