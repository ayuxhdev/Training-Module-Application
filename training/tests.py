import json
import tempfile
from io import BytesIO
from datetime import timedelta
from decimal import Decimal
from importlib import import_module
from unittest.mock import patch

from django.apps import apps
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import ValidationError
from django.core.files.base import ContentFile
from django.core.files.storage import FileSystemStorage
from django.db import IntegrityError, models, transaction
from django.test import Client, TestCase

from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from organization.models import Employee, JobRole
from .forms import TrainingForm
from .models import Lesson, LessonProgress, Module, RoleTrainingRequirement, Training, TrainingAssignment, TrainingVersion, VideoWatchSession


class CurriculumTests(CurriculumTestCase):
    def test_published_version_content_cannot_be_changed(self):
        for obj, field, value in [(self.version, "title", "Changed"), (self.module, "title", "Changed"),
                                   (self.video_lesson, "video_file", "replacement.mp4"),
                                   (self.quiz, "pass_percentage", Decimal("10.00")),
                                   (self.quiz_item, "points", Decimal("10.00"))]:
            with self.subTest(model=type(obj).__name__):
                setattr(obj, field, value)
                with self.assertRaises(ValidationError):
                    obj.save()

    def test_publication_requires_complete_assessment_structure(self):
        version = self.new_version()
        version.status = "PUBLISHED"
        version.published_at = self.now
        version.published_by = self.user
        with self.assertRaises(ValidationError):
            version.save()

    def test_published_children_cannot_be_added_or_deleted(self):
        with self.assertRaises(ValidationError):
            Module.objects.create(training_version=self.version, title="Extra", position=2)
        with self.assertRaises(ValidationError):
            self.text_lesson.delete()
        with self.assertRaises(ValidationError):
            self.version.delete()

    def test_new_version_preserves_old_assignment(self):
        version = self.new_version()
        version.title = "Revised safety"
        version.save()
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.training_version_id, self.version.pk)
        self.assertNotEqual(version.pk, self.version.pk)

    def test_retired_version_cannot_revert_to_draft(self):
        self.version.status = "RETIRED"
        self.version.save()
        self.version.status = "DRAFT"
        with self.assertRaises(ValidationError):
            self.version.save()

    def test_bulk_writes_cannot_bypass_publication_guards(self):
        with self.assertRaises(ValidationError):
            Lesson.objects.filter(pk=self.text_lesson.pk).update(body="Changed")
        with self.assertRaises(ValidationError):
            Lesson.objects.bulk_update([self.text_lesson], ["body"])


class ContentPermissionTests(TestCase):
    def test_only_content_roles_receive_management_permissions(self):
        coordinator = Group.objects.get(name="Training Coordinator")
        self.assertTrue(coordinator.permissions.filter(codename="change_training").exists())
        self.assertTrue(coordinator.permissions.filter(codename="change_lesson").exists())
        for name in ("Manager", "Trainer", "Supervisor", "Employee"):
            with self.subTest(group=name):
                self.assertFalse(Group.objects.get(name=name).permissions.filter(
                    content_type__app_label="training"
                ).exists())

    def test_permission_migration_preserves_existing_grants_and_memberships(self):
        migration = import_module("accounts.migrations.0002_training_content_permissions")
        unrelated = Permission.objects.get(content_type__app_label="auth", codename="view_group")
        for name in ("Administrator", "Training Coordinator"):
            group = Group.objects.get(name=name)
            member = get_user_model().objects.create_user(username=f"existing-{name}")
            group.permissions.add(unrelated)
            group.user_set.add(member)
        migration.grant_content_permissions(apps, None)
        migration.grant_content_permissions(apps, None)
        for name in ("Administrator", "Training Coordinator"):
            group = Group.objects.get(name=name)
            self.assertTrue(group.permissions.filter(pk=unrelated.pk).exists())
            self.assertTrue(group.user_set.filter(username=f"existing-{name}").exists())
            for model in migration.CONTENT_MODELS:
                for action in migration.CONTENT_ACTIONS:
                    self.assertTrue(group.permissions.filter(
                        content_type__app_label="training", codename=f"{action}_{model}"
                    ).exists())
            self.assertEqual(Group.objects.filter(name=name).count(), 1)
        for name in ("Manager", "Trainer", "Supervisor", "Employee"):
            self.assertFalse(Group.objects.get(name=name).permissions.filter(
                content_type__app_label="training",
            ).exists())

    def test_permission_migration_reverse_preserves_groups_grants_and_memberships(self):
        migration = import_module("accounts.migrations.0002_training_content_permissions")
        group = Group.objects.get(name="Training Coordinator")
        member = get_user_model().objects.create_user(username="content-member")
        unrelated = Permission.objects.get(content_type__app_label="auth", codename="view_group")
        group.permissions.add(unrelated)
        group.user_set.add(member)
        migration.Migration.operations[0].reverse_code(apps, None)
        self.assertTrue(Group.objects.filter(pk=group.pk).exists())
        self.assertTrue(group.user_set.filter(pk=member.pk).exists())
        self.assertTrue(group.permissions.filter(pk=unrelated.pk).exists())
        self.assertTrue(group.permissions.filter(codename="change_lesson").exists())


