from rest_framework import serializers

from training.models import Lesson, Module, TrainingAssignment
from training.views import _progress_response


class AssignmentListSerializer(serializers.ModelSerializer):
	training_id = serializers.IntegerField(source="training_version.training_id", read_only=True)
	training_title = serializers.CharField(source="training_version.title", read_only=True)
	version_number = serializers.IntegerField(source="training_version.version_number", read_only=True)
	is_overdue = serializers.BooleanField(read_only=True)
	progress_summary = serializers.SerializerMethodField()

	class Meta:
		model = TrainingAssignment
		fields = (
			"id", "training_id", "training_title", "version_number", "status",
			"assigned_at", "due_at", "started_at", "completed_at", "is_overdue",
			"progress_summary",
		)

	def get_progress_summary(self, obj):
		return {
			"required_lessons_completed": obj.required_lessons_completed,
			"required_lessons_total": obj.required_lessons_total,
		}


class LessonLearningSerializer(serializers.ModelSerializer):
	type = serializers.CharField(source="content_type", read_only=True)
	progress = serializers.SerializerMethodField()
	body = serializers.SerializerMethodField()

	class Meta:
		model = Lesson
		fields = (
			"id", "title", "position", "type", "is_required", "body",
			"video_duration_seconds", "minimum_watch_percent", "progress",
		)

	def get_body(self, obj):
		return obj.body if obj.content_type == Lesson.ContentType.TEXT else ""

	def get_progress(self, obj):
		progress = self.context["progress_by_lesson"].get(obj.pk)
		if progress:
			return _progress_response(progress)
		return {
			"resume_position": 0.0,
			"watched_ranges": [],
			"watched_seconds": 0.0,
			"progress_percent": 0.0,
			"completed": False,
			"completed_at": None,
			"session_id": None,
		}


class ModuleLearningSerializer(serializers.ModelSerializer):
	lessons = LessonLearningSerializer(many=True, read_only=True)

	class Meta:
		model = Module
		fields = ("id", "title", "description", "position", "lessons")


class AssignmentDetailSerializer(serializers.ModelSerializer):
	training_id = serializers.IntegerField(source="training_version.training_id", read_only=True)
	training_title = serializers.CharField(source="training_version.title", read_only=True)
	version_number = serializers.IntegerField(source="training_version.version_number", read_only=True)
	is_overdue = serializers.BooleanField(read_only=True)
	modules = serializers.SerializerMethodField()

	class Meta:
		model = TrainingAssignment
		fields = (
			"id", "training_id", "training_title", "version_number", "status",
			"assigned_at", "due_at", "started_at", "completed_at", "is_overdue", "modules",
		)

	def get_modules(self, obj):
		return ModuleLearningSerializer(
			self.context["modules"],
			many=True,
			context={"progress_by_lesson": self.context["progress_by_lesson"]},
		).data
