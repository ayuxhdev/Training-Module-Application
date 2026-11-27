from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from types import SimpleNamespace
from unittest import skipUnless
from unittest.mock import patch
from uuid import uuid4

from django.conf import settings
from django.core.exceptions import ValidationError
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import DatabaseError, IntegrityError, connection, connections, transaction
from django.test import Client, SimpleTestCase, TestCase, TransactionTestCase

from accounts.system_admin_services import update_system_user_groups
from assessments.models import Assessment, AssessmentQuestion, Question, QuestionOption, QuestionRevision
from certifications.models import Certificate
from certifications.services import issue_completed_assignment_certificate
from config.model_test_utils import CurriculumTestCase
from config.role_requirement_test_config import ENGINE, IntegrationConfig, validate_settings
from config.role_requirement_test_runner import require_authorized_connection
from organization.models import Employee
from training.models import (
    Lesson,
    Module,
    RoleTrainingRequirement,
    TrainingAssignment,
    TrainingVersion,
)

from .models import AuditLog
from .services import AuditWriteError, audit_snapshot, record_event


class TransactionalAuditContractTests(SimpleTestCase):
    def setUp(self):
        self.actor = get_user_model()(id=8, username="audit-actor", password="private-sentinel")
        self.target = TrainingVersion(id=14, training_id=2, version_number=1, title="Training", status="DRAFT")
        for model in (self.actor, self.target):
            model._state.adding = False
            model._state.db = "default"

    def test_synchronous_write_on_target_connection_never_registers_callback(self):
        with patch.object(transaction, "get_connection", return_value=SimpleNamespace(in_atomic_block=True)), \
                patch.object(AuditLog.objects, "db_manager") as manager, patch.object(transaction, "on_commit") as callback:
            record_event(self.actor, "training.trainingversion.published", self.target,
                         before=audit_snapshot(self.target), after={"status": "PUBLISHED"}, reason="Approved")
        manager.assert_called_once_with("default")
        manager.return_value.create.assert_called_once_with(
            actor=self.actor, actor_label_snapshot="audit-actor", action="training.trainingversion.published",
            entity_type="training.trainingversion", entity_id="14",
            before_data={"training_id": 2, "version_number": 1, "title": "Training", "status": "DRAFT"},
            after_data={"status": "PUBLISHED"}, reason="Approved",
        )
        callback.assert_not_called()

    def test_outside_transaction_cannot_write_a_required_record(self):
        with patch.object(transaction, "get_connection", return_value=SimpleNamespace(in_atomic_block=False)), \
                patch.object(AuditLog.objects, "db_manager") as manager, self.assertRaises(AuditWriteError):
            record_event(self.actor, "training.trainingversion.published", self.target)
        manager.assert_not_called()

    def test_cross_database_actor_marks_rollback_and_fails_closed(self):
        self.actor._state.db = "alternate"
        with patch.object(transaction, "get_connection", return_value=SimpleNamespace(in_atomic_block=True)), \
                patch.object(AuditLog.objects, "db_manager") as manager, patch.object(transaction, "set_rollback") as rollback, \
                self.assertRaises(AuditWriteError):
            record_event(self.actor, "training.trainingversion.published", self.target)
        manager.assert_not_called()
        rollback.assert_called_once_with(True, using="default")

    def test_audit_storage_error_marks_outer_transaction_and_uses_generic_error(self):
        for failure in (DatabaseError("private-sentinel"), ValidationError("private-sentinel")):
            with self.subTest(failure_type=type(failure).__name__), \
                    patch.object(transaction, "get_connection", return_value=SimpleNamespace(in_atomic_block=True)), \
                    patch.object(AuditLog.objects, "db_manager") as manager, patch.object(transaction, "set_rollback") as rollback:
                manager.return_value.create.side_effect = failure
                with self.assertRaisesMessage(AuditWriteError, "Required audit event could not be saved.") as caught:
                    record_event(self.actor, "training.trainingversion.published", self.target)
                self.assertNotIn("private-sentinel", str(caught.exception))
                rollback.assert_called_once_with(True, using="default")

    def test_password_change_audit_has_no_credential_snapshot(self):
        self.assertEqual(audit_snapshot(self.actor), {})
        with patch.object(transaction, "get_connection", return_value=SimpleNamespace(in_atomic_block=True)), \
                patch.object(AuditLog.objects, "db_manager") as manager:
            record_event(self.actor, "auth.password.changed", self.actor)
        values = manager.return_value.create.call_args.kwargs
        self.assertEqual(values["before_data"], {})
        self.assertEqual(values["after_data"], {})
        self.assertEqual(values["reason"], "")
        self.assertNotIn("private-sentinel", repr(values))