class ContentManagementViewTests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.coordinator = get_user_model().objects.create_user(username="content-coordinator", password="password")
        Group.objects.get(name="Training Coordinator").user_set.add(cls.coordinator)
        cls.manager = get_user_model().objects.create_user(username="content-manager", password="password")
        Group.objects.get(name="Manager").user_set.add(cls.manager)

    def client_for(self, user):
        client = Client()
        self.assertTrue(client.login(username=user.username, password="password"))
        return client

    def test_non_content_role_is_denied_by_backend(self):
        response = self.client_for(self.manager).get("/trainings/")
        self.assertEqual(response.status_code, 403)

    def test_training_and_version_pages_link_through_the_existing_hierarchy(self):
        client = self.client_for(self.coordinator)
        training_list = client.get("/trainings/")
        self.assertEqual(training_list.status_code, 200)
        self.assertContains(training_list, "Safety")
        self.assertContains(training_list, f"/trainings/{self.training.pk}/edit/")
        self.assertContains(training_list, "/trainings/new/")

        training_detail = client.get(f"/trainings/{self.training.pk}/")
        self.assertEqual(training_detail.status_code, 200)
        self.assertContains(training_detail, f"/trainings/{self.training.pk}/versions/")
        self.assertContains(training_detail, f"/trainings/{self.training.pk}/versions/new/")
        self.assertContains(training_detail, f"/versions/{self.version.pk}/")
        self.assertContains(training_detail, "Published")

        version_list = client.get(f"/trainings/{self.training.pk}/versions/")
        self.assertEqual(version_list.status_code, 200)
        self.assertContains(version_list, f"/versions/{self.version.pk}/")
        self.assertEqual(client.get(f"/versions/{self.version.pk}/").status_code, 200)

    def test_draft_builder_shows_empty_states_and_trusted_parent_breadcrumbs(self):
        client = self.client_for(self.coordinator)
        version = self.new_version()
        version_detail = client.get(f"/versions/{version.pk}/")
        self.assertContains(version_detail, "No modules in this version yet.")
        self.assertContains(version_detail, f"/versions/{version.pk}/modules/new/")

        module_form = client.get(f"/versions/{version.pk}/modules/new/")
        self.assertEqual(module_form.status_code, 200)
        self.assertContains(module_form, self.training.catalog_title)
        self.assertContains(module_form, f"Version {version.version_number}")
        self.assertNotContains(module_form, 'name="training_version"')

        module_response = client.post(f"/versions/{version.pk}/modules/new/", {
            "title": "Builder module", "description": "Module description", "position": 1,
        })
        self.assertEqual(module_response.status_code, 302)
        module = Module.objects.get(training_version=version)
        version_detail = client.get(f"/versions/{version.pk}/")
        self.assertContains(version_detail, "No lessons in this module yet.")
        self.assertContains(version_detail, f"/modules/{module.pk}/edit/")
        self.assertContains(version_detail, f"/modules/{module.pk}/lessons/new/")

        lesson_form = client.get(f"/modules/{module.pk}/lessons/new/")
        self.assertEqual(lesson_form.status_code, 200)
        self.assertContains(lesson_form, "Builder module")
        self.assertContains(lesson_form, f"Version {version.version_number}")
        self.assertNotContains(lesson_form, 'name="module"')

        lesson_response = client.post(f"/modules/{module.pk}/lessons/new/", {
            "title": "Builder lesson", "position": 1, "content_type": "TEXT",
            "body": "Lesson body", "minimum_watch_percent": "90",
        })
        self.assertEqual(lesson_response.status_code, 302)
        version_detail = client.get(f"/versions/{version.pk}/")
        self.assertContains(version_detail, "Builder lesson")
        self.assertContains(version_detail, "Lesson body")
        self.assertContains(version_detail, f"/lessons/{Lesson.objects.get(module=module).pk}/edit/")

    def test_builder_order_is_rendered_once_and_position_inputs_advertise_minimum(self):
        client = self.client_for(self.coordinator)
        version_detail = client.get(f"/versions/{self.version.pk}/")
        self.assertContains(version_detail, "Introduction")
        self.assertContains(version_detail, "Read")
        self.assertNotContains(version_detail, "1. Introduction")
        self.assertNotContains(version_detail, "1. Read")

        version = self.new_version()
        module_form = client.get(f"/versions/{version.pk}/modules/new/")
        module_position = str(module_form.context["form"]["position"])
        self.assertIn('min="1"', module_position)
        self.assertIn('step="1"', module_position)

        module = Module.objects.create(training_version=version, title="Ordered module", position=1)
        lesson_form = client.get(f"/modules/{module.pk}/lessons/new/")
        lesson_position = str(lesson_form.context["form"]["position"])
        self.assertIn('min="1"', lesson_position)
        self.assertIn('step="1"', lesson_position)

    def test_version_actions_follow_real_state_and_permission_rules(self):
        client = self.client_for(self.coordinator)
        published_page = client.get(f"/versions/{self.version.pk}/")
        self.assertContains(published_page, "Status: Published")
        self.assertContains(published_page, f"/versions/{self.version.pk}/retire/")
        self.assertNotContains(published_page, "Edit draft")
        self.assertNotContains(published_page, "Publish version")
        self.assertNotContains(published_page, "Add module")
        self.assertNotContains(published_page, "Edit module")
        self.assertNotContains(published_page, "Add lesson")
        self.assertNotContains(published_page, "Edit lesson")

        response = client.get(f"/versions/{self.version.pk}/retire/")
        self.assertEqual(response.status_code, 404)
        self.assertEqual(client.post(f"/versions/{self.version.pk}/retire/").status_code, 302)
        retired_page = client.get(f"/versions/{self.version.pk}/")
        self.assertContains(retired_page, "Status: Retired")
        self.assertNotContains(retired_page, "Retire version")
        self.assertNotContains(retired_page, "Edit draft")
        self.assertNotContains(retired_page, "Add module")

    def test_duplicate_training_code_is_a_controlled_form_error(self):
        response = self.client_for(self.coordinator).post("/trainings/new/", {
            "code": self.training.code,
            "catalog_title": "Duplicate training",
            "description": "",
            "is_active": "on",
        })
        self.assertEqual(response.status_code, 200)
        self.assertIn("code", response.context["form"].errors)
        self.assertFalse(Training.objects.filter(catalog_title="Duplicate training").exists())

    def test_published_version_is_not_in_edit_queryset(self):
        response = self.client_for(self.coordinator).get(f"/versions/{self.version.pk}/edit/")
        self.assertEqual(response.status_code, 404)

    def test_duplicate_version_number_is_a_form_error(self):
        other_training = Training.objects.create(code="OTHER", catalog_title="Other", created_by=self.user)
        response = self.client_for(self.coordinator).post(
            f"/trainings/{self.training.pk}/versions/new/",
            {"version_number": self.version.version_number, "title": "Duplicate version",
             "training": other_training.pk},
        )
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "already has that version number")
        self.assertEqual(response.context["form"]["version_number"].value(), str(self.version.version_number))
        self.assertFalse(TrainingVersion.objects.filter(title="Duplicate version").exists())

    def test_training_create_handles_duplicate_saved_after_form_validation(self):
        save_form = TrainingForm.save

        def save_after_competing_create(form, *args, **kwargs):
            Training.objects.create(code="RACE-TRAINING", catalog_title="Winner", created_by=self.coordinator)
            return save_form(form, *args, **kwargs)

        with patch.object(TrainingForm, "save", save_after_competing_create):
            with self.captureOnCommitCallbacks(execute=True):
                response = self.client_for(self.coordinator).post("/trainings/new/", {
                    "code": "RACE-TRAINING", "catalog_title": "Loser",
                })
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.context["form"].errors)
        self.assertEqual(Training.objects.filter(code="RACE-TRAINING").count(), 1)
        self.assertEqual(Training.objects.get(code="RACE-TRAINING").catalog_title, "Winner")
        self.assertFalse(AuditLog.objects.filter(action="training.training.created").exists())

    def test_version_create_uses_url_training_not_posted_training(self):
        other_training = Training.objects.create(code="OTHER", catalog_title="Other", created_by=self.user)
        response = self.client_for(self.coordinator).post(
            f"/trainings/{self.training.pk}/versions/new/",
            {"version_number": 2, "title": "New version", "training": other_training.pk},
        )
        self.assertEqual(response.status_code, 302)
        self.assertEqual(TrainingVersion.objects.get(title="New version").training_id, self.training.pk)

    def test_module_create_validates_with_draft_parent(self):
        version = self.new_version()
        response = self.client_for(self.coordinator).post(
            f"/versions/{version.pk}/modules/new/",
            {"title": "New module", "position": 1, "training_version": self.version.pk},
        )
        self.assertEqual(response.status_code, 302)
        self.assertEqual(Module.objects.get(title="New module").training_version_id, version.pk)
        self.assertEqual(self.client_for(self.coordinator).post(
            f"/versions/{self.version.pk}/modules/new/", {"title": "Rejected", "position": 3}
        ).status_code, 404)

    def test_duplicate_module_position_on_create_is_a_form_error(self):
        version = self.new_version()
        Module.objects.create(training_version=version, title="Existing module", position=1)
        response = self.client_for(self.coordinator).post(
            f"/versions/{version.pk}/modules/new/",
            {"title": "Duplicate module", "position": 1, "training_version": self.version.pk},
        )
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "already has a module at that position")
        self.assertEqual(response.context["form"]["position"].value(), "1")
        self.assertFalse(Module.objects.filter(title="Duplicate module").exists())

    def test_duplicate_module_position_on_edit_is_a_form_error(self):
        version = self.new_version()
        Module.objects.create(training_version=version, title="First module", position=1)
        module = Module.objects.create(training_version=version, title="Second module", position=2)
        response = self.client_for(self.coordinator).post(
            f"/modules/{module.pk}/edit/",
            {"title": "Changed module", "position": 1, "training_version": self.version.pk},
        )
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "already has a module at that position")
        module.refresh_from_db()
        self.assertEqual((module.title, module.position, module.training_version_id),
                         ("Second module", 2, version.pk))

    def test_lesson_create_validates_with_draft_parent(self):
        version = self.new_version()
        module = Module.objects.create(training_version=version, title="New module", position=1)
        response = self.client_for(self.coordinator).post(
            f"/modules/{module.pk}/lessons/new/",
            {"title": "New lesson", "position": 1, "content_type": "TEXT",
             "body": "Read this", "minimum_watch_percent": "90", "module": self.module.pk},
        )
        self.assertEqual(response.status_code, 302)
        self.assertEqual(Lesson.objects.get(title="New lesson").module_id, module.pk)
        self.assertEqual(self.client_for(self.coordinator).post(
            f"/modules/{self.module.pk}/lessons/new/",
            {"title": "Rejected", "position": 3, "content_type": "TEXT", "body": "Read this"},
        ).status_code, 404)

    def test_duplicate_lesson_position_on_create_is_a_form_error(self):
        version = self.new_version()
        module = Module.objects.create(training_version=version, title="Draft module", position=1)
        Lesson.objects.create(module=module, title="First lesson", position=1,
                              content_type="TEXT", body="First")
        response = self.client_for(self.coordinator).post(
            f"/modules/{module.pk}/lessons/new/",
            {"title": "Duplicate lesson", "position": 1, "content_type": "TEXT",
             "body": "Second", "minimum_watch_percent": "90", "module": self.module.pk},
        )
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "already has a lesson at that position")
        self.assertEqual(response.context["form"]["position"].value(), "1")
        self.assertFalse(Lesson.objects.filter(title="Duplicate lesson").exists())

    def test_duplicate_lesson_position_on_edit_is_a_form_error(self):
        version = self.new_version()
        module = Module.objects.create(training_version=version, title="Draft module", position=1)
        Lesson.objects.create(module=module, title="First lesson", position=1,
                              content_type="TEXT", body="First")
        lesson = Lesson.objects.create(module=module, title="Second lesson", position=2,
                                       content_type="TEXT", body="Second")
        response = self.client_for(self.coordinator).post(
            f"/lessons/{lesson.pk}/edit/",
            {"title": "Changed lesson", "position": 1, "content_type": "TEXT",
             "body": "Changed", "minimum_watch_percent": "90", "module": self.module.pk},
        )
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "already has a lesson at that position")
        lesson.refresh_from_db()
        self.assertEqual((lesson.title, lesson.position, lesson.body, lesson.module_id),
                         ("Second lesson", 2, "Second", module.pk))

    def test_positions_can_repeat_under_different_draft_parents(self):
        first_version = self.new_version()
        second_version = TrainingVersion.objects.create(training=self.training, version_number=3,
                                                        title="Safety v3", created_by=self.user)
        client = self.client_for(self.coordinator)
        for version in (first_version, second_version):
            response = client.post(f"/versions/{version.pk}/modules/new/",
                                   {"title": f"Module {version.pk}", "position": 1})
            self.assertEqual(response.status_code, 302)
            module = Module.objects.get(training_version=version, position=1)
            response = client.post(f"/modules/{module.pk}/lessons/new/", {
                "title": f"Lesson {module.pk}", "position": 1, "content_type": "TEXT",
                "body": "Read this", "minimum_watch_percent": "90",
            })
            self.assertEqual(response.status_code, 302)
            self.assertTrue(Lesson.objects.filter(module=module, position=1).exists())

    def test_draft_module_edit_uses_its_own_version(self):
        version = self.new_version()
        module = Module.objects.create(training_version=version, title="Original module", position=1)
        client = self.client_for(self.coordinator)
        self.assertEqual(client.get(f"/modules/{module.pk}/edit/").status_code, 200)
        response = client.post(f"/modules/{module.pk}/edit/", {
            "title": "Updated module", "position": 1, "training_version": self.version.pk,
        })
        self.assertEqual(response.status_code, 302)
        module.refresh_from_db()
        self.assertEqual(module.title, "Updated module")
        self.assertEqual(module.training_version_id, version.pk)

    def test_draft_lesson_edit_uses_its_own_module_and_version(self):
        version = self.new_version()
        module = Module.objects.create(training_version=version, title="Draft module", position=1)
        lesson = Lesson.objects.create(module=module, title="Original lesson", position=1,
                                       content_type="TEXT", body="Original body")
        client = self.client_for(self.coordinator)
        self.assertEqual(client.get(f"/lessons/{lesson.pk}/edit/").status_code, 200)
        response = client.post(f"/lessons/{lesson.pk}/edit/", {
            "title": "Updated lesson", "position": 1, "content_type": "TEXT",
            "body": "Updated body", "minimum_watch_percent": "90", "module": self.module.pk,
        })
        self.assertEqual(response.status_code, 302)
        lesson.refresh_from_db()
        self.assertEqual(lesson.title, "Updated lesson")
        self.assertEqual(lesson.body, "Updated body")
        self.assertEqual(lesson.module_id, module.pk)

    def test_published_and_retired_content_cannot_be_edited_by_url(self):
        client = self.client_for(self.coordinator)
        for status in ("PUBLISHED", "RETIRED"):
            if status == "RETIRED":
                self.version.status = status
                self.version.save()
            for path, data in (
                (f"/modules/{self.module.pk}/edit/", {"title": "Changed", "position": 1}),
                (f"/lessons/{self.text_lesson.pk}/edit/", {
                    "title": "Changed", "position": 1, "content_type": "TEXT",
                    "body": "Changed", "minimum_watch_percent": "90",
                }),
            ):
                with self.subTest(status=status, path=path):
                    self.assertEqual(client.get(path).status_code, 404)
                    self.assertEqual(client.post(path, data).status_code, 404)
        self.module.refresh_from_db()
        self.text_lesson.refresh_from_db()
        self.assertEqual(self.module.title, "Introduction")
        self.assertEqual(self.text_lesson.body, "Safety instructions")

    def test_failed_publication_renders_persisted_draft_state(self):
        version = self.new_version()
        response = self.client_for(self.coordinator).post(f"/versions/{version.pk}/publish/")
        self.assertEqual(response.status_code, 400)
        self.assertContains(response, "Status: Draft", status_code=400)
        self.assertContains(response, "final assessment", status_code=400)
        self.assertContains(response, "Publish", status_code=400)
        self.assertNotContains(response, "Retire", status_code=400)
        version.refresh_from_db()
        self.assertEqual(version.status, "DRAFT")

    def test_draft_ordering_and_lesson_types_are_managed(self):
        version = self.new_version()
        second = Module.objects.create(training_version=version, title="Second", position=2)
        first = Module.objects.create(training_version=version, title="First", position=1)
        Lesson.objects.create(module=second, title="Text", position=1, content_type="TEXT", body="Read this")
        Lesson.objects.create(module=first, title="Video", position=1, content_type="VIDEO",
                              video_file="training/videos/lesson.mp4", video_duration_seconds=30,
                              video_checksum="a" * 64)
        self.assertEqual(list(version.modules.values_list("title", flat=True)), ["First", "Second"])
        self.assertEqual(list(first.lessons.values_list("title", flat=True)), ["Video"])
        self.assertEqual(list(second.lessons.values_list("title", flat=True)), ["Text"])

    def test_invalid_lesson_content_is_rejected(self):
        version = self.new_version()
        module = Module.objects.create(training_version=version, title="Module", position=1)
        with self.assertRaises(ValidationError):
            Lesson.objects.create(module=module, title="Empty text", position=1, content_type="TEXT")
        with self.assertRaises(ValidationError):
            Lesson.objects.create(module=module, title="Incomplete video", position=2, content_type="VIDEO",
                                  video_duration_seconds=30, video_checksum="a" * 64)


