from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from decimal import Decimal
from tempfile import TemporaryDirectory
from threading import Barrier
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError
from django.db import connection, connections
from django.test import TransactionTestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from assessments.models import Assessment, AssessmentAttempt, AssessmentQuestion, Question, QuestionOption, QuestionRevision
from certifications.models import Certificate
from config.model_test_utils import CurriculumTestCase
from organization.models import Employee
from training.models import Lesson, LessonProgress, Module, TrainingAssignment, TrainingVersion


class AssessmentAPIRequests:
	def authenticated_client(self, user=None):
		client = APIClient()
		token = RefreshToken.for_user(user or self.employee_user).access_token
		client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
		return client

	def list_url(self, assignment=None):
		return reverse("api:v1:assessment-list", args=[(assignment or self.assignment).pk])

	def start_url(self, assessment=None, assignment=None):
		return reverse("api:v1:assessment-start", args=[(assignment or self.assignment).pk, (assessment or self.quiz).pk])

	def detail_url(self, attempt_id):
		return reverse("api:v1:assessment-attempt-detail", args=[attempt_id])

	def submit_url(self, attempt_id):
		return reverse("api:v1:assessment-submit", args=[attempt_id])

	def submit(self, attempt_id, *, item=None, option=None):
		return self.client.post(self.submit_url(attempt_id), {
			"answers": {str((item or self.quiz_item).pk): (option or self.correct_option).pk},
		}, format="json")


