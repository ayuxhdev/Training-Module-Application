"""Explicit authoring contracts, separate from learner assessment responses."""

from decimal import Decimal

from rest_framework import serializers

from assessments.models import Assessment, QuestionRevision

from .training_management_serializers import ExplicitInputSerializer


class AssessmentInputSerializer(ExplicitInputSerializer):
    kind = serializers.ChoiceField(choices=Assessment.Kind.choices)
    module_id = serializers.IntegerField(min_value=1, allow_null=True, required=False, default=None)
    title = serializers.CharField(max_length=200)
    sequence = serializers.IntegerField(min_value=1, max_value=4294967295, required=False, default=1)
    pass_percentage = serializers.DecimalField(max_digits=5, decimal_places=2, min_value=0, max_value=100, required=False, default="80.00")
    max_attempts = serializers.IntegerField(min_value=1, max_value=4294967295, required=False, default=3)
    time_limit_minutes = serializers.IntegerField(min_value=1, max_value=4294967295, allow_null=True, required=False, default=None)
    is_required = serializers.BooleanField(required=False, default=True)


class AssessmentAuthoringSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    training_version_id = serializers.IntegerField()
    module_id = serializers.IntegerField(allow_null=True)
    kind = serializers.CharField()
    title = serializers.CharField()
    sequence = serializers.IntegerField()
    pass_percentage = serializers.DecimalField(max_digits=5, decimal_places=2)
    max_attempts = serializers.IntegerField()
    time_limit_minutes = serializers.IntegerField(allow_null=True)
    is_required = serializers.BooleanField()


class AssessmentQuestionInputSerializer(ExplicitInputSerializer):
    question_revision_id = serializers.IntegerField(min_value=1)
    position = serializers.IntegerField(min_value=1, max_value=4294967295)
    points = serializers.DecimalField(max_digits=8, decimal_places=2, min_value=Decimal("0.01"), required=False, default="1.00")


class AssessmentQuestionAuthoringSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    assessment_id = serializers.IntegerField()
    question_revision_id = serializers.IntegerField()
    position = serializers.IntegerField()
    points = serializers.DecimalField(max_digits=8, decimal_places=2)


class QuestionInputSerializer(ExplicitInputSerializer):
    code = serializers.CharField(max_length=40)
    topic = serializers.CharField(max_length=120, required=False, allow_blank=True, default="")
    is_active = serializers.BooleanField(required=False, default=True)


class QuestionAuthoringSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    code = serializers.CharField()
    topic = serializers.CharField()
    is_active = serializers.BooleanField()


class RevisionInputSerializer(ExplicitInputSerializer):
    question_type = serializers.ChoiceField(choices=QuestionRevision.QuestionType.choices, required=False, default="SINGLE_CHOICE")
    prompt = serializers.CharField()
    explanation = serializers.CharField(required=False, allow_blank=True, default="")


class OptionInputSerializer(ExplicitInputSerializer):
    id = serializers.IntegerField(min_value=1, required=False)
    text = serializers.CharField(required=False)
    position = serializers.IntegerField(min_value=1, max_value=4294967295, required=False)
    is_correct = serializers.BooleanField(required=False)
    delete = serializers.BooleanField(required=False, default=False)

    def validate(self, attrs):
        if "id" not in attrs:
            if attrs.get("delete"):
                raise serializers.ValidationError("Only an existing draft option can be removed.")
            missing = {key: ["This field is required."] for key in ("text", "position") if key not in attrs}
            if missing:
                raise serializers.ValidationError(missing)
        return attrs


class RevisionEditInputSerializer(RevisionInputSerializer):
    options = OptionInputSerializer(many=True, required=False, max_length=1000)


class OptionAuthoringSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    text = serializers.CharField()
    position = serializers.IntegerField()
    is_correct = serializers.BooleanField()


class RevisionSummarySerializer(serializers.Serializer):
    id = serializers.IntegerField()
    question_id = serializers.IntegerField()
    revision_number = serializers.IntegerField()
    question_type = serializers.CharField()
    status = serializers.CharField()
    frozen_at = serializers.DateTimeField(allow_null=True)


class RevisionAuthoringSerializer(RevisionSummarySerializer):
    prompt = serializers.CharField()
    explanation = serializers.CharField()
    options = OptionAuthoringSerializer(many=True)


class EmptyAuthoringInputSerializer(ExplicitInputSerializer):
    pass