class AssignmentTests(CurriculumTestCase):
    def duplicate(self, **overrides):
        values = dict(employee=self.employee, training_version=self.version, department_at_assignment=self.department,
                      job_role_at_assignment=self.role, assigned_by=self.user)
        values.update(overrides)
        return TrainingAssignment(**values)

    def test_database_rejects_duplicate_assignment_even_without_model_validation(self):
        with self.assertRaises(IntegrityError), transaction.atomic():
            models.Model.save(self.duplicate(), force_insert=True)

    def test_role_and_manual_sources_cannot_duplicate_assignment(self):
        rule = RoleTrainingRequirement.objects.create(job_role=self.role, training_version=self.version, created_by=self.user)
        with self.assertRaises(ValidationError):
            self.duplicate(source="ROLE", role_requirement=rule).save()

    def test_role_requirements_are_unique_and_version_bound(self):
        rule = RoleTrainingRequirement.objects.create(job_role=self.role, training_version=self.version, created_by=self.user)
        with self.assertRaises(ValidationError):
            RoleTrainingRequirement.objects.create(job_role=self.role, training_version=self.version, created_by=self.user)
        rule.training_version = self.new_version()
        with self.assertRaises(ValidationError):
            rule.save()

    def test_cancelled_assignment_cannot_be_duplicated(self):
        self.assignment.status = "CANCELLED"
        self.assignment.cancelled_at = self.now + timedelta(seconds=1)
        self.assignment.cancellation_reason = "Role changed"
        self.assignment.save()
        with self.assertRaises(ValidationError):
            self.duplicate().save()

    def test_assignment_cannot_change_employee_or_version(self):
        self.assignment.training_version = self.new_version()
        with self.assertRaises(ValidationError):
            self.assignment.save()

    def test_premature_completion_rejected(self):
        self.assignment.status = "COMPLETED"
        self.assignment.completed_at = self.now + timedelta(seconds=1)
        with self.assertRaises(ValidationError):
            self.assignment.save()

    def test_inactive_employee_cannot_reopen_assignment(self):
        self.assignment.status = "CANCELLED"
        self.assignment.cancelled_at = self.now
        self.assignment.cancellation_reason = "Left"
        self.assignment.save()
        self.employee.is_active = False
        self.employee.deactivation_reason = "Left"
        self.employee.save()
        self.assignment.status = "IN_PROGRESS"
        self.assignment.cancelled_at = None
        with self.assertRaises(ValidationError):
            self.assignment.save()


