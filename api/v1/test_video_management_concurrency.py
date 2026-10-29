"""Committed MySQL upload races with isolated media and exact fixture cleanup."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import nullcontext
from pathlib import Path
from threading import Event, local
from unittest import skipUnless
from unittest.mock import patch
from uuid import uuid4
import hashlib
import tempfile

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.files.base import ContentFile
from django.core.files.uploadedfile import SimpleUploadedFile
from django.db import close_old_connections, connection, models
from django.test import SimpleTestCase, override_settings
from rest_framework.test import APIRequestFactory, force_authenticate

from audit.models import AuditLog
from training.models import Lesson, Module, Training, TrainingVersion

from .video_management_views import VideoLessonCreateView, VideoLessonDetailView


@skipUnless(connection.vendor == "mysql", "Real upload races require MySQL row locks.")
class VideoManagementConcurrencyTests(SimpleTestCase):
    databases = {"default"}

    def assert_isolated(self):
        self.assertEqual(connection.settings_dict["NAME"], "test_gardens_training")
        with connection.cursor() as cursor:
            cursor.execute("SELECT DATABASE()")
            self.assertEqual(cursor.fetchone()[0], "test_gardens_training")

    def setUp(self):
        self.assert_isolated()
        self.assertTrue(connection.get_autocommit())
        self.media = tempfile.TemporaryDirectory(prefix="video-race-")
        self.addCleanup(self.media.cleanup)
        self.enterContext(override_settings(MEDIA_ROOT=self.media.name))
        self.enterContext(patch("training.video_uploads._probe_video_duration", return_value=69))
        marker = "video-race-" + uuid4().hex[:16]
        self.users = []
        self.training_id = None
        self.groups = list(Group.objects.order_by("pk").values())
        self.grants = list(Group.permissions.through.objects.order_by("pk").values())
        self.addCleanup(self.cleanup_fixtures)
        for suffix in ("first", "second"):
            self.users.append(get_user_model().objects.create_user(username=f"{marker}-{suffix}", is_superuser=True))
        self.training = Training.objects.create(code=marker, catalog_title="Isolated", created_by=self.users[0])
        self.training_id = self.training.pk
        self.version = TrainingVersion.objects.create(training=self.training, version_number=1, title="Draft", created_by=self.users[0])
        self.module = Module.objects.create(training_version=self.version, title="Module", position=1)
        self.payload = b"\x00\x00\x00\x18ftypisom" + b"0" * 20
        self.video = Lesson.objects.create(
            module=self.module, title="Original", position=1, content_type="VIDEO",
            video_file=ContentFile(self.payload, name="original.mp4"),
            video_checksum=hashlib.sha256(self.payload).hexdigest(), video_duration_seconds=69,
        )

    def cleanup_fixtures(self):
        self.assert_isolated()
        ids = [user.pk for user in self.users]
        for model, filters in (
            (AuditLog, {"actor_id__in": ids}),
            (Lesson, {"module__training_version__training_id": self.training_id}),
            (Module, {"training_version__training_id": self.training_id}),
            (TrainingVersion, {"training_id": self.training_id}),
            (Training, {"pk": self.training_id}),
            (get_user_model(), {"pk__in": ids}),
        ):
            models.QuerySet(model, using="default").filter(**filters)._raw_delete("default")
        self.assertEqual(list(Group.objects.order_by("pk").values()), self.groups)
        self.assertEqual(list(Group.permissions.through.objects.order_by("pk").values()), self.grants)
        connection.close()

    def call(self, data, create=False):
        kwargs = {"version_pk": self.version.pk, "module_pk": self.module.pk}
        if not create:
            kwargs["pk"] = self.video.pk
        return (VideoLessonCreateView if create else VideoLessonDetailView,
                "post" if create else "patch", kwargs, data)

    def race(self, calls, expected):
        held, boundary, finished, release = (Event() for _ in range(4))
        thread = local()
        original = Lesson.save
        table = connection.ops.quote_name(TrainingVersion._meta.db_table)

        def hold(instance, *args, **kwargs):
            result = original(instance, *args, **kwargs)
            if thread.role == "first":
                self.assertTrue(connection.in_atomic_block)
                held.set()
                if not release.wait(30):
                    raise AssertionError("First upload was not released")
            return result

        def observe(execute, sql, params, many, context):
            if "FOR UPDATE" in sql.upper() and table in sql:
                boundary.set()
            return execute(sql, params, many, context)

        def run(role, actor, call):
            thread.role = role
            close_old_connections()
            try:
                self.assert_isolated()
                with connection.cursor() as cursor:
                    cursor.execute("SET SESSION innodb_lock_wait_timeout=10")
                view, method, kwargs, data = call
                request = getattr(APIRequestFactory(), method)("/isolated-video/", data, format="multipart")
                force_authenticate(request, user=actor)
                observer = connection.execute_wrapper(observe) if role == "second" else nullcontext()
                with observer:
                    response = view.as_view()(request, **kwargs)
                return response.status_code, response.data
            finally:
                if role == "second":
                    finished.set()
                connection.close()

        with patch.object(Lesson, "save", hold), ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(run, "first", self.users[0], calls[0])
            try:
                self.assertTrue(held.wait(15), "First mutation never reached its uncommitted write")
                second = pool.submit(run, "second", self.users[1], calls[1])
                self.assertTrue(boundary.wait(15), "Second request never attempted the version lock")
                finished_while_locked = finished.wait(1)
            finally:
                release.set()
            results = first.result(20), second.result(20)
        self.assertFalse(finished_while_locked)
        self.assertEqual(tuple(status for status, _ in results), expected, results)

    def test_concurrent_create_at_same_position_has_one_file_record_and_audit(self):
        calls = [self.call({
            "title": "New", "position": 2,
            "video_file": SimpleUploadedFile("new.mp4", self.payload, "video/mp4"),
        }, create=True) for _ in range(2)]
        self.race(calls, (201, 400))
        self.assertEqual(Lesson.objects.filter(module=self.module, position=2).count(), 1)
        self.assertEqual(len(list(Path(self.media.name).rglob("*.mp4"))), 2)
        self.assertEqual(AuditLog.objects.filter(actor__in=self.users).count(), 1)

    def test_replacement_and_metadata_edit_preserve_fresh_file_and_old_bytes(self):
        original_name = self.video.video_file.name
        replacement = self.payload + b"new"
        self.race([
            self.call({"video_file": SimpleUploadedFile("new.mp4", replacement, "video/mp4")}),
            self.call({"title": "New title", "is_required": False}),
        ], (200, 200))
        self.video.refresh_from_db()
        self.assertEqual(self.video.title, "New title")
        self.assertFalse(self.video.is_required)
        self.assertEqual(self.video.video_checksum, hashlib.sha256(replacement).hexdigest())
        with self.video.video_file.storage.open(original_name, "rb") as file:
            self.assertEqual(file.read(), self.payload)
        self.assertEqual(AuditLog.objects.filter(actor__in=self.users).count(), 2)

    def test_two_replacements_keep_distinct_uploads_and_last_committed_metadata(self):
        first, second = self.payload + b"first", self.payload + b"second"
        self.race([
            self.call({"video_file": SimpleUploadedFile("same.mp4", first, "video/mp4")}),
            self.call({"video_file": SimpleUploadedFile("same.mp4", second, "video/mp4")}),
        ], (200, 200))
        self.video.refresh_from_db()
        self.assertEqual(self.video.video_checksum, hashlib.sha256(second).hexdigest())
        files = [p.read_bytes() for p in Path(self.media.name).rglob("*.mp4")]
        self.assertCountEqual(files, [self.payload, first, second])
        self.assertEqual(AuditLog.objects.filter(actor__in=self.users).count(), 2)
