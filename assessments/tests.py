import json
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from decimal import Decimal
from threading import Event

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.exceptions import ValidationError
from django.db import IntegrityError, connection, models, transaction
from django.test import Client, TestCase, TransactionTestCase
from django.utils import timezone

from config.model_test_utils import CurriculumTestCase
from organization.models import Employee
from training.models import LessonProgress, Module, TrainingAssignment, TrainingVersion
from .models import Assessment, AssessmentAttempt, AssessmentQuestion, AttemptAnswer, Question, QuestionOption, QuestionRevision


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

    def test_assessment_question_order_is_unique_within_assessment(self):
        version = self.new_version()
        module = Module.objects.create(training_version=version, title="Draft module", position=1)
        assessment = Assessment.objects.create(
            training_version=version, module=module, kind=Assessment.Kind.QUIZ, title="Draft quiz",
        )
        other_question = Question.objects.create(code="Q-ORDER", topic="Safety", created_by=self.user)
        other_revision = QuestionRevision.objects.create(
            question=other_question, revision_number=1, prompt="Second question", created_by=self.user,
        )
        QuestionOption.objects.create(question_revision=other_revision, text="A", position=1, is_correct=True)
        QuestionOption.objects.create(question_revision=other_revision, text="B", position=2)
        other_revision.status = QuestionRevision.Status.FROZEN
        other_revision.frozen_at = timezone.now()
        other_revision.save()
        AssessmentQuestion.objects.create(assessment=assessment, question_revision=self.revision, position=1)
        with self.assertRaises(ValidationError):
            AssessmentQuestion.objects.create(assessment=assessment, question_revision=other_revision, position=1)


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


