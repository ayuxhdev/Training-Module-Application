"""Real lifecycle API requests; all fixtures are isolated by Django TestCase."""

from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import ValidationError
from django.db import transaction
from organization.models import Employee
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from assessments.models import Assessment, AssessmentQuestion
from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from training.models import Lesson, LessonProgress, Module, TrainingAssignment

from . import training_management_services as services


class VersionLifecycleAPITests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.user.user_permissions.add(Permission.objects.get(
            content_type__app_label="training", codename="change_trainingversion",
        ))

    def setUp(self):
        self.client = APIClient()

    def authenticate(self, user=None):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + str(RefreshToken.for_user(user or self.user).access_token))

    def url(self, version=None, action="publish"):
        return f"/api/v1/management/versions/{(version or self.version).pk}/{action}/"

    def ready_draft(self):
        draft = self.new_version()
        module = Module.objects.create(training_version=draft, title="Module", position=1)
        Lesson.objects.create(module=module, title="Read", position=1, content_type="TEXT", body="Content")
        final = Assessment.objects.create(training_version=draft, kind="FINAL", title="Final")
        AssessmentQuestion.objects.create(assessment=final, question_revision=self.revision, position=1, points=1)
        return draft

    def test_publish_uses_change_permission_and_authoritative_publication_validation(self):
        draft = self.ready_draft()
        self.authenticate()
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(self.url(draft), {}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["id"], draft.pk)
        self.assertEqual(response.data["training_id"], self.training.pk)
        self.assertEqual(response.data["status"], "PUBLISHED")
        self.assertNotIn("modules", response.data)
        self.assertNotIn("published_by", response.data)
        draft.refresh_from_db()
        self.assertEqual(draft.published_by_id, self.user.pk)
        self.assertIsNotNone(draft.published_at)
        event = AuditLog.objects.get(action="training.trainingversion.published")
        self.assertEqual(event.actor_id, self.user.pk)
        self.assertEqual(event.before_data["status"], "DRAFT")
        self.assertEqual(event.after_data["status"], "PUBLISHED")

    def test_retire_preserves_publication_and_existing_assignment_progress_and_history(self):
        self.complete_assignment()
        before = list(TrainingAssignment.objects.values())
        progress = list(LessonProgress.objects.order_by("pk").values())
        published_at, published_by = self.version.published_at, self.version.published_by_id
        self.authenticate()
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(self.url(action="retire"), {}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["status"], "RETIRED")
        self.version.refresh_from_db()
        self.assertEqual(self.version.published_at, published_at)
        self.assertEqual(self.version.published_by_id, published_by)
        self.assertEqual(list(TrainingAssignment.objects.values()), before)
        self.assertEqual(list(LessonProgress.objects.order_by("pk").values()), progress)
        self.assertEqual(AuditLog.objects.filter(action="training.trainingversion.retired").count(), 1)

    def test_administrator_and_coordinator_keep_effective_lifecycle_authority(self):
        for name in ("Administrator", "Training Coordinator"):
            actor = get_user_model().objects.create_user(username="lifecycle-" + name.replace(" ", "-"))
            actor.groups.add(Group.objects.get(name=name))
            self.authenticate(actor)
            response = self.client.post(self.url(action="retire"), {}, format="json")
            self.assertEqual(response.status_code, 200 if name == "Administrator" else 409, response.data)

    def test_in_progress_assignment_remains_pinned_and_unchanged_after_retirement(self):
        before = list(TrainingAssignment.objects.values())
        self.authenticate()
        self.assertEqual(self.client.post(self.url(action="retire"), {}, format="json").status_code, 200)
        self.assertEqual(list(TrainingAssignment.objects.values()), before)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, "IN_PROGRESS")
        self.assertEqual(self.assignment.training_version_id, self.version.pk)

    def test_anonymous_invalid_tokens_and_inactive_users_are_denied(self):
        for token in (None, "invalid"):
            self.client.credentials(**({"HTTP_AUTHORIZATION": "Bearer " + token} if token else {}))
            for action in ("publish", "retire"):
                self.assertEqual(self.client.post(self.url(action=action), {}, format="json").status_code, 401)
        self.authenticate()
        self.user.is_active = False
        self.user.save()
        self.assertEqual(self.client.post(self.url(action="retire"), {}, format="json").status_code, 401)
        self.assertFalse(AuditLog.objects.exists())

    def test_view_add_employee_and_team_only_permissions_cannot_transition(self):
        for codename in (None, "view_trainingversion", "add_trainingversion", "assign_team_trainingassignment"):
            with self.subTest(permission=codename):
                actor = get_user_model().objects.create_user(username="no-lifecycle-" + str(codename))
                if codename:
                    actor.user_permissions.add(Permission.objects.get(content_type__app_label="training", codename=codename))
                self.authenticate(actor)
                for action in ("publish", "retire"):
                    self.assertEqual(self.client.post(self.url(action=action), {}, format="json").status_code, 403)
        self.assertFalse(AuditLog.objects.exists())

    def test_superuser_can_retire_without_business_groups(self):
        actor = get_user_model().objects.create_user(username="lifecycle-super", is_superuser=True)
        self.authenticate(actor)
        self.assertEqual(self.client.post(self.url(action="retire"), {}, format="json").status_code, 200)
        self.assertFalse(actor.groups.exists())

    def test_invalid_transitions_are_conflicts_and_do_not_emit_success(self):
        self.authenticate()
        draft = self.new_version()
        for version, action in ((self.version, "publish"), (draft, "retire")):
            response = self.client.post(self.url(version, action), {}, format="json")
            self.assertEqual(response.status_code, 409, response.data)
            self.assertEqual(response.data["error"]["code"], "conflict")
        self.version.status = "RETIRED"
        self.version.save()
        for action in ("publish", "retire"):
            self.assertEqual(self.client.post(self.url(action=action), {}, format="json").status_code, 409)
        self.assertFalse(AuditLog.objects.exists())

    def test_failed_publication_rolls_back_status_metadata_and_audit(self):
        draft = self.new_version()
        self.authenticate()
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(self.url(draft), {}, format="json")
        self.assertEqual(response.status_code, 400, response.data)
        self.assertIn("non_field_errors", response.data["error"]["fields"])
        draft.refresh_from_db()
        self.assertEqual(draft.status, "DRAFT")
        self.assertIsNone(draft.published_at)
        self.assertIsNone(draft.published_by_id)
        self.assertFalse(AuditLog.objects.exists())

    def test_missing_modules_and_invalid_assessments_cannot_publish(self):
        draft = self.ready_draft()
        self.authenticate()
        with patch.object(Assessment, "validate_for_publication", side_effect=ValidationError("Incomplete assessment.")):
            response = self.client.post(self.url(draft), {}, format="json")
        self.assertEqual(response.status_code, 400)
        self.assertIn("Incomplete assessment.", str(response.data))
        self.assertFalse(AuditLog.objects.exists())

    def test_unexpected_payload_fields_and_non_objects_are_rejected(self):
        self.authenticate()
        for payload in ({"status": "DRAFT"}, {"published_by": self.employee_user.pk}, [], "retire", None):
            with self.subTest(payload=payload):
                # Explicit JSON null must not be silently converted into {} by APIClient.
                import json
                response = self.client.generic("POST", self.url(action="retire"), json.dumps(payload), content_type="application/json")
                self.assertEqual(response.status_code, 400, response.data)
        self.version.refresh_from_db()
        self.assertEqual(self.version.status, "PUBLISHED")

    def test_get_and_other_verbs_cannot_mutate_and_missing_version_is_404(self):
        self.authenticate()
        for method in ("get", "patch", "delete"):
            response = getattr(self.client, method)(self.url(action="retire"))
            self.assertEqual(response.status_code, 405)
        self.assertEqual(self.client.post("/api/v1/management/versions/999999/publish/", {}, format="json").status_code, 404)
        self.version.refresh_from_db()
        self.assertEqual(self.version.status, "PUBLISHED")

    def test_published_and_retired_curriculum_stays_immutable(self):
        self.user.user_permissions.add(Permission.objects.get(content_type__app_label="training", codename="add_module"))
        self.authenticate()
        for retire in (False, True):
            if retire:
                self.assertEqual(self.client.post(self.url(action="retire"), {}, format="json").status_code, 200)
            response = self.client.post(f"/api/v1/management/versions/{self.version.pk}/modules/", {"title": "Forbidden", "position": 5}, format="json")
            self.assertEqual(response.status_code, 404)
            self.assertEqual(self.version.modules.count(), 1)

    def test_retirement_excludes_new_assignments_but_keeps_the_existing_pin(self):
        self.authenticate()
        self.assertEqual(self.client.post(self.url(action="retire"), {}, format="json").status_code, 200)
        self.version.refresh_from_db()
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.training_version_id, self.version.pk)
        other = Employee.objects.create(employee_code="LIFECYCLE-OTHER", display_name="Other learner",
                                        department=self.department, job_role=self.role, date_joined=self.now.date())
        with self.assertRaisesMessage(ValidationError, "published version"):
            TrainingAssignment(employee=other, training_version=self.version,
                               department_at_assignment=self.department, job_role_at_assignment=self.role,
                               assigned_by=self.user, assigned_at=self.now).full_clean()
        self.user.user_permissions.add(Permission.objects.get(
            content_type__app_label="training", codename="add_trainingassignment"))
        response = self.client.post("/api/v1/management/assignments/", {
            "employee_id": other.pk, "training_version_id": self.version.pk,
        }, format="json")
        self.assertEqual(response.status_code, 400, response.data)
        self.assertIn("training_version_id", response.data["error"]["fields"])
        self.assertFalse(TrainingAssignment.objects.filter(employee=other).exists())

    def test_outer_rollback_preserves_lifecycle_and_discards_commit_audit(self):
        with self.captureOnCommitCallbacks(execute=True):
            with self.assertRaisesMessage(RuntimeError, "abort"):
                with transaction.atomic():
                    services.transition_version(self.user, self.version.pk, publish=False)
                    raise RuntimeError("abort")
        self.version.refresh_from_db()
        self.assertEqual(self.version.status, "PUBLISHED")
        self.assertFalse(AuditLog.objects.exists())
