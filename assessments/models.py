from decimal import Decimal

from django.conf import settings
from django.core.validators import MaxValueValidator, MinValueValidator
from django.db import models
from django.db.models import F, Q
from django.utils import timezone

from config.model_utils import TimestampedModel, protect_delete, require
from training.models import Lesson, TrainingAssignment, VersionContent


class Question(TimestampedModel):
    code = models.CharField(max_length=40, unique=True)
    topic = models.CharField(max_length=120, blank=True)
    is_active = models.BooleanField(default=True)
    created_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name="created_questions")

    class Meta:
        indexes = [models.Index(fields=["topic", "is_active"], name="question_topic_active_idx")]

    def delete(self, *args, **kwargs):
        protect_delete("Deactivate question-bank entries instead of deleting history.")


class QuestionRevision(TimestampedModel):
    class QuestionType(models.TextChoices):
        SINGLE_CHOICE = "SINGLE_CHOICE", "Single choice"
        TRUE_FALSE = "TRUE_FALSE", "True or false"

    class Status(models.TextChoices):
        DRAFT = "DRAFT", "Draft"
        FROZEN = "FROZEN", "Frozen"

    question = models.ForeignKey(Question, on_delete=models.PROTECT, related_name="revisions")
    revision_number = models.PositiveIntegerField(validators=[MinValueValidator(1)])
    question_type = models.CharField(max_length=13, choices=QuestionType, default=QuestionType.SINGLE_CHOICE)
    prompt = models.TextField()
    explanation = models.TextField(blank=True)
    status = models.CharField(max_length=6, choices=Status, default=Status.DRAFT)
    frozen_at = models.DateTimeField(null=True, blank=True)
    created_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name="created_question_revisions")

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["question", "revision_number"], name="unique_question_revision"),
            models.CheckConstraint(condition=Q(revision_number__gte=1), name="question_revision_positive"),
            models.CheckConstraint(condition=(Q(status="DRAFT", frozen_at__isnull=True) | Q(status="FROZEN", frozen_at__isnull=False)), name="question_revision_freeze_date"),
        ]

    def clean(self):
        super().clean()
        old = self.original()
        self.require_unchanged(old, ["question_id", "revision_number"])
        if old and old.status == self.Status.FROZEN:
            self.require_frozen(old)
        elif self.status == self.Status.FROZEN:
            require(self.pk is not None, "Create a draft question before freezing it.")
            options = list(self.options.all())
            require(len(options) >= 2 and sum(option.is_correct for option in options) == 1,
                    "A frozen question needs at least two options and exactly one correct option.")
            if self.question_type == self.QuestionType.TRUE_FALSE:
                require({option.text.strip().lower() for option in options} == {"true", "false"} and len(options) == 2,
                        "True/false questions require exactly the True and False options.")

    def validate_delete(self):
        require(self.original().status == self.Status.DRAFT, "Frozen question revisions cannot be deleted.")


class QuestionOption(TimestampedModel):
    question_revision = models.ForeignKey(QuestionRevision, on_delete=models.PROTECT, related_name="options")
    text = models.TextField()
    position = models.PositiveIntegerField(validators=[MinValueValidator(1)])
    is_correct = models.BooleanField(default=False)

    class Meta:
        ordering = ["position"]
        constraints = [models.UniqueConstraint(fields=["question_revision", "position"], name="unique_question_option_order"),
                       models.CheckConstraint(condition=Q(position__gte=1), name="question_option_order_positive")]

    def lock_parents(self, using):
        QuestionRevision.objects.using(using).select_for_update().get(pk=self.question_revision_id)

    def clean(self):
        super().clean()
        self.require_unchanged(self.original(), ["question_revision_id"])
        require(QuestionRevision.objects.get(pk=self.question_revision_id).status == QuestionRevision.Status.DRAFT,
                "Frozen question options cannot be changed.")

    def validate_delete(self):
        require(QuestionRevision.objects.get(pk=self.question_revision_id).status == QuestionRevision.Status.DRAFT,
                "Frozen question options cannot be deleted.")


