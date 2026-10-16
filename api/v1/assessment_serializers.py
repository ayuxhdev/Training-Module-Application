from django.core.exceptions import ValidationError as ModelValidationError
from rest_framework import serializers

from assessments.models import AssessmentAttempt, AssessmentQuestion, AttemptAnswer, QuestionOption
from assessments.views import _parse_answer_pairs


class AssessmentSubmissionSerializer(serializers.Serializer):
	answers = serializers.JSONField()

	def validate(self, attrs):
		if set(self.initial_data) - {"answers"}:
			raise serializers.ValidationError("Only answers may be submitted.")
		return attrs

	def validate_answers(self, value):
		if not isinstance(value, dict):
			raise serializers.ValidationError("Answers must be an object keyed by assessment question ID.")
		try:
			return _parse_answer_pairs(value.items())
		except ModelValidationError as exc:
			raise serializers.ValidationError(exc.messages) from exc


class AttemptSummarySerializer(serializers.ModelSerializer):
	class Meta:
		model = AssessmentAttempt
		fields = (
			"id", "attempt_number", "status", "started_at", "deadline_at", "submitted_at",
			"score_points", "maximum_points", "pass_percentage_snapshot", "passed",
		)


class AssessmentOverviewSerializer(serializers.Serializer):
	id = serializers.IntegerField(source="assessment.pk")
	kind = serializers.CharField(source="assessment.kind")
	module_id = serializers.IntegerField(source="assessment.module_id", allow_null=True)
	title = serializers.CharField(source="assessment.title")
	sequence = serializers.IntegerField(source="assessment.sequence")
	is_required = serializers.BooleanField(source="assessment.is_required")
	pass_percentage = serializers.DecimalField(source="assessment.pass_percentage", max_digits=5, decimal_places=2)
	time_limit_minutes = serializers.IntegerField(source="assessment.time_limit_minutes", allow_null=True)
	max_attempts = serializers.IntegerField(source="assessment.max_attempts")
	attempts_used = serializers.SerializerMethodField()
	attempts_remaining = serializers.SerializerMethodField()
	ongoing_attempt_id = serializers.IntegerField(source="ongoing.pk", default=None, allow_null=True)
	passed = serializers.BooleanField()
	completed = serializers.BooleanField(source="passed")
	can_start = serializers.BooleanField()
	can_resume = serializers.BooleanField()
	blocking_reason = serializers.CharField(source="unavailable_reason", allow_null=True)
	attempts = AttemptSummarySerializer(many=True)

	def get_attempts_used(self, obj):
		return len(obj["attempts"])

	def get_attempts_remaining(self, obj):
		return max(0, obj["assessment"].max_attempts - len(obj["attempts"]))


class AssessmentOptionSerializer(serializers.ModelSerializer):
	class Meta:
		model = QuestionOption
		fields = ("id", "text", "position")


class AssessmentQuestionSerializer(serializers.ModelSerializer):
	prompt = serializers.CharField(source="question_revision.prompt")
	type = serializers.CharField(source="question_revision.question_type")
	options = AssessmentOptionSerializer(source="question_revision.options", many=True)

	class Meta:
		model = AssessmentQuestion
		fields = ("id", "position", "points", "prompt", "type", "options")


class AttemptAnswerSerializer(serializers.ModelSerializer):
	prompt = serializers.CharField(source="assessment_question.question_revision.prompt")
	selected_option_text = serializers.CharField(source="selected_option.text", default=None, allow_null=True)

	class Meta:
		model = AttemptAnswer
		fields = (
			"assessment_question_id", "presented_position", "prompt", "selected_option_id",
			"selected_option_text", "points_possible", "points_awarded",
		)


class AttemptDetailSerializer(AttemptSummarySerializer):
	assignment_status = serializers.CharField(source="assignment.status")
	training_version_id = serializers.IntegerField(source="assignment.training_version_id")
	certificate_id = serializers.IntegerField(source="assignment.certificate.pk", default=None, allow_null=True)
	questions = serializers.SerializerMethodField()
	answers = serializers.SerializerMethodField()

	class Meta(AttemptSummarySerializer.Meta):
		fields = AttemptSummarySerializer.Meta.fields + (
			"assignment_id", "assessment_id", "training_version_id", "assignment_status",
			"certificate_id", "questions", "answers",
		)

	def get_questions(self, obj):
		if obj.status != AssessmentAttempt.Status.IN_PROGRESS:
			return []
		questions = obj.assessment.questions.select_related("question_revision").prefetch_related("question_revision__options")
		return AssessmentQuestionSerializer(questions, many=True).data

	def get_answers(self, obj):
		if obj.status == AssessmentAttempt.Status.IN_PROGRESS:
			return []
		answers = obj.answers.select_related("assessment_question__question_revision", "selected_option").order_by("presented_position")
		return AttemptAnswerSerializer(answers, many=True).data
