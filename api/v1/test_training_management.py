"""Permission, validation and lifecycle contracts for mobile course authoring."""

import json
from unittest import skipUnless
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import ValidationError
from django.db import IntegrityError, connection, transaction
from django.test.utils import CaptureQueriesContext
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from assessments.models import Assessment, AssessmentAttempt, QuestionOption
from audit.models import AuditLog
from certifications.models import Certificate
from config.model_test_utils import CurriculumTestCase
from notifications.models import Notification
from training.forms import TrainingForm
from training.models import (
    Lesson, LessonProgress, Module, Training, TrainingAssignment, TrainingVersion,
    VideoWatchSession,
)

from .training_management_views import VERSION_NUMBER_CONSTRAINT


class TrainingManagementAPITests(CurriculumTestCase):
    catalog_url = "/api/v1/management/trainings/"
    discovery_url = "/api/v1/management/versions/"

    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.user.groups.add(Group.objects.get(name="Training Coordinator"))
        cls.employee_user.groups.add(Group.objects.get(name="Employee"))
        cls.admin = get_user_model().objects.create_user(username="catalog-admin")
        cls.admin.groups.add(Group.objects.get(name="Administrator"))
        cls.manager = get_user_model().objects.create_user(username="catalog-manager")
        cls.manager.groups.add(Group.objects.get(name="Manager"))

    def setUp(self):
        self.client = APIClient()

    def authenticate(self, user=None):
        token = RefreshToken.for_user(user or self.user).access_token
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + str(token))

    def grant(self, user, *permissions):
        for codename in permissions:
            user.user_permissions.add(Permission.objects.get(
                content_type__app_label="training", codename=codename,
            ))

    def permission_user(self, name, *permissions):
        user = get_user_model().objects.create_user(username=name)
        self.grant(user, *permissions)
        return user

    def training_url(self, training=None):
        return f"{self.catalog_url}{(training or self.training).pk}/"

    def versions_url(self, training=None):
        return self.training_url(training) + "versions/"

    def version_url(self, version=None):
        return f"/api/v1/management/versions/{(version or self.version).pk}/"

    def read_urls(self):
        return [self.catalog_url, self.training_url(), self.versions_url(), self.version_url(), self.discovery_url]

    def post_course(self, payload=None, user=None):
        self.authenticate(user)
        return self.client.post(self.catalog_url, payload if payload is not None else {
            "code": "MOBILE-COURSE", "catalog_title": "Mobile course",
        }, format="json")

    def snapshot(self):
        models = (
            Training, TrainingVersion, Module, Lesson, TrainingAssignment,
            LessonProgress, VideoWatchSession, Assessment, AssessmentAttempt,
            QuestionOption, Certificate, Notification, AuditLog,
        )
        return {model._meta.label: list(model.objects.order_by("pk").values()) for model in models}

    def assert_validation(self, response, field=None):
        self.assertEqual(response.status_code, 400, response.data)
        self.assertEqual(set(response.data), {"error"})
        self.assertEqual(response.data["error"]["code"], "validation_error")
        if field is not None:
            self.assertIn(field, response.data["error"]["fields"])

    def test_every_endpoint_requires_valid_jwt(self):
        for token in (None, "invalid-token"):
            self.client.credentials(**({"HTTP_AUTHORIZATION": "Bearer " + token} if token else {}))
            for url in self.read_urls():
                with self.subTest(token=token, url=url):
                    self.assertEqual(self.client.get(url).status_code, 401)
            self.assertEqual(self.client.post(self.catalog_url, {}, format="json").status_code, 401)
            self.assertEqual(self.client.patch(self.training_url(), {}, format="json").status_code, 401)
            self.assertEqual(self.client.post(self.versions_url(), {}, format="json").status_code, 401)

    def test_employee_and_ungranted_manager_cannot_read_or_write_catalog(self):
        for user in (self.employee_user, self.manager):
            self.authenticate(user)
            for url in self.read_urls():
                with self.subTest(user=user.username, url=url):
                    self.assertEqual(self.client.get(url).status_code, 403)
            self.assertEqual(self.client.post(self.catalog_url, {}, format="json").status_code, 403)
            self.assertEqual(self.client.patch(self.training_url(), {}, format="json").status_code, 403)
            self.assertEqual(self.client.post(self.versions_url(), {}, format="json").status_code, 403)
        self.assertFalse(AuditLog.objects.exists())

    def test_inactive_users_and_linked_employees_cannot_use_authoring_grants(self):
        self.authenticate()
        self.user.is_active = False
        self.user.save()
        for url in self.read_urls():
            self.assertEqual(self.client.get(url).status_code, 401)
        self.assertEqual(self.client.post(self.catalog_url, {}, format="json").status_code, 401)
        self.employee_user.groups.add(Group.objects.get(name="Administrator"))
        self.employee.is_active = False
        self.employee.deactivation_reason = "Isolated API fixture"
        self.employee.save()
        self.employee_user.is_active = True
        self.employee_user.save()
        self.authenticate(self.employee_user)
        for url in self.read_urls():
            self.assertEqual(self.client.get(url).status_code, 403)
        self.assertEqual(self.client.patch(self.training_url(), {}, format="json").status_code, 403)
        self.assertEqual(self.client.post(self.versions_url(), {}, format="json").status_code, 403)

    def test_management_only_admin_and_coordinator_can_read_without_employee_links(self):
        for user in (self.admin, self.user):
            self.authenticate(user)
            for url in self.read_urls():
                with self.subTest(user=user.username, url=url):
                    self.assertEqual(self.client.get(url).status_code, 200)
            self.assertEqual(self.client.get("/api/v1/assignments/").status_code, 403)

    def test_course_and_version_read_permissions_are_independent(self):
        course_reader = self.permission_user("course-reader", "view_training")
        version_reader = self.permission_user("version-reader", "view_trainingversion")
        for user, course_status, version_status in (
            (course_reader, 200, 403), (version_reader, 403, 200),
        ):
            self.authenticate(user)
            self.assertEqual(self.client.get(self.catalog_url).status_code, course_status)
            self.assertEqual(self.client.get(self.training_url()).status_code, course_status)
            self.assertEqual(self.client.get(self.versions_url()).status_code, version_status)
            self.assertEqual(self.client.get(self.discovery_url).status_code, version_status)
            detail = self.client.get(self.version_url())
            self.assertEqual(detail.status_code, version_status)
            if version_status == 200:
                self.assertEqual(detail.data["modules"][0]["id"], self.module.pk)
            self.assertEqual(self.client.post(self.catalog_url, {}, format="json").status_code, 403)
            self.assertEqual(self.client.patch(self.training_url(), {}, format="json").status_code, 403)
            self.assertEqual(self.client.post(self.versions_url(), {}, format="json").status_code, 403)

    def test_effective_permissions_apply_to_mixed_roles_without_personal_learning_access(self):
        self.manager.groups.add(Group.objects.get(name="Employee"))
        self.grant(self.manager, "view_training", "view_trainingversion")
        self.authenticate(self.manager)
        for url in self.read_urls():
            self.assertEqual(self.client.get(url).status_code, 200)
        self.assertEqual(self.client.get(f"/api/v1/assignments/{self.assignment.pk}/").status_code, 403)
        self.assertEqual(self.client.post(self.catalog_url, {}, format="json").status_code, 403)

    def test_denied_requests_do_not_enumerate_existing_object_ids(self):
        self.authenticate(self.employee_user)
        for existing, missing in (
            (self.training_url(), self.catalog_url + "999999/"),
            (self.versions_url(), self.catalog_url + "999999/versions/"),
            (self.version_url(), "/api/v1/management/versions/999999/"),
        ):
            first = self.client.get(existing)
            second = self.client.get(missing)
            self.assertEqual(first.status_code, 403)
            self.assertEqual(second.status_code, 403)
            self.assertEqual(first.data, second.data)
        self.authenticate()
        self.assertEqual(self.client.get(self.catalog_url + "999999/").status_code, 404)
        self.assertEqual(self.client.get(self.catalog_url + "999999/versions/").status_code, 404)
        self.assertEqual(self.client.get("/api/v1/management/versions/999999/").status_code, 404)

    def test_catalog_contract_and_latest_version_use_highest_number_not_publication(self):
        draft = self.new_version()
        empty = Training.objects.create(code="EMPTY", catalog_title="No versions", created_by=self.user)
        self.authenticate()
        response = self.client.get(self.catalog_url)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(set(response.data), {"count", "next", "previous", "results"})
        rows = {row["id"]: row for row in response.data["results"]}
        for row in rows.values():
            self.assertTrue({"id", "code", "catalog_title", "description", "is_active",
                             "latest_version_number", "latest_version_status"} <= set(row))
        self.assertEqual(rows[self.training.pk]["latest_version_number"], draft.version_number)
        self.assertEqual(rows[self.training.pk]["latest_version_status"], "DRAFT")
        self.assertIsNone(rows[empty.pk]["latest_version_number"])
        self.assertIsNone(rows[empty.pk]["latest_version_status"])
        detail = self.client.get(self.training_url())
        self.assertEqual(detail.data["code"], self.training.code)
        self.assertEqual(detail.data["catalog_title"], self.training.catalog_title)
        self.assertIn("created_at", detail.data)
        self.assertIn("updated_at", detail.data)

    def test_catalog_search_matches_code_title_description_and_combines_active_filter(self):
        inactive = Training.objects.create(code="ARCHIVED", catalog_title="Archived course",
                                           description="Needle detail", is_active=False, created_by=self.user)
        self.authenticate()
        for search, expected in (("safety", self.training.pk), ("ARCHIVED", inactive.pk),
                                 ("archived course", inactive.pk), ("needle", inactive.pk)):
            with self.subTest(search=search):
                response = self.client.get(self.catalog_url, {"search": search})
                self.assertEqual(response.status_code, 200)
                self.assertEqual([row["id"] for row in response.data["results"]], [expected])
        response = self.client.get(self.catalog_url, {"search": "needle", "is_active": "true"})
        self.assertEqual(response.data["count"], 0)
        response = self.client.get(self.catalog_url, {"search": "needle", "is_active": "false"})
        self.assertEqual([row["id"] for row in response.data["results"]], [inactive.pk])

    def test_catalog_and_history_pagination_has_no_duplicates_and_bounds_are_validated(self):
        Training.objects.create(code="ANOTHER", catalog_title="Another", created_by=self.user)
        self.new_version()
        self.authenticate()
        for url in (self.catalog_url, self.versions_url()):
            first = self.client.get(url, {"page_size": 1})
            second = self.client.get(url, {"page_size": 1, "page": 2})
            self.assertEqual(first.status_code, 200)
            self.assertEqual(second.status_code, 200)
            self.assertEqual(first.data["count"], 2)
            self.assertIsNotNone(first.data["next"])
            self.assertIsNone(first.data["previous"])
            self.assertIsNone(second.data["next"])
            self.assertIsNotNone(second.data["previous"])
            self.assertNotEqual(first.data["results"][0]["id"], second.data["results"][0]["id"])
            self.assertEqual(self.client.get(url, {"page": 999}).status_code, 404)
            for key, value in (("page", "bad"), ("page", 0), ("page", -1),
                               ("page_size", 0), ("page_size", 101), ("page_size", "1.5")):
                with self.subTest(url=url, key=key, value=value):
                    self.assert_validation(self.client.get(url, {key: value}), key)
        self.assert_validation(self.client.get(self.catalog_url, {"search": "x" * 151}), "search")
        self.assert_validation(self.client.get(self.catalog_url, {"is_active": "unknown"}), "is_active")

    def test_version_history_includes_draft_published_and_retired_in_descending_number_order(self):
        draft = self.new_version()
        self.authenticate()
        response = self.client.get(self.versions_url())
        self.assertEqual([row["id"] for row in response.data["results"]], [draft.pk, self.version.pk])
        self.assertEqual([row["status"] for row in response.data["results"]], ["DRAFT", "PUBLISHED"])
        self.version.status = "RETIRED"
        self.version.save()
        response = self.client.get(self.versions_url())
        self.assertEqual([row["status"] for row in response.data["results"]], ["DRAFT", "RETIRED"])
        for row in response.data["results"]:
            self.assertEqual(row["training_id"], self.training.pk)
            self.assertTrue({"id", "training_id", "version_number", "title", "status"} <= set(row))

    def test_ordered_curriculum_contains_only_safe_summaries(self):
        draft = self.new_version()
        later = Module.objects.create(training_version=draft, title="Later", position=3)
        first = Module.objects.create(training_version=draft, title="First", position=1)
        last_lesson = Lesson.objects.create(module=first, title="Optional", position=8,
                                            content_type="TEXT", body="Secret content", is_required=False)
        first_lesson = Lesson.objects.create(module=first, title="Required", position=2,
                                             content_type="TEXT", body="Private lesson content")
        self.authenticate()
        response = self.client.get(self.version_url(draft))
        self.assertEqual(response.status_code, 200)
        self.assertEqual([row["id"] for row in response.data["modules"]], [first.pk, later.pk])
        lessons = response.data["modules"][0]["lessons"]
        self.assertEqual([row["id"] for row in lessons], [first_lesson.pk, last_lesson.pk])
        self.assertEqual([row["order"] for row in lessons], [2, 8])
        self.assertEqual([row["is_required"] for row in lessons], [True, False])
        self.assertEqual([row["lesson_type"] for row in lessons], ["TEXT", "TEXT"])
        self.assertEqual(response.data["modules"][0]["order"], 1)
        forbidden = {"body", "video_file", "video_url", "media_url", "video_checksum",
                     "password", "questions", "assessments", "is_correct", "correct_option"}

        def assert_safe(value):
            if isinstance(value, dict):
                self.assertFalse(set(value) & forbidden)
                for child in value.values():
                    assert_safe(child)
            elif isinstance(value, (list, tuple)):
                for child in value:
                    assert_safe(child)

        for url in (self.version_url(draft), self.version_url(), self.training_url(), self.catalog_url):
            result = self.client.get(url)
            self.assertEqual(result.status_code, 200)
            assert_safe(result.data)
            serialized = json.dumps(result.data)
            for secret in ("training/videos", "Wear PPE?", "Private lesson content", "Secret content"):
                self.assertNotIn(secret, serialized)

    def test_read_endpoints_do_not_mutate_business_state(self):
        self.new_version()
        self.authenticate()
        before = self.snapshot()
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            for url in self.read_urls():
                self.assertEqual(self.client.get(url).status_code, 200)
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    def test_catalog_query_count_does_not_grow_per_course(self):
        self.authenticate()
        with CaptureQueriesContext(connection) as initial:
            self.assertEqual(self.client.get(self.catalog_url).status_code, 200)
        for index in range(12):
            training = Training.objects.create(code=f"BULK-{index}", catalog_title=f"Course {index}",
                                               created_by=self.user)
            TrainingVersion.objects.create(training=training, version_number=1, title="Draft", created_by=self.user)
        with CaptureQueriesContext(connection) as expanded:
            response = self.client.get(self.catalog_url)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.data["count"], 13)
        self.assertLessEqual(len(expanded), len(initial) + 2)

    def test_version_query_count_does_not_grow_per_module_or_lesson(self):
        draft = self.new_version()
        self.authenticate()
        Module.objects.create(training_version=draft, title="First", position=1)
        with CaptureQueriesContext(connection) as initial:
            self.assertEqual(self.client.get(self.version_url(draft)).status_code, 200)
        for index in range(2, 12):
            module = Module.objects.create(training_version=draft, title=f"Module {index}", position=index)
            Lesson.objects.create(module=module, title="Read", position=1, content_type="TEXT", body="Body")
        with CaptureQueriesContext(connection) as expanded:
            response = self.client.get(self.version_url(draft))
            self.assertEqual(response.status_code, 200)
            self.assertEqual(len(response.data["modules"]), 11)
        self.assertLessEqual(len(expanded), len(initial) + 2)

    def test_course_creation_uses_server_actor_defaults_and_commit_time_audit(self):
        with self.captureOnCommitCallbacks(execute=True):
            response = self.post_course()
            self.assertEqual(response.status_code, 201, response.data)
            self.assertFalse(AuditLog.objects.exists())
        training = Training.objects.get(pk=response.data["id"])
        self.assertEqual(training.code, "MOBILE-COURSE")
        self.assertEqual(training.catalog_title, "Mobile course")
        self.assertEqual(training.description, "")
        self.assertTrue(training.is_active)
        self.assertEqual(training.created_by_id, self.user.pk)
        self.assertFalse(training.versions.exists())
        event = AuditLog.objects.get(action="training.training.created")
        self.assertEqual(event.entity_id, str(training.pk))
        self.assertEqual(event.actor_id, self.user.pk)
        self.assertEqual(event.after_data["code"], training.code)

    def test_creation_edit_and_version_add_permissions_are_independent(self):
        creator = self.permission_user("course-creator", "add_training")
        response = self.post_course(user=creator)
        self.assertEqual(response.status_code, 201, response.data)
        created = Training.objects.get(pk=response.data["id"])
        self.assertEqual(created.created_by_id, creator.pk)
        self.assertEqual(self.client.get(self.training_url(created)).status_code, 403)
        self.assertEqual(self.client.patch(self.training_url(), {"catalog_title": "No"}, format="json").status_code, 403)
        self.assertEqual(self.client.post(self.versions_url(), {"title": "No"}, format="json").status_code, 403)
        editor = self.permission_user("course-editor", "change_training")
        self.authenticate(editor)
        self.assertEqual(self.client.patch(self.training_url(), {"catalog_title": "Edited"}, format="json").status_code, 200)
        self.assertEqual(self.client.get(self.training_url()).status_code, 403)
        self.assertEqual(self.client.post(self.catalog_url, {}, format="json").status_code, 403)
        version_creator = self.permission_user("version-creator", "add_trainingversion")
        self.authenticate(version_creator)
        self.assertEqual(self.client.post(self.versions_url(), {"title": "Next"}, format="json").status_code, 201)
        self.assertEqual(self.client.get(self.versions_url()).status_code, 403)
        self.assertEqual(self.client.patch(self.training_url(), {}, format="json").status_code, 403)

    def test_code_and_title_validation_matches_existing_web_form(self):
        for code, title in (("", "Title"), (" " * 2, "Title"), ("x" * 41, "Title"),
                            ("VALID", ""), ("VALID", " " * 2), ("VALID", "x" * 201)):
            payload = {"code": code, "catalog_title": title, "is_active": True}
            with self.subTest(code=code, title=title):
                form = TrainingForm(data=payload)
                self.assertFalse(form.is_valid())
                response = self.post_course(payload)
                self.assert_validation(response)
                self.assertTrue(set(form.errors) <= set(response.data["error"]["fields"]))
        payload = {"code": "LOWER.code / 2", "catalog_title": "Web-compatible code", "is_active": True}
        form = TrainingForm(data=payload)
        self.assertTrue(form.is_valid(), form.errors)
        self.assertEqual(self.post_course(payload).status_code, 201)
        self.assertFalse(AuditLog.objects.exists())

    def test_duplicate_course_codes_are_rejected_without_success_audit(self):
        for code in (self.training.code, self.training.code.lower()):
            with self.subTest(code=code), self.captureOnCommitCallbacks(execute=True):
                response = self.post_course({"code": code, "catalog_title": "Duplicate"})
                self.assert_validation(response, "code")
        self.assertEqual(Training.objects.count(), 1)
        self.assertFalse(AuditLog.objects.exists())

    def test_course_unknown_privileged_and_readonly_fields_are_rejected(self):
        for field, value in (("id", 1), ("created_by", self.employee_user.pk),
                             ("created_by_id", self.employee_user.pk), ("created_at", "2000-01-01"),
                             ("updated_at", "2000-01-01"), ("latest_version_number", 20),
                             ("versions", []), ("permissions", [])):
            with self.subTest(field=field), self.captureOnCommitCallbacks(execute=True):
                response = self.post_course({"code": "FORGED", "catalog_title": "Forged", field: value})
                self.assert_validation(response, field)
                response = self.client.patch(self.training_url(), {field: value}, format="json")
                self.assert_validation(response, field)
        self.assertEqual(Training.objects.count(), 1)
        self.assertFalse(AuditLog.objects.exists())

    def test_malformed_payload_shapes_and_types_are_controlled(self):
        self.authenticate()
        for method, url in (("POST", self.catalog_url), ("PATCH", self.training_url()),
                            ("POST", self.versions_url())):
            for value in ([], ["field"], "text", 1, True, None):
                with self.subTest(method=method, url=url, value=value):
                    response = self.client.generic(method, url, json.dumps(value), content_type="application/json")
                    self.assert_validation(response)
        for payload in ({"code": [], "catalog_title": "Title"},
                        {"code": "TYPE", "catalog_title": {}},
                        {"code": "TYPE", "catalog_title": "Title", "description": []},
                        {"code": "TYPE", "catalog_title": "Title", "is_active": "unknown"}):
            self.assert_validation(self.post_course(payload))
        response = self.client.post(self.catalog_url, "{broken", content_type="application/json")
        self.assertEqual(response.status_code, 400)
        self.assertEqual(set(response.data), {"error"})
        self.assertEqual(Training.objects.count(), 1)

    def test_partial_course_edit_preserves_unspecified_fields_and_frozen_history(self):
        self.authenticate()
        before_version = TrainingVersion.objects.filter(pk=self.version.pk).values().get()
        before_assignment = TrainingAssignment.objects.filter(pk=self.assignment.pk).values().get()
        before_modules = list(Module.objects.values())
        before_lessons = list(Lesson.objects.values())
        creator = self.training.created_by_id
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.patch(self.training_url(), {"catalog_title": "New catalog title"}, format="json")
            self.assertEqual(response.status_code, 200, response.data)
            self.assertFalse(AuditLog.objects.exists())
        self.training.refresh_from_db()
        self.assertEqual(self.training.catalog_title, "New catalog title")
        self.assertEqual(self.training.code, "SAFETY")
        self.assertEqual(self.training.created_by_id, creator)
        self.assertTrue(self.training.is_active)
        event = AuditLog.objects.get(action="training.training.updated")
        self.assertEqual(event.actor_id, self.user.pk)
        self.assertEqual(event.before_data["catalog_title"], "Safety")
        self.assertEqual(event.after_data["catalog_title"], "New catalog title")
        self.assertEqual(TrainingVersion.objects.filter(pk=self.version.pk).values().get(), before_version)
        self.assertEqual(TrainingAssignment.objects.filter(pk=self.assignment.pk).values().get(), before_assignment)
        self.assertEqual(list(Module.objects.values()), before_modules)
        self.assertEqual(list(Lesson.objects.values()), before_lessons)

    def test_edit_active_state_and_description_matches_web_without_cancelling_assignments(self):
        self.authenticate()
        response = self.client.patch(self.training_url(), {"is_active": False, "description": "Archived catalog"}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.training.refresh_from_db()
        self.assignment.refresh_from_db()
        self.assertFalse(self.training.is_active)
        self.assertEqual(self.training.description, "Archived catalog")
        self.assertEqual(self.assignment.status, "IN_PROGRESS")
        self.assertEqual(self.assignment.training_version_id, self.version.pk)

    def test_edit_duplicate_code_and_invalid_title_do_not_partially_save(self):
        other = Training.objects.create(code="OTHER", catalog_title="Other", created_by=self.user)
        self.authenticate()
        for changes, field in (({"code": other.code, "description": "Must not save"}, "code"),
                                ({"catalog_title": "", "description": "Must not save"}, "catalog_title")):
            with self.subTest(field=field), self.captureOnCommitCallbacks(execute=True):
                self.assert_validation(self.client.patch(self.training_url(), changes, format="json"), field)
        self.training.refresh_from_db()
        self.assertEqual(self.training.description, "")
        self.assertEqual(self.training.code, "SAFETY")
        self.assertEqual(self.training.catalog_title, "Safety")
        self.assertFalse(AuditLog.objects.exists())

    def test_unchanged_course_patch_creates_no_success_event_or_timestamp_change(self):
        self.authenticate()
        before = Training.objects.filter(pk=self.training.pk).values().get()
        with self.captureOnCommitCallbacks(execute=True):
            for payload in ({}, {"catalog_title": self.training.catalog_title, "is_active": True}):
                response = self.client.patch(self.training_url(), payload, format="json")
                self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(Training.objects.filter(pk=self.training.pk).values().get(), before)
        self.assertFalse(AuditLog.objects.exists())

    def test_new_draft_uses_next_number_and_server_metadata_without_cloning(self):
        self.authenticate()
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(self.versions_url(), {
                "title": "Revised safety", "description": "Overview",
                "learning_objectives": "Understand safe work", "change_summary": "New edition",
            }, format="json")
            self.assertEqual(response.status_code, 201, response.data)
            self.assertFalse(AuditLog.objects.exists())
        draft = TrainingVersion.objects.get(pk=response.data["id"])
        self.assertEqual(draft.training_id, self.training.pk)
        self.assertEqual(draft.version_number, 2)
        self.assertEqual(draft.status, "DRAFT")
        self.assertEqual(draft.created_by_id, self.user.pk)
        self.assertIsNone(draft.published_by_id)
        self.assertIsNone(draft.published_at)
        self.assertEqual(draft.title, "Revised safety")
        self.assertEqual(draft.description, "Overview")
        self.assertEqual(draft.learning_objectives, "Understand safe work")
        self.assertEqual(draft.change_summary, "New edition")
        self.assertEqual(response.data["modules"], [])
        self.assertFalse(draft.modules.exists())
        self.assertFalse(draft.assessments.exists())
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.training_version_id, self.version.pk)
        self.version.refresh_from_db()
        self.assertEqual(self.version.status, "PUBLISHED")
        event = AuditLog.objects.get(action="training.trainingversion.created")
        self.assertEqual(event.entity_id, str(draft.pk))
        self.assertEqual(event.actor_id, self.user.pk)
        self.assertEqual(event.after_data["status"], "DRAFT")

    def test_draft_numbering_uses_max_existing_and_works_on_inactive_courses(self):
        self.training.is_active = False
        self.training.save()
        TrainingVersion.objects.create(training=self.training, version_number=5, title="Fifth", created_by=self.user)
        self.authenticate()
        response = self.client.post(self.versions_url(), {"title": "Sixth"}, format="json")
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data["version_number"], 6)
        self.assertEqual(response.data["status"], "DRAFT")
        self.assertEqual(response.data["description"], "")
        self.assertEqual(response.data["learning_objectives"], "")
        self.assertEqual(response.data["change_summary"], "")
        empty = Training.objects.create(code="EMPTY", catalog_title="Empty", created_by=self.user)
        response = self.client.post(self.versions_url(empty), {"title": "First"}, format="json")
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["version_number"], 1)

    def test_draft_fields_reject_lifecycle_actor_cloning_and_number_injection(self):
        self.authenticate()
        for field, value in (("version_number", 90), ("status", "PUBLISHED"),
                             ("training", self.training.pk), ("training_id", self.training.pk),
                             ("created_by", self.employee_user.pk), ("created_by_id", self.employee_user.pk),
                             ("published_by", self.user.pk), ("published_at", "2020-01-01"),
                             ("source_version_id", self.version.pk), ("clone", True), ("modules", [])):
            with self.subTest(field=field), self.captureOnCommitCallbacks(execute=True):
                response = self.client.post(self.versions_url(), {"title": "Forged", field: value}, format="json")
                self.assert_validation(response, field)
        self.assertEqual(TrainingVersion.objects.count(), 1)
        self.assertFalse(AuditLog.objects.exists())

    def test_draft_title_and_text_validation_and_unknown_parent_are_controlled(self):
        self.authenticate()
        for payload in ({}, {"title": ""}, {"title": "   "}, {"title": "x" * 201},
                        {"title": []}, {"title": "Valid", "description": []},
                        {"title": "Valid", "learning_objectives": {}},
                        {"title": "Valid", "change_summary": False}):
            with self.subTest(payload=payload), self.captureOnCommitCallbacks(execute=True):
                self.assert_validation(self.client.post(self.versions_url(), payload, format="json"))
        response = self.client.post(self.catalog_url + "999999/versions/", {"title": "Valid"}, format="json")
        self.assertEqual(response.status_code, 404)
        self.assertEqual(TrainingVersion.objects.count(), 1)
        self.assertFalse(AuditLog.objects.exists())

    def test_outer_rollback_discards_course_version_writes_and_audit_callbacks(self):
        self.authenticate()
        before = self.snapshot()
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            with self.assertRaisesMessage(RuntimeError, "rollback fixture"):
                with transaction.atomic():
                    self.assertEqual(self.post_course().status_code, 201)
                    self.assertEqual(self.client.patch(self.training_url(), {"description": "Rolled back"}, format="json").status_code, 200)
                    self.assertEqual(self.client.post(self.versions_url(), {"title": "Rolled back"}, format="json").status_code, 201)
                    raise RuntimeError("rollback fixture")
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    def test_version_detail_has_no_mutation_methods_including_published_and_retired(self):
        draft = self.new_version()
        self.authenticate()
        for version in (self.version, draft):
            for method in ("post", "patch", "put", "delete"):
                with self.subTest(version=version.pk, method=method):
                    response = getattr(self.client, method)(self.version_url(version), {"title": "Changed"}, format="json")
                    self.assertEqual(response.status_code, 405)
        self.version.status = "RETIRED"
        self.version.save()
        response = self.client.patch(self.version_url(), {"status": "DRAFT"}, format="json")
        self.assertEqual(response.status_code, 405)
        self.version.refresh_from_db()
        self.assertEqual(self.version.status, "RETIRED")
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.training_version_id, self.version.pk)

    def test_assignment_picker_stays_published_only_with_its_existing_envelope(self):
        self.new_version()
        self.authenticate()
        response = self.client.get("/api/v1/management/training-versions/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(set(response.data), {"count", "next", "previous", "results"})
        self.assertEqual([row["id"] for row in response.data["results"]], [self.version.pk])
        self.assertEqual(response.data["results"][0]["training_id"], self.training.pk)
        self.assertEqual(response.data["results"][0]["version_number"], self.version.version_number)
        reader = self.permission_user("catalog-no-assignment", "view_training", "view_trainingversion")
        self.authenticate(reader)
        self.assertEqual(self.client.get(self.catalog_url).status_code, 200)
        self.assertEqual(self.client.get("/api/v1/management/training-versions/").status_code, 403)

    def test_course_race_conflict_mapping_requires_the_exact_existing_code(self):
        other = Training.objects.create(code="OTHER", catalog_title="Other", created_by=self.user)
        self.authenticate()
        before = self.snapshot()
        cases = (
            ("post", self.catalog_url, "create_training", self.training.code.lower()),
            ("patch", self.training_url(), "update_training", other.code.lower()),
        )
        for method, url, service, code in cases:
            with self.subTest(method=method), self.captureOnCommitCallbacks(execute=True) as callbacks:
                with patch(
                    f"api.v1.training_management_views.services.{service}",
                    side_effect=IntegrityError(1062, "Duplicate entry for key code"),
                ) as save:
                    response = getattr(self.client, method)(url, {
                        "code": code, "catalog_title": "Racing request",
                    }, format="json")
                save.assert_called_once()
                self.assert_validation(response, "code")
                self.assertEqual(set(response.data["error"]["fields"]), {"code"})
                self.assertNotIn("Duplicate entry", str(response.data))
            self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    def test_unexpected_course_integrity_errors_propagate_without_success_events(self):
        self.authenticate()
        before = self.snapshot()
        cases = (
            ("post", self.catalog_url, "create_training", "NEW", 1062),
            ("patch", self.training_url(), "update_training", "NEW", 1062),
            # The edited row itself is not evidence of a conflicting course.
            ("patch", self.training_url(), "update_training", self.training.code, 1062),
            ("post", self.catalog_url, "create_training", self.training.code, 1048),
            ("patch", self.training_url(), "update_training", self.training.code, 1048),
        )
        for method, url, service, code, error_number in cases:
            failure = IntegrityError(error_number, "Unexpected integrity failure")
            with self.subTest(method=method, code=code, error=error_number):
                with self.captureOnCommitCallbacks(execute=True) as callbacks:
                    with patch(
                        f"api.v1.training_management_views.services.{service}", side_effect=failure,
                    ) as save:
                        with self.assertRaises(IntegrityError) as raised:
                            getattr(self.client, method)(url, {
                                "code": code, "catalog_title": "Must not save",
                            }, format="json")
                    self.assertIs(raised.exception, failure)
                    save.assert_called_once()
                self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    def test_expected_version_number_race_returns_conflict_without_sql_details(self):
        self.authenticate()
        before = self.snapshot()
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            with patch(
                "api.v1.training_management_views.services.create_draft_version",
                side_effect=IntegrityError(1062, "Duplicate entry for key 'training_trainingversion.unique_training_version'"),
            ) as save:
                response = self.client.post(self.versions_url(), {"title": "Racing draft"}, format="json")
            save.assert_called_once()
            self.assertEqual(response.status_code, 409, response.data)
            self.assertEqual(set(response.data), {"error"})
            self.assertEqual(response.data["error"]["code"], "conflict")
            self.assertIn("Refresh", response.data["error"]["message"])
            self.assertNotIn("unique_training_version", str(response.data))
            self.assertNotIn("1062", str(response.data))
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    def test_unrelated_version_integrity_errors_are_not_misreported_as_number_conflicts(self):
        self.authenticate()
        before = self.snapshot()
        for failure in (
            IntegrityError(1062, "Duplicate entry for key unrelated_constraint"),
            IntegrityError(1048, "Failure involving unique_training_version"),
            IntegrityError(1062, "Duplicate entry for key 'unique_training_version_extra'"),
            IntegrityError(1062, "Duplicate entry for key 'other_table.unique_training_version'"),
            IntegrityError(1062, "Duplicate entry 'unique_training_version' for key 'training_training.code'"),
        ):
            with self.subTest(error=failure.args), self.captureOnCommitCallbacks(execute=True) as callbacks:
                with patch(
                    "api.v1.training_management_views.services.create_draft_version", side_effect=failure,
                ) as save:
                    with self.assertRaises(IntegrityError) as raised:
                        self.client.post(self.versions_url(), {"title": "Must not save"}, format="json")
                self.assertIs(raised.exception, failure)
                save.assert_called_once()
            self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    @skipUnless(connection.vendor == "mysql", "Verifies the MySQL index contract.")
    def test_version_number_constraint_matches_the_real_mysql_unique_index(self):
        self.assertEqual(connection.settings_dict["NAME"], "test_gardens_training")
        constraints = [
            constraint for constraint in TrainingVersion._meta.constraints
            if constraint.name == VERSION_NUMBER_CONSTRAINT
        ]
        self.assertEqual(len(constraints), 1)
        self.assertEqual(constraints[0].fields, ("training", "version_number"))
        self.assertEqual(TrainingVersion._meta.unique_together, ())
        with connection.cursor() as cursor:
            cursor.execute("SELECT DATABASE()")
            self.assertEqual(cursor.fetchone()[0], "test_gardens_training")
            indexes = connection.introspection.get_constraints(cursor, TrainingVersion._meta.db_table)
        self.assertIn(VERSION_NUMBER_CONSTRAINT, indexes)
        index = indexes[VERSION_NUMBER_CONSTRAINT]
        self.assertTrue(index["unique"])
        self.assertFalse(index["primary_key"])
        self.assertEqual(index["columns"], ["training_id", "version_number"])

    def insert_duplicate_fixture_row(self, instance):
        # Intentionally reach the database constraint rather than Model.full_clean.
        # Only copy an existing isolated fixture, excluding its primary key; the
        # INSERT must fail and the service's atomic block must roll it back.
        self.assertEqual(connection.vendor, "mysql")
        self.assertEqual(connection.settings_dict["NAME"], "test_gardens_training")
        quote = connection.ops.quote_name
        columns = ", ".join(
            quote(field.column) for field in instance._meta.concrete_fields if not field.primary_key
        )
        table = quote(instance._meta.db_table)
        with connection.cursor() as cursor:
            cursor.execute("SELECT DATABASE()")
            self.assertEqual(cursor.fetchone()[0], "test_gardens_training")
            cursor.execute(
                f"INSERT INTO {table} ({columns}) SELECT {columns} FROM {table} WHERE {quote('id')} = %s",
                [instance.pk],
            )
        self.fail("Expected a real database uniqueness violation")

    @skipUnless(connection.vendor == "mysql", "Exercises an actual MySQL duplicate-key exception.")
    def test_real_version_unique_violation_returns_409_and_rolls_back(self):
        self.authenticate()
        before = self.snapshot()
        errors = []

        def collide(*args, **kwargs):
            self.assertTrue(connection.in_atomic_block)
            try:
                self.insert_duplicate_fixture_row(self.version)
            except IntegrityError as exc:
                errors.append(exc)
                raise

        # Keep the real endpoint, parent-row lock, allocator and atomic service.
        # Inject only the failing SQL at the save boundary; never invent its text.
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            with patch("api.v1.training_management_services._save_form", side_effect=collide) as save:
                response = self.client.post(self.versions_url(), {"title": "Racing draft"}, format="json")
            save.assert_called_once()
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0].args[0], 1062)
        self.assertEqual(response.status_code, 409, response.data)
        self.assertEqual(response.data["error"]["code"], "conflict")
        self.assertNotIn(VERSION_NUMBER_CONSTRAINT, str(response.data))
        self.assertNotIn("1062", str(response.data))
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    @skipUnless(connection.vendor == "mysql", "Exercises an actual unrelated MySQL duplicate key.")
    def test_real_unrelated_duplicate_value_is_not_a_version_conflict(self):
        self.authenticate()
        other = Training.objects.create(
            code=VERSION_NUMBER_CONSTRAINT, catalog_title="Unrelated code conflict", created_by=self.user,
        )
        before = self.snapshot()
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            with patch(
                "api.v1.training_management_services._save_form",
                side_effect=lambda *args, **kwargs: self.insert_duplicate_fixture_row(other),
            ) as save:
                with self.assertRaises(IntegrityError) as raised:
                    self.client.post(self.versions_url(), {"title": "Must not save"}, format="json")
            save.assert_called_once()
        self.assertEqual(raised.exception.args[0], 1062)
        self.assertIn(VERSION_NUMBER_CONSTRAINT, raised.exception.args[1])
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    def test_save_time_validation_preserves_field_and_nonfield_errors(self):
        self.authenticate()
        before = self.snapshot()
        cases = (
            ("post", self.catalog_url, "create_training", {"code": "VALID", "catalog_title": "Valid"}, "code"),
            ("patch", self.training_url(), "update_training", {"catalog_title": "Valid"}, "catalog_title"),
            ("post", self.versions_url(), "create_draft_version", {"title": "Valid"}, "title"),
        )
        for method, url, service, payload, field in cases:
            errors = ValidationError({field: ["Field validation failed."], "__all__": ["State validation failed."]})
            with self.subTest(method=method, service=service), self.captureOnCommitCallbacks(execute=True):
                with patch(f"api.v1.training_management_views.services.{service}", side_effect=errors):
                    response = getattr(self.client, method)(url, payload, format="json")
                self.assert_validation(response, field)
                self.assertEqual(response.data["error"]["fields"], {
                    field: ["Field validation failed."], "non_field_errors": ["State validation failed."],
                })
                with patch(
                    f"api.v1.training_management_views.services.{service}",
                    side_effect=ValidationError("State validation failed."),
                ):
                    response = getattr(self.client, method)(url, payload, format="json")
                self.assert_validation(response, "non_field_errors")
                self.assertEqual(response.data["error"]["fields"], {
                    "non_field_errors": ["State validation failed."],
                })
        self.assertEqual(self.snapshot(), before)

    def test_discovery_version_only_reader_gets_minimal_openable_summaries(self):
        self.new_version()
        self.authenticate(self.permission_user("discovery-reader", "view_trainingversion"))
        before = self.snapshot()
        response = self.client.get(self.discovery_url)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(set(response.data), {"count", "next", "previous", "results"})
        self.assertEqual(response.data["count"], 2)
        for row in response.data["results"]:
            self.assertEqual(set(row), {
                "id", "training_id", "training_title", "version_number", "title", "status",
            })
            self.assertEqual(row["training_id"], self.training.pk)
            self.assertEqual(row["training_title"], self.training.catalog_title)
            detail = self.client.get(f"/api/v1/management/versions/{row['id']}/")
            self.assertEqual(detail.status_code, 200)
            self.assertEqual(detail.data["id"], row["id"])
        self.assertEqual(self.client.get(self.catalog_url).status_code, 403)
        self.assertEqual(self.snapshot(), before)
        for method in ("post", "put", "patch", "delete"):
            self.assertEqual(getattr(self.client, method)(self.discovery_url).status_code, 405)

    def test_discovery_lifecycle_matches_detail_including_inactive_courses(self):
        draft = self.new_version()
        self.authenticate()
        response = self.client.get(self.discovery_url)
        self.assertEqual([row["status"] for row in response.data["results"]], ["DRAFT", "PUBLISHED"])
        self.version.status = "RETIRED"
        self.version.save()
        self.training.is_active = False
        self.training.save()
        response = self.client.get(self.discovery_url)
        self.assertEqual([row["id"] for row in response.data["results"]], [draft.pk, self.version.pk])
        self.assertEqual([row["status"] for row in response.data["results"]], ["DRAFT", "RETIRED"])

    def test_discovery_search_is_bounded_and_uses_only_identification_fields(self):
        draft = self.new_version()
        draft.title = "Distinct version"
        draft.description = "private-description-marker"
        draft.save()
        self.authenticate()
        for search, expected in (("  distinct  ", [draft.pk]),
                                 (self.training.code.lower(), [draft.pk, self.version.pk]),
                                 (self.training.catalog_title, [draft.pk, self.version.pk]),
                                 ("private-description-marker", []), ("no-such-course", [])):
            with self.subTest(search=search):
                response = self.client.get(self.discovery_url, {"search": search})
                self.assertEqual(response.status_code, 200)
                self.assertEqual([row["id"] for row in response.data["results"]], expected)
        for key, value in (("search", "x" * 151), ("page", 0), ("page", "bad"),
                           ("page_size", 0), ("page_size", 101), ("page_size", "bad")):
            self.assert_validation(self.client.get(self.discovery_url, {key: value}), key)
        self.assertEqual(self.client.get(self.discovery_url, {"page": 999}).status_code, 404)

    def test_discovery_pagination_order_defaults_and_query_count(self):
        self.authenticate()
        other = Training.objects.create(
            code="OTHER", catalog_title=self.training.catalog_title, created_by=self.user,
        )
        for number in range(1, 22):
            TrainingVersion.objects.create(
                training=other, version_number=number, title=f"Other {number}", created_by=self.user,
            )
        expected = list(TrainingVersion.objects.order_by(
            "training__catalog_title", "training_id", "-version_number", "pk",
        ).values_list("pk", flat=True))
        response = self.client.get(self.discovery_url)
        self.assertEqual(len(response.data["results"]), 20)
        self.assertEqual(response.data["count"], 22)
        self.assertIsNotNone(response.data["next"])
        self.assertIsNone(response.data["previous"])
        second = self.client.get(self.discovery_url, {"page": 2})
        self.assertIsNotNone(second.data["previous"])
        self.assertIsNone(second.data["next"])
        actual = [row["id"] for row in response.data["results"] + second.data["results"]]
        self.assertEqual(actual, expected)
        self.assertEqual(len(set(actual)), 22)
        with CaptureQueriesContext(connection) as small:
            self.client.get(self.discovery_url, {"page_size": 1})
        with CaptureQueriesContext(connection) as large:
            maximum = self.client.get(self.discovery_url, {"page_size": 100})
        self.assertEqual(len(maximum.data["results"]), 22)
        self.assertEqual(len(small), len(large))