class Assessment(VersionContent):
    class Kind(models.TextChoices):
        QUIZ = "QUIZ", "Module quiz"
        FINAL = "FINAL", "Final assessment"

    training_version = models.ForeignKey("training.TrainingVersion", on_delete=models.PROTECT, related_name="assessments")
    module = models.ForeignKey("training.Module", on_delete=models.PROTECT, null=True, blank=True, related_name="quizzes")
    kind = models.CharField(max_length=5, choices=Kind)
    title = models.CharField(max_length=200)
    sequence = models.PositiveIntegerField(default=1, validators=[MinValueValidator(1)])
    pass_percentage = models.DecimalField(max_digits=5, decimal_places=2, default=Decimal("80.00"),
                                         validators=[MinValueValidator(0), MaxValueValidator(100)])
    max_attempts = models.PositiveIntegerField(default=3, validators=[MinValueValidator(1)])
    time_limit_minutes = models.PositiveIntegerField(null=True, blank=True, validators=[MinValueValidator(1)])
    is_required = models.BooleanField(default=True)
    question_revisions = models.ManyToManyField(QuestionRevision, through="AssessmentQuestion", related_name="assessments")

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["training_version", "kind", "sequence"], name="unique_version_assessment_seq"),
            models.CheckConstraint(condition=(Q(kind="FINAL", sequence=1, module__isnull=True, is_required=True) |
                                              Q(kind="QUIZ", module__isnull=False)), name="assessment_kind_scope"),
            models.CheckConstraint(condition=Q(sequence__gte=1, max_attempts__gte=1), name="assessment_positive_limits"),
            models.CheckConstraint(condition=Q(pass_percentage__gte=0, pass_percentage__lte=100), name="assessment_pass_percent_range"),
            models.CheckConstraint(condition=Q(time_limit_minutes__isnull=True) | Q(time_limit_minutes__gte=1), name="assessment_time_limit_positive"),
        ]

    def get_version_id(self):
        return self.training_version_id

    def clean(self):
        super().clean()
        self.require_unchanged(self.original(), ["training_version_id"])
        if self.module_id:
            from training.models import Module
            require(Module.objects.get(pk=self.module_id).training_version_id == self.training_version_id,
                    "Quiz module and assessment versions must match.")

    def validate_for_publication(self):
        self.full_clean()
        require(self.questions.exists(), "Published assessments require questions.")
        for item in self.questions.select_related("question_revision__question"):
            item.full_clean()
            require(item.question_revision.status == QuestionRevision.Status.FROZEN, "Published assessments require frozen question revisions.")
            require(item.question_revision.question.is_active, "New publications cannot use inactive questions.")


class AssessmentQuestion(VersionContent):
    assessment = models.ForeignKey(Assessment, on_delete=models.PROTECT, related_name="questions")
    question_revision = models.ForeignKey(QuestionRevision, on_delete=models.PROTECT, related_name="assessment_questions")
    position = models.PositiveIntegerField(validators=[MinValueValidator(1)])
    points = models.DecimalField(max_digits=8, decimal_places=2, default=Decimal("1.00"), validators=[MinValueValidator(Decimal("0.01"))])

    class Meta:
        ordering = ["position"]
        constraints = [
            models.UniqueConstraint(fields=["assessment", "position"], name="unique_assessment_question_pos"),
            models.UniqueConstraint(fields=["assessment", "question_revision"], name="unique_assessment_question_rev"),
            models.CheckConstraint(condition=Q(position__gte=1, points__gt=0), name="assessment_question_positive"),
        ]

    def get_version_id(self):
        return Assessment.objects.values_list("training_version_id", flat=True).get(pk=self.assessment_id)

    def clean(self):
        super().clean()
        self.require_unchanged(self.original(), ["assessment_id"])
        require(not AssessmentQuestion.objects.filter(assessment_id=self.assessment_id,
                question_revision__question_id=self.question_revision.question_id).exclude(pk=self.pk).exists(),
                "An assessment cannot contain multiple revisions of the same question.")