class AssessmentEndpointTests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.other_user = get_user_model().objects.create_user(username="other-employee", password="test-password")
        cls.other_employee = Employee.objects.create(
            employee_code="GN-099", display_name="Other employee", user=cls.other_user,
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(),
        )
        cls.other_assignment = TrainingAssignment.objects.create(
            employee=cls.other_employee, training_version=cls.version,
            department_at_assignment=cls.department, job_role_at_assignment=cls.role,
            assigned_by=cls.user,
        )
        cls.coordinator = get_user_model().objects.create_user(username="assessment-coordinator", password="test-password")
        Group.objects.get(name="Training Coordinator").user_set.add(cls.coordinator)
        Group.objects.get(name="Employee").user_set.add(cls.employee_user)
        cls.employee_group = Group.objects.get(name="Employee")

    def client_for(self, user):
        client = Client()
        client.force_login(user)
        return client

    def start(self, assessment=None, assignment=None):
        assessment = assessment or self.quiz
        assignment = assignment or self.assignment
        return self.client_for(self.employee_user).post(
            f"/assignments/{assignment.pk}/assessments/{assessment.pk}/start/",
        )

    def submit(self, attempt, assessment_question, option):
        return self.client_for(self.employee_user).post(
            f"/attempts/{attempt.pk}/submit/",
            {f"answer_{assessment_question.pk}": option.pk if option else ""},
        )

    def test_only_administrator_and_coordinator_receive_assessment_permissions(self):
        coordinator_group = Group.objects.get(name="Training Coordinator")
        manager_group = Group.objects.get(name="Manager")
        self.assertTrue(coordinator_group.permissions.filter(codename="change_questionrevision").exists())
        self.assertTrue(coordinator_group.permissions.filter(codename="add_assessmentquestion").exists())
        self.assertFalse(manager_group.permissions.filter(content_type__app_label="assessments").exists())

    def test_employee_can_start_only_own_assignment_assessment(self):
        response = self.start(assignment=self.other_assignment)
        self.assertEqual(response.status_code, 404)
        response = self.start()
        self.assertEqual(response.status_code, 409)
        self.complete_lessons()
        response = self.start()
        self.assertEqual(response.status_code, 302)
        self.assertEqual(AssessmentAttempt.objects.filter(assignment=self.assignment).count(), 1)
        attempt_page = self.client_for(self.employee_user).get(response["Location"])
        self.assertContains(attempt_page, "Wear PPE?")
        assignment_page = self.client_for(self.employee_user).get(f"/assignments/{self.assignment.pk}/")
        self.assertContains(assignment_page, "Start assessment")

    def test_text_completion_cannot_bypass_required_video_completion_for_quiz(self):
        LessonProgress.objects.create(
            assignment=self.assignment,
            lesson=self.text_lesson,
            started_at=self.now,
            last_accessed_at=self.now + timedelta(seconds=10),
            completed_at=self.now + timedelta(seconds=10),
        )
        response = self.start()
        self.assertEqual(response.status_code, 409)
        self.assertFalse(AssessmentAttempt.objects.filter(assignment=self.assignment).exists())

    def test_assessment_from_another_version_is_not_startable(self):
        other_version = self.new_version()
        other = Assessment.objects.create(training_version=other_version, kind="FINAL", title="Other version")
        self.assertEqual(self.start(assessment=other).status_code, 404)

    def test_other_employee_cannot_view_or_submit_attempt(self):
        self.complete_lessons()
        self.start()
        attempt = AssessmentAttempt.objects.get(assignment=self.assignment)
        other_client = self.client_for(self.other_user)
        self.assertEqual(other_client.get(f"/attempts/{attempt.pk}/").status_code, 404)
        self.assertEqual(other_client.post(f"/attempts/{attempt.pk}/submit/", {}).status_code, 404)

    def test_foreign_assessment_question_and_foreign_revision_option_are_rejected(self):
        self.complete_lessons()
        self.start()
        attempt = AssessmentAttempt.objects.get(assignment=self.assignment)
        response = self.submit(attempt, self.final_item, self.correct_option)
        self.assertEqual(response.status_code, 400)

        other_question = Question.objects.create(code="Q-OTHER", topic="Other", created_by=self.user)
        other_revision = QuestionRevision.objects.create(
            question=other_question, revision_number=1, prompt="Other question", created_by=self.user,
        )
        other_correct = QuestionOption.objects.create(question_revision=other_revision, text="True", position=1, is_correct=True)
        QuestionOption.objects.create(question_revision=other_revision, text="False", position=2)
        other_revision.question_type = QuestionRevision.QuestionType.TRUE_FALSE
        other_revision.status = QuestionRevision.Status.FROZEN
        other_revision.frozen_at = timezone.now()
        other_revision.save()
        response = self.submit(attempt, self.quiz_item, other_correct)
        self.assertEqual(response.status_code, 400)

    def test_malformed_question_and_option_ids_return_4xx(self):
        self.complete_lessons()
        self.start()
        attempt = AssessmentAttempt.objects.get(assignment=self.assignment)
        client = self.client_for(self.employee_user)
        self.assertEqual(client.post(f"/attempts/{attempt.pk}/submit/", {"answer_invalid": "1"}).status_code, 400)
        self.assertEqual(client.post(f"/attempts/{attempt.pk}/submit/", {f"answer_{self.quiz_item.pk}": "bad"}).status_code, 400)
        response = client.post(
            f"/attempts/{attempt.pk}/submit/",
            data=json.dumps({"answers": {str(self.quiz_item.pk): True}}),
            content_type="application/json",
        )
        self.assertEqual(response.status_code, 400)

    def test_question_bank_permission_and_draft_revision_workflow(self):
        client = self.client_for(self.coordinator)
        question = Question.objects.create(code="Q-EDIT", topic="Safety", created_by=self.user)
        revision = QuestionRevision.objects.create(
            question=question, revision_number=1, prompt="Original", created_by=self.user,
        )
        QuestionOption.objects.create(question_revision=revision, text="Yes", position=1, is_correct=True)
        QuestionOption.objects.create(question_revision=revision, text="No", position=2)
        revision.status = QuestionRevision.Status.FROZEN
        revision.frozen_at = timezone.now()
        revision.save()
        response = client.post(f"/questions/{question.pk}/revisions/new/", {
            "question_type": "SINGLE_CHOICE", "prompt": "Revised", "explanation": "Updated",
        })
        self.assertEqual(response.status_code, 302)
        revision.refresh_from_db()
        self.assertEqual(revision.prompt, "Original")
        self.assertEqual(question.revisions.count(), 2)
        self.assertEqual(client.get(response["Location"]).status_code, 200)

    def test_score_pass_and_client_grade_fields_are_server_controlled(self):
        self.complete_lessons()
        self.start()
        attempt = AssessmentAttempt.objects.get(assignment=self.assignment)
        response = self.client_for(self.employee_user).post(
            f"/attempts/{attempt.pk}/submit/",
            {f"answer_{self.quiz_item.pk}": self.correct_option.pk,
             "score_points": "0", "passed": "false", "is_correct": "false", "points_awarded": "0"},
        )
        self.assertEqual(response.status_code, 302)
        attempt.refresh_from_db()
        self.assertEqual(attempt.score_points, Decimal("2.00"))
        self.assertTrue(attempt.passed)
        with self.assertRaises(ValidationError):
            attempt.answers.get().save()
        self.assertEqual(self.client_for(self.employee_user).post(f"/attempts/{attempt.pk}/submit/", {}).status_code, 409)

    def test_incorrect_answer_does_not_pass_or_create_lesson_completion(self):
        self.complete_lessons()
        existing_progress_count = LessonProgress.objects.filter(assignment=self.assignment).count()
        self.start()
        attempt = AssessmentAttempt.objects.get(assignment=self.assignment)
        response = self.submit(attempt, self.quiz_item, self.wrong_option)
        self.assertEqual(response.status_code, 302)
        attempt.refresh_from_db()
        self.assertEqual(attempt.score_points, Decimal("0"))
        self.assertFalse(attempt.passed)
        self.assertEqual(LessonProgress.objects.filter(assignment=self.assignment).count(), existing_progress_count)
        self.assignment.refresh_from_db()
        self.assertNotEqual(self.assignment.status, TrainingAssignment.Status.COMPLETED)

    def test_attempt_limit_is_enforced_by_start_endpoint(self):
        self.complete_lessons()
        for _ in range(self.quiz.max_attempts):
            self.finish_attempt(correct=False)
        response = self.start()
        self.assertEqual(response.status_code, 409)

    def test_final_assessment_requires_all_lesson_and_quiz_prerequisites(self):
        self.assertEqual(self.start(self.final).status_code, 409)
        self.complete_lessons()
        self.assertEqual(self.start(self.final).status_code, 409)

    def test_passed_final_completes_assignment_only_when_all_requirements_pass(self):
        self.complete_lessons()
        self.finish_attempt(self.quiz)
        self.assertEqual(self.assignment.status, TrainingAssignment.Status.IN_PROGRESS)
        response = self.start(self.final)
        self.assertEqual(response.status_code, 302)
        attempt = AssessmentAttempt.objects.get(assignment=self.assignment, assessment=self.final)
        response = self.submit(attempt, self.final_item, self.correct_option)
        self.assertEqual(response.status_code, 302)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, TrainingAssignment.Status.COMPLETED)
        self.assertIsNotNone(self.assignment.completed_at)
        self.assertEqual(self.start().status_code, 404)

    def test_failed_final_does_not_complete_assignment(self):
        self.complete_lessons()
        self.finish_attempt(self.quiz)
        self.start(self.final)
        attempt = AssessmentAttempt.objects.get(assignment=self.assignment, assessment=self.final)
        self.submit(attempt, self.final_item, self.wrong_option)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, TrainingAssignment.Status.IN_PROGRESS)
        self.assertIsNone(self.assignment.completed_at)

    def test_attempt_uses_frozen_assessment_revision_after_new_revision(self):
        self.complete_lessons()
        self.start()
        attempt = AssessmentAttempt.objects.get(assignment=self.assignment)
        new_revision = QuestionRevision.objects.create(
            question=self.question, revision_number=2, prompt="Updated question", created_by=self.user,
        )
        QuestionOption.objects.create(question_revision=new_revision, text="Yes", position=1, is_correct=True)
        QuestionOption.objects.create(question_revision=new_revision, text="No", position=2)
        new_revision.status = QuestionRevision.Status.FROZEN
        new_revision.frozen_at = timezone.now()
        new_revision.save()
        self.submit(attempt, self.quiz_item, self.correct_option)
        answer = AttemptAnswer.objects.get(attempt=attempt)
        self.assertEqual(answer.assessment_question.question_revision.prompt, "Wear PPE?")
        self.assertEqual(answer.points_awarded, Decimal("2.00"))

    def test_content_management_is_permission_gated(self):
        employee_client = self.client_for(self.employee_user)
        self.assertEqual(employee_client.get("/questions/").status_code, 403)
        coordinator_client = self.client_for(self.coordinator)
        self.assertEqual(coordinator_client.get("/questions/").status_code, 200)

    def test_assessment_parents_are_derived_and_published_assessments_are_read_only(self):
        version = self.new_version()
        module = Module.objects.create(training_version=version, title="Draft module", position=1)
        client = self.client_for(self.coordinator)
        response = client.post(f"/versions/{version.pk}/assessments/new/", {
            "kind": "QUIZ", "module": module.pk, "title": "Draft quiz", "sequence": 1,
            "pass_percentage": "80.00", "max_attempts": 2, "time_limit_minutes": "",
            "is_required": "on", "training_version": self.version.pk,
        })
        self.assertEqual(response.status_code, 302)
        assessment = Assessment.objects.get(title="Draft quiz")
        self.assertEqual(assessment.training_version_id, version.pk)
        response = client.post(f"/assessments/{assessment.pk}/questions/new/", {
            "question_revision": self.revision.pk, "position": 1, "points": "2.00",
            "assessment": self.final.pk,
        })
        self.assertEqual(response.status_code, 302)
        item = assessment.questions.get()
        self.assertEqual(item.assessment_id, assessment.pk)
        self.assertEqual(client.get(f"/assessments/{self.quiz.pk}/edit/").status_code, 404)

    def test_duplicate_assessment_sequence_create_is_a_form_error(self):
        version = self.new_version()
        module = Module.objects.create(training_version=version, title="Draft module", position=1)
        Assessment.objects.create(training_version=version, module=module, kind="QUIZ", title="First", sequence=1)
        response = self.client_for(self.coordinator).post(f"/versions/{version.pk}/assessments/new/", {
            "kind": "QUIZ", "module": module.pk, "title": "Duplicate", "sequence": 1,
            "pass_percentage": "80.00", "max_attempts": 3, "time_limit_minutes": "", "is_required": "on",
            "training_version": self.version.pk,
        })
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "This sequence is already used", html=False)
        self.assertContains(response, "Duplicate")
        self.assertFalse(Assessment.objects.filter(training_version=version, title="Duplicate").exists())

    def test_duplicate_assessment_sequence_edit_is_a_form_error_and_unchanged_sequence_succeeds(self):
        version = self.new_version()
        module = Module.objects.create(training_version=version, title="Draft module", position=1)
        Assessment.objects.create(training_version=version, module=module, kind="QUIZ", title="First", sequence=1)
        second = Assessment.objects.create(training_version=version, module=module, kind="QUIZ", title="Second", sequence=2)
        client = self.client_for(self.coordinator)
        data = {
            "kind": "QUIZ", "module": module.pk, "title": "Edited", "sequence": 1,
            "pass_percentage": "80.00", "max_attempts": 3, "time_limit_minutes": "", "is_required": "on",
            "training_version": self.version.pk,
        }
        response = client.post(f"/assessments/{second.pk}/edit/", data)
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "This sequence is already used", html=False)
        second.refresh_from_db()
        self.assertEqual((second.title, second.sequence, second.training_version_id), ("Second", 2, version.pk))
        data["sequence"] = 2
        self.assertEqual(client.post(f"/assessments/{second.pk}/edit/", data).status_code, 302)
        second.refresh_from_db()
        self.assertEqual((second.title, second.sequence, second.training_version_id), ("Edited", 2, version.pk))