class AssessmentAPITests(AssessmentAPIRequests, CurriculumTestCase):
	def setUp(self):
		self.client = self.authenticated_client()

	def start(self, assessment=None):
		response = self.client.post(self.start_url(assessment), {}, format="json")
		self.assertEqual(response.status_code, 201, response.data)
		return response.data["id"]

	def state(self, assessment=None):
		response = self.client.get(self.list_url())
		self.assertEqual(response.status_code, 200, response.data)
		return next(item for item in response.data["assessments"] if item["id"] == (assessment or self.quiz).pk)

	def other_learner(self):
		user = get_user_model().objects.create_user(username="other-assessment-learner")
		employee = Employee.objects.create(
			employee_code="ASSESS-OTHER", display_name="Other QA learner", user=user,
			department=self.department, job_role=self.role, date_joined=self.now.date(),
		)
		assignment = TrainingAssignment.objects.create(
			employee=employee, training_version=self.version, department_at_assignment=self.department,
			job_role_at_assignment=self.role, assigned_by=self.user, assigned_at=self.now,
		)
		return user, assignment

	def test_overview_reports_pinned_curriculum_and_authoritative_prerequisites(self):
		state = self.state()
		self.assertEqual((state["kind"], state["module_id"], state["sequence"]), ("QUIZ", self.module.pk, 1))
		self.assertEqual((state["pass_percentage"], state["time_limit_minutes"]), ("80.00", 1))
		self.assertEqual((state["attempts_used"], state["attempts_remaining"]), (0, self.quiz.max_attempts))
		self.assertFalse(state["can_start"])
		self.assertIn("required module lessons", state["blocking_reason"])
		self.assertFalse(state["passed"])
		self.assertIsNone(state["ongoing_attempt_id"])
		self.assertEqual(self.client.post(self.start_url(), {}).status_code, 409)
		self.assertEqual(self.client.post(self.start_url(self.final), {}).status_code, 409)
		self.assertFalse(AssessmentAttempt.objects.exists())

	def test_text_completion_does_not_bypass_video_or_final_quiz_prerequisites(self):
		url = reverse("api:v1:lesson-complete", args=[self.assignment.pk, self.text_lesson.pk])
		self.assertEqual(self.client.post(url, {}, format="json").status_code, 200)
		self.assertFalse(self.state()["can_start"])
		self.assertEqual(self.client.post(self.start_url(), {}).status_code, 409)
		self.assertFalse(LessonProgress.objects.filter(lesson=self.video_lesson, completed_at__isnull=False).exists())
		LessonProgress.objects.create(
			assignment=self.assignment, lesson=self.video_lesson, started_at=self.now,
			last_accessed_at=timezone.now(), completed_at=timezone.now(), watched_ranges=[[0, 95]],
		)
		self.assertIn("Pass required quizzes", self.state(self.final)["blocking_reason"])
		self.assertEqual(self.client.post(self.start_url(self.final), {}).status_code, 409)

	def test_start_resume_and_detail_expose_frozen_display_data_without_keys_or_drafts(self):
		self.complete_lessons()
		attempt_id = self.start()
		response = self.client.post(self.start_url(), {"answers": {str(self.quiz_item.pk): self.correct_option.pk}}, format="json")
		self.assertEqual((response.status_code, response.data["id"]), (200, attempt_id))
		state = self.state()
		self.assertTrue(state["can_resume"])
		self.assertFalse(state["can_start"])
		self.assertEqual((state["ongoing_attempt_id"], state["attempts_used"]), (attempt_id, 1))
		data = self.client.get(self.detail_url(attempt_id)).data
		self.assertEqual(data["assignment_id"], self.assignment.pk)
		self.assertEqual(data["maximum_points"], "2.00")
		self.assertIsNotNone(data["deadline_at"])
		self.assertEqual(data["answers"], [])
		question = data["questions"][0]
		self.assertEqual((question["id"], question["prompt"], question["type"]), (self.quiz_item.pk, "Wear PPE?", "SINGLE_CHOICE"))
		self.assertEqual([option["id"] for option in question["options"]], [self.correct_option.pk, self.wrong_option.pk])
		self.assertEqual(set(question["options"][0]), {"id", "text", "position"})
		for private in ("is_correct", "explanation", "correct_option", "question_revision_id"):
			self.assertNotIn(private, str(data))
		self.assertFalse(AssessmentAttempt.objects.get(pk=attempt_id).answers.exists())
		self.assertEqual(self.assignment.attempts.count(), 1)

	def test_start_transitions_assigned_assignment_and_ignores_posted_ownership(self):
		self.complete_lessons()
		self.assignment.status = TrainingAssignment.Status.ASSIGNED
		self.assignment.started_at = None
		self.assignment.save()
		_, other = self.other_learner()
		response = self.client.post(self.start_url(), {"assignment_id": other.pk, "assessment_id": self.final.pk}, format="json")
		self.assertEqual(response.status_code, 201)
		attempt = AssessmentAttempt.objects.get(pk=response.data["id"])
		self.assertEqual((attempt.assignment_id, attempt.assessment_id), (self.assignment.pk, self.quiz.pk))
		self.assignment.refresh_from_db()
		self.assertEqual(self.assignment.status, "IN_PROGRESS")
		self.assertIsNotNone(self.assignment.started_at)
		self.assertFalse(other.attempts.exists())

	def test_all_endpoints_require_jwt_and_reject_session_only_login(self):
		self.complete_lessons()
		attempt_id = self.start()
		client = APIClient()
		client.force_login(self.employee_user)
		for method, url in (("get", self.list_url()), ("post", self.start_url()),
				("get", self.detail_url(attempt_id)), ("post", self.submit_url(attempt_id))):
			with self.subTest(url=url):
				response = getattr(client, method)(url)
				self.assertEqual(response.status_code, 401)
				self.assertIn("error", response.data)

	def test_expired_and_invalid_tokens_are_rejected(self):
		token = RefreshToken.for_user(self.employee_user).access_token
		token.set_exp(lifetime=timedelta(seconds=-1))
		for value in (str(token), "not-a-token"):
			with self.subTest(token_kind="expired" if value == str(token) else "invalid"):
				self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {value}")
				self.assertEqual(self.client.get(self.list_url()).status_code, 401)

	def test_inactive_user_employee_and_unlinked_admin_cannot_access(self):
		self.employee_user.is_active = False
		self.employee_user.save()
		self.assertEqual(self.client.get(self.list_url()).status_code, 401)
		self.employee_user.is_active = True
		self.employee_user.save()
		self.employee.is_active = False
		self.employee.deactivation_reason = "QA inactive"
		self.employee.save()
		self.assertEqual(self.client.get(self.list_url()).status_code, 401)
		# Employee deactivation also disables its User. Exercise the separate permission guard.
		self.employee_user.is_active = True
		self.employee_user.save()
		self.assertEqual(self.client.get(self.list_url()).status_code, 403)
		self.user.is_staff = self.user.is_superuser = True
		self.user.save()
		self.assertEqual(self.authenticated_client(self.user).get(self.list_url()).status_code, 403)

	def test_cross_account_access_is_hidden_even_for_an_admin_with_employee_record(self):
		self.complete_lessons()
		attempt_id = self.start()
		user, other = self.other_learner()
		user.is_staff = user.is_superuser = True
		user.save()
		client = self.authenticated_client(user)
		for method, url in (("get", self.list_url()), ("post", self.start_url()),
				("get", self.detail_url(attempt_id)), ("post", self.submit_url(attempt_id))):
			with self.subTest(url=url):
				self.assertEqual(getattr(client, method)(url).status_code, 404)
		self.assertEqual(self.client.get(self.list_url(other)).status_code, 404)
		self.assertEqual(self.client.post(self.start_url(assignment=other), {}).status_code, 404)
		self.assertFalse(other.attempts.exists())

	def test_other_version_and_unknown_assessment_cannot_start_or_leak_into_list(self):
		version = self.new_version()
		other = Assessment.objects.create(training_version=version, kind="FINAL", title="Private draft final")
		response = self.client.get(self.list_url())
		self.assertNotIn(other.pk, [item["id"] for item in response.data["assessments"]])
		self.assertEqual(self.client.post(self.start_url(other), {}).status_code, 404)
		unknown = reverse("api:v1:assessment-start", args=[self.assignment.pk, 999999])
		self.assertEqual(self.client.post(unknown, {}).status_code, 404)

	def test_retired_pinned_version_remains_eligible_but_new_assignment_is_rejected(self):
		self.version.status = TrainingVersion.Status.RETIRED
		self.version.save()
		self.complete_lessons()
		self.assertTrue(self.state()["can_start"])
		attempt_id = self.start()
		self.assertEqual(self.submit(attempt_id).status_code, 200)
		user = get_user_model().objects.create_user(username="retired-new-assignment")
		employee = Employee.objects.create(
			employee_code="RETIRED-NEW", display_name="QA", user=user, department=self.department,
			job_role=self.role, date_joined=self.now.date(),
		)
		with self.assertRaises(ValidationError):
			TrainingAssignment.objects.create(employee=employee, training_version=self.version,
				department_at_assignment=self.department, job_role_at_assignment=self.role)

	def test_passed_quiz_cannot_restart_and_history_remains_readable(self):
		self.complete_lessons()
		attempt_id = self.start()
		self.assertEqual(self.submit(attempt_id).status_code, 200)
		state = self.state()
		self.assertTrue(state["passed"] and state["completed"])
		self.assertFalse(state["can_start"] or state["can_resume"])
		response = self.client.post(self.start_url(), {})
		self.assertEqual(response.status_code, 409)
		self.assertIn("already passed", response.data["error"]["message"])
		self.assertEqual(len(state["attempts"]), 1)
		self.assertEqual(self.client.get(self.detail_url(attempt_id)).status_code, 200)
		self.assertEqual(self.assignment.attempts.count(), 1)

	def test_failed_retry_attempt_limit_and_no_quiz_lesson_progress(self):
		self.complete_lessons()
		before = list(self.assignment.lesson_progress.values())
		for number in range(1, self.quiz.max_attempts + 1):
			attempt_id = self.start()
			response = self.submit(attempt_id, option=self.wrong_option)
			self.assertFalse(response.data["passed"])
			self.assertEqual(response.data["attempt_number"], number)
		state = self.state()
		self.assertEqual((state["attempts_used"], state["attempts_remaining"]), (self.quiz.max_attempts, 0))
		self.assertIn("attempt limit", state["blocking_reason"])
		self.assertEqual(self.client.post(self.start_url(), {}).status_code, 409)
		self.assertEqual(before, list(self.assignment.lesson_progress.values()))
		self.assertFalse(Certificate.objects.exists())

	def test_submission_returns_persisted_result_and_repeated_submission_is_conflict(self):
		self.complete_lessons()
		attempt_id = self.start()
		response = self.submit(attempt_id)
		self.assertEqual(response.status_code, 200)
		self.assertEqual((response.data["status"], response.data["score_points"], response.data["passed"]), ("SUBMITTED", "2.00", True))
		self.assertEqual(response.data["questions"], [])
		answer = response.data["answers"][0]
		self.assertEqual((answer["assessment_question_id"], answer["selected_option_id"]), (self.quiz_item.pk, self.correct_option.pk))
		self.assertEqual(answer["selected_option_text"], "Yes")
		self.assertNotIn("is_correct", answer)
		self.assertEqual(self.client.get(self.detail_url(attempt_id)).data, response.data)
		self.assertEqual(self.submit(attempt_id).status_code, 409)
		self.assertEqual(AssessmentAttempt.objects.get(pk=attempt_id).answers.count(), 1)

	def test_forged_scoring_or_ownership_fields_cannot_be_submitted(self):
		self.complete_lessons()
		attempt_id = self.start()
		response = self.client.post(self.submit_url(attempt_id), {
			"answers": {str(self.quiz_item.pk): self.wrong_option.pk},
			"score_points": "2.00", "passed": True, "assignment_id": 999999, "completed": True,
		}, format="json")
		self.assertEqual(response.status_code, 400)
		self.assertFalse(AssessmentAttempt.objects.get(pk=attempt_id).answers.exists())
		response = self.submit(attempt_id, option=self.wrong_option)
		self.assertEqual((response.data["score_points"], response.data["passed"]), ("0.00", False))

	def test_malformed_answers_and_normalized_duplicates_return_controlled_errors_without_writes(self):
		self.complete_lessons()
		attempt_id = self.start()
		key = str(self.quiz_item.pk)
		payloads = [None, [], {"answers": []}, {}, {"answers": {"bad": 1}},
			{"answers": {"0": 1}}, {"answers": {"-1": 1}}, {"answers": {key: True}},
			{"answers": {key: 1.5}}, {"answers": {key: -1}}, {"answers": {key: [1, 2]}},
			{"answers": {key: self.correct_option.pk, "0" + key: self.wrong_option.pk}}]
		for payload in payloads:
			with self.subTest(payload=payload):
				response = self.client.post(self.submit_url(attempt_id), payload, format="json")
				self.assertEqual(response.status_code, 400, response.data)
				self.assertIn("error", response.data)
		response = self.client.post(self.submit_url(attempt_id), "{broken", content_type="application/json")
		self.assertEqual(response.status_code, 400)
		self.assertFalse(AssessmentAttempt.objects.get(pk=attempt_id).answers.exists())

	def test_forged_question_and_revision_option_are_rejected_atomically(self):
		self.complete_lessons()
		attempt_id = self.start()
		question = Question.objects.create(code="FOREIGN", created_by=self.user)
		revision = QuestionRevision.objects.create(question=question, revision_number=1, prompt="Foreign", created_by=self.user)
		option = QuestionOption.objects.create(question_revision=revision, text="Foreign option", position=1, is_correct=True)
		for answers in ({str(self.final_item.pk): self.correct_option.pk}, {str(self.quiz_item.pk): option.pk}, {str(self.quiz_item.pk): 999999}):
			with self.subTest(answers=answers):
				response = self.client.post(self.submit_url(attempt_id), {"answers": answers}, format="json")
				self.assertEqual(response.status_code, 400)
				self.assertFalse(AssessmentAttempt.objects.get(pk=attempt_id).answers.exists())

	def test_unanswered_questions_score_zero(self):
		self.complete_lessons()
		attempt_id = self.start()
		response = self.client.post(self.submit_url(attempt_id), {"answers": {}}, format="json")
		self.assertEqual(response.status_code, 200)
		self.assertFalse(response.data["passed"])
		self.assertIsNone(response.data["answers"][0]["selected_option_id"])
		self.assertEqual(response.data["score_points"], "0.00")

	def test_new_question_revision_does_not_change_attempt_questions_or_grading(self):
		self.complete_lessons()
		attempt_id = self.start()
		revision = QuestionRevision.objects.create(
			question=self.question, revision_number=2, prompt="Updated prompt", created_by=self.user,
		)
		option = QuestionOption.objects.create(question_revision=revision, text="Different key", position=1, is_correct=True)
		QuestionOption.objects.create(question_revision=revision, text="Other", position=2)
		revision.status = "FROZEN"
		revision.frozen_at = timezone.now()
		revision.save()
		detail = self.client.get(self.detail_url(attempt_id)).data
		self.assertEqual(detail["questions"][0]["prompt"], self.revision.prompt)
		self.assertEqual(self.submit(attempt_id, option=option).status_code, 400)
		self.assertTrue(self.submit(attempt_id).data["passed"])
		self.assertEqual(self.client.get(self.detail_url(attempt_id)).data["answers"][0]["prompt"], self.revision.prompt)

	def test_ordered_true_false_questions_atomic_validation_and_exact_decimal_threshold(self):
		version = self.new_version()
		module = Module.objects.create(training_version=version, title="Decimal QA", position=1)
		lesson = Lesson.objects.create(module=module, title="Read", position=1, content_type="TEXT", body="Read first.")
		question = Question.objects.create(code="TRUE-FALSE", created_by=self.user)
		revision = QuestionRevision.objects.create(
			question=question, revision_number=1, prompt="Is this true?", question_type="TRUE_FALSE", created_by=self.user,
		)
		correct = QuestionOption.objects.create(question_revision=revision, text="True", position=1, is_correct=True)
		wrong = QuestionOption.objects.create(question_revision=revision, text="False", position=2)
		revision.status = "FROZEN"
		revision.frozen_at = timezone.now()
		revision.save()
		final = Assessment.objects.create(training_version=version, kind="FINAL", title="Decimal final")
		second = AssessmentQuestion.objects.create(assessment=final, question_revision=revision, position=2, points=Decimal("0.20"))
		first = AssessmentQuestion.objects.create(assessment=final, question_revision=self.revision, position=1, points=Decimal("0.80"))
		version.status = "PUBLISHED"
		version.published_at = timezone.now()
		version.published_by = self.user
		version.save()
		assignment = TrainingAssignment.objects.create(
			employee=self.employee, training_version=version, department_at_assignment=self.department,
			job_role_at_assignment=self.role, assigned_by=self.user,
		)
		url = reverse("api:v1:lesson-complete", args=[assignment.pk, lesson.pk])
		self.assertEqual(self.client.post(url, {}, format="json").status_code, 200)
		response = self.client.post(self.start_url(final, assignment), {}, format="json")
		self.assertEqual(response.status_code, 201, response.data)
		self.assertEqual([item["id"] for item in response.data["questions"]], [first.pk, second.pk])
		self.assertEqual(response.data["questions"][1]["type"], "TRUE_FALSE")
		attempt_id = response.data["id"]
		# A bad second answer rolls back the valid first answer too.
		response = self.client.post(self.submit_url(attempt_id), {"answers": {
			str(first.pk): self.correct_option.pk, str(second.pk): self.correct_option.pk,
		}}, format="json")
		self.assertEqual(response.status_code, 400)
		self.assertFalse(AssessmentAttempt.objects.get(pk=attempt_id).answers.exists())
		response = self.client.post(self.submit_url(attempt_id), {"answers": {
			str(first.pk): self.wrong_option.pk, str(second.pk): correct.pk,
		}}, format="json")
		self.assertEqual((response.data["score_points"], response.data["passed"]), ("0.20", False))
		response = self.client.post(self.start_url(final, assignment), {}, format="json")
		self.assertEqual(response.status_code, 201)
		response = self.client.post(self.submit_url(response.data["id"]), {"answers": {
			str(first.pk): self.correct_option.pk, str(second.pk): wrong.pk,
		}}, format="json")
		self.assertEqual((response.data["score_points"], response.data["maximum_points"], response.data["passed"]), ("0.80", "1.00", True))

	def test_deadline_exact_boundary_passes_and_late_submission_expires_only_on_submit(self):
		self.complete_lessons()
		first_id = self.start()
		first = AssessmentAttempt.objects.get(pk=first_id)
		with patch("assessments.views.timezone.now", return_value=first.deadline_at + timedelta(microseconds=1)):
			self.assertEqual(self.client.get(self.detail_url(first_id)).data["status"], "IN_PROGRESS")
			resume = self.client.post(self.start_url(), {})
			self.assertEqual((resume.status_code, resume.data["id"]), (200, first_id))
			response = self.submit(first_id)
		self.assertEqual((response.data["status"], response.data["score_points"], response.data["passed"]), ("EXPIRED", "0.00", False))
		second_id = self.start()
		second = AssessmentAttempt.objects.get(pk=second_id)
		with patch("assessments.views.timezone.now", return_value=second.deadline_at):
			self.assertTrue(self.submit(second_id).data["passed"])

	def test_final_success_completes_assignment_and_issues_exactly_one_pinned_certificate(self):
		self.complete_lessons()
		self.assertEqual(self.submit(self.start()).status_code, 200)
		attempt_id = self.start(self.final)
		response = self.submit(attempt_id, item=self.final_item)
		self.assertEqual(response.status_code, 200)
		self.assertEqual(response.data["assignment_status"], "COMPLETED")
		certificate = Certificate.objects.get(assignment=self.assignment)
		self.assertEqual(response.data["certificate_id"], certificate.pk)
		self.assertEqual(certificate.training_version_id, self.version.pk)
		self.assertEqual(certificate.qualifying_final_attempt_id, attempt_id)
		before = self.client.get(self.detail_url(attempt_id)).data
		self.assertEqual(self.submit(attempt_id, item=self.final_item).status_code, 409)
		self.assertEqual(self.client.get(self.detail_url(attempt_id)).data, before)
		self.assertEqual(Certificate.objects.filter(assignment=self.assignment).count(), 1)
		self.assertTrue(self.state(self.final)["completed"])
		self.assertFalse(self.state(self.final)["can_start"])

	def test_cancelled_assignment_preserves_history_but_rejects_mutation(self):
		self.complete_lessons()
		attempt_id = self.start()
		self.assignment.status = "CANCELLED"
		self.assignment.cancelled_at = timezone.now()
		self.assignment.cancellation_reason = "QA cancelled"
		self.assignment.save()
		self.assertFalse(self.state()["can_resume"])
		self.assertEqual(self.client.get(self.detail_url(attempt_id)).status_code, 200)
		self.assertEqual(self.client.post(self.start_url(), {}).status_code, 404)
		self.assertEqual(self.submit(attempt_id).status_code, 409)
		self.assertFalse(AssessmentAttempt.objects.get(pk=attempt_id).answers.exists())

	def test_malformed_ids_and_unsafe_methods_return_standard_errors(self):
		for url in ("/api/v1/assignments/bad/assessments/", "/api/v1/assessment-attempts/-1/",
			"/api/v1/assessment-attempts/bad/submit/", "/api/v1/assessment-attempts/999999/"):
			with self.subTest(url=url):
				response = self.client.get(url)
				self.assertEqual(response.status_code, 404)
				self.assertIn("error", response.data)
		self.assertEqual(self.client.get(self.start_url()).status_code, 405)
		self.assertEqual(self.client.post(self.list_url(), {}).status_code, 405)