class AssessmentAttempt(TimestampedModel):
    class Status(models.TextChoices):
        IN_PROGRESS = "IN_PROGRESS", "In progress"
        SUBMITTED = "SUBMITTED", "Submitted"
        EXPIRED = "EXPIRED", "Expired"
        ABANDONED = "ABANDONED", "Abandoned"

    assignment = models.ForeignKey(TrainingAssignment, on_delete=models.PROTECT, related_name="attempts")
    assessment = models.ForeignKey(Assessment, on_delete=models.PROTECT, related_name="attempts")
    attempt_number = models.PositiveIntegerField(validators=[MinValueValidator(1)])
    status = models.CharField(max_length=12, choices=Status, default=Status.IN_PROGRESS)
    started_at = models.DateTimeField(default=timezone.now)
    deadline_at = models.DateTimeField(null=True, blank=True)
    submitted_at = models.DateTimeField(null=True, blank=True)
    score_points = models.DecimalField(max_digits=12, decimal_places=2, null=True, blank=True)
    maximum_points = models.DecimalField(max_digits=12, decimal_places=2, validators=[MinValueValidator(Decimal("0.01"))])
    pass_percentage_snapshot = models.DecimalField(max_digits=5, decimal_places=2, validators=[MinValueValidator(0), MaxValueValidator(100)])
    passed = models.BooleanField(null=True, blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["assignment", "assessment", "attempt_number"], name="unique_assessment_attempt_no"),
            models.CheckConstraint(condition=Q(attempt_number__gte=1, maximum_points__gt=0), name="attempt_positive_values"),
            models.CheckConstraint(condition=Q(score_points__isnull=True) | Q(score_points__gte=0, score_points__lte=F("maximum_points")), name="attempt_score_range"),
            models.CheckConstraint(condition=Q(pass_percentage_snapshot__gte=0, pass_percentage_snapshot__lte=100), name="attempt_pass_percent_range"),
            models.CheckConstraint(condition=Q(deadline_at__isnull=True) | Q(deadline_at__gte=F("started_at")), name="attempt_deadline_order"),
            models.CheckConstraint(condition=Q(submitted_at__isnull=True) | Q(submitted_at__gte=F("started_at")), name="attempt_submission_order"),
            models.CheckConstraint(condition=(Q(status="IN_PROGRESS", submitted_at__isnull=True, score_points__isnull=True, passed__isnull=True) |
                Q(status__in=["SUBMITTED", "EXPIRED"], submitted_at__isnull=False, score_points__isnull=False, passed__isnull=False) |
                Q(status="ABANDONED", submitted_at__isnull=False, score_points__isnull=True, passed__isnull=True)), name="attempt_result_fields"),
        ]
        indexes = [models.Index(fields=["assignment", "assessment", "status"], name="attempt_assignment_status_idx")]

    def lock_parents(self, using):
        TrainingAssignment.objects.using(using).select_for_update().get(pk=self.assignment_id)

    def clean(self):
        super().clean()
        old = self.original()
        self.assessment = Assessment.objects.get(pk=self.assessment_id)
        self.require_unchanged(old, ["assignment_id", "assessment_id", "attempt_number", "started_at", "deadline_at",
                                     "maximum_points", "pass_percentage_snapshot"])
        if old and old.status != self.Status.IN_PROGRESS:
            self.require_frozen(old)
            return
        assignment = TrainingAssignment.objects.select_related("employee").get(pk=self.assignment_id)
        require(self.assessment.training_version_id == assignment.training_version_id, "Attempt and assignment training versions must match.")
        if not old:
            require(self.status == self.Status.IN_PROGRESS, "Create an ongoing attempt before recording results.")
            require(assignment.employee.is_active and assignment.status in [TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS],
                    "Attempts require an active employee and open assignment.")
            previous = AssessmentAttempt.objects.filter(assignment_id=self.assignment_id, assessment_id=self.assessment_id)
            require(not previous.filter(status=self.Status.IN_PROGRESS).exists(), "Only one ongoing attempt is allowed per assessment and assignment.")
            count = previous.count()
            require(count < self.assessment.max_attempts and self.attempt_number == count + 1, "Attempt number must be sequential and within the allowed limit.")
            total = sum(self.assessment.questions.values_list("points", flat=True), Decimal(0))
            require(self.maximum_points == total and self.pass_percentage_snapshot == self.assessment.pass_percentage,
                    "Attempt scoring snapshots must match the published assessment.")
            from datetime import timedelta
            expected_deadline = self.started_at + timedelta(minutes=self.assessment.time_limit_minutes) if self.assessment.time_limit_minutes else None
            require(self.deadline_at == expected_deadline, "Deadline must match the published time limit.")
            if self.assessment.kind == Assessment.Kind.FINAL:
                lessons = Lesson.objects.filter(module__training_version_id=assignment.training_version_id, is_required=True)
                require(not lessons.exclude(pk__in=assignment.lesson_progress.filter(completed_at__isnull=False).values("lesson_id")).exists(),
                        "Complete required lessons before the final assessment.")
                quizzes = assignment.training_version.assessments.filter(kind=Assessment.Kind.QUIZ, is_required=True)
                require(not quizzes.exclude(pk__in=assignment.attempts.filter(status=self.Status.SUBMITTED, passed=True).values("assessment_id")).exists(),
                        "Pass required quizzes before the final assessment.")
        if self.status in [self.Status.SUBMITTED, self.Status.EXPIRED]:
            require(assignment.employee.is_active or self.status == self.Status.EXPIRED, "Inactive employees cannot submit assessments.")
            require(assignment.status in [TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS], "Assignment must be open.")
            require(self.pk is not None, "Save an attempt before submitting it.")
            answers = list(self.answers.all())
            require(len(answers) == self.assessment.questions.count(), "Preserve an answer row for every presented question, including unanswered questions.")
            require(all(answer.points_awarded is not None and answer.is_correct is not None for answer in answers), "Grade every answer before submission.")
            total = sum((answer.points_awarded for answer in answers), Decimal(0))
            require(self.score_points == total, "Attempt score must equal the stored answer grades.")
            expected_pass = total * 100 >= self.maximum_points * self.pass_percentage_snapshot
            require(self.passed == (expected_pass and self.status == self.Status.SUBMITTED), "Pass result must match the stored score and status.")
            if self.deadline_at and self.submitted_at:
                if self.status == self.Status.SUBMITTED:
                    require(self.submitted_at <= self.deadline_at, "Late submissions must be expired.")
                else:
                    require(self.submitted_at >= self.deadline_at, "Attempts cannot expire before their deadline.")
            if self.status == self.Status.EXPIRED:
                require(self.deadline_at is not None, "Only timed attempts can expire.")

    def delete(self, *args, **kwargs):
        protect_delete("Assessment attempts are permanent history.")


