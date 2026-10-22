from django import forms
from django.forms import inlineformset_factory

from training.models import Module

from .models import Assessment, AssessmentQuestion, Question, QuestionOption, QuestionRevision


class QuestionForm(forms.ModelForm):
    class Meta:
        model = Question
        fields = ["code", "topic", "is_active"]


class QuestionRevisionForm(forms.ModelForm):
    class Meta:
        model = QuestionRevision
        fields = ["question_type", "prompt", "explanation"]


class QuestionOptionForm(forms.ModelForm):
    class Meta:
        model = QuestionOption
        fields = ["text", "position", "is_correct"]


QuestionOptionFormSet = inlineformset_factory(
    QuestionRevision,
    QuestionOption,
    form=QuestionOptionForm,
    extra=2,
    can_delete=True,
)


class AssessmentForm(forms.ModelForm):
    class Meta:
        model = Assessment
        fields = [
            "kind", "module", "title", "sequence", "pass_percentage",
            "max_attempts", "time_limit_minutes", "is_required",
        ]

    def __init__(self, *args, training_version, **kwargs):
        super().__init__(*args, **kwargs)
        self.training_version = training_version
        self.fields["module"].queryset = Module.objects.filter(training_version=training_version)
        self.fields["module"].required = False

    def clean(self):
        cleaned = super().clean()
        kind = cleaned.get("kind")
        if kind == Assessment.Kind.QUIZ and cleaned.get("module") is None:
            self.add_error("module", "A lesson quiz must belong to a module.")
        if kind == Assessment.Kind.FINAL:
            cleaned["module"] = None
            cleaned["sequence"] = 1
            cleaned["is_required"] = True
        if kind and cleaned.get("sequence") is not None:
            conflict = Assessment.objects.filter(
                training_version=self.training_version,
                kind=kind,
                sequence=cleaned["sequence"],
            ).exclude(pk=self.instance.pk)
            if conflict.exists():
                self.add_error("sequence", "This sequence is already used for this assessment kind in this version.")
        return cleaned


def format_question_revision_label(revision):
    prompt_clean = " ".join(revision.prompt.split())
    prompt_excerpt = (prompt_clean[:65] + "…") if len(prompt_clean) > 65 else prompt_clean
    topic_str = f" [{revision.question.topic}]" if revision.question.topic else ""
    return f"{revision.question.code}{topic_str} — {prompt_excerpt} (rev {revision.revision_number})"


class AssessmentQuestionForm(forms.ModelForm):
    class Meta:
        model = AssessmentQuestion
        fields = ["question_revision", "position", "points"]

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["question_revision"].queryset = QuestionRevision.objects.filter(
            status=QuestionRevision.Status.FROZEN,
            question__is_active=True,
        ).select_related("question")
        self.fields["question_revision"].label_from_instance = format_question_revision_label
        self.fields["question_revision"].empty_label = "Select a question revision"
