from datetime import timedelta
from decimal import Decimal

from django.core.exceptions import ValidationError
from django.db import IntegrityError, models, transaction

from config.model_test_utils import CurriculumTestCase
from .models import Assessment, AssessmentAttempt, AssessmentQuestion, AttemptAnswer, QuestionOption, QuestionRevision


class QuestionHistoryTests(CurriculumTestCase):
    def test_frozen_revision_and_options_are_immutable(self):
        self.revision.prompt = "Changed question"
        with self.assertRaises(ValidationError):
            self.revision.save()
        self.correct_option.is_correct = False
        with self.assertRaises(ValidationError):
            self.correct_option.save()
        with self.assertRaises(ValidationError):
            QuestionOption.objects.create(question_revision=self.revision, text="Another", position=3)
        with self.assertRaises(ValidationError):
            self.wrong_option.delete()

    def test_question_revision_requires_one_correct_answer(self):
        revision = QuestionRevision.objects.create(question=self.question, revision_number=2, prompt="Changed?", created_by=self.user)
        QuestionOption.objects.create(question_revision=revision, text="A", position=1)
        QuestionOption.objects.create(question_revision=revision, text="B", position=2)
        revision.status = "FROZEN"
        revision.frozen_at = self.now
        with self.assertRaises(ValidationError):
            revision.save()

    def test_new_revision_does_not_change_historical_attempt(self):
        attempt = self.finish_attempt()
        QuestionRevision.objects.create(question=self.question, revision_number=2, prompt="New question wording", created_by=self.user)
        self.question.is_active = False
        self.question.save()
        answer = attempt.answers.get()
        self.assertEqual(answer.assessment_question.question_revision.prompt, "Wear PPE?")
        self.assertEqual(answer.selected_option.text, "Yes")
        self.assertEqual(answer.points_awarded, Decimal("2.00"))

    def test_multiple_revisions_of_question_cannot_enter_same_assessment(self):
        assessment = Assessment.objects.create(training_version=self.new_version(), kind="FINAL", title="New final")
        AssessmentQuestion.objects.create(assessment=assessment, question_revision=self.revision, position=1)
        revision = QuestionRevision.objects.create(question=self.question, revision_number=2, prompt="New", created_by=self.user)
        with self.assertRaises(ValidationError):
            AssessmentQuestion.objects.create(assessment=assessment, question_revision=revision, position=2)

    def test_database_allows_only_one_final_per_version(self):
        other = Assessment(training_version=self.version, kind="FINAL", title="Duplicate final", sequence=1)
        with self.assertRaises(IntegrityError), transaction.atomic():
            models.Model.save(other, force_insert=True)
        other.sequence = 2
        with self.assertRaises(IntegrityError), transaction.atomic():
            models.Model.save(other, force_insert=True)