class AttemptAnswer(TimestampedModel):
    attempt = models.ForeignKey(AssessmentAttempt, on_delete=models.PROTECT, related_name="answers")
    assessment_question = models.ForeignKey(AssessmentQuestion, on_delete=models.PROTECT, related_name="attempt_answers")
    selected_option = models.ForeignKey(QuestionOption, on_delete=models.PROTECT, null=True, blank=True, related_name="attempt_answers")
    presented_position = models.PositiveIntegerField(validators=[MinValueValidator(1)])
    answered_at = models.DateTimeField(null=True, blank=True)
    points_possible = models.DecimalField(max_digits=8, decimal_places=2)
    points_awarded = models.DecimalField(max_digits=8, decimal_places=2, null=True, blank=True)
    is_correct = models.BooleanField(null=True, blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["attempt", "assessment_question"], name="unique_attempt_question_answer"),
            models.UniqueConstraint(fields=["attempt", "presented_position"], name="unique_attempt_answer_position"),
            models.CheckConstraint(condition=Q(presented_position__gte=1, points_possible__gt=0), name="answer_positive_values"),
            models.CheckConstraint(condition=Q(points_awarded__isnull=True) | Q(points_awarded__gte=0, points_awarded__lte=F("points_possible")), name="answer_awarded_range"),
            models.CheckConstraint(condition=(Q(selected_option__isnull=True, answered_at__isnull=True) |
                                              Q(selected_option__isnull=False, answered_at__isnull=False)), name="answer_response_fields"),
            models.CheckConstraint(condition=(Q(points_awarded__isnull=True, is_correct__isnull=True) |
                                              Q(points_awarded__isnull=False, is_correct__isnull=False)), name="answer_grade_fields"),
        ]

    def lock_parents(self, using):
        assignment_id = AssessmentAttempt.objects.using(using).values_list("assignment_id", flat=True).get(pk=self.attempt_id)
        TrainingAssignment.objects.using(using).select_for_update().get(pk=assignment_id)
        AssessmentAttempt.objects.using(using).select_for_update().get(pk=self.attempt_id)

    def clean(self):
        super().clean()
        self.require_unchanged(self.original(), ["attempt_id", "assessment_question_id", "presented_position", "points_possible"])
        self.assessment_question = AssessmentQuestion.objects.get(pk=self.assessment_question_id)
        if self.selected_option_id:
            self.selected_option = QuestionOption.objects.get(pk=self.selected_option_id)
        attempt = AssessmentAttempt.objects.select_related("assignment__employee").get(pk=self.attempt_id)
        require(attempt.status == AssessmentAttempt.Status.IN_PROGRESS, "Answers on closed attempts are immutable.")
        require(attempt.assignment.employee.is_active, "Inactive employees cannot answer assessments.")
        require(attempt.assignment.status in [TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS],
                "Answers require an open assignment.")
        require(self.assessment_question.assessment_id == attempt.assessment_id, "Question must belong to the attempted assessment.")
        require(self.points_possible == self.assessment_question.points, "Possible marks must match the published question.")
        if self.selected_option_id:
            require(self.selected_option.question_revision_id == self.assessment_question.question_revision_id,
                    "Selected option must belong to the exact question revision.")
        if self.answered_at:
            require(self.answered_at >= attempt.started_at and (not attempt.deadline_at or self.answered_at <= attempt.deadline_at),
                    "Answer time must fall within the attempt window.")
        if self.points_awarded is not None:
            correct = bool(self.selected_option_id and self.selected_option.is_correct)
            require(self.is_correct == correct and self.points_awarded == (self.points_possible if correct else 0),
                    "Grade must match the frozen single-choice answer key.")

    def delete(self, *args, **kwargs):
        protect_delete("Presented questions and answers are permanent history.")