class AssignmentViewTests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.admin = get_user_model().objects.create_user(username="assignment-admin", password="password")
        cls.coordinator = get_user_model().objects.create_user(username="assignment-coordinator", password="password")
        cls.manager_user = get_user_model().objects.create_user(username="assignment-manager", password="password")
        cls.other_user = get_user_model().objects.create_user(username="assignment-other", password="password")
        cls.employee_user.set_password("password")
        cls.employee_user.save(update_fields=["password"])
        Group.objects.get(name="Administrator").user_set.add(cls.admin)
        Group.objects.get(name="Training Coordinator").user_set.add(cls.coordinator)
        Group.objects.get(name="Manager").user_set.add(cls.manager_user)
        Group.objects.get(name="Employee").user_set.add(cls.employee_user)
        cls.manager = Employee.objects.create(employee_code="GN-010", display_name="Manager",
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(), user=cls.manager_user)
        cls.report = Employee.objects.create(employee_code="GN-011", display_name="Report",
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(), reporting_manager=cls.manager)
        cls.other = Employee.objects.create(employee_code="GN-012", display_name="Other",
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(), user=cls.other_user)
        cls.employee.reporting_manager = cls.manager
        cls.employee.save()

    def client_for(self, user):
        client = Client()
        self.assertTrue(client.login(username=user.username, password="password"))
        return client

    def test_administrator_and_coordinator_can_create_manual_assignments(self):
        for user, code in ((self.admin, "GN-ADMIN"), (self.coordinator, "GN-COORD")):
            employee = Employee.objects.create(employee_code=code, display_name=code,
                department=self.department, job_role=self.role, date_joined=self.now.date())
            response = self.client_for(user).post("/assignments/new/", {
                "employee": employee.pk, "training_version": self.version.pk, "due_date": "2026-12-31",
            })
            self.assertEqual(response.status_code, 302)
            assignment = TrainingAssignment.objects.get(employee=employee, training_version=self.version)
            self.assertEqual(assignment.source, TrainingAssignment.Source.MANUAL)
            self.assertEqual(assignment.department_at_assignment_id, self.department.pk)
            self.assertEqual(assignment.job_role_at_assignment_id, self.role.pk)

    def test_role_requirement_management_uses_existing_assignment_permission(self):
        for user in (self.admin, self.coordinator):
            client = self.client_for(user)
            self.assertContains(client.get("/assignments/"), "Manage job-role requirements")
            self.assertEqual(client.get("/assignments/requirements/").status_code, 200)
            self.assertContains(client.get("/assignments/requirements/new/"), 'class="form-stack"')
        for user in (self.manager_user, self.employee_user):
            client = self.client_for(user)
            self.assertNotContains(client.get("/assignments/"), "Manage job-role requirements")
            self.assertEqual(client.get("/assignments/requirements/").status_code, 403)
            self.assertEqual(client.get("/assignments/requirements/new/").status_code, 403)
            self.assertEqual(client.post("/assignments/requirements/new/", {
                "job_role": self.role.pk, "training_version": self.version.pk,
                "due_in_days": 14, "is_active": "on",
            }).status_code, 403)
        self.assertFalse(RoleTrainingRequirement.objects.exists())
        requirement = RoleTrainingRequirement.objects.create(
            job_role=self.role, training_version=self.version, created_by=self.admin,
        )
        manager = self.client_for(self.manager_user)
        self.assertEqual(manager.get(f"/assignments/requirements/{requirement.pk}/edit/").status_code, 403)
        self.assertEqual(manager.post(f"/assignments/requirements/{requirement.pk}/edit/", {
            "due_in_days": 1, "is_active": "on",
        }).status_code, 403)
        requirement.refresh_from_db()
        self.assertEqual(requirement.due_in_days, 30)

    def test_role_requirement_create_edit_and_duplicate_are_controlled(self):
        client = self.client_for(self.admin)
        create_url = "/assignments/requirements/new/"
        payload = {
            "job_role": self.role.pk, "training_version": self.version.pk,
            "due_in_days": 14, "is_active": "on", "created_by": self.manager_user.pk,
        }
        self.assertEqual(client.post(create_url, payload).status_code, 302)
        requirement = RoleTrainingRequirement.objects.get(job_role=self.role, training_version=self.version)
        self.assertEqual(requirement.created_by_id, self.admin.pk)
        self.assertContains(client.get("/assignments/requirements/"), self.training.catalog_title)
        self.assertContains(client.get("/assignments/role/new/"), "due in 14 days")
        duplicate = client.post(create_url, payload)
        self.assertEqual(duplicate.status_code, 200)
        self.assertTrue(duplicate.context["form"].errors)
        self.assertEqual(RoleTrainingRequirement.objects.count(), 1)

        other_role = JobRole.objects.create(code="OTHER-REQ", name="Other role")
        other_version = self.new_version()
        edit_url = f"/assignments/requirements/{requirement.pk}/edit/"
        update = client.post(edit_url, {
            "job_role": other_role.pk, "training_version": other_version.pk,
            "due_in_days": 7, "is_active": "on", "created_by": self.manager_user.pk,
        })
        self.assertEqual(update.status_code, 302)
        requirement.refresh_from_db()
        self.assertEqual((requirement.job_role_id, requirement.training_version_id, requirement.created_by_id),
                         (self.role.pk, self.version.pk, self.admin.pk))
        self.assertEqual(requirement.due_in_days, 7)
        self.assertEqual(client.post("/assignments/role/new/", {"role_requirement": requirement.pk}).status_code, 302)
        historical_ids = set(TrainingAssignment.objects.filter(role_requirement=requirement).values_list("pk", flat=True))
        self.assertTrue(historical_ids)
        self.assertEqual(client.post(edit_url, {"due_in_days": 7}).status_code, 302)
        requirement.refresh_from_db()
        self.assertFalse(requirement.is_active)
        self.assertEqual(set(TrainingAssignment.objects.filter(role_requirement=requirement).values_list("pk", flat=True)), historical_ids)
        self.assertNotContains(client.get("/assignments/role/new/"), f'value="{requirement.pk}"')
        self.assertContains(client.get("/assignments/requirements/"), "Inactive")

    def test_role_requirement_choices_and_csrf_reject_ineligible_posts(self):
        draft = self.new_version()
        inactive_role = JobRole.objects.create(code="INACTIVE-REQ", name="Inactive role", is_active=False)
        client = self.client_for(self.admin)
        form = client.get("/assignments/requirements/new/").context["form"]
        self.assertIn(self.role, form.fields["job_role"].queryset)
        self.assertNotIn(inactive_role, form.fields["job_role"].queryset)
        self.assertIn(self.version, form.fields["training_version"].queryset)
        self.assertNotIn(draft, form.fields["training_version"].queryset)
        for role_id, version_id in ((inactive_role.pk, self.version.pk), (self.role.pk, draft.pk)):
            response = client.post("/assignments/requirements/new/", {
                "job_role": role_id, "training_version": version_id,
                "due_in_days": 14, "is_active": "on",
            })
            self.assertEqual(response.status_code, 200)
            self.assertTrue(response.context["form"].errors)
        self.assertFalse(RoleTrainingRequirement.objects.exists())

        csrf_client = Client(enforce_csrf_checks=True)
        csrf_client.force_login(self.admin)
        self.assertEqual(csrf_client.post("/assignments/requirements/new/", {
            "job_role": self.role.pk, "training_version": self.version.pk,
            "due_in_days": 14, "is_active": "on",
        }).status_code, 403)
        self.assertFalse(RoleTrainingRequirement.objects.exists())

    def test_employee_and_manager_assignment_scopes_are_enforced(self):
        employee_client = self.client_for(self.employee_user)
        response = employee_client.get("/assignments/")
        self.assertContains(response, str(self.employee))
        self.assertNotContains(response, str(self.report))
        self.assertEqual(employee_client.get(f"/assignments/{self.report.pk}/").status_code, 404)

        manager_client = self.client_for(self.manager_user)
        self.assertContains(manager_client.get("/assignments/"), str(self.employee))
        outside = TrainingAssignment.objects.create(employee=self.other, training_version=self.version,
            department_at_assignment=self.other.department, job_role_at_assignment=self.other.job_role,
            assigned_by=self.coordinator)
        self.assertEqual(manager_client.get(f"/assignments/{outside.pk}/").status_code, 404)

    def test_administrator_assignment_pages_show_relationships_and_real_actions(self):
        client = self.client_for(self.admin)
        response = client.get("/assignments/")
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, self.training.catalog_title)
        self.assertContains(response, self.version.title)
        self.assertContains(response, self.employee.display_name)
        self.assertContains(response, f'/assignments/{self.assignment.pk}/')
        self.assertContains(response, 'href="/assignments/new/"')
        self.assertContains(response, 'href="/assignments/role/new/"')
        detail = client.get(f"/assignments/{self.assignment.pk}/")
        self.assertEqual(detail.status_code, 200)
        self.assertContains(detail, "Department at assignment")
        self.assertContains(detail, 'href="/versions/')
        self.assertEqual(client.get("/assignments/new/").status_code, 200)
        role_form = client.get("/assignments/role/new/")
        self.assertEqual(role_form.status_code, 200)
        self.assertContains(role_form, "No active job-role requirements are available.")
        self.assertNotContains(role_form, "<button type=\"submit\">Create missing assignments</button>")

    def test_manager_and_employee_assignment_pages_keep_scope_and_hide_management(self):
        report_assignment = TrainingAssignment.objects.create(
            employee=self.report, training_version=self.version,
            department_at_assignment=self.department, job_role_at_assignment=self.role,
            assigned_by=self.coordinator,
        )
        outside = TrainingAssignment.objects.create(
            employee=self.other, training_version=self.version,
            department_at_assignment=self.department, job_role_at_assignment=self.role,
            assigned_by=self.coordinator,
        )
        manager = self.client_for(self.manager_user)
        manager_list = manager.get("/assignments/")
        self.assertEqual(manager_list.status_code, 200)
        self.assertContains(manager_list, "Team assignments")
        self.assertIn(report_assignment, manager_list.context["assignments"])
        self.assertNotIn(outside, manager_list.context["assignments"])
        self.assertNotContains(manager_list, 'href="/assignments/new/"')
        self.assertEqual(manager.get(f"/assignments/{report_assignment.pk}/").status_code, 200)
        self.assertEqual(manager.get(f"/assignments/{outside.pk}/").status_code, 404)
        self.assertEqual(manager.get("/assignments/new/").status_code, 403)
        self.assertEqual(manager.get("/assignments/role/new/").status_code, 403)

        employee = self.client_for(self.employee_user)
        employee_list = employee.get("/assignments/")
        self.assertEqual(employee_list.status_code, 200)
        self.assertContains(employee_list, "My assignments")
        self.assertEqual(list(employee_list.context["assignments"]), [self.assignment])
        self.assertNotContains(employee_list, 'href="/assignments/new/"')
        self.assertNotContains(employee_list, 'href="/assignments/role/new/"')
        self.assertEqual(employee.get(f"/assignments/{outside.pk}/").status_code, 404)
        self.assertEqual(employee.get("/assignments/new/").status_code, 403)

    def test_assignment_empty_state_and_server_derived_overdue_status(self):
        Group.objects.get(name="Employee").user_set.add(self.other_user)
        empty = self.client_for(self.other_user).get("/assignments/")
        self.assertEqual(empty.status_code, 200)
        self.assertContains(empty, "You have no training assignments yet.")

        self.assignment.due_at = self.now + timedelta(minutes=1)
        self.assignment.save()
        client = self.client_for(self.employee_user)
        self.assertContains(client.get("/assignments/"), "Overdue")
        self.assertContains(client.get(f"/assignments/{self.assignment.pk}/"), "Overdue")
        self.complete_assignment()
        self.assertNotContains(client.get(f"/assignments/{self.assignment.pk}/"), "Overdue")
        self.assertContains(client.get(f"/assignments/{self.assignment.pk}/"), "Completed")

    def test_assignment_forms_label_choices_and_render_validation_errors(self):
        client = self.client_for(self.admin)
        manual = client.get("/assignments/new/")
        self.assertContains(manual, "Select an employee")
        self.assertContains(manual, "Select a training version")
        self.assertContains(manual, self.training.catalog_title)
        self.assertContains(manual, "Due at the end of the selected day")

        requirement = RoleTrainingRequirement.objects.create(
            job_role=self.role, training_version=self.version,
            created_by=self.admin, due_in_days=14,
        )
        role_form = client.get("/assignments/role/new/")
        self.assertContains(role_form, "Select a job-role requirement")
        self.assertContains(role_form, self.role.name)
        self.assertContains(role_form, self.training.catalog_title)
        self.assertContains(role_form, "due in 14 days")
        self.assertContains(role_form, f'value="{requirement.pk}"')
        empty_role = client.post("/assignments/role/new/", {"role_requirement": ""})
        self.assertEqual(empty_role.status_code, 200)
        self.assertContains(empty_role, "This field is required")

        duplicate = client.post("/assignments/new/", {
            "employee": self.employee.pk, "training_version": self.version.pk, "due_date": "",
        })
        self.assertEqual(duplicate.status_code, 200)
        self.assertContains(duplicate, "already has an assignment")
        past_due = client.post("/assignments/new/", {
            "employee": self.other.pk, "training_version": self.version.pk, "due_date": "2000-01-01",
        })
        self.assertEqual(past_due.status_code, 200)
        self.assertContains(past_due, "due date cannot be in the past")
        self.assertFalse(TrainingAssignment.objects.filter(employee=self.other).exists())

    def test_manual_assignment_choices_exclude_inactive_employees_and_unpublished_versions(self):
        inactive = Employee.objects.create(
            employee_code="GN-INELIGIBLE", display_name="Inactive choice",
            department=self.department, job_role=self.role, date_joined=self.now.date(),
        )
        inactive.is_active = False
        inactive.deactivation_reason = "No longer employed"
        inactive.save()
        draft = self.new_version()
        client = self.client_for(self.admin)

        response = client.get("/assignments/new/")
        self.assertEqual(response.status_code, 200)
        employee_choices = response.context["form"].fields["employee"].queryset
        version_choices = response.context["form"].fields["training_version"].queryset
        self.assertIn(self.other, employee_choices)
        self.assertNotIn(inactive, employee_choices)
        self.assertIn(self.version, version_choices)
        self.assertNotIn(draft, version_choices)
        self.assertNotContains(response, str(inactive))
        self.assertNotContains(response, draft.title)

        inactive_post = client.post("/assignments/new/", {
            "employee": inactive.pk, "training_version": self.version.pk, "due_date": "",
        })
        self.assertEqual(inactive_post.status_code, 200)
        self.assertIn("employee", inactive_post.context["form"].errors)
        self.assertFalse(TrainingAssignment.objects.filter(employee=inactive).exists())
        draft_post = client.post("/assignments/new/", {
            "employee": self.other.pk, "training_version": draft.pk, "due_date": "",
        })
        self.assertEqual(draft_post.status_code, 200)
        self.assertIn("training_version", draft_post.context["form"].errors)
        self.assertFalse(TrainingAssignment.objects.filter(employee=self.other, training_version=draft).exists())

    def test_duplicate_and_inactive_manual_submissions_are_form_errors(self):
        client = self.client_for(self.coordinator)
        duplicate = client.post("/assignments/new/", {
            "employee": self.employee.pk, "training_version": self.version.pk, "due_date": "2026-12-31",
        })
        self.assertEqual(duplicate.status_code, 200)
        self.assertContains(duplicate, "already has an assignment")

        self.other.is_active = False
        self.other.deactivation_reason = "Left company"
        self.other.save()
        inactive = client.post("/assignments/new/", {
            "employee": self.other.pk, "training_version": self.version.pk, "due_date": "2026-12-31",
        })
        self.assertEqual(inactive.status_code, 200)
        self.assertIn("employee", inactive.context["form"].errors)
        self.assertContains(inactive, "Select a valid choice")
        self.assertFalse(TrainingAssignment.objects.filter(employee=self.other).exists())

    def test_role_assignment_creates_missing_skips_inactive_and_preserves_origin(self):
        inactive = Employee.objects.create(employee_code="GN-013", display_name="Inactive",
            department=self.department, job_role=self.role, date_joined=self.now.date())
        inactive.is_active = False
        inactive.deactivation_reason = "Left company"
        inactive.save()
        requirement = RoleTrainingRequirement.objects.create(job_role=self.role, training_version=self.version,
            created_by=self.coordinator, due_in_days=14)
        response = self.client_for(self.coordinator).post("/assignments/role/new/", {"role_requirement": requirement.pk})
        self.assertEqual(response.status_code, 302)
        created = TrainingAssignment.objects.get(employee=self.report, training_version=self.version)
        self.assertEqual(created.source, TrainingAssignment.Source.ROLE)
        self.assertEqual(created.role_requirement_id, requirement.pk)
        self.assertFalse(TrainingAssignment.objects.filter(employee=inactive, training_version=self.version).exists())
        self.assertEqual(TrainingAssignment.objects.filter(training_version=self.version).count(), 4)

    def test_role_assignment_due_today_uses_the_assignment_start_time(self):
        requirement = RoleTrainingRequirement.objects.create(
            job_role=self.role, training_version=self.version,
            created_by=self.coordinator, due_in_days=0,
        )
        response = self.client_for(self.coordinator).post(
            "/assignments/role/new/", {"role_requirement": requirement.pk},
        )
        self.assertEqual(response.status_code, 302)
        created = TrainingAssignment.objects.get(employee=self.report, training_version=self.version)
        self.assertEqual(created.due_at, created.assigned_at)

    def test_role_assignment_with_no_matching_employees_creates_nothing(self):
        vacant_role = JobRole.objects.create(code="VACANT", name="Vacant role")
        requirement = RoleTrainingRequirement.objects.create(
            job_role=vacant_role, training_version=self.version,
            created_by=self.coordinator, due_in_days=14,
        )
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client_for(self.coordinator).post(
                "/assignments/role/new/", {"role_requirement": requirement.pk},
            )
        self.assertEqual(response.status_code, 302)
        self.assertEqual(TrainingAssignment.objects.filter(role_requirement=requirement).count(), 0)
        self.assertFalse(AuditLog.objects.filter(
            action="training.role_assignment.batch_created", entity_id=str(requirement.pk),
        ).exists())

    def test_role_assignment_skips_a_duplicate_created_after_initial_lookup(self):
        requirement = RoleTrainingRequirement.objects.create(
            job_role=self.role, training_version=self.version,
            created_by=self.coordinator, due_in_days=14,
        )
        create_assignment = TrainingAssignment.objects.create
        raced = False

        def create_with_competing_assignment(**values):
            nonlocal raced
            if values["employee"].pk == self.report.pk and not raced:
                raced = True
                create_assignment(**values)
            return create_assignment(**values)

        with patch.object(TrainingAssignment.objects, "create", side_effect=create_with_competing_assignment):
            response = self.client_for(self.coordinator).post(
                "/assignments/role/new/", {"role_requirement": requirement.pk},
            )
        self.assertTrue(raced)
        self.assertEqual(response.status_code, 302)
        self.assertEqual(TrainingAssignment.objects.filter(
            employee=self.report, training_version=self.version,
        ).count(), 1)

    def test_role_assignment_recovers_from_database_duplicate_after_initial_lookup(self):
        requirement = RoleTrainingRequirement.objects.create(
            job_role=self.role, training_version=self.version,
            created_by=self.coordinator, due_in_days=14,
        )
        create_assignment = TrainingAssignment.objects.create
        raced = False

        def create_with_competing_assignment(**values):
            nonlocal raced
            if values["employee"].pk == self.report.pk and not raced:
                raced = True
                create_assignment(**values)
            return create_assignment(**values)

        with patch.object(TrainingAssignment, "full_clean", return_value=None), patch.object(
            TrainingAssignment.objects, "create", side_effect=create_with_competing_assignment,
        ):
            response = self.client_for(self.coordinator).post(
                "/assignments/role/new/", {"role_requirement": requirement.pk},
            )
        self.assertTrue(raced)
        self.assertEqual(response.status_code, 302)
        self.assertEqual(TrainingAssignment.objects.filter(
            employee=self.report, training_version=self.version,
        ).count(), 1)

    def test_role_assignment_rejects_due_period_outside_supported_dates(self):
        requirement = RoleTrainingRequirement.objects.create(
            job_role=self.role, training_version=self.version,
            created_by=self.coordinator, due_in_days=1_000_000_000,
        )
        response = self.client_for(self.coordinator).post(
            "/assignments/role/new/", {"role_requirement": requirement.pk},
        )
        self.assertEqual(response.status_code, 200)
        self.assertIn("role_requirement", response.context["form"].errors)
        self.assertFalse(TrainingAssignment.objects.filter(role_requirement=requirement).exists())

    def test_manual_assignment_rejects_retired_version(self):
        self.version.status = TrainingVersion.Status.RETIRED
        self.version.save()
        response = self.client_for(self.coordinator).post("/assignments/new/", {
            "employee": self.other.pk, "training_version": self.version.pk, "due_date": "",
        })
        self.assertEqual(response.status_code, 200)
        self.assertIn("training_version", response.context["form"].errors)
        self.assertContains(response, "Select a valid choice")
        self.assertFalse(TrainingAssignment.objects.filter(
            employee=self.other, training_version=self.version,
        ).exists())

    def test_invalid_submission_returns_form_response_not_server_error(self):
        response = self.client_for(self.coordinator).post("/assignments/new/", {
            "employee": self.employee.pk, "training_version": self.new_version().pk, "due_date": "not-a-date",
        })
        self.assertEqual(response.status_code, 200)
        self.assertIn("training_version", response.context["form"].errors)
        self.assertContains(response, "Select a valid choice")
        self.assertContains(response, "Enter a valid date")


