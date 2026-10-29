"""VIDEO API validation and storage ownership, using temporary private media."""

import hashlib
import json
import tempfile
from pathlib import Path
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import ValidationError
from django.core.files.base import ContentFile
from django.core.files.uploadedfile import SimpleUploadedFile
from django.db import IntegrityError, OperationalError, transaction
from django.test import override_settings
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from training.models import Lesson, Module, TrainingVersion

from . import video_management_services as services


class VideoManagementAPITests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.draft = TrainingVersion.objects.create(
            training=cls.training, version_number=2, title="Draft", created_by=cls.user,
        )
        cls.draft_module = Module.objects.create(training_version=cls.draft, title="Module", position=1)
        cls.user.user_permissions.add(*Permission.objects.filter(
            content_type__app_label="training", codename__in=["add_lesson", "view_lesson", "change_lesson"],
        ))

    def setUp(self):
        self.media = tempfile.TemporaryDirectory(prefix="api-video-test-")
        self.addCleanup(self.media.cleanup)
        media_setting = override_settings(MEDIA_ROOT=self.media.name)
        media_setting.enable()
        self.addCleanup(media_setting.disable)
        self.client = APIClient()
        self.authenticate(self.user)
        self.probe = patch("training.video_uploads._probe_video_duration", return_value=69)
        self.duration = self.probe.start()
        self.addCleanup(self.probe.stop)
        self.payload = b"\x00\x00\x00\x18ftypisom" + b"\x00" * 20

    def authenticate(self, user):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + str(RefreshToken.for_user(user).access_token))

    def upload(self, data=None, name="lesson.mp4"):
        return SimpleUploadedFile(name, self.payload if data is None else data, "video/mp4")

    def list_url(self, module=None, version=None):
        return (f"/api/v1/management/versions/{(version or self.draft).pk}/modules/"
                f"{(module or self.draft_module).pk}/video-lessons/")

    def detail_url(self, lesson, module=None, version=None):
        return self.list_url(module, version) + f"{lesson.pk}/"

    def create(self, **values):
        return self.client.post(self.list_url(), {
            "title": "Video lesson", "position": 1, "video_file": self.upload(), **values,
        }, format="multipart")

    def make_video(self):
        response = self.create()
        self.assertEqual(response.status_code, 201, response.data)
        return Lesson.objects.get(pk=response.data["id"])

    def media_files(self):
        return {p.relative_to(self.media.name).as_posix(): p.read_bytes()
                for p in Path(self.media.name).rglob("*") if p.is_file()}

    def snapshot(self):
        from .test_training_management import TrainingManagementAPITests
        return TrainingManagementAPITests.snapshot(self)

    def assert_field_error(self, response, field):
        self.assertEqual(response.status_code, 400, response.data)
        self.assertIn(field, response.data["error"]["fields"])

    def test_create_server_metadata_defaults_safe_response_and_audit(self):
        with self.captureOnCommitCallbacks(execute=True):
            response = self.create()
        self.assertEqual(response.status_code, 201, response.data)
        lesson = Lesson.objects.get(pk=response.data["id"])
        self.assertEqual(response.data, {
            "id": lesson.pk, "module_id": self.draft_module.pk, "training_version_id": self.draft.pk,
            "title": "Video lesson", "content_type": "VIDEO", "position": 1, "is_required": True,
            "minimum_watch_percent": "90.00", "video_duration_seconds": 69, "has_video": True,
        })
        self.assertEqual(lesson.video_checksum, hashlib.sha256(self.payload).hexdigest())
        self.assertEqual(lesson.video_duration_seconds, 69)
        self.assertEqual(lesson.video_file.read(), self.payload)
        lesson.video_file.close()
        self.assertEqual(self.duration.call_count, 1)
        self.assertNotIn("lesson.mp4", lesson.video_file.name)
        event = AuditLog.objects.get(action="training.lesson.created")
        self.assertEqual(event.actor_id, self.user.pk)
        self.assertNotIn(lesson.video_file.name, json.dumps(event.after_data))
        self.assertNotIn("video_checksum", event.after_data)

    def test_memory_and_disk_handlers_and_stream_lifecycle(self):
        for index, limit in enumerate((2621440, 0), start=1):
            with override_settings(FILE_UPLOAD_MAX_MEMORY_SIZE=limit):
                response = self.create(position=index)
            self.assertEqual(response.status_code, 201, response.data)
            lesson = Lesson.objects.get(pk=response.data["id"])
            with lesson.video_file.open("rb") as file:
                self.assertEqual(file.read(), self.payload)
            self.assertEqual(lesson.video_checksum, hashlib.sha256(self.payload).hexdigest())

    def test_metadata_edit_noop_and_replacement_keep_old_media(self):
        video = self.make_video()
        original_name = video.video_file.name
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.patch(self.detail_url(video), {
                "title": "Updated", "is_required": False, "minimum_watch_percent": "80.25", "position": 5,
            }, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertFalse(response.data["is_required"])
        self.assertEqual(response.data["minimum_watch_percent"], "80.25")
        self.assertEqual(self.duration.call_count, 1)
        before, files = self.snapshot(), self.media_files()
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            self.assertEqual(self.client.patch(self.detail_url(video), {}, format="json").status_code, 200)
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)
        replacement = self.payload + b"replacement"
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.patch(self.detail_url(video), {"video_file": self.upload(replacement)}, format="multipart")
        self.assertEqual(response.status_code, 200, response.data)
        video.refresh_from_db()
        self.assertNotEqual(video.video_file.name, original_name)
        self.assertEqual(video.video_checksum, hashlib.sha256(replacement).hexdigest())
        self.assertFalse(video.is_required)
        self.assertEqual(str(video.minimum_watch_percent), "80.25")
        self.assertEqual(self.duration.call_count, 2)
        self.assertEqual(self.media_files()[original_name], files[original_name])

    def test_invalid_and_missing_uploads_do_not_write_storage_or_audits(self):
        before, files = self.snapshot(), self.media_files()
        for upload in (None, self.upload(b""), self.upload(name="wrong.exe"), self.upload(b"corrupt")):
            response = self.client.post(self.list_url(), {
                "title": "Invalid", "position": 1, **({"video_file": upload} if upload is not None else {}),
            }, format="multipart")
            self.assert_field_error(response, "video_file")
        self.duration.assert_not_called()
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.media_files(), files)

    def test_signature_alone_does_not_bypass_probe_and_processing_fails_closed(self):
        for message in ("Automatic video processing is unavailable.", "This video could not be read.", "Video inspection took too long."):
            with patch("training.video_uploads._probe_video_duration", side_effect=ValidationError(message)):
                response = self.create()
            self.assert_field_error(response, "video_file")
            self.assertFalse(Lesson.objects.filter(module=self.draft_module).exists())
        self.assertEqual(self.media_files(), {})

    def test_bad_metadata_types_unknown_fields_and_no_client_metadata_authority(self):
        for field, value in (("position", 0), ("position", 1.5), ("position", True),
                             ("title", ""), ("title", "x" * 201), ("minimum_watch_percent", "NaN"),
                             ("minimum_watch_percent", "100.01"), ("minimum_watch_percent", "-1"),
                             ("is_required", "bad"), ("content_type", "TEXT"),
                             ("body", "Not supported"), ("video_checksum", "a" * 64),
                             ("video_duration_seconds", 1), ("module_id", 999),
                             ("training_version_id", 999), ("video_url", "file:///private")):
            with self.subTest(field=field):
                self.assert_field_error(self.create(**{field: value}), field)
        self.assert_field_error(self.client.post(self.list_url(), {
            "title": "Bad reference", "position": 1, "video_file": "training/videos/existing.mp4",
        }, format="json"), "video_file")
        self.assertFalse(self.media_files())

    def test_duplicate_positions_and_failed_replacement_preserve_existing_bytes(self):
        video = self.make_video()
        before, files = self.snapshot(), self.media_files()
        self.assert_field_error(self.create(title="Duplicate"), "position")
        self.assert_field_error(self.client.patch(self.detail_url(video), {
            "video_file": self.upload(b"invalid"), "title": "Rejected",
        }, format="multipart"), "video_file")
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.media_files(), files)

    def test_get_is_independent_read_only_and_never_exposes_a_media_url(self):
        video = self.make_video()
        before, files = self.snapshot(), self.media_files()
        reader = get_user_model().objects.create_user(username="video-reader")
        reader.user_permissions.add(Permission.objects.get(content_type__app_label="training", codename="view_lesson"))
        self.authenticate(reader)
        response = self.client.get(self.detail_url(video))
        self.assertEqual(response.status_code, 200, response.data)
        for forbidden in ("video_file", "video_url", "url", "video_checksum", "body", "questions"):
            self.assertNotIn(forbidden, response.data)
        self.assertNotIn(video.video_file.name, json.dumps(response.data))
        self.assertEqual(self.client.patch(self.detail_url(video), {"title": "Denied"}, format="json").status_code, 403)
        self.assertEqual(self.media_files(), files)
        # The reader fixture itself is excluded from the business snapshot.
        self.assertEqual(self.snapshot(), before)

    def test_add_view_change_permissions_and_manager_denial_are_independent(self):
        video = self.make_video()
        for index, permission in enumerate(("add_lesson", "view_lesson", "change_lesson", "view_trainingversion")):
            user = get_user_model().objects.create_user(username=f"video-perm-{index}")
            user.user_permissions.add(Permission.objects.get(content_type__app_label="training", codename=permission))
            self.authenticate(user)
            self.assertEqual(self.create(position=index + 2).status_code, 201 if permission == "add_lesson" else 403)
            self.assertEqual(self.client.get(self.detail_url(video)).status_code, 200 if permission == "view_lesson" else 403)
            self.assertEqual(self.client.patch(self.detail_url(video), {"title": "Edited"}, format="json").status_code,
                             200 if permission == "change_lesson" else 403)
        manager = get_user_model().objects.create_user(username="video-manager")
        manager.groups.add(Group.objects.get(name="Manager"))
        self.authenticate(manager)
        self.assertEqual(self.create(position=9).status_code, 403)
        self.assertEqual(self.client.get(self.detail_url(video)).status_code, 403)

    def test_wrong_parents_text_records_and_frozen_versions_cannot_mutate(self):
        video = self.make_video()
        text = Lesson.objects.create(module=self.draft_module, title="Text", content_type="TEXT", position=2, body="Read")
        other = TrainingVersion.objects.create(training=self.training, version_number=3, title="Other", created_by=self.user)
        other_module = Module.objects.create(training_version=other, title="Other", position=1)
        before, files = self.snapshot(), self.media_files()
        for url in (self.detail_url(video, other_module), self.detail_url(text)):
            self.assertEqual(self.client.get(url).status_code, 404)
            self.assertEqual(self.client.patch(url, {"title": "Rejected"}, format="json").status_code, 404)
        self.assertEqual(self.client.post(self.list_url(other_module), {
            "title": "Rejected", "position": 1, "video_file": self.upload(),
        }, format="multipart").status_code, 404)
        for state in ("PUBLISHED", "RETIRED"):
            if state == "RETIRED":
                self.version.status = state
                self.version.save()
                before = self.snapshot()
            frozen = self.detail_url(self.video_lesson, self.module, self.version)
            self.assertEqual(self.client.get(frozen).status_code, 404)
            self.assertEqual(self.client.patch(frozen, {"title": "Rejected"}, format="json").status_code, 404)
            self.assertEqual(self.client.post(self.list_url(self.module, self.version), {
                "title": "Rejected", "position": 9, "video_file": self.upload(),
            }, format="multipart").status_code, 404)
            self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.media_files(), files)

    def test_anonymous_inactive_and_foreign_ids_are_denied_without_processing(self):
        self.client.credentials()
        self.assertEqual(self.create().status_code, 401)
        self.assertEqual(self.client.get(self.list_url() + "999999/").status_code, 401)
        self.authenticate(self.employee_user)
        known = self.create()
        missing = self.client.post(self.list_url().replace(str(self.draft.pk), "999999", 1), {
            "title": "Denied", "position": 1, "video_file": self.upload(),
        }, format="multipart")
        self.assertEqual(known.status_code, 403)
        self.assertEqual(known.data, missing.data)
        self.authenticate(self.user)
        self.user.is_active = False
        self.user.save()
        self.assertEqual(self.create().status_code, 401)
        self.employee_user.user_permissions.add(Permission.objects.get(
            content_type__app_label="training", codename="add_lesson",
        ))
        self.employee.is_active = False
        self.employee.deactivation_reason = "Isolated video API fixture"
        self.employee.save()
        self.employee_user.is_active = True
        self.employee_user.save()
        self.authenticate(self.employee_user)
        self.assertEqual(self.create().status_code, 403)
        self.duration.assert_not_called()

    def test_database_failure_after_file_save_cleans_only_new_upload(self):
        video = self.make_video()
        before, files = self.snapshot(), self.media_files()
        original = Lesson.save

        def fail_after_save(instance, *args, **kwargs):
            original(instance, *args, **kwargs)
            raise IntegrityError("Isolated DB failure")

        with self.captureOnCommitCallbacks(execute=True) as callbacks, patch.object(Lesson, "save", fail_after_save):
            with self.assertRaises(IntegrityError):
                services.update_video_lesson(self.user, self.draft.pk, self.draft_module.pk, video.pk,
                                            {"video_file": self.upload(self.payload + b"new")})
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.media_files(), files)

    def test_partial_storage_failure_is_cleaned_without_paths_in_response(self):
        video = self.make_video()
        storage = video.video_file.storage
        original = storage.save
        before, files = self.snapshot(), self.media_files()

        def fail_after_partial_write(name, content, max_length=None):
            original(name, ContentFile(b"partial"), max_length=max_length)
            raise OSError("private filesystem details")

        with patch.object(storage, "save", side_effect=fail_after_partial_write):
            response = self.client.patch(self.detail_url(video), {
                "video_file": self.upload(self.payload + b"new"),
            }, format="multipart")
        self.assertEqual(response.status_code, 503, response.data)
        self.assertNotIn("private filesystem", json.dumps(response.data))
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.media_files(), files)

    def test_enclosing_transaction_is_rejected_before_new_files(self):
        before, files = self.snapshot(), self.media_files()
        with transaction.atomic(), self.assertRaises(RuntimeError):
            services.create_video_lesson(self.user, self.draft.pk, self.draft_module.pk,
                                         {"title": "Rejected", "position": 1, "video_file": self.upload()})
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.media_files(), files)

    def test_shared_size_stream_and_filename_checks_are_preserved(self):
        before, files = self.snapshot(), self.media_files()
        for size in (len(self.payload) + 1, 2 * 1024**3 + 1):
            uploaded = self.upload()
            uploaded.size = size
            with self.assertRaises(ValidationError):
                services.create_video_lesson(self.user, self.draft.pk, self.draft_module.pk,
                                             {"title": "Rejected", "position": 1, "video_file": uploaded})
        self.duration.assert_not_called()
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.media_files(), files)
        response = self.create(video_file=self.upload(name="../../untrusted.mp4"))
        self.assertEqual(response.status_code, 201, response.data)
        lesson = Lesson.objects.get(pk=response.data["id"])
        self.assertNotIn("..", lesson.video_file.name)
        self.assertNotIn("untrusted", lesson.video_file.name)

    def test_malformed_payloads_and_missing_fields_are_controlled(self):
        for payload in ([], "value", 1, True, None):
            response = self.client.post(self.list_url(), json.dumps(payload), content_type="application/json")
            self.assertEqual(response.status_code, 400, response.data)
        for field in ("title", "position"):
            values = {"title": "Video", "position": 1, "video_file": self.upload()}
            del values[field]
            self.assert_field_error(self.client.post(self.list_url(), values, format="multipart"), field)
        self.assertEqual(self.media_files(), {})

    def test_rollback_after_audit_scheduling_discards_file_and_success_event(self):
        video = self.make_video()
        before, files = self.snapshot(), self.media_files()
        original = services.record_event

        def fail_after_scheduling(*args, **kwargs):
            original(*args, **kwargs)
            raise ValidationError({"__all__": ["Isolated save failure"]})

        with self.captureOnCommitCallbacks(execute=True) as callbacks, patch.object(services, "record_event", fail_after_scheduling):
            response = self.client.patch(self.detail_url(video), {"video_file": self.upload(self.payload + b"new")}, format="multipart")
        self.assertEqual(response.status_code, 400, response.data)
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.media_files(), files)

    def test_existing_missing_media_namespace_is_never_reused(self):
        video = self.make_video()
        old_name = video.video_file.name
        old_directory = Path(video.video_file.storage.path(old_name)).parent
        # Only this test's newly created file is removed to reproduce an old
        # record whose media is already missing. No shared media is involved.
        video.video_file.storage.delete(old_name)
        old_directory.rmdir()
        original = tempfile.mkdtemp
        attempted_collision = False

        def reserve(*args, **kwargs):
            nonlocal attempted_collision
            prefix = kwargs.get("prefix", args[1] if len(args) > 1 else None)
            if prefix == "upload-" and not attempted_collision:
                attempted_collision = True
                old_directory.mkdir()
                return str(old_directory)
            return original(*args, **kwargs)

        before = Lesson.objects.filter(pk=video.pk).values().get()
        with patch("api.v1.video_management_services.tempfile.mkdtemp", side_effect=reserve):
            response = self.create(position=2)
        self.assertEqual(response.status_code, 201, response.data)
        new = Lesson.objects.get(pk=response.data["id"])
        self.assertNotEqual(Path(new.video_file.name).parent, Path(old_name).parent)
        self.assertEqual(Lesson.objects.filter(pk=video.pk).values().get(), before)

    def test_lock_conflicts_are_controlled_without_masking_unrelated_db_errors(self):
        for code in (1205, 1213):
            with patch.object(services, "create_video_lesson", side_effect=OperationalError(code, "private SQL details")):
                response = self.create()
            self.assertEqual(response.status_code, 409)
            self.assertNotIn("private SQL", json.dumps(response.data))
        with patch.object(services, "create_video_lesson", side_effect=OperationalError(2006, "unrelated")):
            with self.assertRaises(OperationalError):
                self.create()