class AttemptTests(CurriculumTestCase):
    def test_final_requires_lessons_and_module_quiz(self):
        with self.assertRaises(ValidationError):
            self.start_attempt(self.final)
        self.complete_lessons()
        with self.assertRaises(ValidationError):
            self.start_attempt(self.final)
        self.finish_attempt(self.quiz)
        self.assertEqual(self.start_attempt(self.final).status, "IN_PROGRESS")

    def test_only_one_ongoing_attempt_allowed(self):
        self.start_attempt()
        with self.assertRaises(ValidationError):
            self.start_attempt()

    def test_attempt_limit_and_sequential_numbering(self):
        for _ in range(3):
            self.finish_attempt(correct=False)
        with self.assertRaises(ValidationError):
            self.start_attempt()
        self.assertEqual(self.assignment.attempts.count(), 3)

    def test_attempt_version_must_match_assignment(self):
        other = Assessment.objects.create(training_version=self.new_version(), kind="FINAL", title="Other version")
        with self.assertRaises(ValidationError):
            self.start_attempt(other)

    def test_answers_must_use_attempt_question_and_matching_option(self):
        attempt = self.start_attempt()
        with self.assertRaises(ValidationError):
            AttemptAnswer.objects.create(attempt=attempt, assessment_question=self.final_item, presented_position=1, points_possible=2)
        revision = QuestionRevision.objects.create(question=self.question, revision_number=2, prompt="Changed", created_by=self.user)
        option = QuestionOption.objects.create(question_revision=revision, text="Different revision", position=1)
        with self.assertRaises(ValidationError):
            AttemptAnswer.objects.create(attempt=attempt, assessment_question=self.quiz_item, selected_option=option,
                                         answered_at=attempt.started_at, presented_position=1, points_possible=2)

    def test_submitted_attempt_and_answers_cannot_change(self):
        attempt = self.finish_attempt()
        attempt.score_points = 0
        with self.assertRaises(ValidationError):
            attempt.save()
        answer = attempt.answers.get()
        answer.selected_option = self.wrong_option
        with self.assertRaises(ValidationError):
            answer.save()
        with self.assertRaises(ValidationError):
            attempt.delete()

    def test_unanswered_question_is_preserved_and_scores_zero(self):
        attempt = self.start_attempt()
        answer = AttemptAnswer.objects.create(attempt=attempt, assessment_question=self.quiz_item, presented_position=1,
                                             points_possible=2, points_awarded=0, is_correct=False)
        attempt.status = "SUBMITTED"
        attempt.submitted_at = attempt.started_at + timedelta(seconds=2)
        attempt.score_points = 0
        attempt.passed = False
        attempt.save()
        self.assertIsNone(answer.selected_option)
        self.assertFalse(attempt.passed)

    def test_incorrect_grade_rejected(self):
        attempt = self.start_attempt()
        answer = self.answer_attempt(attempt)
        answer.points_awarded = 0
        with self.assertRaises(ValidationError):
            answer.save()

    def test_cached_answer_option_cannot_change_the_answer_key(self):
        attempt = self.start_attempt()
        self.wrong_option.is_correct = True
        with self.assertRaises(ValidationError):
            AttemptAnswer.objects.create(attempt=attempt, assessment_question=self.quiz_item,
                selected_option=self.wrong_option, presented_position=1, answered_at=attempt.started_at,
                points_possible=2, points_awarded=2, is_correct=True)

    def test_cancelled_assignment_cannot_receive_answers(self):
        attempt = self.start_attempt()
        self.assignment.status = "CANCELLED"
        self.assignment.cancelled_at = self.now
        self.assignment.cancellation_reason = "Cancelled"
        self.assignment.save()
        with self.assertRaises(ValidationError):
            self.answer_attempt(attempt)

    def test_incorrect_totals_and_missing_answers_rejected(self):
        attempt = self.start_attempt()
        attempt.status = "SUBMITTED"
        attempt.submitted_at = attempt.started_at + timedelta(seconds=2)
        attempt.score_points = 2
        attempt.passed = True
        with self.assertRaises(ValidationError):
            attempt.save()
        attempt.refresh_from_db()
        self.answer_attempt(attempt)
        attempt.status = "SUBMITTED"
        attempt.submitted_at = attempt.started_at + timedelta(seconds=2)
        attempt.score_points = 0
        attempt.passed = False
        with self.assertRaises(ValidationError):
            attempt.save()

    def test_deactivated_employee_cannot_start_attempt(self):
        self.employee.is_active = False
        self.employee.deactivation_reason = "Left"
        self.employee.save()
        with self.assertRaises(ValidationError):
            self.start_attempt()

    def test_scoring_snapshot_cannot_be_changed(self):
        attempt = self.start_attempt()
        attempt.pass_percentage_snapshot = 10
        with self.assertRaises(ValidationError):
            attempt.save()

    def test_late_submission_expires_and_preserves_answers(self):
        attempt = self.start_attempt()
        self.answer_attempt(attempt)
        attempt.status = "SUBMITTED"
        attempt.submitted_at = attempt.deadline_at + timedelta(seconds=1)
        attempt.score_points = 2
        attempt.passed = True
        with self.assertRaises(ValidationError):
            attempt.save()
        attempt.status = "EXPIRED"
        attempt.passed = False
        attempt.save()
        self.assertEqual(attempt.answers.count(), 1)
        answer = attempt.answers.get()
        with self.assertRaises(ValidationError):
            answer.save()

    def test_answer_after_deadline_rejected(self):
        attempt = self.start_attempt()
        with self.assertRaises(ValidationError):
            AttemptAnswer.objects.create(attempt=attempt, assessment_question=self.quiz_item,
                selected_option=self.correct_option, answered_at=attempt.deadline_at + timedelta(seconds=1),
                presented_position=1, points_possible=2)