class LearnerFrontendTests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        Group.objects.get(name="Employee").user_set.add(cls.employee_user)
        cls.manager_user = get_user_model().objects.create_user(username="learner-manager")
        Group.objects.get(name="Manager").user_set.add(cls.manager_user)
        cls.manager = Employee.objects.create(
            employee_code="GN-LEARN-MGR", display_name="Learning Manager",
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(), user=cls.manager_user,
        )
        cls.employee.reporting_manager = cls.manager
        cls.employee.save()
        cls.admin_user = get_user_model().objects.create_user(username="learner-admin")
        Group.objects.get(name="Administrator").user_set.add(cls.admin_user)

    def page(self, lesson=None):
        url = f"/assignments/{self.assignment.pk}/"
        return f"{url}?lesson={lesson.pk}" if lesson else url

    def test_employee_sees_ordered_lessons_and_text_content_without_builder_controls(self):
        self.client.force_login(self.employee_user)
        response = self.client.get(self.page())
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "Safety instructions")
        self.assertContains(response, "Mark lesson complete")
        self.assertContains(response, self.page(self.video_lesson))
        self.assertContains(response, "Next: Watch")
        self.assertNotContains(response, "Edit lesson")
        self.assertNotContains(response, "Add lesson")
        self.assertNotContains(response, 'id="lesson-video"')

    def test_video_page_uses_only_assigned_lesson_and_server_progress(self):
        LessonProgress.objects.create(
            assignment=self.assignment, lesson=self.video_lesson, started_at=self.now,
            last_accessed_at=self.now + timedelta(seconds=20),
            last_position_seconds=20, watched_ranges=[[0, 20]],
        )
        self.client.force_login(self.employee_user)
        response = self.client.get(self.page(self.video_lesson))
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'id="lesson-video"')
        self.assertContains(response, f'/assignments/{self.assignment.pk}/lessons/{self.video_lesson.pk}/progress/')
        self.assertContains(response, 'value="20')
        self.assertContains(response, "Resume position: 20 seconds")
        self.assertContains(response, "Previous: Read")
        self.assertNotContains(response, "Edit lesson")

    def test_completed_text_and_video_use_persisted_completion(self):
        self.complete_lessons()
        self.client.force_login(self.employee_user)
        text_response = self.client.get(self.page(self.text_lesson))
        video_response = self.client.get(self.page(self.video_lesson))
        self.assertContains(text_response, 'id="lesson-completion">Completed')
        self.assertContains(video_response, 'id="lesson-completion">Completed')
        self.assertContains(video_response, 'value="95')

    def test_completed_text_detail_matches_curriculum_when_later_video_is_incomplete(self):
        self.client.force_login(self.employee_user)
        completion_url = (
            f"/assignments/{self.assignment.pk}/lessons/{self.text_lesson.pk}/complete/"
        )
        response = self.client.post(completion_url)
        self.assertRedirects(response, self.page(self.text_lesson))
        progress = LessonProgress.objects.get(assignment=self.assignment, lesson=self.text_lesson)
        self.assertIsNotNone(progress.completed_at)
        self.assertFalse(LessonProgress.objects.filter(
            assignment=self.assignment, lesson=self.video_lesson,
        ).exists())

        for _ in range(2):
            page = self.client.get(self.page(self.text_lesson))
            self.assertEqual(page.status_code, 200)
            self.assertEqual(page.context["selected_progress"].pk, progress.pk)
            self.assertContains(page, 'id="lesson-completion">Completed')
            self.assertNotContains(page, "Mark lesson complete")
            text_entry = page.context["module_items"][0]["lessons"][0]
            self.assertEqual(text_entry["progress"].pk, progress.pk)

        self.assertRedirects(self.client.post(completion_url), self.page(self.text_lesson))
        progress.refresh_from_db()
        self.assertEqual(LessonProgress.objects.filter(
            assignment=self.assignment, lesson=self.text_lesson,
        ).count(), 1)
        self.assertIsNotNone(progress.completed_at)

    def test_direct_lesson_selection_rejects_other_versions_and_malformed_ids(self):
        draft = self.new_version()
        module = Module.objects.create(training_version=draft, title="Other module", position=1)
        other_lesson = Lesson.objects.create(
            module=module, title="Other lesson", position=1, content_type="TEXT", body="Private text",
        )
        self.client.force_login(self.employee_user)
        for selector in (str(other_lesson.pk), "invalid", "", "-1"):
            with self.subTest(selector=selector):
                response = self.client.get(f"/assignments/{self.assignment.pk}/?lesson={selector}")
                self.assertEqual(response.status_code, 404)

    def test_employee_cannot_open_another_employees_assignment_or_lesson(self):
        other_user = get_user_model().objects.create_user(username="learner-other")
        other = Employee.objects.create(
            employee_code="GN-LEARN-OTHER", display_name="Other employee",
            department=self.department, job_role=self.role, date_joined=self.now.date(), user=other_user,
        )
        other_assignment = TrainingAssignment.objects.create(
            employee=other, training_version=self.version,
            department_at_assignment=self.department, job_role_at_assignment=self.role, assigned_by=self.user,
        )
        self.client.force_login(self.employee_user)
        response = self.client.get(f"/assignments/{other_assignment.pk}/?lesson={self.text_lesson.pk}")
        self.assertEqual(response.status_code, 404)

    def test_manager_and_admin_keep_assignment_scope_without_employee_player(self):
        for user in (self.manager_user, self.admin_user):
            with self.subTest(user=user.username):
                self.client.force_login(user)
                response = self.client.get(self.page())
                self.assertEqual(response.status_code, 200)
                self.assertNotContains(response, 'id="lesson-video"')
                self.assertNotContains(response, "Safety instructions")
                self.assertEqual(self.client.get(self.page(self.video_lesson)).status_code, 404)

    def test_inactive_cancelled_and_retired_assignments_cannot_open_lesson(self):
        self.client.force_login(self.employee_user)
        self.employee.is_active = False
        self.employee.deactivation_reason = "Inactive for test"
        self.employee.save()
        # Simulate a stale account whose login was re-enabled independently.
        get_user_model().objects.filter(pk=self.employee_user.pk).update(is_active=True)
        self.client.force_login(self.employee_user)
        self.assertEqual(self.client.get(self.page(self.video_lesson)).status_code, 404)
        self.employee.is_active = True
        self.employee.deactivated_at = None
        self.employee.deactivation_reason = ""
        self.employee.save()
        self.assignment.status = TrainingAssignment.Status.CANCELLED
        self.assignment.cancelled_at = self.now + timedelta(seconds=1)
        self.assignment.cancellation_reason = "Cancelled for test"
        self.assignment.save()
        self.assertEqual(self.client.get(self.page(self.video_lesson)).status_code, 404)
        self.assignment.status = TrainingAssignment.Status.IN_PROGRESS
        self.assignment.cancelled_at = None
        self.assignment.cancellation_reason = ""
        self.assignment.save()
        self.version.status = TrainingVersion.Status.RETIRED
        self.version.save()
        self.assertEqual(self.client.get(self.page(self.video_lesson)).status_code, 404)

    def test_empty_assignment_list_renders_normally(self):
        other_user = get_user_model().objects.create_user(username="learner-empty")
        Group.objects.get(name="Employee").user_set.add(other_user)
        Employee.objects.create(
            employee_code="GN-LEARN-EMPTY", display_name="New employee",
            department=self.department, job_role=self.role, date_joined=self.now.date(), user=other_user,
        )
        self.client.force_login(other_user)
        response = self.client.get("/assignments/")
        self.assertContains(response, "You have no training assignments yet.")


class ProtectedVideoTests(CurriculumTestCase):
    video_bytes = b"0123456789video-content"

    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        Group.objects.get(name="Employee").user_set.add(cls.employee_user)

    def setUp(self):
        size_patch = patch.object(FileSystemStorage, "size", return_value=len(self.video_bytes))
        open_patch = patch.object(FileSystemStorage, "open", side_effect=lambda name, mode: BytesIO(self.video_bytes))
        size_patch.start()
        open_patch.start()
        self.addCleanup(size_patch.stop)
        self.addCleanup(open_patch.stop)
        self.client.force_login(self.employee_user)

    def start(self):
        response = self.client.post(
            f"/assignments/{self.assignment.pk}/lessons/{self.video_lesson.pk}/sessions/start/",
            data="{}", content_type="application/json",
        )
        self.assertEqual(response.status_code, 201, response.content.decode())
        return response.json()["session_id"]

    def media_url(self, session_id, assignment=None, lesson=None):
        assignment = assignment or self.assignment
        lesson = lesson or self.video_lesson
        return f"/assignments/{assignment.pk}/lessons/{lesson.pk}/sessions/{session_id}/media/"

    def test_authorized_employee_can_stream_video_with_byte_ranges(self):
        session_id = self.start()
        response = self.client.get(self.media_url(session_id))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(b"".join(response.streaming_content), self.video_bytes)
        self.assertEqual(response["Content-Type"], "video/mp4")
        self.assertEqual(response["Cache-Control"], "private, no-store")
        self.assertEqual(response["Accept-Ranges"], "bytes")
        partial = self.client.get(self.media_url(session_id), HTTP_RANGE="bytes=2-5")
        self.assertEqual(partial.status_code, 206)
        self.assertEqual(partial["Content-Range"], f"bytes 2-5/{len(self.video_bytes)}")
        self.assertEqual(b"".join(partial.streaming_content), self.video_bytes[2:6])
        suffix = self.client.get(self.media_url(session_id), HTTP_RANGE="bytes=-4")
        self.assertEqual(b"".join(suffix.streaming_content), self.video_bytes[-4:])
        head = self.client.head(self.media_url(session_id))
        self.assertEqual(head.status_code, 200)
        self.assertEqual(head["Content-Length"], str(len(self.video_bytes)))
        with patch("training.views.mimetypes.guess_type", return_value=("text/html", None)):
            fallback = self.client.get(self.media_url(session_id))
        self.assertEqual(fallback["Content-Type"], "application/octet-stream")
        self.assertEqual(b"".join(fallback.streaming_content), self.video_bytes)

    def test_media_requires_authentication_and_matching_assignment_lesson_session(self):
        session_id = self.start()
        self.client.logout()
        self.assertEqual(self.client.get(self.media_url(session_id)).status_code, 302)
        other_user = get_user_model().objects.create_user(username="video-other")
        other = Employee.objects.create(
            employee_code="GN-MEDIA-OTHER", display_name="Other viewer",
            department=self.department, job_role=self.role, date_joined=self.now.date(), user=other_user,
        )
        other_assignment = TrainingAssignment.objects.create(
            employee=other, training_version=self.version,
            department_at_assignment=self.department, job_role_at_assignment=self.role, assigned_by=self.user,
        )
        self.client.force_login(other_user)
        self.assertEqual(self.client.get(self.media_url(session_id)).status_code, 404)
        self.assertEqual(self.client.get(self.media_url(session_id, assignment=other_assignment)).status_code, 404)
        self.client.force_login(self.employee_user)
        self.assertEqual(self.client.get(self.media_url(session_id + 9999)).status_code, 404)
        self.assertEqual(self.client.get(self.media_url(session_id, lesson=self.text_lesson)).status_code, 400)
        draft = self.new_version()
        module = Module.objects.create(training_version=draft, title="Other module", position=1)
        other_video = Lesson.objects.create(
            module=module, title="Other video", position=1, content_type="VIDEO",
            video_file="training/videos/other.mp4", video_duration_seconds=30, video_checksum="b" * 64,
        )
        self.assertEqual(self.client.get(self.media_url(session_id, lesson=other_video)).status_code, 404)

    def test_ended_and_idle_sessions_cannot_fetch_video(self):
        session_id = self.start()
        session = VideoWatchSession.objects.get(pk=session_id)
        with patch("training.views.timezone.now", return_value=session.updated_at + timedelta(seconds=31)):
            self.assertEqual(self.client.get(self.media_url(session_id)).status_code, 404)
        response = self.client.post(
            f"/assignments/{self.assignment.pk}/lessons/{self.video_lesson.pk}/sessions/{session_id}/end/",
            data=json.dumps({"position": 0}), content_type="application/json",
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.client.get(self.media_url(session_id)).status_code, 404)

    def test_bad_ranges_and_missing_video_are_controlled(self):
        session_id = self.start()
        for header in ("bytes=999-", "bytes=5-2", "bytes=0-1,3-4", "invalid"):
            with self.subTest(header=header):
                response = self.client.get(self.media_url(session_id), HTTP_RANGE=header)
                self.assertEqual(response.status_code, 416)
        with patch.object(FileSystemStorage, "open", side_effect=FileNotFoundError):
            self.assertEqual(self.client.get(self.media_url(session_id)).status_code, 404)

    def test_learner_page_does_not_expose_direct_storage_url(self):
        response = self.client.get(f"/assignments/{self.assignment.pk}/?lesson={self.video_lesson.pk}")
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "Start or resume video")
        self.assertNotContains(response, "/training/videos/")
        self.assertNotContains(response, self.video_lesson.video_file.name)
        self.assertEqual(self.client.get(f"/{self.video_lesson.video_file.name}").status_code, 404)