class AssessmentOverviewOrderingTests(AssessmentAPIRequests, CurriculumTestCase):
	@classmethod
	def setUpTestData(cls):
		super().setUpTestData()
		cls.version = TrainingVersion.objects.create(
			training=cls.training, version_number=2, title="Ordered curriculum", created_by=cls.user,
		)
		later = Module.objects.create(training_version=cls.version, title="Later module", position=2)
		earlier = Module.objects.create(training_version=cls.version, title="Earlier module", position=1)
		for module in (later, earlier):
			Lesson.objects.create(module=module, title="Required reading", position=1, content_type="TEXT", body="Read first.")
		final = Assessment.objects.create(training_version=cls.version, kind=Assessment.Kind.FINAL, title="Final")
		quizzes = [Assessment.objects.create(
			training_version=cls.version, module=module, kind=Assessment.Kind.QUIZ, sequence=sequence,
			title=f"{module.title} quiz {sequence}",
		) for module, sequence in ((later, 1), (earlier, 5), (earlier, 3), (later, 2))]
		for assessment in [final, *quizzes]:
			AssessmentQuestion.objects.create(assessment=assessment, question_revision=cls.revision, position=1, points=Decimal("2.00"))
		cls.expected_ids = [quizzes[2].pk, quizzes[1].pk, quizzes[0].pk, quizzes[3].pk, final.pk]
		cls.version.status = TrainingVersion.Status.PUBLISHED
		cls.version.published_at = cls.now
		cls.version.published_by = cls.user
		cls.version.save()
		cls.assignment = TrainingAssignment.objects.create(
			employee=cls.employee, training_version=cls.version, department_at_assignment=cls.department,
			job_role_at_assignment=cls.role, assigned_by=cls.user, assigned_at=cls.now,
		)

	def setUp(self):
		self.client = self.authenticated_client()

	def test_quizzes_follow_module_then_sequence_with_final_last_on_repeated_requests(self):
		for _ in range(3):
			response = self.client.get(self.list_url())
			self.assertEqual(response.status_code, 200)
			items = response.data["assessments"]
			self.assertEqual([item["id"] for item in items], self.expected_ids)
			self.assertEqual([item["kind"] for item in items], ["QUIZ"] * 4 + ["FINAL"])

	def test_ordered_overview_preserves_contract_eligibility_and_employee_scope(self):
		response = self.client.get(self.list_url())
		self.assertEqual(response.status_code, 200)
		self.assertEqual(set(response.data), {"assignment_id", "training_version_id", "assessments"})
		self.assertEqual(response.data["training_version_id"], self.version.pk)
		fields = {"id", "kind", "module_id", "title", "sequence", "is_required", "pass_percentage",
			"time_limit_minutes", "max_attempts", "attempts_used", "attempts_remaining", "ongoing_attempt_id",
			"passed", "completed", "can_start", "can_resume", "blocking_reason", "attempts"}
		for item in response.data["assessments"]:
			self.assertEqual(set(item), fields)
			self.assertFalse(item["can_start"])
			self.assertFalse(item["can_resume"])
			self.assertEqual(item["attempts_used"], 0)
			self.assertEqual(item["pass_percentage"], "80.00")
			self.assertTrue(item["blocking_reason"])
			if item["kind"] == "QUIZ":
				self.assertIn("required module lessons", item["blocking_reason"])
		user = get_user_model().objects.create_user(username="ordering-other-learner")
		Employee.objects.create(employee_code="ORDER-OTHER", display_name="Other QA learner", user=user,
			department=self.department, job_role=self.role, date_joined=self.now.date())
		foreign = self.authenticated_client(user).get(self.list_url(), {"employee_id": self.employee.pk})
		self.assertEqual(foreign.status_code, 404)
		self.assertIn("error", foreign.data)
		self.assertFalse(AssessmentAttempt.objects.exists())
		self.assertFalse(Certificate.objects.exists())