class AuditLogTests(TestCase):
    def log(self):
        return AuditLog.objects.create(actor_label_snapshot="System", action="training.published",
                                       entity_type="training.trainingversion", entity_id="1",
                                       before_data={"status": "DRAFT"}, after_data={"status": "PUBLISHED"})

    def test_system_event_without_user(self):
        log = self.log()
        self.assertIsNone(log.actor)
        self.assertEqual(log.after_data["status"], "PUBLISHED")

    def test_instance_and_queryset_mutations_rejected(self):
        log = self.log()
        log.reason = "Rewrite history"
        with self.assertRaises(ValidationError):
            log.save()
        with self.assertRaises(ValidationError):
            log.delete()
        with self.assertRaises(ValidationError):
            AuditLog.objects.update(action="changed")
        with self.assertRaises(ValidationError):
            AuditLog.objects.all().delete()
        with self.assertRaises(ValidationError):
            AuditLog.objects.bulk_create([AuditLog(actor_label_snapshot="System", action="x", entity_type="x", entity_id="1")])

    def test_event_participates_in_caller_transaction(self):
        with self.assertRaises(RuntimeError):
            with transaction.atomic():
                self.log()
                raise RuntimeError("Business operation failed")
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_reconstructed_instance_cannot_overwrite_event(self):
        log = self.log()
        replacement = AuditLog(pk=log.pk, actor_label_snapshot="System", action="rewrite",
                               entity_type=log.entity_type, entity_id=log.entity_id)
        with self.assertRaises((ValidationError, IntegrityError)), transaction.atomic():
            replacement.save()
        log.refresh_from_db()
        self.assertEqual(log.action, "training.published")