class ProtectedVideoDiskTests(CurriculumTestCase):
    def test_authorized_range_reads_private_local_file(self):
        with tempfile.TemporaryDirectory() as media_directory:
            storage = FileSystemStorage(location=media_directory)
            storage.save(self.video_lesson.video_file.name, ContentFile(b"local-video-bytes"))
            field = Lesson._meta.get_field("video_file")
            with patch.object(field, "storage", storage):
                self.client.force_login(self.employee_user)
                start = self.client.post(
                    f"/assignments/{self.assignment.pk}/lessons/{self.video_lesson.pk}/sessions/start/",
                    data="{}", content_type="application/json",
                )
                self.assertEqual(start.status_code, 201)
                session_id = start.json()["session_id"]
                response = self.client.get(
                    f"/assignments/{self.assignment.pk}/lessons/{self.video_lesson.pk}/sessions/{session_id}/media/",
                    HTTP_RANGE="bytes=6-10",
                )
                self.assertEqual(response.status_code, 206)
                self.assertEqual(b"".join(response.streaming_content), b"video")


class TextCompletionTests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        Group.objects.get(name="Employee").user_set.add(cls.employee_user)

    def setUp(self):
        self.client.force_login(self.employee_user)

    def url(self, assignment=None, lesson=None):
        assignment = assignment or self.assignment
        lesson = lesson or self.text_lesson
        return f"/assignments/{assignment.pk}/lessons/{lesson.pk}/complete/"

    def test_own_text_completion_is_idempotent_and_unlocks_required_lesson(self):
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(self.url(), {"completed": False, "score": 100})
        self.assertEqual(response.status_code, 302)
        progress = LessonProgress.objects.get(assignment=self.assignment, lesson=self.text_lesson)
        self.assertIsNotNone(progress.completed_at)
        self.assertEqual(progress.progress_percent, 100)
        completed_at = progress.completed_at
        with self.captureOnCommitCallbacks(execute=True):
            self.assertEqual(self.client.post(self.url()).status_code, 302)
        progress.refresh_from_db()
        self.assertEqual(progress.completed_at, completed_at)
        self.assertEqual(AuditLog.objects.filter(
            action="training.lessonprogress.completed", entity_id=str(progress.pk),
        ).count(), 1)
        self.assignment.refresh_from_db()
        self.assertNotEqual(self.assignment.status, TrainingAssignment.Status.COMPLETED)

    def test_first_text_completion_starts_assigned_training(self):
        self.assignment.status = TrainingAssignment.Status.ASSIGNED
        self.assignment.started_at = None
        self.assignment.save()
        self.assertEqual(self.client.post(self.url()).status_code, 302)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, TrainingAssignment.Status.IN_PROGRESS)
        self.assertIsNotNone(self.assignment.started_at)

    def test_text_completion_can_finish_assignment_only_after_server_prerequisites(self):
        self.assertEqual(self.client.post(self.url()).status_code, 302)
        completed = self.now + timedelta(seconds=110)
        LessonProgress.objects.create(
            assignment=self.assignment, lesson=self.video_lesson,
            started_at=self.now, last_accessed_at=completed, completed_at=completed,
            watched_ranges=[[0, 95]],
        )
        self.finish_attempt(self.quiz)
        self.finish_attempt(self.final)
        from assessments.views import _try_complete_assignment
        _try_complete_assignment(self.assignment, actor=self.employee_user)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, TrainingAssignment.Status.COMPLETED)
        self.assertIsNotNone(self.assignment.completed_at)
        self.assertEqual(self.client.post(self.url()).status_code, 302)

    def test_other_employee_manager_and_wrong_lesson_cannot_complete(self):
        other_user = get_user_model().objects.create_user(username="text-other")
        other = Employee.objects.create(
            employee_code="GN-TEXT-OTHER", display_name="Other learner",
            department=self.department, job_role=self.role, date_joined=self.now.date(), user=other_user,
        )
        other_assignment = TrainingAssignment.objects.create(
            employee=other, training_version=self.version,
            department_at_assignment=self.department, job_role_at_assignment=self.role, assigned_by=self.user,
        )
        self.client.force_login(other_user)
        self.assertEqual(self.client.post(self.url()).status_code, 404)
        manager_user = get_user_model().objects.create_user(username="text-manager")
        Group.objects.get(name="Manager").user_set.add(manager_user)
        manager = Employee.objects.create(
            employee_code="GN-TEXT-MGR", display_name="Text manager",
            department=self.department, job_role=self.role, date_joined=self.now.date(), user=manager_user,
        )
        self.employee.reporting_manager = manager
        self.employee.save()
        self.client.force_login(manager_user)
        self.assertEqual(self.client.get(f"/assignments/{self.assignment.pk}/").status_code, 200)
        self.assertEqual(self.client.post(self.url()).status_code, 404)
        self.client.force_login(self.user)
        self.assertEqual(self.client.post(self.url()).status_code, 404)
        self.client.force_login(self.employee_user)
        self.assertEqual(self.client.post(self.url(assignment=other_assignment)).status_code, 404)
        self.assertEqual(self.client.post(self.url(lesson=self.video_lesson)).status_code, 404)
        draft = self.new_version()
        module = Module.objects.create(training_version=draft, title="Other module", position=1)
        other_text = Lesson.objects.create(
            module=module, title="Other text", position=1, content_type="TEXT", body="Other content",
        )
        self.assertEqual(self.client.post(self.url(lesson=other_text)).status_code, 404)
        self.assertFalse(LessonProgress.objects.filter(lesson=self.text_lesson).exists())

    def test_text_completion_requires_post_and_csrf(self):
        self.assertEqual(self.client.get(self.url()).status_code, 405)
        client = Client(enforce_csrf_checks=True)
        client.force_login(self.employee_user)
        self.assertEqual(client.post(self.url()).status_code, 403)
        page = client.get(f"/assignments/{self.assignment.pk}/?lesson={self.text_lesson.pk}")
        self.assertEqual(page.status_code, 200)
        token = client.cookies["csrftoken"].value
        self.assertEqual(client.post(self.url(), {"csrfmiddlewaretoken": token}).status_code, 302)

    def test_cancelled_assignment_rejects_text_completion(self):
        self.assignment.status = TrainingAssignment.Status.CANCELLED
        self.assignment.cancelled_at = self.now + timedelta(seconds=1)
        self.assignment.cancellation_reason = "Cancelled for test"
        self.assignment.save()
        self.assertEqual(self.client.post(self.url()).status_code, 409)
        self.assertFalse(LessonProgress.objects.filter(assignment=self.assignment, lesson=self.text_lesson).exists())