class AssessmentAPIConcurrencyTests(AssessmentAPIRequests, TransactionTestCase):
	start_attempt = CurriculumTestCase.start_attempt
	answer_attempt = CurriculumTestCase.answer_attempt

	start_attempt = CurriculumTestCase.start_attempt
	answer_attempt = CurriculumTestCase.answer_attempt

	@classmethod
	def setUpClass(cls):
		super().setUpClass()
		media = TemporaryDirectory()
		cls.addClassCleanup(media.cleanup)
		override = override_settings(MEDIA_ROOT=media.name)
		override.enable()
		cls.addClassCleanup(override.disable)

	def setUp(self):
		if connection.vendor != "mysql":
			self.skipTest("Requires MySQL row locks.")
		CurriculumTestCase.setUpTestData.__func__(type(self))
		CurriculumTestCase.complete_lessons(self)

	def concurrent_posts(self, url, payload):
		barrier = Barrier(2)
		token = str(RefreshToken.for_user(self.employee_user).access_token)

		def post():
			try:
				client = APIClient()
				client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
				barrier.wait(timeout=10)
				response = client.post(url, payload, format="json")
				return response.status_code, response.data
			finally:
				connections.close_all()

		with ThreadPoolExecutor(max_workers=2) as executor:
			futures = [executor.submit(post) for _ in range(2)]
			return [future.result(timeout=20) for future in futures]

	def test_concurrent_starts_resume_one_sequential_attempt(self):
		for _ in range(self.quiz.max_attempts - 1):
			CurriculumTestCase.finish_attempt(self, self.quiz, correct=False)
		results = self.concurrent_posts(self.start_url(), {})
		self.assertEqual(sorted(status for status, _ in results), [200, 201])
		self.assertEqual(len({data["id"] for _, data in results}), 1)
		self.assertEqual(self.assignment.attempts.count(), self.quiz.max_attempts)
		attempt = self.assignment.attempts.get(status="IN_PROGRESS")
		self.assertEqual(attempt.attempt_number, self.quiz.max_attempts)

	def test_concurrent_final_submissions_grade_once_and_issue_one_certificate(self):
		CurriculumTestCase.finish_attempt(self, self.quiz)
		client = self.authenticated_client()
		response = client.post(self.start_url(self.final), {}, format="json")
		self.assertEqual(response.status_code, 201, response.data)
		attempt_id = response.data["id"]
		results = self.concurrent_posts(self.submit_url(attempt_id), {
			"answers": {str(self.final_item.pk): self.correct_option.pk},
		})
		self.assertEqual(sorted(status for status, _ in results), [200, 409])
		attempt = AssessmentAttempt.objects.get(pk=attempt_id)
		self.assertEqual((attempt.score_points, attempt.passed, attempt.answers.count()), (Decimal("2.00"), True, 1))
		self.assignment.refresh_from_db()
		self.assertEqual(self.assignment.status, "COMPLETED")
		self.assertEqual(Certificate.objects.filter(assignment=self.assignment).count(), 1)