class AuditWorkflowTests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        Group.objects.get(name="Administrator").user_set.add(cls.user)
        Group.objects.get(name="Employee").user_set.add(cls.employee_user)

    def client_for(self, user):
        client = Client()
        client.force_login(user)
        return client

    def audited_post(self, client, path, data=None):
        with self.captureOnCommitCallbacks(execute=True):
            return client.post(path, data)

    def employee_data(self, code, name):
        return {
            "employee_code": code,
            "display_name": name,
            "user": "",
            "department": self.department.pk,
            "job_role": self.role.pk,
            "reporting_manager": "",
            "date_joined": self.now.date().isoformat(),
        }

    def test_repeated_employee_deactivation_keeps_original_reason_and_one_event(self):
        client = self.client_for(self.user)
        path = f"/employees/{self.employee.pk}/deactivate/"
        self.assertEqual(self.audited_post(client, path, {"reason": "Employment ended"}).status_code, 302)
        self.assertEqual(self.audited_post(client, path, {"reason": "Retry changed reason"}).status_code, 409)
        self.employee.refresh_from_db()
        self.assertEqual(self.employee.deactivation_reason, "Employment ended")
        self.assertEqual(AuditLog.objects.filter(
            action="organization.employee.deactivated", entity_id=str(self.employee.pk),
        ).count(), 1)

    def test_employee_department_and_assignment_mutations_are_audited_safely(self):
        client = self.client_for(self.user)
        payload = self.employee_data("GN-AUDIT-1", "Audit employee")
        payload.update({
            "actor": "9999",
            "actor_label_snapshot": "Forged actor",
            "occurred_at": "2000-01-01T00:00:00Z",
            "password": "request-secret",
        })
        response = self.audited_post(client, "/employees/new/", payload)
        self.assertEqual(response.status_code, 302)
        employee = Employee.objects.get(employee_code="GN-AUDIT-1")
        created = AuditLog.objects.get(entity_type="organization.employee", entity_id=str(employee.pk))
        self.assertEqual(created.action, "organization.employee.created")
        self.assertEqual(created.actor, self.user)
        self.assertEqual(created.actor_label_snapshot, self.user.get_username())
        self.assertNotIn("request-secret", str(created.before_data) + str(created.after_data))
        self.assertNotIn("password", str(created.before_data) + str(created.after_data))

        payload = self.employee_data(employee.employee_code, "Updated audit employee")
        self.assertEqual(self.audited_post(client, f"/employees/{employee.pk}/edit/", payload).status_code, 302)
        updated = AuditLog.objects.get(action="organization.employee.updated", entity_id=str(employee.pk))
        self.assertEqual(updated.before_data["display_name"], "Audit employee")
        self.assertEqual(updated.after_data["display_name"], "Updated audit employee")
        self.assertEqual(self.audited_post(client,
            f"/employees/{employee.pk}/deactivate/", {"reason": "Employment ended"},
        ).status_code, 302)
        deactivation_event = AuditLog.objects.get(
            action="organization.employee.deactivated", entity_id=str(employee.pk),
        )
        self.assertFalse(deactivation_event.after_data["is_active"])
        self.assertEqual(deactivation_event.reason, "")

        before_count = AuditLog.objects.filter(action="organization.employee.created").count()
        self.assertEqual(self.audited_post(client, "/employees/new/", self.employee_data(employee.employee_code, "Duplicate")).status_code, 200)
        self.assertEqual(AuditLog.objects.filter(action="organization.employee.created").count(), before_count)

        department_response = self.audited_post(client, "/departments/new/", {
            "code": "AUDIT-DEPT", "name": "Audit department", "description": "", "is_active": "on",
        })
        self.assertEqual(department_response.status_code, 302)
        self.assertTrue(AuditLog.objects.filter(action="organization.department.created").exists())

        assigned_employee = Employee.objects.create(
            employee_code="GN-AUDIT-2", display_name="Assignment target",
            department=self.department, job_role=self.role, date_joined=self.now.date(),
        )
        assignment_response = self.audited_post(client, "/assignments/new/", {
            "employee": assigned_employee.pk,
            "training_version": self.version.pk,
            "due_date": "",
            "status": "COMPLETED",
        })
        self.assertEqual(assignment_response.status_code, 302)
        assignment = TrainingAssignment.objects.get(employee=assigned_employee)
        assignment_event = AuditLog.objects.get(
            action="training.trainingassignment.created", entity_id=str(assignment.pk),
        )
        self.assertEqual(assignment_event.actor, self.user)
        self.assertEqual(assignment_event.after_data["status"], TrainingAssignment.Status.ASSIGNED)

        requirement = RoleTrainingRequirement.objects.create(
            job_role=self.role, training_version=self.version, created_by=self.user, due_in_days=14,
        )
        Employee.objects.create(
            employee_code="GN-AUDIT-3", display_name="Role assignment target",
            department=self.department, job_role=self.role, date_joined=self.now.date(),
        )
        self.assertEqual(self.audited_post(client, "/assignments/role/new/", {"role_requirement": requirement.pk}).status_code, 302)
        batch_event = AuditLog.objects.get(action="training.role_assignment.batch_created")
        self.assertEqual(batch_event.actor, self.user)
        self.assertGreaterEqual(batch_event.after_data["created_count"], 1)
        self.assertGreaterEqual(batch_event.after_data["skipped_count"], 1)

    def test_publish_and_retire_are_audited_only_after_successful_post(self):
        client = self.client_for(self.user)
        self.assertEqual(self.audited_post(client, "/questions/new/", {
            "code": "AUDIT-Q", "topic": "Safety", "is_active": "on",
        }).status_code, 302)
        question = Question.objects.get(code="AUDIT-Q")
        revision = question.revisions.get()
        self.assertTrue(AuditLog.objects.filter(action="assessments.question.created", entity_id=str(question.pk)).exists())
        self.assertTrue(AuditLog.objects.filter(action="assessments.questionrevision.created", entity_id=str(revision.pk)).exists())

        self.assertEqual(self.audited_post(client, f"/trainings/{self.training.pk}/versions/new/", {
            "version_number": 2, "title": "Audit version",
        }).status_code, 302)
        version = TrainingVersion.objects.get(training=self.training, version_number=2)
        self.assertTrue(AuditLog.objects.filter(
            action="training.trainingversion.created", entity_id=str(version.pk),
        ).exists())
        self.assertEqual(self.audited_post(client, f"/versions/{version.pk}/modules/new/", {
            "title": "Module", "position": 1,
        }).status_code, 302)
        module = Module.objects.get(training_version=version)
        self.assertTrue(AuditLog.objects.filter(action="training.module.created", entity_id=str(module.pk)).exists())
        self.assertEqual(self.audited_post(client, f"/modules/{module.pk}/lessons/new/", {
            "title": "Lesson", "position": 1, "content_type": "TEXT", "body": "Read",
            "minimum_watch_percent": "90",
        }).status_code, 302)
        lesson = Lesson.objects.get(module=module)
        self.assertTrue(AuditLog.objects.filter(action="training.lesson.created", entity_id=str(lesson.pk)).exists())
        self.assertEqual(self.audited_post(client, f"/lessons/{lesson.pk}/edit/", {
            "title": "Lesson", "position": 1, "content_type": "TEXT", "body": "Changed read",
            "minimum_watch_percent": "90", "is_required": "on",
        }).status_code, 302)
        lesson_update = AuditLog.objects.get(action="training.lesson.updated", entity_id=str(lesson.pk))
        self.assertIn("body", lesson_update.after_data["changed_fields"])
        self.assertNotIn("Changed read", str(lesson_update.before_data) + str(lesson_update.after_data))
        assessment = Assessment.objects.create(
            training_version=version, kind=Assessment.Kind.FINAL, title="Final assessment",
        )
        self.assertEqual(self.audited_post(client, f"/assessments/{assessment.pk}/questions/new/", {
            "question_revision": self.revision.pk, "position": 1, "points": "2.00",
        }).status_code, 302)
        assessment_question = AssessmentQuestion.objects.get(assessment=assessment)
        self.assertTrue(AuditLog.objects.filter(
            action="assessments.assessmentquestion.created", entity_id=str(assessment_question.pk),
        ).exists())
        before_count = AuditLog.objects.count()
        self.assertEqual(client.get(f"/versions/{version.pk}/publish/").status_code, 404)
        self.assertEqual(AuditLog.objects.count(), before_count)
        self.assertEqual(self.audited_post(client, f"/versions/{version.pk}/publish/").status_code, 302)
        self.assertTrue(AuditLog.objects.filter(
            action="training.trainingversion.published", entity_id=str(version.pk),
            before_data__status=TrainingVersion.Status.DRAFT,
            after_data__status=TrainingVersion.Status.PUBLISHED,
        ).exists())
        self.assertEqual(self.audited_post(client, f"/versions/{version.pk}/publish/").status_code, 404)
        self.assertEqual(AuditLog.objects.filter(
            action="training.trainingversion.published", entity_id=str(version.pk),
        ).count(), 1)
        self.assertEqual(self.audited_post(client, f"/versions/{version.pk}/retire/").status_code, 302)
        self.assertTrue(AuditLog.objects.filter(
            action="training.trainingversion.retired", entity_id=str(version.pk),
            before_data__status=TrainingVersion.Status.PUBLISHED,
            after_data__status=TrainingVersion.Status.RETIRED,
        ).exists())
        self.assertEqual(self.audited_post(client, f"/versions/{version.pk}/retire/").status_code, 404)
        self.assertEqual(AuditLog.objects.filter(
            action="training.trainingversion.retired", entity_id=str(version.pk),
        ).count(), 1)

    def test_attempt_completion_and_certificate_lifecycle_are_audited_once(self):
        self.complete_lessons()
        self.finish_attempt(self.quiz)
        client = self.client_for(self.employee_user)
        start_response = self.audited_post(client,
            f"/assignments/{self.assignment.pk}/assessments/{self.final.pk}/start/",
        )
        self.assertEqual(start_response.status_code, 302)
        attempt = self.assignment.attempts.get(assessment=self.final)
        self.assertEqual(self.audited_post(client,
            f"/attempts/{attempt.pk}/submit/", {f"answer_{self.final_item.pk}": self.correct_option.pk},
        ).status_code, 302)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, TrainingAssignment.Status.COMPLETED)
        certificate = Certificate.objects.get(assignment=self.assignment)
        self.assertEqual(certificate.issued_by, self.employee_user)
        for action in (
            "assessments.attempt.started",
            "assessments.attempt.submitted",
            "training.trainingassignment.completed",
            "certifications.certificate.issued",
        ):
            with self.subTest(action=action):
                event = AuditLog.objects.get(action=action)
                self.assertEqual(event.actor, self.employee_user)
        self.assertNotIn("selected_option", str(AuditLog.objects.filter(action="assessments.attempt.submitted").values_list("after_data", flat=True)))

        issue_completed_assignment_certificate(self.assignment.pk, actor=self.user)
        self.assertEqual(AuditLog.objects.filter(action="certifications.certificate.issued").count(), 1)
        coordinator_client = self.client_for(self.user)
        before_revoke_events = AuditLog.objects.filter(action="certifications.certificate.revoked").count()
        self.assertEqual(coordinator_client.post(
            f"/certificates/{certificate.pk}/revoke/", {"reason": "x" * 1001},
        ).status_code, 400)
        self.assertEqual(AuditLog.objects.filter(action="certifications.certificate.revoked").count(), before_revoke_events)
        certificate.refresh_from_db()
        self.assertIsNone(certificate.revoked_at)
        self.assertEqual(coordinator_client.get(f"/certificates/{certificate.pk}/revoke/").status_code, 405)
        self.assertEqual(self.audited_post(coordinator_client,
            f"/certificates/{certificate.pk}/revoke/", {"reason": "Issued in error"},
        ).status_code, 302)
        self.assertEqual(AuditLog.objects.filter(
            action="certifications.certificate.revoked", entity_id=str(certificate.pk),
            reason="Issued in error", actor=self.user,
        ).count(), 1)

    def test_audit_ui_is_read_only_and_restricted_to_admin_and_coordinator(self):
        event = AuditLog.objects.create(
            actor=self.user, actor_label_snapshot=self.user.get_username(), action="test.event",
            entity_type="training.trainingversion", entity_id=str(self.version.pk),
            after_data={"status": "PUBLISHED"},
        )
        known_event = AuditLog.objects.create(
            actor=self.user,
            actor_label_snapshot=self.user.get_username(),
            action="training.trainingversion.published",
            entity_type="training.trainingversion",
            entity_id=str(self.version.pk),
            before_data={"status": "DRAFT"},
            after_data={"status": "PUBLISHED", "changed_fields": ["status"]},
            reason="<b>Approved & verified</b>",
            request_id=uuid4(),
        )
        client = self.client_for(self.user)
        filtered = client.get(
            "/audit/?action=test.event&target_type=training.trainingversion"
        )
        self.assertEqual(filtered.status_code, 200)
        self.assertContains(filtered, '<form method="get" class="form-stack audit-filter-form">', html=False)
        self.assertContains(filtered, 'aria-label="Audit history results"')
        self.assertContains(filtered, "Clear filters")
        self.assertEqual(list(filtered.context["audit_logs"]), [event])
        self.assertContains(filtered, "Performed by")
        self.assertContains(filtered, "From date")
        self.assertContains(filtered, "Through date")
        self.assertContains(filtered, "Record type")
        self.assertContains(filtered, "System events are not included.")

        presentation = client.get("/audit/")
        self.assertEqual(presentation.status_code, 200)
        rendered = presentation.content.decode()
        self.assertContains(presentation, "Training version published")
        self.assertContains(presentation, "Training version")
        self.assertContains(presentation, "Draft")
        self.assertContains(presentation, "Published")
        self.assertContains(presentation, "Status")
        self.assertContains(presentation, "View complete event details")
        self.assertGreater(
            rendered.index("training.trainingversion.published"),
            rendered.index("View complete event details"),
        )
        self.assertContains(presentation, "&quot;status&quot;: &quot;PUBLISHED&quot;")
        self.assertNotContains(presentation, "{'status': 'DRAFT'}")
        self.assertContains(presentation, "&lt;b&gt;Approved &amp; verified&lt;/b&gt;")
        self.assertNotContains(presentation, "<b>Approved & verified</b>")
        self.assertContains(presentation, str(known_event.request_id))

        coordinator = get_user_model().objects.create_user(username="audit-coordinator")
        Group.objects.get(name="Training Coordinator").user_set.add(coordinator)
        self.assertEqual(self.client_for(coordinator).get("/audit/").status_code, 200)
        for name, user in (("Employee", self.employee_user), ("Manager", get_user_model().objects.create_user(username="audit-manager"))):
            if name == "Manager":
                Group.objects.get(name="Manager").user_set.add(user)
            with self.subTest(role=name):
                self.assertEqual(self.client_for(user).get("/audit/").status_code, 403)
        self.assertEqual(Client().get("/audit/").status_code, 302)
        self.assertEqual(self.client_for(self.user).get("/audit/?start_date=not-a-date").status_code, 400)
        self.assertEqual(self.client_for(self.user).get("/audit/not-an-id/").status_code, 404)
        self.assertEqual(self.client_for(self.user).get(f"/audit/{event.pk}/edit/").status_code, 404)
        self.assertEqual(self.client_for(self.user).post(f"/audit/{event.pk}/delete/").status_code, 404)

    def test_rolled_back_business_transaction_does_not_leave_audit_event(self):
        with self.assertRaises(RuntimeError):
            with transaction.atomic():
                record_event(
                    self.user, "training.training.updated", self.training,
                    before={"catalog_title": self.training.catalog_title},
                    after={"catalog_title": "Rolled back"},
                )
                self.assertTrue(AuditLog.objects.filter(action="training.training.updated").exists())
                raise RuntimeError("rollback")
        self.assertFalse(AuditLog.objects.filter(action="training.training.updated").exists())

    def test_failed_issuance_audit_rolls_back_certificate_and_allows_idempotent_retry(self):
        self.complete_assignment()
        action = "certifications.certificate.issued"
        with patch.object(AuditLog, "save", side_effect=IntegrityError("Simulated audit failure")):
            with self.assertRaises(AuditWriteError):
                issue_completed_assignment_certificate(self.assignment.pk, actor=self.user)
        self.assertFalse(Certificate.objects.filter(assignment=self.assignment).exists())
        self.assertFalse(AuditLog.objects.filter(action=action).exists())
        issued = issue_completed_assignment_certificate(self.assignment.pk, actor=self.user)
        self.assertEqual(issue_completed_assignment_certificate(self.assignment.pk, actor=self.user).pk, issued.pk)
        self.assertEqual(AuditLog.objects.filter(action=action, entity_id=str(issued.pk)).count(), 1)

    def test_inner_savepoint_rollback_removes_business_change_and_its_audit_only(self):
        client = self.client_for(self.user)
        path = f"/versions/{self.version.pk}/retire/"
        with transaction.atomic():
            record_event(self.user, "test.outer", self.training)
            with transaction.atomic():
                self.assertEqual(client.post(path).status_code, 302)
                self.assertTrue(AuditLog.objects.filter(action="training.trainingversion.retired").exists())
                transaction.set_rollback(True)
            self.version.refresh_from_db()
            self.assertEqual(self.version.status, TrainingVersion.Status.PUBLISHED)
            self.assertEqual(list(AuditLog.objects.values_list("action", flat=True)), ["test.outer"])

    def test_website_audit_insert_failure_rolls_back_lifecycle_and_form_saves(self):
        draft = QuestionRevision.objects.create(question=self.question, revision_number=2, prompt="Practice?", created_by=self.user)
        QuestionOption.objects.create(question_revision=draft, text="Yes", position=1, is_correct=True)
        QuestionOption.objects.create(question_revision=draft, text="No", position=2)
        client = self.client_for(self.user)
        operations = (
            (f"/versions/{self.version.pk}/retire/", {}, self.version, "status", TrainingVersion.Status.PUBLISHED),
            (f"/revisions/{draft.pk}/freeze/", {}, draft, "status", QuestionRevision.Status.DRAFT),
            (f"/trainings/{self.training.pk}/edit/",
             {"code": self.training.code, "catalog_title": "Rejected", "is_active": "on"},
             self.training, "catalog_title", self.training.catalog_title),
        )
        for path, data, entity, field, expected in operations:
            with self.subTest(path=path), patch.object(AuditLog, "save", side_effect=IntegrityError("Simulated write failure")):
                with self.assertRaises(AuditWriteError):
                    client.post(path, data)
                entity.refresh_from_db()
                self.assertEqual(getattr(entity, field), expected)
        self.assertFalse(AuditLog.objects.exists())

    def test_failed_group_change_audit_restores_membership(self):
        actor = get_user_model().objects.create_user(username="audit-superuser", is_superuser=True)
        group = Group.objects.get(name="Trainer")
        with patch.object(AuditLog, "save", side_effect=IntegrityError("Simulated audit failure")):
            with self.assertRaises(AuditWriteError):
                update_system_user_groups(actor, self.employee_user.pk, [group])
        self.assertFalse(self.employee_user.groups.filter(pk=group.pk).exists())
        self.assertFalse(AuditLog.objects.filter(action="accounts.user.groups_changed").exists())


