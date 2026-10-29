"""Draft authoring permissions, parent isolation, forms and audit contracts."""

import json
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import ValidationError
from django.core.files.base import ContentFile
from django.db import IntegrityError, connection, transaction
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from training.models import Lesson, Module, TrainingVersion

from . import training_management_services as services


class CurriculumManagementAPITests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.draft = TrainingVersion.objects.create(
            training=cls.training, version_number=2, title="Draft", created_by=cls.user,
        )
        cls.draft_module = Module.objects.create(
            training_version=cls.draft, title="Draft module", description="Original", position=1,
        )
        cls.draft_lesson = Lesson.objects.create(
            module=cls.draft_module, title="Draft text", content_type="TEXT",
            body="Original text", position=1,
        )
        permissions = Permission.objects.filter(
            content_type__app_label="training", codename__in=[
                f"{action}_{model}" for model in ("module", "lesson")
                for action in ("view", "add", "change")
            ],
        )
        cls.user.user_permissions.add(*permissions)

    def setUp(self):
        self.client = APIClient()
        self.authenticate(self.user)

    def authenticate(self, user):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + str(RefreshToken.for_user(user).access_token))

    def identity(self, name, *permissions):
        user = get_user_model().objects.create_user(username=name)
        user.user_permissions.add(*Permission.objects.filter(
            content_type__app_label="training", codename__in=permissions,
        ))
        return user

    def modules_url(self, version=None):
        return f"/api/v1/management/versions/{(version or self.draft).pk}/modules/"

    def module_url(self, module=None, version=None):
        return self.modules_url(version) + f"{(module or self.draft_module).pk}/"

    def lessons_url(self, module=None, version=None):
        return self.module_url(module, version) + "text-lessons/"

    def lesson_url(self, lesson=None, module=None, version=None):
        return self.lessons_url(module, version) + f"{(lesson or self.draft_lesson).pk}/"

    def post_module(self, **values):
        return self.client.post(self.modules_url(), {"title": "New module", "position": 2, **values}, format="json")

    def post_lesson(self, **values):
        return self.client.post(self.lessons_url(), {
            "title": "New text", "body": "Read this", "position": 2, **values,
        }, format="json")

    def snapshot(self):
        # Match the existing catalog's historical/business-state assertions.
        from .test_training_management import TrainingManagementAPITests
        return TrainingManagementAPITests.snapshot(self)

    def assert_field_error(self, response, field):
        self.assertEqual(response.status_code, 400, response.data)
        self.assertEqual(response.data["error"]["code"], "validation_error")
        self.assertIn(field, response.data["error"]["fields"])

    def test_module_create_reuses_form_and_commits_metadata_only_audit(self):
        with self.captureOnCommitCallbacks(execute=True):
            response = self.post_module(description="Module description")
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data, {
            "id": response.data["id"], "training_version_id": self.draft.pk,
            "title": "New module", "description": "Module description", "position": 2,
        })
        event = AuditLog.objects.get(action="training.module.created")
        self.assertEqual(event.actor_id, self.user.pk)
        self.assertEqual(event.before_data, {})
        self.assertEqual(event.after_data["position"], 2)
        self.assertNotIn("Module description", json.dumps(event.after_data))

    def test_partial_module_edit_preserves_other_fields_and_noop_has_no_audit(self):
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.patch(self.module_url(), {"title": "Edited"}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.draft_module.refresh_from_db()
        self.assertEqual((self.draft_module.title, self.draft_module.description, self.draft_module.position),
                         ("Edited", "Original", 1))
        event = AuditLog.objects.get(action="training.module.updated")
        self.assertEqual(event.before_data["title"], "Draft module")
        self.assertEqual(event.after_data["changed_fields"], ["title"])
        before = self.snapshot()
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            self.assertEqual(self.client.patch(self.module_url(), {}, format="json").status_code, 200)
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    def test_module_positions_are_explicit_unique_and_scoped_to_version(self):
        self.assert_field_error(self.post_module(position=1), "position")
        for value in (0, -1, 1.5, True, None, "bad", 2147483648):
            self.assert_field_error(self.post_module(position=value), "position")
        response = self.client.patch(self.module_url(), {"position": 5}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(self.post_module(position=1).status_code, 201)
        before = self.snapshot()
        self.assert_field_error(self.client.patch(self.module_url(), {"position": 1}, format="json"), "position")
        self.assertEqual(self.snapshot(), before)
        self.module.refresh_from_db()
        self.assertEqual(self.module.position, 1)

    def test_text_creation_plain_text_optional_and_safe_response(self):
        text = "Read <script>alert(1)</script> & literal text\nSecond line"
        with self.captureOnCommitCallbacks(execute=True):
            response = self.post_lesson(body=text, is_required=False)
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data, {
            "id": response.data["id"], "module_id": self.draft_module.pk,
            "training_version_id": self.draft.pk, "title": "New text", "body": text,
            "position": 2, "is_required": False, "content_type": "TEXT",
        })
        lesson = Lesson.objects.get(pk=response.data["id"])
        self.assertEqual(lesson.body, text)
        self.assertFalse(lesson.video_file)
        self.assertIsNone(lesson.video_duration_seconds)
        self.assertEqual(lesson.video_checksum, "")
        event = AuditLog.objects.get(action="training.lesson.created")
        self.assertFalse(event.after_data["is_required"])
        self.assertNotIn(text, json.dumps(event.after_data))
        self.assertNotIn("body", event.after_data)

    def test_text_partial_edit_and_required_flag_preserve_other_fields(self):
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.patch(self.lesson_url(), {"is_required": False}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["body"], "Original text")
        self.assertFalse(response.data["is_required"])
        response = self.client.patch(self.lesson_url(), {"body": "Changed text", "position": 7}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertFalse(response.data["is_required"])
        self.assertEqual(response.data["position"], 7)
        self.assertEqual(response.data["body"], "Changed text")
        before = self.snapshot()
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            self.assertEqual(self.client.patch(self.lesson_url(), {}, format="json").status_code, 200)
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    def test_text_title_only_patch_preserves_formatted_body_and_audit(self):
        body = "   Preserve this indentation\n\nSecond paragraph\n\n"
        self.draft_lesson.body = body
        self.draft_lesson.save()
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.patch(self.lesson_url(), {"title": "After"}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["body"], body)
        self.draft_lesson.refresh_from_db()
        self.assertEqual((self.draft_lesson.title, self.draft_lesson.body), ("After", body))
        event = AuditLog.objects.get(action="training.lesson.updated")
        self.assertEqual(event.actor_id, self.user.pk)
        self.assertEqual(event.after_data["changed_fields"], ["title"])
        self.assertNotIn(body, json.dumps(event.after_data))

    def test_text_position_only_patch_preserves_formatted_body(self):
        body = "   Preserve this indentation\n\nSecond paragraph\n\n"
        self.draft_lesson.body = body
        self.draft_lesson.save()
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.patch(self.lesson_url(), {"position": 5}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["body"], body)
        self.draft_lesson.refresh_from_db()
        self.assertEqual((self.draft_lesson.position, self.draft_lesson.body), (5, body))
        event = AuditLog.objects.get(action="training.lesson.updated")
        self.assertEqual(event.after_data["changed_fields"], ["position"])

    def test_text_required_only_patch_preserves_formatted_body(self):
        body = "   Preserve this indentation\n\nSecond paragraph\n\n"
        self.draft_lesson.body = body
        self.draft_lesson.save()
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.patch(self.lesson_url(), {"is_required": False}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["body"], body)
        self.draft_lesson.refresh_from_db()
        self.assertFalse(self.draft_lesson.is_required)
        self.assertEqual(self.draft_lesson.body, body)
        event = AuditLog.objects.get(action="training.lesson.updated")
        self.assertEqual(event.after_data["changed_fields"], ["is_required"])

    def test_text_explicit_body_keeps_existing_normalization(self):
        body = "   Submitted indentation\n\nSecond paragraph\n\n"
        response = self.post_lesson(body=body)
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data["body"], body.strip())
        self.assertEqual(Lesson.objects.get(pk=response.data["id"]).body, body.strip())
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.patch(self.lesson_url(), {"body": body}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["body"], body.strip())
        self.draft_lesson.refresh_from_db()
        self.assertEqual(self.draft_lesson.body, body.strip())
        event = AuditLog.objects.get(action="training.lesson.updated")
        self.assertEqual(event.after_data["changed_fields"], ["body"])

    def test_text_explicit_empty_body_is_not_treated_as_omitted(self):
        self.draft_lesson.body = "   Existing indentation\n\n"
        self.draft_lesson.save()
        before = self.snapshot()
        for body in ("", "   ", "\n\t\n", None):
            with self.subTest(body=body), self.captureOnCommitCallbacks(execute=True) as callbacks:
                response = self.client.patch(self.lesson_url(), {"body": body}, format="json")
            self.assert_field_error(response, "body")
            self.assertEqual(callbacks, [])
            self.assertEqual(self.snapshot(), before)

    def test_text_unchanged_patch_preserves_formatted_body_without_audit(self):
        self.draft_lesson.body = "   Existing indentation\n\nSecond paragraph\n\n"
        self.draft_lesson.save()
        before = self.snapshot()
        for payload in ({}, {"title": self.draft_lesson.title}, {"position": 1}, {"is_required": True}):
            with self.subTest(payload=payload), self.captureOnCommitCallbacks(execute=True) as callbacks:
                response = self.client.patch(self.lesson_url(), payload, format="json")
            self.assertEqual(response.status_code, 200, response.data)
            self.assertEqual(response.data["body"], self.draft_lesson.body)
            self.assertEqual(callbacks, [])
            self.assertEqual(self.snapshot(), before)

    def test_text_positions_body_type_and_title_validation(self):
        self.assert_field_error(self.post_lesson(position=1), "position")
        for field, value in (("position", 0), ("position", 1.5), ("position", True),
                             ("position", 2147483648), ("body", "  "), ("body", None),
                             ("title", ""), ("title", "x" * 201), ("content_type", "VIDEO"),
                             ("content_type", "INVALID"), ("is_required", "unknown")):
            with self.subTest(field=field, value=value):
                self.assert_field_error(self.post_lesson(**{field: value}), field)
        for field in ("title", "body", "position"):
            payload = {"title": "Text", "body": "Read", "position": 2}
            del payload[field]
            self.assert_field_error(self.client.post(self.lessons_url(), payload, format="json"), field)
        self.assertEqual(self.post_lesson(content_type="TEXT").status_code, 201)
        self.assert_field_error(self.client.patch(self.lesson_url(), {"position": 2}, format="json"), "position")

    def test_module_titles_and_required_create_fields(self):
        for field, value in (("title", ""), ("title", "x" * 201), ("description", [])):
            self.assert_field_error(self.post_module(**{field: value}), field)
        for field in ("title", "position"):
            payload = {"title": "Module", "position": 2}
            del payload[field]
            self.assert_field_error(self.client.post(self.modules_url(), payload, format="json"), field)

    def test_mass_assignment_and_video_fields_are_rejected(self):
        before = self.snapshot()
        for field in ("id", "training_version", "training_version_id", "created_by", "status", "order"):
            self.assert_field_error(self.post_module(**{field: 1}), field)
            self.assert_field_error(self.client.patch(self.module_url(), {field: 1}, format="json"), field)
        for field in ("id", "module", "module_id", "training_version_id", "video_file", "video_url",
                      "video_checksum", "video_duration_seconds", "minimum_watch_percent", "created_by"):
            self.assert_field_error(self.post_lesson(**{field: 1}), field)
            self.assert_field_error(self.client.patch(self.lesson_url(), {field: 1}, format="json"), field)
        self.assertEqual(self.snapshot(), before)

    def test_malformed_payloads_are_controlled(self):
        for payload in ([], [1], "value", 1, True, None):
            for method, url in (("post", self.modules_url()), ("post", self.lessons_url()),
                                ("patch", self.module_url()), ("patch", self.lesson_url())):
                response = getattr(self.client, method)(url, json.dumps(payload), content_type="application/json")
                self.assertEqual(response.status_code, 400, response.data)

    def test_permissions_remain_independent_for_read_add_and_change(self):
        for index, permission in enumerate(("add_module", "change_module", "view_module",
                                            "add_lesson", "change_lesson", "view_lesson",
                                            "view_training", "view_trainingversion")):
            self.authenticate(self.identity(f"independent-{index}", permission))
            self.assertEqual(self.post_module(position=10 + index).status_code,
                             201 if permission == "add_module" else 403)
            self.assertEqual(self.client.patch(self.module_url(), {"title": "Edited"}, format="json").status_code,
                             200 if permission == "change_module" else 403)
            self.assertEqual(self.client.get(self.module_url()).status_code,
                             200 if permission == "view_module" else 403)
            self.assertEqual(self.post_lesson(position=10 + index).status_code,
                             201 if permission == "add_lesson" else 403)
            self.assertEqual(self.client.patch(self.lesson_url(), {"title": "Edited"}, format="json").status_code,
                             200 if permission == "change_lesson" else 403)
            self.assertEqual(self.client.get(self.lesson_url()).status_code,
                             200 if permission == "view_lesson" else 403)

    def test_mixed_role_effective_grants_work_without_course_or_version_grants(self):
        user = self.identity("mixed", "add_module", "change_module", "add_lesson", "change_lesson")
        user.groups.add(Group.objects.get(name="Manager"), Group.objects.get(name="Employee"))
        self.authenticate(user)
        self.assertEqual(self.post_module().status_code, 201)
        self.assertEqual(self.post_lesson().status_code, 201)
        self.assertEqual(self.client.patch(self.module_url(), {"position": 8}, format="json").status_code, 200)
        self.assertEqual(self.client.patch(self.lesson_url(), {"position": 8}, format="json").status_code, 200)
        self.assertEqual(self.client.get("/api/v1/management/trainings/").status_code, 403)
        self.assertEqual(self.client.get(f"/api/v1/management/versions/{self.draft.pk}/").status_code, 403)

    def test_manager_employee_and_viewer_writes_are_denied_before_lookup(self):
        manager = self.identity("manager-only")
        manager.groups.add(Group.objects.get(name="Manager"))
        for user in (manager, self.employee_user, self.identity("viewer", "view_module", "view_lesson")):
            self.authenticate(user)
            before = self.snapshot()
            for method, url, payload in (("post", self.modules_url(), {"title": "X", "position": 2}),
                                         ("patch", self.module_url(), {"title": "X"}),
                                         ("post", self.lessons_url(), {"title": "X", "body": "X", "position": 2}),
                                         ("patch", self.lesson_url(), {"title": "X"})):
                known = getattr(self.client, method)(url, payload, format="json")
                missing = getattr(self.client, method)(url.replace(f"/versions/{self.draft.pk}/", "/versions/999999/"), payload, format="json")
                self.assertEqual(known.status_code, 403)
                self.assertEqual(known.data, missing.data)
            self.assertEqual(self.snapshot(), before)

    def test_jwt_and_inactive_mobile_identity_requirements(self):
        for token in (None, "invalid"):
            self.client.credentials(**({"HTTP_AUTHORIZATION": "Bearer " + token} if token else {}))
            self.assertEqual(self.post_module().status_code, 401)
            self.assertEqual(self.post_lesson().status_code, 401)
            self.assertEqual(self.client.get(self.module_url()).status_code, 401)
            self.assertEqual(self.client.patch(self.lesson_url(), {}, format="json").status_code, 401)
        self.user.is_active = False
        self.user.save()
        self.authenticate(self.user)
        self.assertEqual(self.post_module().status_code, 401)
        self.employee_user.user_permissions.add(*Permission.objects.filter(
            content_type__app_label="training", codename__in=["add_module", "add_lesson"],
        ))
        self.employee.is_active = False
        self.employee.deactivation_reason = "Isolated inactive fixture"
        self.employee.save()
        self.employee_user.is_active = True
        self.employee_user.save()
        self.authenticate(self.employee_user)
        self.assertEqual(self.post_module().status_code, 403)
        self.assertEqual(self.post_lesson().status_code, 403)

    def test_published_and_retired_mutations_preserve_all_historical_state(self):
        self.complete_assignment()
        for status in ("PUBLISHED", "RETIRED"):
            if status == "RETIRED":
                self.version.status = status
                self.version.save()
            before = self.snapshot()
            urls = (
                ("post", self.modules_url(self.version)),
                ("patch", self.module_url(self.module, self.version)),
                ("post", self.lessons_url(self.module, self.version)),
                ("patch", self.lesson_url(self.text_lesson, self.module, self.version)),
            )
            with self.captureOnCommitCallbacks(execute=True) as callbacks:
                for method, url in urls:
                    payload = {"title": "Rejected", "position": 9}
                    if "text-lessons" in url:
                        payload["body"] = "Rejected text"
                    self.assertEqual(getattr(self.client, method)(url, payload, format="json").status_code, 404)
            self.assertEqual(callbacks, [])
            self.assertEqual(self.snapshot(), before)
            self.assignment.refresh_from_db()
            self.assertEqual(self.assignment.training_version_id, self.version.pk)

    def test_nested_parent_mismatches_and_video_edits_return_404(self):
        other_version = TrainingVersion.objects.create(
            training=self.training, version_number=3, title="Other", created_by=self.user,
        )
        other_module = Module.objects.create(training_version=other_version, title="Other", position=1)
        video = Lesson.objects.create(
            module=self.draft_module, title="Video", position=2, content_type="VIDEO",
            video_file=ContentFile(b"\x00\x00\x00\x18ftypmp42" + b"0" * 16, name="isolated.mp4"),
            video_duration_seconds=10, video_checksum="a" * 64,
        )
        before = self.snapshot()
        for url in (self.module_url(other_module), self.lesson_url(module=other_module), self.lesson_url(video)):
            self.assertEqual(self.client.patch(url, {"title": "Rejected"}, format="json").status_code, 404)
            self.assertEqual(self.client.get(url).status_code, 404)
        response = self.client.post(self.lessons_url(other_module), {
            "title": "Rejected", "body": "Read", "position": 2,
        }, format="json")
        self.assertEqual(response.status_code, 404)
        self.assertEqual(self.snapshot(), before)

    def test_read_details_are_draft_only_and_have_no_audit_or_business_mutations(self):
        before = self.snapshot()
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            self.assertEqual(self.client.get(self.module_url()).status_code, 200)
            lesson = self.client.get(self.lesson_url())
            self.assertEqual(lesson.status_code, 200)
            self.assertEqual(lesson.data["body"], "Original text")
            self.assertEqual(self.client.get(self.module_url(self.module, self.version)).status_code, 404)
            self.assertEqual(self.client.get(self.lesson_url(self.text_lesson, self.module, self.version)).status_code, 404)
            self.assertEqual(self.client.delete(self.lesson_url()).status_code, 405)
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    def test_failed_outer_transaction_discards_writes_and_success_audits(self):
        before = self.snapshot()
        original = services._save_form

        def fail_after_save(*args, **kwargs):
            original(*args, **kwargs)
            raise ValidationError({"__all__": ["Isolated failure"]})

        with self.captureOnCommitCallbacks(execute=True) as callbacks, patch.object(services, "_save_form", fail_after_save):
            self.assertEqual(self.post_module().status_code, 400)
            self.assertEqual(self.post_lesson().status_code, 400)
            self.assertEqual(self.client.patch(self.module_url(), {"title": "Rejected"}, format="json").status_code, 400)
            self.assertEqual(self.client.patch(self.lesson_url(), {"body": "Rejected"}, format="json").status_code, 400)
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            with transaction.atomic():
                self.assertEqual(self.post_module().status_code, 201)
                transaction.set_rollback(True)
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    def test_position_conflict_mapping_is_exact_and_schema_contract_is_real(self):
        for model, constraint, columns, url in (
            (Module, "unique_module_position", ["training_version_id", "position"], self.modules_url()),
            (Lesson, "unique_lesson_position", ["module_id", "position"], self.lessons_url()),
        ):
            with connection.cursor() as cursor:
                found = connection.introspection.get_constraints(cursor, model._meta.db_table)[constraint]
            self.assertTrue(found["unique"])
            self.assertEqual(found["columns"], columns)
            service = "create_module" if model is Module else "create_text_lesson"
            payload = {"title": "Valid", "position": 3}
            if model is Lesson:
                payload["body"] = "Valid"
            for key, expected in ((constraint, 409), (f"{model._meta.db_table}.{constraint}", 409),
                                  (constraint + "_other", None), ("other_table." + constraint, None)):
                error = IntegrityError(1062, f"Duplicate entry '3' for key '{key}'")
                with patch.object(services, service, side_effect=error):
                    if expected:
                        response = self.client.post(url, payload, format="json")
                        self.assertEqual(response.status_code, expected)
                        self.assertNotIn(constraint, json.dumps(response.data))
                    else:
                        with self.assertRaises(IntegrityError):
                            self.client.post(url, payload, format="json")
