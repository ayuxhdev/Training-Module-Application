import json
from datetime import timedelta
from io import BytesIO
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.core.files.storage import FileSystemStorage
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from config.model_test_utils import CurriculumTestCase
from organization.models import Employee
from training.models import Lesson, LessonProgress, Module, TrainingAssignment, TrainingVersion, VideoWatchSession


User = get_user_model()


class LearningAPITests(CurriculumTestCase):
	def setUp(self):
		self.client = APIClient()
		self.employee_user.is_active = True
		self.employee_user.set_password("password")
		self.employee_user.save()
		self.employee.is_active = True
		self.employee.save()

	def auth_as(self, user=None):
		user = user or self.employee_user
		self.client.credentials(
			HTTP_AUTHORIZATION=f"Bearer {RefreshToken.for_user(user).access_token}",
		)

	def request_json(self, method, url, payload=None, **extra):
		return getattr(self.client, method)(
			url,
			data=json.dumps(payload or {}),
			content_type="application/json",
			**extra,
		)

	def other_assignment(self):
		user = User.objects.create_user(username="learning-api-other", password="password")
		employee = Employee.objects.create(
			employee_code="GN-API-OTHER",
			display_name="Other employee",
			department=self.department,
			job_role=self.role,
			date_joined=self.now.date(),
			user=user,
		)
		assignment = TrainingAssignment.objects.create(
			employee=employee,
			training_version=self.version,
			department_at_assignment=employee.department,
			job_role_at_assignment=employee.job_role,
			assigned_by=self.user,
			assigned_at=self.now,
		)
		return user, employee, assignment

	def test_assignment_list_is_jwt_only_and_employee_scoped(self):
		_, _, other = self.other_assignment()
		url = reverse("api:v1:assignment-list")

		self.assertTrue(self.client.login(username="employee", password="password"))
		self.assertEqual(self.client.get(url).status_code, 401)

		self.client.logout()
		self.auth_as()
		response = self.client.get(url, {"employee_id": other.employee_id})
		self.assertEqual(response.status_code, 200)
		self.assertEqual(response.data["count"], 1)
		items = response.data["results"]
		self.assertEqual([item["id"] for item in items], [self.assignment.pk])
		self.assertEqual(items[0]["progress_summary"], {
			"required_lessons_completed": 0,
			"required_lessons_total": 2,
		})
		self.assertNotIn("employee_id", items[0])

	def test_missing_or_inactive_employee_cannot_use_learning_api(self):
		url = reverse("api:v1:assignment-list")
		self.auth_as()
		self.employee.is_active = False
		self.employee.deactivation_reason = "Inactive for API test"
		self.employee.save()
		self.assertIn(self.client.get(url).status_code, (401, 403))

		user_without_employee = User.objects.create_user(username="learning-api-no-employee")
		self.auth_as(user_without_employee)
		self.assertIn(self.client.get(url).status_code, (401, 403))

	def test_assignment_detail_returns_owned_ordered_curriculum_and_progress(self):
		progress_time = timezone.now() - timedelta(seconds=5)
		LessonProgress.objects.create(
			assignment=self.assignment,
			lesson=self.text_lesson,
			started_at=progress_time,
			last_accessed_at=progress_time,
			completed_at=progress_time,
		)
		self.auth_as()
		response = self.client.get(reverse("api:v1:assignment-detail", args=[self.assignment.pk]))
		self.assertEqual(response.status_code, 200)
		self.assertEqual(response.data["training_id"], self.training.pk)
		lessons = response.data["modules"][0]["lessons"]
		self.assertEqual([lesson["id"] for lesson in lessons], [self.text_lesson.pk, self.video_lesson.pk])
		self.assertEqual(lessons[0]["body"], self.text_lesson.body)
		self.assertTrue(lessons[0]["progress"]["completed"])
		self.assertFalse(lessons[1]["progress"]["completed"])
		self.assertNotIn("video_file", lessons[1])
		self.assertNotIn("video_checksum", lessons[1])
		self.assertNotIn("employee_id", response.data)

	def test_retired_assignment_keeps_its_curriculum_and_progress(self):
		LessonProgress.objects.create(
			assignment=self.assignment, lesson=self.text_lesson,
			started_at=self.now, last_accessed_at=self.now, completed_at=self.now,
		)
		self.auth_as()
		url = reverse("api:v1:assignment-detail", args=[self.assignment.pk])
		published = self.client.get(url)
		self.assertEqual(published.status_code, 200)
		self.version.status = TrainingVersion.Status.RETIRED
		self.version.save()

		retired = self.client.get(url)
		self.assertEqual(retired.status_code, 200)
		self.assertEqual(retired.data, published.data)
		self.assertTrue(retired.data["modules"][0]["lessons"][0]["progress"]["completed"])
		self.assignment.refresh_from_db()
		self.assertEqual(self.assignment.training_version_id, self.version.pk)

	def test_retired_assignment_still_requires_ownership_and_active_employee(self):
		other_user, _, other = self.other_assignment()
		self.version.status = TrainingVersion.Status.RETIRED
		self.version.save()
		self.auth_as()
		self.assertEqual(self.client.get(
			reverse("api:v1:assignment-detail", args=[other.pk]),
		).status_code, 404)
		url = reverse("api:v1:assignment-detail", args=[self.assignment.pk])
		self.auth_as(other_user)
		self.assertEqual(self.client.get(url).status_code, 404)
		self.auth_as()
		self.employee.is_active = False
		self.employee.deactivation_reason = "Inactive for retired assignment test"
		self.employee.save()
		self.assertIn(self.client.get(url).status_code, (401, 403))
		self.client.credentials()
		self.assertEqual(self.client.get(url).status_code, 401)

	def test_cancelled_retired_assignment_has_no_curriculum(self):
		self.version.status = TrainingVersion.Status.RETIRED
		self.version.save()
		self.assignment.status = TrainingAssignment.Status.CANCELLED
		self.assignment.cancelled_at = timezone.now()
		self.assignment.cancellation_reason = "Cancelled for retired assignment test"
		self.assignment.save()
		self.auth_as()
		response = self.client.get(reverse("api:v1:assignment-detail", args=[self.assignment.pk]))
		self.assertEqual(response.status_code, 200)
		self.assertEqual(response.data["modules"], [])

	def test_assignment_detail_cannot_select_unassigned_draft_curriculum(self):
		draft = self.new_version()
		module = Module.objects.create(training_version=draft, title="Draft module", position=1)
		lesson = Lesson.objects.create(
			module=module, title="Draft lesson", position=1,
			content_type=Lesson.ContentType.TEXT, body="Unpublished content",
		)
		self.version.status = TrainingVersion.Status.RETIRED
		self.version.save()
		self.auth_as()
		response = self.client.get(
			reverse("api:v1:assignment-detail", args=[self.assignment.pk]),
			{"training_version_id": draft.pk, "module_id": module.pk, "lesson_id": lesson.pk},
		)
		self.assertEqual(response.status_code, 200)
		self.assertEqual(response.data["version_number"], self.version.version_number)
		self.assertEqual([item["id"] for item in response.data["modules"]], [self.module.pk])
		self.assertEqual(
			[item["id"] for item in response.data["modules"][0]["lessons"]],
			[self.text_lesson.pk, self.video_lesson.pk],
		)

	def test_assignment_detail_hides_other_employee_and_unavailable_curriculum(self):
		_, _, other = self.other_assignment()
		self.auth_as()
		self.assertEqual(
			self.client.get(reverse("api:v1:assignment-detail", args=[other.pk])).status_code,
			404,
		)

		self.assignment.status = TrainingAssignment.Status.CANCELLED
		self.assignment.cancelled_at = timezone.now()
		self.assignment.cancellation_reason = "Test cancellation"
		self.assignment.save()
		response = self.client.get(reverse("api:v1:assignment-detail", args=[self.assignment.pk]))
		self.assertEqual(response.status_code, 200)
		self.assertEqual(response.data["modules"], [])

	def test_progress_reads_existing_state_and_rejects_mismatched_lesson(self):
		self.auth_as()
		url = reverse("api:v1:lesson-progress", args=[self.assignment.pk, self.video_lesson.pk])
		response = self.client.get(url)
		self.assertEqual(response.status_code, 200)
		self.assertEqual(response.data["watched_ranges"], [])
		self.assertFalse(response.data["completed"])

		draft = self.new_version()
		module = Module.objects.create(training_version=draft, title="Unrelated", position=1)
		unrelated_lesson = Lesson.objects.create(
			module=module, title="Unrelated video", position=1,
			content_type=Lesson.ContentType.VIDEO,
			video_file="training/videos/unrelated.mp4", video_duration_seconds=30,
			video_checksum="c" * 64,
		)
		mismatch = reverse("api:v1:lesson-progress", args=[self.assignment.pk, unrelated_lesson.pk])
		self.assertEqual(self.client.get(mismatch).status_code, 404)

	def test_text_completion_is_owner_scoped_post_only_and_repeat_safe(self):
		self.auth_as()
		url = reverse("api:v1:lesson-complete", args=[self.assignment.pk, self.text_lesson.pk])
		self.assertEqual(self.client.get(url).status_code, 405)
		response = self.request_json("post", url, {
			"employee_id": 999999,
			"completed": False,
			"progress_percent": 0,
		})
		self.assertEqual(response.status_code, 200, response.data)
		self.assertTrue(response.data["completed"])
		completed_at = LessonProgress.objects.get(
			assignment=self.assignment, lesson=self.text_lesson,
		).completed_at
		self.assertEqual(self.assignment.__class__.objects.get(pk=self.assignment.pk).status,
			TrainingAssignment.Status.IN_PROGRESS)

		repeated = self.request_json("post", url, {"completed": False})
		self.assertEqual(repeated.status_code, 200, repeated.data)
		self.assertEqual(LessonProgress.objects.filter(
			assignment=self.assignment, lesson=self.text_lesson,
		).count(), 1)
		self.assertEqual(LessonProgress.objects.get(
			assignment=self.assignment, lesson=self.text_lesson,
		).completed_at, completed_at)

		_, _, other = self.other_assignment()
		other_url = reverse("api:v1:lesson-complete", args=[other.pk, self.text_lesson.pk])
		self.assertEqual(self.request_json("post", other_url).status_code, 404)
		video_url = reverse("api:v1:lesson-complete", args=[self.assignment.pk, self.video_lesson.pk])
		self.assertEqual(self.request_json("post", video_url).status_code, 404)

	def test_completed_or_cancelled_assignment_write_matches_existing_lifecycle(self):
		self.auth_as()
		self.assignment.status = TrainingAssignment.Status.CANCELLED
		self.assignment.cancelled_at = timezone.now()
		self.assignment.cancellation_reason = "Test cancellation"
		self.assignment.save()
		url = reverse("api:v1:lesson-complete", args=[self.assignment.pk, self.text_lesson.pk])
		response = self.request_json("post", url)
		self.assertEqual(response.status_code, 409)
		self.assertEqual(response.data["error"]["code"], "conflict")

	def test_jwt_video_session_progress_and_media_reuse_web_playback_rules(self):
		video_bytes = b"\x00\x00\x00\x18ftyp-video-content"
		size_patch = patch.object(FileSystemStorage, "size", return_value=len(video_bytes))
		open_patch = patch.object(FileSystemStorage, "open", side_effect=lambda name, mode: BytesIO(video_bytes))
		size_patch.start()
		open_patch.start()
		self.addCleanup(size_patch.stop)
		self.addCleanup(open_patch.stop)
		self.auth_as()

		start_at = timezone.now() + timedelta(minutes=1)
		start_url = reverse("api:v1:video-session-start", args=[self.assignment.pk, self.video_lesson.pk])
		with patch("training.views.timezone.now", return_value=start_at):
			started = self.request_json("post", start_url, {"position": 0})
		self.assertEqual(started.status_code, 201, started.data)
		session_id = started.data["session_id"]

		progress_url = reverse("api:v1:lesson-progress", args=[self.assignment.pk, self.video_lesson.pk])
		with patch("training.views.timezone.now", return_value=start_at + timedelta(seconds=1)):
			invalid = self.request_json("post", progress_url, {
				"session_id": session_id,
				"position": -1,
			})
		self.assertEqual(invalid.status_code, 400)
		self.assertEqual(invalid.data["error"]["code"], "validation_error")
		self.assertEqual(LessonProgress.objects.get(
			assignment=self.assignment, lesson=self.video_lesson,
		).watched_seconds, 0)

		with patch("training.views.timezone.now", return_value=start_at + timedelta(seconds=10)):
			heartbeat = self.request_json("post", progress_url, {
				"session_id": session_id,
				"position": 9.5,
				"completed": True,
				"watched_seconds": 999,
			})
		self.assertEqual(heartbeat.status_code, 200, heartbeat.data)
		self.assertEqual(heartbeat.data["watched_seconds"], 9.5)
		self.assertFalse(heartbeat.data["completed"])

		media_url = reverse("api:v1:video-session-media", args=[self.assignment.pk, self.video_lesson.pk, session_id])
		mismatched_media_url = reverse(
			"api:v1:video-session-media",
			args=[self.assignment.pk, self.video_lesson.pk, session_id + 9999],
		)
		self.assertEqual(self.client.get(mismatched_media_url).status_code, 404)
		partial = self.client.get(media_url, HTTP_RANGE="bytes=2-5")
		self.assertEqual(partial.status_code, 206)
		self.assertEqual(b"".join(partial.streaming_content), video_bytes[2:6])
		unsatisfiable = self.client.get(media_url, HTTP_RANGE="bytes=999-1000")
		self.assertEqual(unsatisfiable.status_code, 416)
		self.assertEqual(unsatisfiable.data["error"]["code"], "range_not_satisfiable")
		self.assertEqual(unsatisfiable["Content-Range"], f"bytes */{len(video_bytes)}")
		self.assertEqual(unsatisfiable["Cache-Control"], "private, no-store")

		end_url = reverse("api:v1:video-session-end", args=[self.assignment.pk, self.video_lesson.pk, session_id])
		with patch("training.views.timezone.now", return_value=start_at + timedelta(seconds=11)):
			ended = self.request_json("post", end_url, {"position": 10.5, "completed_normally": True})
		self.assertEqual(ended.status_code, 200, ended.data)
		self.assertIsNotNone(VideoWatchSession.objects.get(pk=session_id).ended_at)
		self.assertFalse(LessonProgress.objects.get(
			assignment=self.assignment, lesson=self.video_lesson,
		).completed_at)

		self.assertEqual(self.client.get(media_url).status_code, 404)

	def test_media_validation_errors_use_api_error_envelope(self):
		self.auth_as()
		text_media_url = reverse(
			"api:v1:video-session-media",
			args=[self.assignment.pk, self.text_lesson.pk, 1],
		)
		wrong_type = self.client.get(text_media_url)
		self.assertEqual(wrong_type.status_code, 400)
		self.assertEqual(wrong_type.data["error"]["code"], "validation_error")
		self.assertIn("Video progress requires a video lesson", wrong_type.data["error"]["message"])

		self.assignment.status = TrainingAssignment.Status.CANCELLED
		self.assignment.cancelled_at = timezone.now()
		self.assignment.cancellation_reason = "Cancelled for media API test"
		self.assignment.save()
		video_media_url = reverse(
			"api:v1:video-session-media",
			args=[self.assignment.pk, self.video_lesson.pk, 1],
		)
		conflict = self.client.get(video_media_url)
		self.assertEqual(conflict.status_code, 409)
		self.assertEqual(conflict.data["error"]["code"], "conflict")

	def test_employee_cannot_use_another_employees_video_session(self):
		_, _, other = self.other_assignment()
		session = VideoWatchSession.objects.create(
			assignment=other,
			lesson=self.video_lesson,
			started_at=timezone.now() - timedelta(seconds=1),
			starting_position_seconds=0,
			ending_position_seconds=0,
		)
		self.auth_as()
		progress_url = reverse("api:v1:lesson-progress", args=[other.pk, self.video_lesson.pk])
		self.assertEqual(self.client.get(progress_url).status_code, 404)
		media_url = reverse("api:v1:video-session-media", args=[other.pk, self.video_lesson.pk, session.pk])
		self.assertEqual(self.client.get(media_url).status_code, 404)