@skipUnless(
    settings.DATABASES.get("default", {}).get("ENGINE") == ENGINE and hasattr(settings, "INTEGRATION_TEST_CONFIG"),
    "Requires the explicitly approved guarded integration test profile.",
)
class AuditTransactionConcurrencyTests(TransactionTestCase):
    @classmethod
    def _pre_setup(cls):
        if type(validate_settings(settings)) is not IntegrationConfig:
            raise RuntimeError("These tests require the guarded integration profile.")
        require_authorized_connection(connection)
        super()._pre_setup()

    def test_concurrent_same_group_change_commits_one_business_change_and_one_audit(self):
        users = get_user_model().objects
        actor = users.create_user(username="audit-race-admin", is_superuser=True)
        target = users.create_user(username="audit-race-target")
        group, _ = Group.objects.get_or_create(name="Trainer")
        ready = Barrier(2)

        def worker():
            try:
                ready.wait(timeout=10)
                return update_system_user_groups(actor, target.pk, [group])
            finally:
                connections.close_all()

        with ThreadPoolExecutor(max_workers=2) as workers:
            pending = [workers.submit(worker) for _ in range(2)]
            self.assertEqual(sorted(job.result(timeout=25) for job in pending), [False, True])
        self.assertEqual(list(target.groups.values_list("pk", flat=True)), [group.pk])
        event = AuditLog.objects.get(action="accounts.user.groups_changed", entity_id=str(target.pk))
        self.assertEqual(event.actor_id, actor.pk)
