from datetime import timedelta
from decimal import Decimal
from importlib import import_module

from django.apps import apps
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import ValidationError
from django.db import IntegrityError, models, transaction
from django.test import Client, TestCase

from config.model_test_utils import CurriculumTestCase
from organization.models import Employee
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
        self.assertContains(inactive, "Inactive employees")

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

    def test_invalid_submission_returns_form_response_not_server_error(self):
        response = self.client_for(self.coordinator).post("/assignments/new/", {
            "employee": self.employee.pk, "training_version": self.new_version().pk, "due_date": "not-a-date",
        })
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "Assignments require a published training version")
        self.assertContains(response, "Enter a valid date")


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
                   dict(ended_at=self.now + timedelta(seconds=10), ending_position_seconds=90, active_watch_seconds=11),
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
