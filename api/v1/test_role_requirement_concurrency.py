"""Real MySQL serialization with owned, committed fixtures and no flush."""

from concurrent.futures import ThreadPoolExecutor
from threading import Event, local
from unittest.mock import patch

from django.contrib.auth.models import Permission
from django.db import connection, models
from django.utils import timezone
from rest_framework.test import APIClient

from assessments.models import Assessment, AssessmentQuestion, Question, QuestionOption, QuestionRevision
from audit.models import AuditLog
from notifications.models import Notification
from organization.models import Employee
from training.models import Lesson, Module, RoleTrainingRequirement, Training, TrainingAssignment, TrainingVersion

from .test_m21_concurrency import MySQLConcurrencyFixtures


class RoleRequirementConcurrencyTests(MySQLConcurrencyFixtures):
    def setUp(self):
        # Stronger than the shared prefix guard: only the approved isolated DB.
        self.assertEqual(connection.settings_dict["NAME"], "test_gardens_training")
        super().setUp()
        self.ids = {}
        self.actor = self.create_user("global")
        self.addCleanup(self.cleanup_curriculum)
        self.actor.user_permissions.add(*Permission.objects.filter(
            content_type__app_label="training", codename__in=(
                "add_trainingassignment", "add_roletrainingrequirement", "change_roletrainingrequirement",
            ),
        ))
        self.recipient = self.remember(Employee.objects.create(
            employee_code=self.marker + "-R", display_name="Recipient", department_id=self.department_id,
            job_role_id=self.role_id, date_joined=timezone.localdate(),
        ))
        self.training = self.remember(Training.objects.create(code=self.marker, catalog_title="Role race", created_by=self.actor))
        self.version = self.remember(TrainingVersion.objects.create(
            training=self.training, version_number=1, title="Role race v1", created_by=self.actor,
        ))
        module = self.remember(Module.objects.create(training_version=self.version, title="Read", position=1))
        self.remember(Lesson.objects.create(module=module, title="Read", position=1, content_type="TEXT", body="Fixture"))
        question = self.remember(Question.objects.create(code=self.marker, topic="Fixture", created_by=self.actor))
        revision = self.remember(QuestionRevision.objects.create(question=question, revision_number=1, prompt="Fixture?", created_by=self.actor))
        self.remember(QuestionOption.objects.create(question_revision=revision, text="Yes", position=1, is_correct=True))
        self.remember(QuestionOption.objects.create(question_revision=revision, text="No", position=2))
        revision.status, revision.frozen_at = "FROZEN", timezone.now()
        revision.save()
        final = self.remember(Assessment.objects.create(training_version=self.version, kind="FINAL", title="Final"))
        self.remember(AssessmentQuestion.objects.create(assessment=final, question_revision=revision, position=1))
        self.version.status, self.version.published_at, self.version.published_by = "PUBLISHED", timezone.now(), self.actor
        self.version.save()
        self.requirement = self.remember(RoleTrainingRequirement.objects.create(
            job_role_id=self.role_id, training_version=self.version, created_by=self.actor,
        ))
        self.detail = f"/api/v1/management/role-requirements/{self.requirement.pk}/"

    def remember(self, instance):
        self.ids.setdefault(type(instance), []).append(instance.pk)
        return instance

    def cleanup_curriculum(self):
        versions = self.ids.get(TrainingVersion, [])
        assignments = TrainingAssignment.objects.filter(training_version_id__in=versions)
        models.QuerySet(Notification, using="default").filter(assignment_id__in=assignments.values("pk"))._raw_delete("default")
        models.QuerySet(TrainingAssignment, using="default").filter(training_version_id__in=versions)._raw_delete("default")
        # A duplicate-create race may add one additional owned requirement.
        models.QuerySet(RoleTrainingRequirement, using="default").filter(training_version_id__in=versions)._raw_delete("default")
        for model in (AssessmentQuestion, Assessment, Lesson, Module, TrainingVersion, Training,
                      QuestionOption, QuestionRevision, Question, Employee):
            models.QuerySet(model, using="default").filter(pk__in=self.ids.get(model, []))._raw_delete("default")
        self.actor.user_permissions.clear()

    def request(self, action):
        self.assertEqual(connection.settings_dict["NAME"], "test_gardens_training")
        with connection.cursor() as cursor:
            cursor.execute("SELECT DATABASE()")
            self.assertEqual(cursor.fetchone(), ("test_gardens_training",))
        client = APIClient()
        client.force_authenticate(self.actor)
        if action == "batch":
            return client.post(self.detail + "assignments/", {}, format="json")
        if action == "disable":
            return client.patch(self.detail, {"is_active": False}, format="json")
        if action == "manual":
            return client.post("/api/v1/management/assignments/", {
                "employee_id": self.recipient.pk, "training_version_id": self.version.pk,
            }, format="json")
        return client.post("/api/v1/management/role-requirements/", {
            "job_role_id": self.role_id, "training_version_id": self.version.pk,
        }, format="json")

    def overlap(self, first_action, second_action, model, blocked_table):
        held, boundary, finished, release = (Event() for _ in range(4))
        thread = local()
        original = model.save

        def hold(instance, *args, **kwargs):
            result = original(instance, *args, **kwargs)
            if getattr(thread, "role", None) == "first" and not held.is_set():
                # Nested model save returned, but the API service/form's outer
                # atomic transaction still holds the root and written-row locks.
                self.assertTrue(connection.in_atomic_block)
                held.set()
                if not release.wait(15):
                    raise AssertionError("First transaction was not released")
            return result

        def observe(execute, sql, params, many, context):
            if "FOR UPDATE" in sql.upper() and blocked_table in sql.lower():
                boundary.set()
            return execute(sql, params, many, context)

        def call(role, action):
            thread.role = role
            try:
                return self.worker(lambda: self.request(action), observe if role == "second" else None)
            finally:
                if role == "second":
                    finished.set()

        with patch.object(model, "save", hold), ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(call, "first", first_action)
            try:
                self.assertTrue(held.wait(15), "First transaction did not reach its held write")
                second = pool.submit(call, "second", second_action)
                self.assertTrue(boundary.wait(15), "Second request did not attempt the root lock")
                finished_while_locked = finished.wait(1)
            finally:
                release.set()
            responses = first.result(20), second.result(20)
        self.assertFalse(finished_while_locked, "Second request finished while root lock was held")
        return responses

    def test_duplicate_batches_serialize_and_emit_one_notification_per_assignment(self):
        first, second = self.overlap("batch", "batch", TrainingAssignment, "organization_employee")
        self.assertEqual((first.status_code, second.status_code), (200, 200), (first.data, second.data))
        self.assertEqual((first.data["created_count"], second.data["created_count"]), (2, 0))
        self.assertEqual(TrainingAssignment.objects.filter(training_version=self.version).count(), 2)
        self.assertEqual(Notification.objects.filter(assignment__training_version=self.version).count(), 2)
        self.assertEqual(AuditLog.objects.filter(actor=self.actor, action="training.role_assignment.batch_created").count(), 1)

    def test_disabling_first_prevents_batch_without_partial_writes(self):
        first, second = self.overlap("disable", "batch", RoleTrainingRequirement, "training_trainingversion")
        self.assertEqual((first.status_code, second.status_code), (200, 400), (first.data, second.data))
        self.assertFalse(TrainingAssignment.objects.filter(training_version=self.version).exists())
        self.assertFalse(Notification.objects.filter(assignment__training_version=self.version).exists())
        self.assertFalse(AuditLog.objects.filter(actor=self.actor, action="training.role_assignment.batch_created").exists())

    def test_batch_first_completes_before_requirement_is_disabled(self):
        first, second = self.overlap("batch", "disable", TrainingAssignment, "training_trainingversion")
        self.assertEqual((first.status_code, second.status_code), (200, 200), (first.data, second.data))
        self.requirement.refresh_from_db()
        self.assertFalse(self.requirement.is_active)
        self.assertEqual(TrainingAssignment.objects.filter(training_version=self.version).count(), 2)

    def test_manual_first_remains_pinned_and_batch_skips_it(self):
        first, second = self.overlap("manual", "batch", TrainingAssignment, "organization_employee")
        self.assertEqual((first.status_code, second.status_code), (201, 200), (first.data, second.data))
        self.assertEqual(second.data["created_count"], 1)
        assignment = TrainingAssignment.objects.get(employee=self.recipient, training_version=self.version)
        self.assertEqual((assignment.source, assignment.role_requirement_id), ("MANUAL", None))
        self.assertEqual(Notification.objects.filter(assignment__training_version=self.version).count(), 2)

    def test_batch_first_causes_manual_duplicate_validation_not_overwrite(self):
        first, second = self.overlap("batch", "manual", TrainingAssignment, "organization_employee")
        self.assertEqual((first.status_code, second.status_code), (200, 400), (first.data, second.data))
        assignment = TrainingAssignment.objects.get(employee=self.recipient, training_version=self.version)
        self.assertEqual((assignment.source, assignment.role_requirement_id), ("ROLE", self.requirement.pk))
        self.assertEqual(Notification.objects.filter(assignment__training_version=self.version).count(), 2)

    def test_concurrent_requirement_creation_preserves_unique_pair(self):
        # Remove only this disposable fixture to race two valid creates.
        models.QuerySet(RoleTrainingRequirement, using="default").filter(pk=self.requirement.pk)._raw_delete("default")
        first, second = self.overlap("create", "create", RoleTrainingRequirement, "training_trainingversion")
        self.assertEqual((first.status_code, second.status_code), (201, 400), (first.data, second.data))
        self.assertEqual(RoleTrainingRequirement.objects.filter(training_version=self.version).count(), 1)
        self.assertEqual(AuditLog.objects.filter(actor=self.actor, action="training.roletrainingrequirement.created").count(), 1)