class AssessmentLockingTests(TransactionTestCase):
    databases = {"default"}

    def setUp(self):
        if connection.vendor != "mysql":
            self.skipTest("Row-lock concurrency coverage requires MySQL.")
        CurriculumTestCase.setUpTestData.__func__(type(self))

    def test_revision_creations_serialize_on_question(self):
        user = get_user_model().objects.create_superuser(username="revision-admin", password="test-password")
        clients = [Client(), Client()]
        for client in clients:
            client.force_login(user)
        started = Event()

        def create_revision(client):
            started.set()
            return client.post(f"/questions/{self.question.pk}/revisions/new/", {
                "question_type": "SINGLE_CHOICE", "prompt": "Concurrent revision", "explanation": "",
            }).status_code

        with ThreadPoolExecutor(max_workers=2) as executor:
            with transaction.atomic():
                Question.objects.select_for_update().get(pk=self.question.pk)
                futures = [executor.submit(create_revision, client) for client in clients]
                self.assertTrue(started.wait(5))
                time.sleep(0.2)
                self.assertTrue(all(not future.done() for future in futures))
            self.assertEqual([future.result(timeout=10) for future in futures], [302, 302])
        self.assertEqual(list(self.question.revisions.order_by("revision_number").values_list("revision_number", flat=True)), [1, 2, 3])

    def test_submission_waits_for_employee_before_locking_assignment(self):
        CurriculumTestCase.complete_lessons(self)
        now = timezone.now()
        attempt = AssessmentAttempt.objects.create(
            assignment=self.assignment, assessment=self.quiz, attempt_number=1,
            started_at=now, deadline_at=now + timedelta(minutes=1),
            maximum_points=Decimal("2.00"), pass_percentage_snapshot=self.quiz.pass_percentage,
        )
        client = Client()
        client.force_login(self.employee_user)
        started = Event()

        def submit():
            started.set()
            return client.post(f"/attempts/{attempt.pk}/submit/", {
                f"answer_{self.quiz_item.pk}": self.correct_option.pk,
            }).status_code

        with ThreadPoolExecutor(max_workers=1) as executor:
            with transaction.atomic():
                Employee.objects.select_for_update().get(pk=self.employee.pk)
                future = executor.submit(submit)
                self.assertTrue(started.wait(5))
                time.sleep(0.2)
                self.assertFalse(future.done())
                # The request must wait on the employee before taking this row lock.
                TrainingAssignment.objects.select_for_update(nowait=True).get(pk=self.assignment.pk)
            self.assertEqual(future.result(timeout=10), 302)
        attempt.refresh_from_db()
        self.assertTrue(attempt.passed)

    def test_start_attempt_waits_for_employee_before_locking_assignment(self):
        CurriculumTestCase.complete_lessons(self)
        client = Client()
        client.force_login(self.employee_user)
        started = Event()

        def start():
            started.set()
            return client.post(f"/assignments/{self.assignment.pk}/assessments/{self.quiz.pk}/start/").status_code

        with ThreadPoolExecutor(max_workers=1) as executor:
            with transaction.atomic():
                Employee.objects.select_for_update().get(pk=self.employee.pk)
                future = executor.submit(start)
                self.assertTrue(started.wait(5))
                time.sleep(0.2)
                self.assertFalse(future.done())
                TrainingAssignment.objects.select_for_update(nowait=True).get(pk=self.assignment.pk)
            self.assertEqual(future.result(timeout=10), 302)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, TrainingAssignment.Status.IN_PROGRESS)
        self.assertEqual(self.assignment.attempts.count(), 1)