class PlaybackViewTests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.employee_user.set_password("password")
        cls.employee_user.save(update_fields=["password"])

    def setUp(self):
        self.client = Client()
        self.assertTrue(self.client.login(username="employee", password="password"))

    def url(self, suffix="progress"):
        return f"/assignments/{self.assignment.pk}/lessons/{self.video_lesson.pk}/{suffix}/"

    def post_json(self, url, payload):
        return self.client.post(url, data=json.dumps(payload), content_type="application/json")

    def start(self, position=0):
        return self.post_json(self.url("sessions/start"), {"position": position})

    def test_resume_position_and_session_start_end_persist(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            response = self.start(10)
        self.assertEqual(response.status_code, 201)
        session_id = response.json()["session_id"]
        progress = LessonProgress.objects.get(assignment=self.assignment, lesson=self.video_lesson)
        self.assertEqual(progress.last_position_seconds, 10)

        self.assertEqual(self.client.get(self.url()).json()["resume_position"], 0.0)
        end_time = start_time + timedelta(seconds=10)
        with patch("training.views.timezone.now", return_value=end_time):
            response = self.post_json(self.url(f"sessions/{session_id}/end"), {
                "position": 20, "completed_normally": True,
            })
        self.assertEqual(response.status_code, 200, response.content.decode())
        session = VideoWatchSession.objects.get(pk=session_id)
        self.assertIsNotNone(session.ended_at)
        self.assertEqual(session.ending_position_seconds, 20)
        self.assertTrue(session.completed_normally)
        self.assertEqual(session.active_watch_seconds, 10)

    def test_browser_precision_first_and_second_heartbeats_record_watch_time(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]

        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=10)):
            first = self.post_json(self.url(), {
                "session_id": session_id, "position": 9.812345678,
            })
        self.assertEqual(first.status_code, 200, first.content.decode())
        self.assertEqual(first.json()["watched_ranges"], [[0.0, 9.812]])

        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=20)):
            second = self.post_json(self.url(), {
                "session_id": session_id, "position": 19.73456789,
            })
        self.assertEqual(second.status_code, 200, second.content.decode())
        self.assertEqual(second.json()["watched_ranges"], [[0.0, 19.734]])
        self.assertFalse(second.json()["completed"])
        self.assertEqual(VideoWatchSession.objects.get(pk=session_id).active_watch_seconds, Decimal("19.734"))

        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=21)):
            beyond_duration = self.post_json(self.url(), {
                "session_id": session_id, "position": 100.0001,
            })
        self.assertEqual(beyond_duration.status_code, 400)
        self.assertEqual(
            LessonProgress.objects.get(assignment=self.assignment, lesson=self.video_lesson).watched_seconds,
            Decimal("19.734"),
        )

    def test_several_heartbeats_then_pause_and_resume(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
        for seconds, position in ((10, 9.501234), (20, 19.002345), (30, 28.503456)):
            with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=seconds)):
                response = self.post_json(self.url(), {"session_id": session_id, "position": position})
            self.assertEqual(response.status_code, 200, response.content.decode())
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=35)):
            paused = self.post_json(self.url(f"sessions/{session_id}/end"), {
                "position": 33.253456, "completed_normally": False,
            })
        self.assertEqual(paused.status_code, 200, paused.content.decode())
        self.assertEqual(paused.json()["watched_ranges"], [[0.0, 33.253]])
        self.assertIsNotNone(VideoWatchSession.objects.get(pk=session_id).ended_at)

        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=40)):
            resumed = self.post_json(self.url("sessions/start"), {})
        self.assertEqual(resumed.status_code, 201, resumed.content.decode())
        self.assertEqual(resumed.json()["resume_position"], 33.253)
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=50)):
            response = self.post_json(self.url(), {
                "session_id": resumed.json()["session_id"], "position": 42.754321,
            })
        self.assertEqual(response.status_code, 200, response.content.decode())
        self.assertEqual(response.json()["watched_ranges"], [[0.0, 42.754]])

    def test_pause_just_after_jitter_assisted_heartbeat_closes_session(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=10)):
            heartbeat = self.post_json(self.url(), {"session_id": session_id, "position": 11.5})
        self.assertEqual(heartbeat.status_code, 200, heartbeat.content.decode())
        accepted_active_seconds = VideoWatchSession.objects.get(pk=session_id).active_watch_seconds
        accepted_watched_ranges = heartbeat.json()["watched_ranges"]
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=10.1)):
            paused = self.post_json(self.url(f"sessions/{session_id}/end"), {
                "position": 11.5, "completed_normally": False,
            })
        self.assertEqual(paused.status_code, 200, paused.content.decode())
        session = VideoWatchSession.objects.get(pk=session_id)
        self.assertIsNotNone(session.ended_at)
        self.assertEqual(session.active_watch_seconds, accepted_active_seconds)
        self.assertEqual(paused.json()["watched_ranges"], accepted_watched_ranges)

    def test_rapid_rejected_seek_then_small_valid_progress_and_pause(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=0.1)):
            skipped = self.post_json(self.url(), {"session_id": session_id, "position": 99})
        self.assertEqual(skipped.status_code, 200, skipped.content.decode())
        self.assertEqual(skipped.json()["watched_seconds"], 0.0)
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=0.2)):
            corrected = self.post_json(self.url(), {"session_id": session_id, "position": 0})
        self.assertEqual(corrected.status_code, 200, corrected.content.decode())
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=0.323456)):
            observed = self.post_json(self.url(), {"session_id": session_id, "position": 0.5})
        self.assertEqual(observed.status_code, 200, observed.content.decode())
        self.assertEqual(observed.json()["watched_ranges"], [[0.0, 0.5]])
        self.assertEqual(VideoWatchSession.objects.get(pk=session_id).active_watch_seconds, Decimal("0.123"))
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=0.4)):
            skipped_again = self.post_json(self.url(), {"session_id": session_id, "position": 99})
        self.assertEqual(skipped_again.status_code, 200, skipped_again.content.decode())
        self.assertEqual(skipped_again.json()["watched_seconds"], 0.5)
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=0.5)):
            paused = self.post_json(self.url(f"sessions/{session_id}/end"), {
                "position": 0.5, "completed_normally": False,
            })
        self.assertEqual(paused.status_code, 200, paused.content.decode())
        self.assertIsNotNone(VideoWatchSession.objects.get(pk=session_id).ended_at)
        self.assertEqual(paused.json()["watched_seconds"], 0.5)
        self.assertFalse(paused.json()["completed"])

    def test_failed_heartbeat_can_close_without_crediting_unwatched_time(self):
        session_id = self.start().json()["session_id"]
        invalid = self.post_json(self.url(), {"session_id": session_id, "position": 101})
        self.assertEqual(invalid.status_code, 400)
        self.assertIsNone(VideoWatchSession.objects.get(pk=session_id).ended_at)

        closed = self.post_json(self.url(f"sessions/{session_id}/end"), {
            "position": 0, "completed_normally": False,
        })
        self.assertEqual(closed.status_code, 200, closed.content.decode())
        self.assertIsNotNone(VideoWatchSession.objects.get(pk=session_id).ended_at)
        self.assertEqual(closed.json()["watched_seconds"], 0.0)
        self.assertFalse(closed.json()["completed"])

    def test_backward_seek_and_unwatched_forward_seek_keep_safe_resume(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=20)):
            watched = self.post_json(self.url(), {"session_id": session_id, "position": 20})
        self.assertEqual(watched.json()["watched_ranges"], [[0.0, 20.0]])
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=21)):
            backward = self.post_json(self.url(), {"session_id": session_id, "position": 5})
        self.assertEqual(backward.status_code, 200, backward.content.decode())
        self.assertEqual(backward.json()["resume_position"], 5)
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=31)):
            replay = self.post_json(self.url(), {"session_id": session_id, "position": 15})
        self.assertEqual(replay.json()["watched_seconds"], 20.0)
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=32)):
            skipped = self.post_json(self.url(), {"session_id": session_id, "position": 99})
        self.assertEqual(skipped.status_code, 200, skipped.content.decode())
        self.assertEqual(skipped.json()["watched_seconds"], 20.0)
        self.assertLessEqual(skipped.json()["resume_position"], 20)
        self.assertFalse(skipped.json()["completed"])
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=33)):
            ended = self.post_json(self.url(f"sessions/{session_id}/end"), {
                "position": 99, "completed_normally": True,
            })
        self.assertEqual(ended.status_code, 200, ended.content.decode())
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=34)):
            resumed = self.post_json(self.url("sessions/start"), {})
        self.assertEqual(resumed.json()["resume_position"], 20.0)

    def test_conservative_continuous_playback_reaches_completion(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
        for seconds in range(10, 101, 10):
            with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=seconds)):
                response = self.post_json(self.url(), {
                    "session_id": session_id, "position": seconds * 0.99,
                })
            self.assertEqual(response.status_code, 200, response.content.decode())
        self.assertGreaterEqual(response.json()["watched_seconds"], 90)
        self.assertTrue(response.json()["completed"])
        self.assertLessEqual(VideoWatchSession.objects.get(pk=session_id).active_watch_seconds, 100)

    def test_employee_cannot_update_another_employees_assignment(self):
        other_user = get_user_model().objects.create_user(username="playback-other", password="password")
        other = Employee.objects.create(employee_code="GN-PLAYBACK", display_name="Other",
            department=self.department, job_role=self.role, date_joined=self.now.date(), user=other_user)
        other_assignment = TrainingAssignment.objects.create(employee=other, training_version=self.version,
            department_at_assignment=self.department, job_role_at_assignment=self.role, assigned_by=self.user)
        response = self.post_json(
            f"/assignments/{other_assignment.pk}/lessons/{self.video_lesson.pk}/sessions/start/", {"position": 0}
        )
        self.assertEqual(response.status_code, 404)

    def test_lesson_from_another_version_is_rejected(self):
        version = self.new_version()
        module = Module.objects.create(training_version=version, title="Other", position=1)
        lesson = Lesson.objects.create(module=module, title="Other video", position=1, content_type="VIDEO",
            video_file="training/videos/other.mp4", video_duration_seconds=100, video_checksum="b" * 64)
        response = self.post_json(
            f"/assignments/{self.assignment.pk}/lessons/{lesson.pk}/sessions/start/", {"position": 0}
        )
        self.assertEqual(response.status_code, 404)

    def test_cancelled_assignment_rejects_progress(self):
        self.assignment.status = TrainingAssignment.Status.CANCELLED
        self.assignment.cancelled_at = self.now + timedelta(seconds=1)
        self.assignment.cancellation_reason = "Cancelled for test"
        self.assignment.save()
        response = self.start()
        self.assertEqual(response.status_code, 409)

    def test_invalid_positions_return_controlled_errors(self):
        for payload in ({"position": -1}, {"position": 101}, {"position": "bad"}):
            with self.subTest(payload=payload):
                response = self.start(payload["position"])
                self.assertEqual(response.status_code, 400)
                self.assertIn("error", response.json())
        response = self.client.post(self.url("sessions/start"), data="not-json", content_type="application/json")
        self.assertEqual(response.status_code, 400)

    def test_video_session_metadata_requires_bounded_strings(self):
        for field, value in (
            ("session_identifier", {"id": "forged"}),
            ("device_identifier", ["device"]),
            ("session_identifier", "x" * 129),
        ):
            with self.subTest(field=field, value_type=type(value).__name__):
                response = self.post_json(self.url("sessions/start"), {"position": 0, field: value})
                self.assertEqual(response.status_code, 400)
        self.assertFalse(VideoWatchSession.objects.filter(assignment=self.assignment).exists())

    def test_playback_mutations_require_csrf(self):
        client = Client(enforce_csrf_checks=True)
        client.force_login(self.employee_user)
        response = client.post(
            self.url("sessions/start"),
            data=json.dumps({"position": 0}),
            content_type="application/json",
        )
        self.assertEqual(response.status_code, 403)

    def test_malformed_session_ids_are_rejected_before_orm_lookup(self):
        session_id = self.start().json()["session_id"]
        for invalid_id in ([], {}, None, True, False, "bad", str(session_id), -1, 0):
            with self.subTest(session_id=invalid_id):
                response = self.post_json(self.url(), {"session_id": invalid_id, "position": 0})
                self.assertEqual(response.status_code, 400)
        response = self.post_json(self.url(), {"session_id": session_id + 1000, "position": 0})
        self.assertEqual(response.status_code, 404)

    def test_heartbeat_after_session_end_is_rejected_without_changing_progress(self):
        session_id = self.start().json()["session_id"]
        self.assertEqual(self.post_json(self.url(f"sessions/{session_id}/end"), {
            "position": 0, "completed_normally": True,
        }).status_code, 200)
        response = self.post_json(self.url(), {"session_id": session_id, "position": 20})
        self.assertEqual(response.status_code, 404)
        progress = LessonProgress.objects.get(assignment=self.assignment, lesson=self.video_lesson)
        self.assertEqual(progress.watched_seconds, 0)

    def test_forward_seek_does_not_count_skipped_time(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=1)):
            response = self.post_json(self.url(), {"session_id": session_id, "position": 99})
        self.assertEqual(response.status_code, 200, response.content.decode())
        self.assertEqual(response.json()["watched_seconds"], 0.0)
        self.assertFalse(response.json()["completed"])

    def test_repeated_tolerance_cannot_manufacture_completion(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
            for position in range(2, 92, 2):
                response = self.post_json(self.url(), {"session_id": session_id, "position": position})
        self.assertEqual(response.status_code, 200, response.content.decode())
        self.assertLessEqual(response.json()["watched_seconds"], 2.0)
        self.assertFalse(response.json()["completed"])

    def test_new_sessions_cannot_reissue_tolerance_without_elapsed_time(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            for index in range(5):
                session_id = self.start(index * 2).json()["session_id"]
                response = self.post_json(self.url(), {
                    "session_id": session_id, "position": (index + 1) * 2,
                })
                self.assertEqual(response.status_code, 200, response.content.decode())
        self.assertLessEqual(response.json()["watched_seconds"], 2.0)
        self.assertFalse(response.json()["completed"])

    def test_overlapping_sessions_use_their_own_positions(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            first_id = self.start(50).json()["session_id"]
            second_id = self.start(0).json()["session_id"]
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=2)):
            second_response = self.post_json(self.url(), {"session_id": second_id, "position": 52})
            first_response = self.post_json(self.url(), {"session_id": first_id, "position": 52})
        self.assertEqual(second_response.status_code, 200, second_response.content.decode())
        self.assertEqual(second_response.json()["watched_seconds"], 0.0)
        self.assertEqual(first_response.status_code, 200, first_response.content.decode())
        self.assertEqual(first_response.json()["watched_ranges"], [[50.0, 52.0]])
        self.assertEqual(VideoWatchSession.objects.get(pk=second_id).active_watch_seconds, 0)
        self.assertEqual(VideoWatchSession.objects.get(pk=first_id).active_watch_seconds, 2)

    def test_interleaved_sessions_merge_coverage_without_losing_updates(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            first_id = self.start(0).json()["session_id"]
            second_id = self.start(20).json()["session_id"]
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=10)):
            first_response = self.post_json(self.url(), {"session_id": first_id, "position": 10})
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=20)):
            second_response = self.post_json(self.url(), {"session_id": second_id, "position": 30})
        self.assertEqual(first_response.status_code, 200, first_response.content.decode())
        self.assertEqual(second_response.status_code, 200, second_response.content.decode())
        self.assertEqual(second_response.json()["watched_ranges"], [[0.0, 10.0], [20.0, 30.0]])

    def test_backward_seek_replay_counts_active_time_without_new_coverage(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=10)):
            response = self.post_json(self.url(), {"session_id": session_id, "position": 10})
        self.assertEqual(response.status_code, 200, response.content.decode())
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=11)):
            response = self.post_json(self.url(), {"session_id": session_id, "position": 0})
        self.assertEqual(response.status_code, 200, response.content.decode())
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=21)):
            response = self.post_json(self.url(), {"session_id": session_id, "position": 10})
        self.assertEqual(response.status_code, 200, response.content.decode())
        self.assertEqual(response.json()["resume_position"], 10.0)
        self.assertEqual(response.json()["watched_seconds"], 10.0)
        self.assertEqual(VideoWatchSession.objects.get(pk=session_id).active_watch_seconds, 20)

    def test_idle_session_has_no_active_watch_time_or_lesson_completion(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
        with patch("training.views.timezone.now", return_value=start_time + timedelta(hours=1)):
            response = self.post_json(self.url(f"sessions/{session_id}/end"), {
                "position": 0, "completed_normally": True,
            })
        self.assertEqual(response.status_code, 200, response.content.decode())
        self.assertEqual(response.json()["watched_seconds"], 0.0)
        self.assertFalse(response.json()["completed"])
        session = VideoWatchSession.objects.get(pk=session_id)
        self.assertEqual(session.active_watch_seconds, 0)
        self.assertTrue(session.completed_normally)

    def test_stale_heartbeat_cannot_turn_idle_time_into_watch_credit(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
        resumed_at = start_time + timedelta(hours=1)
        with patch("training.views.timezone.now", return_value=resumed_at):
            response = self.post_json(self.url(), {"session_id": session_id, "position": 90,
                "completed": True, "watched_seconds": 100, "watched_ranges": [[0, 100]]})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["watched_seconds"], 0.0)
        self.assertFalse(response.json()["completed"])
        self.assertEqual(VideoWatchSession.objects.get(pk=session_id).active_watch_seconds, 0)
        # The stale observation resets the position baseline; fresh playback still works.
        with patch("training.views.timezone.now", return_value=resumed_at + timedelta(seconds=5)):
            response = self.post_json(self.url(), {"session_id": session_id, "position": 95})
        self.assertEqual(response.json()["watched_ranges"], [[90.0, 95.0]])

    def test_stale_session_end_cannot_forge_video_completion(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
        with patch("training.views.timezone.now", return_value=start_time + timedelta(hours=1)):
            response = self.post_json(self.url(f"sessions/{session_id}/end"), {
                "position": 100, "completed_normally": True, "active_watch_seconds": 100,
            })
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["watched_seconds"], 0.0)
        self.assertFalse(response.json()["completed"])
        session = VideoWatchSession.objects.get(pk=session_id)
        self.assertIsNotNone(session.ended_at)
        self.assertEqual(session.active_watch_seconds, 0)

    def test_idle_time_cannot_fund_rapid_heartbeat_tolerance(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
        with patch("training.views.timezone.now", return_value=start_time + timedelta(hours=1)):
            self.post_json(self.url(), {"session_id": session_id, "position": 0})
            for position in range(2, 92, 2):
                response = self.post_json(self.url(), {"session_id": session_id, "position": position})
        self.assertEqual(response.status_code, 200)
        self.assertLessEqual(response.json()["watched_seconds"], 2.0)
        self.assertLessEqual(VideoWatchSession.objects.get(pk=session_id).active_watch_seconds, 2)
        self.assertFalse(response.json()["completed"])

    def test_idle_time_cannot_fund_tolerance_from_new_sessions(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            self.start()
        with patch("training.views.timezone.now", return_value=start_time + timedelta(hours=1)):
            for position in range(0, 10, 2):
                session_id = self.start(position).json()["session_id"]
                response = self.post_json(self.url(), {"session_id": session_id, "position": position + 2})
        self.assertEqual(response.status_code, 200)
        self.assertLessEqual(response.json()["watched_seconds"], 2.0)
        self.assertFalse(response.json()["completed"])

    def test_completed_normally_requires_boolean_and_is_not_lesson_completion(self):
        session_id = self.start().json()["session_id"]
        response = self.post_json(self.url(f"sessions/{session_id}/end"), {
            "position": 0, "completed_normally": "true",
        })
        self.assertEqual(response.status_code, 400)
        self.assertIsNone(VideoWatchSession.objects.get(pk=session_id).ended_at)
        response = self.post_json(self.url(f"sessions/{session_id}/end"), {
            "position": 0, "completed_normally": True,
        })
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["completed"])

    def test_overlapping_ranges_merge_and_replay_does_not_inflate_progress(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start(5).json()["session_id"]
        progress = LessonProgress.objects.get(assignment=self.assignment, lesson=self.video_lesson)
        progress.watched_ranges = [[0, 10], [20, 30]]
        progress.save()
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=30)):
            response = self.post_json(self.url(), {"session_id": session_id, "position": 25})
        self.assertEqual(response.status_code, 200, response.content.decode())
        self.assertEqual(response.json()["watched_ranges"], [[0.0, 30.0]])
        self.assertEqual(response.json()["watched_seconds"], 30.0)

        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=31)):
            response = self.post_json(self.url(), {"session_id": session_id, "position": 30})
        self.assertEqual(response.json()["watched_seconds"], 30.0)

    def test_separate_legitimate_ranges_accumulate(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=10)):
            self.post_json(self.url(), {"session_id": session_id, "position": 10})
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=11)):
            self.post_json(self.url(), {"session_id": session_id, "position": 20})
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=21)):
            response = self.post_json(self.url(), {"session_id": session_id, "position": 30})
        self.assertEqual(response.json()["watched_ranges"], [[0.0, 10.0], [20.0, 30.0]])
        self.assertEqual(response.json()["watched_seconds"], 20.0)

    def test_minimum_watch_completion_and_completion_persistence(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
        for position in (30, 60, 90):
            with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=position)):
                with self.captureOnCommitCallbacks(execute=True):
                    response = self.post_json(self.url(), {"session_id": session_id, "position": position})
        self.assertTrue(response.json()["completed"])
        completed_at = LessonProgress.objects.get(pk=response.json()["progress_id"]).completed_at
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=91)):
            with self.captureOnCommitCallbacks(execute=True):
                response = self.post_json(self.url(), {"session_id": session_id, "position": 20})
        progress = LessonProgress.objects.get(pk=response.json()["progress_id"])
        self.assertTrue(response.json()["completed"])
        self.assertEqual(progress.completed_at, completed_at)
        self.assertEqual(AuditLog.objects.filter(
            action="training.lessonprogress.completed", entity_id=str(progress.pk),
        ).count(), 1)

    def test_video_completion_changes_at_exact_watch_threshold(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
        for position in (30, 60, 89.99):
            with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=position)):
                response = self.post_json(self.url(), {"session_id": session_id, "position": position})
        self.assertEqual(response.status_code, 200, response.content.decode())
        self.assertFalse(response.json()["completed"])
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=90)):
            response = self.post_json(self.url(), {"session_id": session_id, "position": 90})
        self.assertEqual(response.status_code, 200, response.content.decode())
        self.assertTrue(response.json()["completed"])

    def test_seeking_near_end_does_not_complete_lesson(self):
        start_time = self.now + timedelta(minutes=1)
        with patch("training.views.timezone.now", return_value=start_time):
            session_id = self.start().json()["session_id"]
        with patch("training.views.timezone.now", return_value=start_time + timedelta(seconds=1)):
            response = self.post_json(self.url(), {"session_id": session_id, "position": 99})
        self.assertFalse(response.json()["completed"])


