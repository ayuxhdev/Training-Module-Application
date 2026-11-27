"""Run only in a fresh schema owned by the guarded MySQL integration runner."""

from concurrent.futures import ThreadPoolExecutor
from threading import Event
from unittest import skipUnless
from unittest.mock import patch

from django.conf import settings
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import OperationalError, connection, transaction
from django.test import Client, TransactionTestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.system_admin_services import update_system_user_groups
from assessments.models import Assessment, AssessmentQuestion, Question, QuestionOption, QuestionRevision
from audit.models import AuditLog
from audit.services import AuditWriteError, record_event
from config.role_requirement_test_config import ENGINE, IntegrationConfig, validate_settings
from config.role_requirement_test_runner import require_authorized_connection
from organization.models import Department, Employee, JobRole
from training.models import Lesson, Module, Training, TrainingAssignment, TrainingVersion

from . import training_management_services


User = get_user_model()
VERSION_PERMISSION = "training.change_trainingversion"
REVISION_PERMISSION = "assessments.change_questionrevision"
WAIT = 15


@skipUnless(
    settings.DATABASES.get("default", {}).get("ENGINE") == ENGINE
    and hasattr(settings, "INTEGRATION_TEST_CONFIG"),
    "Requires the explicitly approved integration test profile.",
)
class LifecycleAuthorizationMySQLTests(TransactionTestCase):
    @classmethod
    def _pre_setup(cls):
        if type(validate_settings(settings)) is not IntegrationConfig:
            raise RuntimeError("These tests require the guarded integration profile.")
        require_authorized_connection(connection)
        super()._pre_setup()

    def setUp(self):
        self.admin = User.objects.create_user(username="lifecycle-admin", is_superuser=True, is_staff=True)
        self.actor = User.objects.create_user(username="lifecycle-author")
        self.department = Department.objects.create(code="LIFECYCLE", name="Test department")
        self.role = JobRole.objects.create(code="LIFECYCLE", name="Test role")
        self.employee = self.make_employee("AUTHOR", self.actor)
        self.training = Training.objects.create(code="LIFECYCLE", catalog_title="Test training", created_by=self.admin)
        self.version = TrainingVersion.objects.create(
            training=self.training, title="Test version", version_number=1, created_by=self.admin,
        )
        self.module = Module.objects.create(training_version=self.version, title="Test module", position=1)
        Lesson.objects.create(module=self.module, title="Test lesson", position=1, content_type="TEXT", body="Test content")
        self.question = Question.objects.create(code="LIFECYCLE", created_by=self.admin)
        frozen, _ = self.make_revision(1)
        frozen.status = QuestionRevision.Status.FROZEN
        frozen.frozen_at = timezone.now()
        frozen.save()
        self.revision, self.option = self.make_revision(2)
        assessment = Assessment.objects.create(training_version=self.version, kind="FINAL", title="Final")
        AssessmentQuestion.objects.create(assessment=assessment, question_revision=frozen, position=1)

    def make_employee(self, code, user):
        return Employee.objects.create(
            employee_code=code, display_name=code, user=user, department=self.department,
            job_role=self.role, date_joined="2026-01-01",
        )

    def make_revision(self, number):
        revision = QuestionRevision.objects.create(
            question=self.question, revision_number=number, prompt="Is this a test?", created_by=self.admin,
        )
        option = QuestionOption.objects.create(question_revision=revision, text="Yes", position=1, is_correct=True)
        QuestionOption.objects.create(question_revision=revision, text="No", position=2)
        return revision, option

    def grant(self, permission, group=None):
        app_label, codename = permission.split(".")
        grant = Permission.objects.get(content_type__app_label=app_label, codename=codename)
        if group is None:
            self.actor.user_permissions.add(grant)
        else:
            group.permissions.add(grant)
            self.actor.groups.add(group)
        return grant

    def version_request(self, action, *, api=False, actor=None):
        actor = actor or self.actor
        if api:
            client = APIClient()
            client.force_authenticate(actor)
            return client.post(reverse(f"api:v1:management-version-{action}", args=[self.version.pk]), {}, format="json")
        client = Client()
        client.force_login(actor)
        return client.post(reverse(f"training:version-{action}", args=[self.version.pk]))

    def freeze_request(self, *, api=False):
        if api:
            client = APIClient()
            client.force_authenticate(self.actor)
            url = reverse("api:v1:management-question-revision-freeze", args=[self.question.pk, self.revision.pk])
            return client.post(url, {}, format="json")
        client = Client()
        client.force_login(self.actor)
        return client.post(reverse("assessments:revision-freeze", args=[self.revision.pk]))

    def observe_sql(self, ready, table, clause):
        def observe(execute, sql, params, many, context):
            if table.upper() in sql.upper() and clause in sql.upper():
                ready.set()
            return execute(sql, params, many, context)
        return observe

    def worker(self, operation, observer):
        try:
            require_authorized_connection(connection)
            with connection.cursor() as cursor:
                cursor.execute("SET SESSION innodb_lock_wait_timeout = 10")
            if observer is None:
                return operation()
            with connection.execute_wrapper(observer):
                return operation()
        finally:
            connection.close()

    def commit_while_request_waits(self, model, pk, request, commit):
        attempted = Event()
        observer = self.observe_sql(attempted, model._meta.db_table, "FOR UPDATE")
        with ThreadPoolExecutor(max_workers=1) as pool:
            with transaction.atomic():
                model.objects.select_for_update().get(pk=pk)
                pending = pool.submit(self.worker, request, observer)
                self.assertTrue(attempted.wait(WAIT), "Request failed to reach its lifecycle lock.")
                commit()
            return pending.result(timeout=WAIT)

    def assert_no_success(self, action, entity):
        self.assertFalse(AuditLog.objects.filter(action=action, entity_id=str(entity.pk)).exists())

    def assert_row_locked(self, queryset):
        # NOWAIT makes this fail deterministically if the open mutation is
        # missing a lock. The inner atomic block rolls back the probe.
        with self.assertRaises(OperationalError) as error, transaction.atomic():
            queryset.select_for_update(nowait=True).get()
        self.assertEqual(error.exception.args[0], 3572)

    def test_employee_deactivation_commits_before_pending_website_publication(self):
        self.grant(VERSION_PERMISSION)

        def deactivate():
            employee = Employee.objects.select_for_update().get(pk=self.employee.pk)
            employee.is_active = False
            employee.deactivation_reason = "Test deactivation"
            employee.save()

        result = self.commit_while_request_waits(
            TrainingVersion, self.version.pk, lambda: self.version_request("publish"), deactivate,
        )
        self.assertEqual(result.status_code, 403)
        self.version.refresh_from_db()
        self.assertEqual(self.version.status, TrainingVersion.Status.DRAFT)
        self.assert_no_success("training.trainingversion.published", self.version)

    def test_user_deactivation_commits_before_pending_api_retirement(self):
        self.grant(VERSION_PERMISSION)
        self.assertEqual(self.version_request("publish", api=True).status_code, 200)
        result = self.commit_while_request_waits(
            TrainingVersion, self.version.pk, lambda: self.version_request("retire", api=True),
            lambda: User.objects.filter(pk=self.actor.pk).update(is_active=False),
        )
        self.assertEqual(result.status_code, 403)
        self.version.refresh_from_db()
        self.assertEqual(self.version.status, TrainingVersion.Status.PUBLISHED)
        self.assert_no_success("training.trainingversion.retired", self.version)

    def test_business_role_removal_commits_before_pending_api_freeze(self):
        coordinator, _ = Group.objects.get_or_create(name="Training Coordinator")
        self.grant(REVISION_PERMISSION, coordinator)
        result = self.commit_while_request_waits(
            Question, self.question.pk, lambda: self.freeze_request(api=True),
            lambda: update_system_user_groups(self.admin, self.actor.pk, []),
        )
        self.assertEqual(result.status_code, 403)
        self.revision.refresh_from_db()
        self.assertEqual(self.revision.status, QuestionRevision.Status.DRAFT)
        self.assert_no_success("assessments.questionrevision.frozen", self.revision)

    def test_group_permission_removal_commits_before_pending_website_freeze(self):
        group = Group.objects.create(name="Test lifecycle group")
        grant = self.grant(REVISION_PERMISSION, group)
        result = self.commit_while_request_waits(
            Question, self.question.pk, self.freeze_request, lambda: group.permissions.remove(grant),
        )
        self.assertEqual(result.status_code, 403)
        self.revision.refresh_from_db()
        self.assertEqual(self.revision.status, QuestionRevision.Status.DRAFT)
        self.assert_no_success("assessments.questionrevision.frozen", self.revision)

    def test_cached_direct_permission_cannot_authorize_publication(self):
        grant = self.grant(VERSION_PERMISSION)
        self.assertTrue(self.actor.has_perm(VERSION_PERMISSION))
        self.actor.user_permissions.remove(grant)
        self.assertTrue(self.actor.has_perm(VERSION_PERMISSION))
        with self.assertRaises(PermissionDenied):
            training_management_services.transition_version(self.actor, self.version.pk, publish=True)
        self.version.refresh_from_db()
        self.assertEqual(self.version.status, TrainingVersion.Status.DRAFT)
        self.assert_no_success("training.trainingversion.published", self.version)

    def test_admin_group_deletion_commits_before_pending_publication(self):
        group = Group.objects.create(name="Test group to delete")
        self.grant(VERSION_PERMISSION, group)

        def delete_group():
            client = Client()
            client.force_login(self.admin)
            result = client.post(reverse("admin:auth_group_delete", args=[group.pk]), {"post": "yes"})
            self.assertEqual(result.status_code, 302)

        result = self.commit_while_request_waits(
            TrainingVersion, self.version.pk, lambda: self.version_request("publish", api=True), delete_group,
        )
        self.assertEqual(result.status_code, 403)
        self.version.refresh_from_db()
        self.assertEqual(self.version.status, TrainingVersion.Status.DRAFT)
        self.assert_no_success("training.trainingversion.published", self.version)

    def test_earlier_mutation_commits_before_waiting_group_grant_removal(self):
        group = Group.objects.create(name="Test publishing group")
        grant = self.grant(VERSION_PERMISSION, group)
        audited, attempted, release = Event(), Event(), Event()

        def hold_audit(*args, **kwargs):
            event = record_event(*args, **kwargs)
            audited.set()
            if not release.wait(WAIT):
                raise AssertionError("Publication was not released.")
            return event

        with patch.object(training_management_services, "record_event", side_effect=hold_audit):
            with ThreadPoolExecutor(max_workers=2) as pool:
                publish = pool.submit(self.worker, lambda: self.version_request("publish", api=True), None)
                try:
                    self.assertTrue(audited.wait(WAIT), "Publication did not reach its transactional audit.")
                    self.assert_row_locked(Group.objects.filter(pk=group.pk))
                    self.assert_row_locked(Group.permissions.through.objects.filter(group_id=group.pk, permission_id=grant.pk))
                    self.assert_row_locked(User.groups.through.objects.filter(user_id=self.actor.pk, group_id=group.pk))
                    revoke = pool.submit(self.worker, lambda: group.permissions.remove(grant),
                                         self.observe_sql(attempted, Group.permissions.through._meta.db_table, "DELETE"))
                    self.assertTrue(attempted.wait(WAIT), "Revocation did not reach the grant row.")
                finally:
                    release.set()
                self.assertEqual(publish.result(timeout=WAIT).status_code, 200)
                revoke.result(timeout=WAIT)
        self.version.refresh_from_db()
        self.assertEqual(self.version.status, TrainingVersion.Status.PUBLISHED)
        self.assertFalse(group.permissions.filter(pk=grant.pk).exists())
        self.assertEqual(AuditLog.objects.filter(action="training.trainingversion.published", actor=self.actor).count(), 1)
        self.assertEqual(self.version_request("retire", api=True).status_code, 403)

    def test_draft_module_edit_commits_before_website_publication(self):
        self.grant(VERSION_PERMISSION)

        def edit():
            self.module.title = "Edited test module"
            self.module.save()

        result = self.commit_while_request_waits(
            TrainingVersion, self.version.pk, lambda: self.version_request("publish"), edit,
        )
        self.assertEqual(result.status_code, 302)
        self.module.refresh_from_db()
        self.assertEqual(self.module.title, "Edited test module")
        self.module.title = "Disallowed change"
        with self.assertRaises(ValidationError):
            self.module.save()
        with self.assertRaises(ValidationError):
            self.version.delete()

    def test_publication_commits_before_pending_api_draft_edit(self):
        self.grant(VERSION_PERMISSION)
        self.grant("training.change_module")

        def edit():
            client = APIClient()
            client.force_authenticate(self.actor)
            url = reverse("api:v1:management-module-detail", args=[self.version.pk, self.module.pk])
            return client.patch(url, {"title": "Late edit"}, format="json")

        result = self.commit_while_request_waits(
            TrainingVersion, self.version.pk, edit,
            lambda: self.assertEqual(self.version_request("publish").status_code, 302),
        )
        self.assertEqual(result.status_code, 404)
        self.module.refresh_from_db()
        self.assertEqual(self.module.title, "Test module")
        self.assert_no_success("training.module.updated", self.module)

    def test_pending_api_retirement_observes_committed_website_publication(self):
        outsider = User.objects.create_user(username="lifecycle-unprivileged")
        self.make_employee("UNPRIVILEGED", outsider)
        self.assertEqual(self.version_request("retire", api=True, actor=outsider).status_code, 403)
        self.assert_no_success("training.trainingversion.retired", self.version)
        self.grant(VERSION_PERMISSION)

        def publish():
            self.assertEqual(self.version_request("publish").status_code, 302)
            self.version.refresh_from_db()
            self.assertEqual(self.version.status, TrainingVersion.Status.PUBLISHED)

        result = self.commit_while_request_waits(
            TrainingVersion, self.version.pk, lambda: self.version_request("retire", api=True), publish,
        )
        self.assertEqual(result.status_code, 200)
        published_at = self.version.published_at
        self.version.refresh_from_db()
        self.assertEqual(self.version.status, TrainingVersion.Status.RETIRED)
        self.assertEqual(self.version.published_at, published_at)
        self.assertEqual(self.version.published_by_id, self.actor.pk)
        self.assertEqual(list(AuditLog.objects.filter(
            entity_type="training.trainingversion", entity_id=str(self.version.pk),
        ).order_by("pk").values_list("action", "before_data__status", "after_data__status", "actor_id")), [
            ("training.trainingversion.published", "DRAFT", "PUBLISHED", self.actor.pk),
            ("training.trainingversion.retired", "PUBLISHED", "RETIRED", self.actor.pk),
        ])
        self.module.title = "Late edit"
        with self.assertRaises(ValidationError):
            self.module.save()
        self.module.refresh_from_db()
        self.assertEqual(self.module.title, "Test module")
        with self.assertRaises(ValidationError):
            self.version.delete()

    def test_option_edit_commits_before_api_freeze(self):
        self.grant(REVISION_PERMISSION)

        def edit():
            self.option.text = "Updated answer"
            self.option.save()

        result = self.commit_while_request_waits(
            QuestionRevision, self.revision.pk, lambda: self.freeze_request(api=True), edit,
        )
        self.assertEqual(result.status_code, 200)
        self.revision.refresh_from_db()
        self.option.refresh_from_db()
        self.assertEqual(self.revision.status, QuestionRevision.Status.FROZEN)
        self.assertEqual(self.option.text, "Updated answer")
        self.option.text = "Disallowed change"
        with self.assertRaises(ValidationError):
            self.option.save()

    def test_api_freeze_commits_before_pending_website_option_editor(self):
        self.grant(REVISION_PERMISSION)

        def edit():
            client = Client()
            client.force_login(self.actor)
            return client.post(reverse("assessments:revision-update", args=[self.revision.pk]), {})

        result = self.commit_while_request_waits(
            Question, self.question.pk, edit,
            lambda: self.assertEqual(self.freeze_request(api=True).status_code, 200),
        )
        self.assertEqual(result.status_code, 404)
        self.option.refresh_from_db()
        self.assertEqual(self.option.text, "Yes")
        self.assert_no_success("assessments.questionrevision.updated", self.revision)

    def test_audit_failure_rolls_back_publication_and_event(self):
        self.grant(VERSION_PERMISSION)

        def write_then_fail(*args, **kwargs):
            record_event(*args, **kwargs)
            raise AuditWriteError("Test failure")

        with patch.object(training_management_services, "record_event", side_effect=write_then_fail):
            with self.assertRaises(AuditWriteError):
                training_management_services.transition_version(self.actor, self.version.pk, publish=True)
        self.version.refresh_from_db()
        self.assertEqual(self.version.status, TrainingVersion.Status.DRAFT)
        self.assert_no_success("training.trainingversion.published", self.version)

    def test_authorized_retirement_preserves_pinned_learner_access(self):
        self.grant(VERSION_PERMISSION)
        self.assertEqual(self.version_request("publish").status_code, 302)
        self.version.refresh_from_db()
        learner = User.objects.create_user(username="lifecycle-learner")
        group, _ = Group.objects.get_or_create(name="Employee")
        learner.groups.add(group)
        employee = self.make_employee("LEARNER", learner)
        assignment = TrainingAssignment.objects.create(
            training_version=self.version, employee=employee, assigned_by=self.admin,
            department_at_assignment=self.department, job_role_at_assignment=self.role,
        )
        self.assertEqual(self.version_request("retire", api=True).status_code, 200)
        client = Client()
        client.force_login(learner)
        self.assertEqual(client.get(reverse("training:assignment-detail", args=[assignment.pk])).status_code, 200)
        assignment.refresh_from_db()
        self.assertEqual(assignment.training_version_id, self.version.pk)
        self.version.refresh_from_db()
        self.assertEqual(self.version.status, TrainingVersion.Status.RETIRED)
