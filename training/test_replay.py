"""Completed-assignment replay policy, shared by web and JWT API tests."""
from datetime import timedelta
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.files.storage import FileSystemStorage
from django.urls import reverse

from assessments.models import Assessment, AssessmentAttempt, AssessmentQuestion, AttemptAnswer
from audit.models import AuditLog
from certifications.models import Certificate
from certifications.services import issue_completed_assignment_certificate
from config.model_test_utils import CurriculumTestCase
from organization.models import Employee
from training.models import Lesson, LessonProgress, Module, TrainingAssignment, VideoWatchSession


class ReplayPolicyChecks:
    namespace = "training"

    def setUp(self):
        super().setUp()
        self.complete_assignment()
        issue_completed_assignment_certificate(self.assignment.pk, actor=self.employee_user)
        self.auth_as(self.employee_user)

    def replay_url(self, assignment=None, lesson=None):
        return reverse(f"{self.namespace}:video-replay-media", args=[
            (assignment or self.assignment).pk, (lesson or self.video_lesson).pk,
        ])

    def history(self):
        # Compare every persisted field, including positions, timestamps, answers,
        # certificates and audit rows, rather than just checking record counts.
        return {
            model._meta.label: list(model.objects.order_by("pk").values())
            for model in (TrainingAssignment, LessonProgress, VideoWatchSession,
                          AssessmentAttempt, AttemptAnswer, Certificate, AuditLog)
        }

    def assert_media(self, response, expected, status=200):
        self.assertEqual(response.status_code, status)
        self.assertEqual(b"".join(response.streaming_content), expected)
        self.assertEqual(response["Content-Type"], "video/mp4")
        self.assertEqual(response["Cache-Control"], "private, no-store")
        self.assertEqual(response["X-Playback-Mode"], "read-only-replay")

    def test_published_and_retired_replay_never_mutate_learning_history(self):
        for status in ("PUBLISHED", "RETIRED"):
            with self.subTest(version_status=status):
                if status == "RETIRED":
                    self.version.status = status
                    self.version.save()
                before = self.history()
                self.assertEqual(VideoWatchSession.objects.count(), 0)
                self.assert_media(self.client.get(self.replay_url()), b"\x00\x00\x00\x18ftyp")
                self.assert_media(self.client.get(self.replay_url()), b"\x00\x00\x00\x18ftyp")
                self.assertEqual(before, self.history())

    def test_ranges_head_and_invalid_ranges_are_read_only(self):
        before = self.history()
        for byte_range, expected in (("bytes=2-5", b"\x00\x18ft"), ("bytes=-2", b"yp"), ("bytes=6-", b"yp")):
            with self.subTest(byte_range=byte_range):
                response = self.client.get(self.replay_url(), HTTP_RANGE=byte_range)
                self.assertEqual(response["Accept-Ranges"], "bytes")
                self.assertEqual(int(response["Content-Length"]), len(expected))
                self.assert_media(response, expected, 206)
        response = self.client.head(self.replay_url(), HTTP_RANGE="bytes=0-1")
        self.assertEqual(response.status_code, 206)
        self.assertEqual(response["Content-Range"], "bytes 0-1/8")
        self.assertEqual(response["Content-Length"], "2")
        self.assertEqual(response.content, b"")
        for byte_range in ("bytes=8-", "bytes=5-2", "bytes=-0", "bytes=0-1,3-4", "garbage", "bytes=" + "9" * 110 + "-"):
            with self.subTest(invalid_range=byte_range):
                response = self.client.get(self.replay_url(), HTTP_RANGE=byte_range)
                self.assertEqual(response.status_code, 416)
                self.assertEqual(response["Content-Range"], "bytes */8")
                self.assertEqual(response["Cache-Control"], "private, no-store")
        self.assertEqual(before, self.history())

    def test_other_employee_and_privileged_user_cannot_replay_owner_media(self):
        other = get_user_model().objects.create_user(username="replay-other")
        Employee.objects.create(
            employee_code="REPLAY-OTHER", display_name="Other learner", department=self.department,
            job_role=self.role, date_joined=self.now.date(), user=other,
        )
        self.user.is_staff = True
        self.user.is_superuser = True
        self.user.save()
        before = self.history()
        for user in (other, self.user):
            self.auth_as(user)
            response = self.client.get(self.replay_url(), HTTP_RANGE="bytes=999-")
            self.assertIn(response.status_code, (403, 404))
            self.assertNotIn("Content-Range", response)
        self.assertEqual(before, self.history())

    def test_deactivation_revokes_subsequent_range_requests(self):
        self.assert_media(self.client.get(self.replay_url(), HTTP_RANGE="bytes=0-1"), b"\x00\x00", 206)
        self.employee.is_active = False
        self.employee.deactivation_reason = "Replay test deactivation"
        self.employee.save()
        before = self.history()
        response = self.client.get(self.replay_url(), HTTP_RANGE="bytes=2-5")
        self.assertIn(response.status_code, (302, 401, 403))
        self.assertNotIn("Content-Range", response)
        # Even an inconsistent legacy enabled login cannot override Employee inactivity.
        self.employee_user.is_active = True
        self.employee_user.save()
        self.auth_as(self.employee_user)
        self.assertEqual(self.client.get(self.replay_url()).status_code, 403)
        self.assertEqual(before, self.history())

    def test_inactive_user_and_anonymous_requests_cannot_replay(self):
        self.employee_user.is_active = False
        self.employee_user.save()
        before = self.history()
        self.assertIn(self.client.get(self.replay_url()).status_code, (302, 401, 403))
        self.sign_out()
        self.assertIn(self.client.get(self.replay_url()).status_code, (302, 401))
        self.assertEqual(before, self.history())

    def test_unrelated_lesson_ids_and_path_traversal_cannot_select_media(self):
        draft = self.new_version()
        module = Module.objects.create(training_version=draft, title="Unrelated", position=1)
        lesson = Lesson.objects.create(
            module=module, title="Unrelated", position=1, content_type="VIDEO",
            video_file="training/videos/other.mp4", video_duration_seconds=100, video_checksum="b" * 64,
        )
        before = self.history()
        for url in (self.replay_url(lesson=lesson), self.replay_url(lesson=self.text_lesson),
                    self.replay_url() + "../../secret.mp4", self.replay_url().replace(f"/{self.assignment.pk}/lessons/", "/999999/lessons/")):
            self.assertEqual(self.client.get(url).status_code, 404)
        # No caller-supplied storage path is consumed by this endpoint.
        self.assert_media(self.client.get(self.replay_url(), {"path": "../../secret.mp4"}), b"\x00\x00\x00\x18ftyp")
        self.assertEqual(before, self.history())

    def test_incomplete_optional_lesson_in_completed_assignment_is_denied(self):
        version = self.new_version()
        module = Module.objects.create(training_version=version, title="Optional", position=1)
        lesson = Lesson.objects.create(
            module=module, title="Optional video", position=1, content_type="VIDEO", is_required=False,
            video_file="training/videos/other.mp4", video_duration_seconds=100, video_checksum="b" * 64,
        )
        final = Assessment.objects.create(training_version=version, kind="FINAL", title="Final")
        AssessmentQuestion.objects.create(assessment=final, question_revision=self.revision, position=1, points=2)
        version.status, version.published_at, version.published_by = "PUBLISHED", self.now, self.user
        version.save()
        assignment = TrainingAssignment.objects.create(
            employee=self.employee, training_version=version, department_at_assignment=self.department,
            job_role_at_assignment=self.role, assigned_by=self.user, assigned_at=self.now,
            started_at=self.now, status="IN_PROGRESS",
        )
        self.assignment = assignment
        self.finish_attempt(final)
        assignment.status, assignment.completed_at = "COMPLETED", self.now + timedelta(seconds=130)
        assignment.save()
        before = self.history()
        self.assertEqual(self.client.get(self.replay_url(lesson=lesson)).status_code, 404)
        if self.namespace == "api:v1":
            detail = self.client.get(reverse("api:v1:assignment-detail", args=[assignment.pk]))
            self.assertEqual(detail.data["modules"][0]["lessons"][0]["playback_mode"], "unavailable")
        self.assertEqual(before, self.history())

    def test_replay_requires_completed_assignment_and_tracked_route_stays_open_only(self):
        other = get_user_model().objects.create_user(username="replay-open")
        employee = Employee.objects.create(
            employee_code="REPLAY-OPEN", display_name="Open learner", department=self.department,
            job_role=self.role, date_joined=self.now.date(), user=other,
        )
        assignment = TrainingAssignment.objects.create(
            employee=employee, training_version=self.version, department_at_assignment=self.department,
            job_role_at_assignment=self.role, assigned_by=self.user, assigned_at=self.now,
        )
        self.auth_as(other)
        self.assertEqual(self.client.get(self.replay_url(assignment=assignment)).status_code, 404)
        started = self.client.post(reverse(f"{self.namespace}:video-session-start", args=[assignment.pk, self.video_lesson.pk]),
                                   data='{"position": 0}', content_type="application/json")
        self.assertEqual(started.status_code, 201)
        self.assertEqual(VideoWatchSession.objects.filter(assignment=assignment).count(), 1)
        assignment.refresh_from_db()
        assignment.status = "CANCELLED"
        assignment.cancelled_at = self.now + timedelta(seconds=140)
        assignment.cancellation_reason = "Cancelled replay fixture"
        assignment.save()
        self.assertEqual(self.client.get(self.replay_url(assignment=assignment)).status_code, 404)
        self.auth_as(self.employee_user)
        before = self.history()
        denied = self.client.post(reverse(f"{self.namespace}:video-session-start", args=[self.assignment.pk, self.video_lesson.pk]),
                                  data='{"position": 0}', content_type="application/json")
        self.assertEqual(denied.status_code, 409)
        self.assertEqual(before, self.history())

    def test_missing_or_empty_media_and_unsupported_methods_fail_cleanly(self):
        before = self.history()
        with patch.object(FileSystemStorage, "open", side_effect=OSError("private storage path")):
            response = self.client.get(self.replay_url())
        self.assertEqual(response.status_code, 404)
        self.assertNotIn(b"private storage path", response.content)
        with patch.object(FileSystemStorage, "size", return_value=0):
            self.assertEqual(self.client.get(self.replay_url()).status_code, 404)
        for method in ("post", "put", "delete"):
            self.assertEqual(getattr(self.client, method)(self.replay_url()).status_code, 405)
        self.assertEqual(before, self.history())


class VideoReplayTests(ReplayPolicyChecks, CurriculumTestCase):
    def setUp(self):
        super().setUp()
        self.employee_user.groups.add(Group.objects.get(name="Employee"))

    def auth_as(self, user):
        self.client.force_login(user)

    def sign_out(self):
        self.client.logout()

    def test_web_replay_uses_same_player_without_progress_controls_or_storage_urls(self):
        response = self.client.get(reverse("training:assignment-detail", args=[self.assignment.pk]), {"lesson": self.video_lesson.pk})
        self.assertContains(response, "Read-only replay.")
        self.assertContains(response, f'data-replay-url="{self.replay_url()}"', count=1)
        self.assertContains(response, 'id="video-player"', count=1)
        self.assertNotContains(response, "data-start-url")
        self.assertNotContains(response, "data-progress-url")
        self.assertNotContains(response, self.video_lesson.video_file.url)

    def test_draft_version_never_advertises_completed_replay(self):
        from training.views import can_replay_completed_video
        progress = LessonProgress.objects.get(assignment=self.assignment, lesson=self.video_lesson)
        self.assignment.training_version.status = "DRAFT"
        self.assertFalse(can_replay_completed_video(self.assignment, self.video_lesson, progress))