class ProgressTests(CurriculumTestCase):
    def progress(self, **kwargs):
        return LessonProgress(assignment=self.assignment, lesson=self.video_lesson, started_at=self.now,
                              last_accessed_at=self.now + timedelta(seconds=100), **kwargs)

    def test_coverage_and_resume_are_separate(self):
        progress = self.progress(watched_ranges=[[0, 20], [50, 70]], last_position_seconds=100)
        progress.save()
        self.assertEqual(progress.watched_seconds, 40)
        self.assertEqual(progress.progress_percent, 40)
        self.assertIsNone(progress.completed_at)

    def test_duplicate_progress_rejected(self):
        self.progress().save()
        with self.assertRaises(ValidationError):
            self.progress().save()

    def test_invalid_ranges_and_insufficient_coverage_rejected(self):
        for ranges in [[[0, 60], [50, 80]], [[0, 60], [60, 80]], [[-1, 10]], [[0, 101]], [[0, "bad"]], {}]:
            with self.subTest(ranges=ranges), self.assertRaises(ValidationError):
                self.progress(watched_ranges=ranges).save()
        with self.assertRaises(ValidationError):
            self.progress(watched_ranges=[[0, 50]], completed_at=self.now + timedelta(seconds=100)).save()

    def test_existing_coverage_cannot_be_discarded(self):
        progress = self.progress(watched_ranges=[[0, 40]])
        progress.save()
        progress.watched_ranges = [[0, 20]]
        with self.assertRaises(ValidationError):
            progress.save()

    def test_cached_lesson_cannot_bypass_video_threshold(self):
        self.video_lesson.minimum_watch_percent = 1
        with self.assertRaises(ValidationError):
            self.progress(watched_ranges=[[0, 20]], completed_at=self.now + timedelta(seconds=100)).save()

    def test_lesson_from_another_version_rejected(self):
        module = Module.objects.create(training_version=self.new_version(), title="New", position=1)
        lesson = Lesson.objects.create(module=module, title="New", position=1, content_type="TEXT", body="New text")
        with self.assertRaises(ValidationError):
            LessonProgress.objects.create(assignment=self.assignment, lesson=lesson)

    def test_deactivated_employee_cannot_record_progress(self):
        self.employee.is_active = False
        self.employee.deactivation_reason = "Left"
        self.employee.save()
        with self.assertRaises(ValidationError):
            self.progress().save()


class VideoWatchSessionTests(CurriculumTestCase):
    def session(self, **kwargs):
        values = dict(assignment=self.assignment, lesson=self.video_lesson, started_at=self.now,
                      starting_position_seconds=80, session_identifier="browser-session", device_identifier="shared-training-tablet")
        values.update(kwargs)
        return VideoWatchSession(**values)

    def test_multiple_sessions_preserved_without_inflating_aggregate(self):
        progress = LessonProgress.objects.create(assignment=self.assignment, lesson=self.video_lesson, watched_ranges=[[0, 20]])
        for _ in range(2):
            self.session(ended_at=self.now + timedelta(seconds=30), ending_position_seconds=20,
                         active_watch_seconds=25, completed_normally=True).save()
        self.assertEqual(self.assignment.video_watch_sessions.count(), 2)
        progress.refresh_from_db()
        self.assertEqual(progress.watched_seconds, 20)

    def test_backward_seek_is_allowed(self):
        session = self.session(ended_at=self.now + timedelta(seconds=30), ending_position_seconds=20, active_watch_seconds=25)
        session.save()
        self.assertLess(session.ending_position_seconds, session.starting_position_seconds)

    def test_invalid_session_measurements_rejected(self):
        invalid = [dict(active_watch_seconds=-1), dict(starting_position_seconds=101),
                   dict(ended_at=self.now - timedelta(seconds=1), ending_position_seconds=1),
                  dict(ended_at=self.now + timedelta(seconds=10), ending_position_seconds=90, active_watch_seconds=13),
                   dict(completed_normally=True), dict(ended_at=self.now + timedelta(seconds=10)),
                   dict(lesson=self.text_lesson)]
        for values in invalid:
            with self.subTest(values=values), self.assertRaises(ValidationError):
                self.session(**values).save()

    def test_closed_session_is_immutable_and_retained(self):
        session = self.session()
        session.save()
        session.ended_at = self.now + timedelta(seconds=20)
        session.ending_position_seconds = 100
        session.active_watch_seconds = 20
        session.completed_normally = True
        session.save()
        session.active_watch_seconds = 10
        with self.assertRaises(ValidationError):
            session.save()
        with self.assertRaises(ValidationError):
            VideoWatchSession.objects.filter(pk=session.pk).delete()

    def test_database_checks_session_time_order(self):
        session = self.session(ended_at=self.now - timedelta(seconds=1), ending_position_seconds=90)
        with self.assertRaises(IntegrityError), transaction.atomic():
            models.Model.save(session, force_insert=True)
