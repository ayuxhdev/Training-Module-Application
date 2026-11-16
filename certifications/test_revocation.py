"""Website revocation contracts and disposable-MySQL transaction regressions.

Only WebsiteRevocationContractTests is database-free. The integration and
concurrency classes require explicitly approved disposable MySQL, never a
preserved development, test or QA database. No flush-based fixture cleanup.
"""

from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Event
from types import SimpleNamespace
from unittest.mock import Mock, patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import DatabaseError, connection, models, transaction
from django.test import Client, RequestFactory, SimpleTestCase, override_settings
from django.urls import include, path
from django.utils import timezone

from assessments.models import (
    Assessment, AssessmentAttempt, AssessmentQuestion, AttemptAnswer,
    Question, QuestionOption, QuestionRevision,
)
from audit.models import AuditLog
from api.v1.test_m21_concurrency import MySQLConcurrencyFixtures
from config.model_test_utils import CurriculumTestCase
from training.models import Lesson, LessonProgress, Module, Training, TrainingAssignment, TrainingVersion

from . import views
from .models import Certificate


urlpatterns = [path("certificates/", include("certifications.urls"))]


@override_settings(ROOT_URLCONF=__name__)
class WebsiteRevocationContractTests(SimpleTestCase):
    def setUp(self):
        self.factory = RequestFactory()
        self.actor = SimpleNamespace(
            pk=12, is_authenticated=True, is_active=True, is_superuser=False,
            has_perm=lambda permission: permission == views.CHANGE_CERTIFICATES_PERMISSION,
            get_username=lambda: "website-revoker",
        )
        self.certificate = SimpleNamespace(
            pk=7, assignment_id=15, revoked_at=None, save=Mock(),
            _meta=SimpleNamespace(label_lower="certifications.certificate"),
        )
        self.order = []
        self.inside_transaction = False

    @contextmanager
    def mocks(self):
        @contextmanager
        def atomic():
            self.inside_transaction = True
            try:
                yield
            finally:
                self.inside_transaction = False

        def resolve(queryset, **kwargs):
            self.order.append((queryset.model, queryset.query.select_for_update))
            return self.certificate if queryset.model is Certificate else SimpleNamespace(pk=15)

        users = Mock()
        users.objects.filter.return_value.first.return_value = self.actor
        with patch.object(views.transaction, "atomic", atomic), \
             patch.object(views, "get_object_or_404", side_effect=resolve) as lookup, \
             patch.object(views, "get_user_model", return_value=users, create=True), \
             patch.object(AuditLog.objects, "create") as audit, \
             patch("audit.services.transaction.on_commit") as deferred:
            yield lookup, audit, deferred, users

    def request(self, reason=" Issued in error ", actor=None):
        request = self.factory.post("/certificates/7/revoke/", {"reason": reason})
        request.user = actor or self.actor
        return request

    def test_audit_failure_propagates_inside_transaction_instead_of_being_deferred(self):
        with self.mocks() as (_, audit, deferred, _):
            def fail(**kwargs):
                self.assertTrue(self.inside_transaction)
                raise DatabaseError("Audit unavailable")

            audit.side_effect = fail
            with self.assertRaisesRegex(DatabaseError, "Audit unavailable"):
                views.revoke_certificate(self.request(), 7)
            audit.assert_called_once()
            deferred.assert_not_called()

    def test_success_writes_one_server_derived_event_before_transaction_exit(self):
        with self.mocks() as (_, audit, deferred, users):
            audit.side_effect = lambda **kwargs: self.assertTrue(self.inside_transaction)
            response = views.revoke_certificate(self.request(), 7)
            self.assertEqual(response.status_code, 302)
            self.assertEqual(response.url, "/certificates/7/")
            self.certificate.save.assert_called_once_with()
            users.objects.filter.assert_called_once_with(pk=12, is_active=True)
            audit.assert_called_once_with(
                actor=self.actor, actor_label_snapshot="website-revoker",
                action="certifications.certificate.revoked", entity_type="certifications.certificate",
                entity_id="7", before_data={"revoked_at": None},
                after_data={"revoked_at": self.certificate.revoked_at.isoformat(), "revoked_by_id": 12},
                reason="Issued in error",
            )
            deferred.assert_not_called()
        self.assertEqual(self.order, [(Certificate, False), (TrainingAssignment, True), (Certificate, True)])

    def test_duplicate_returns_409_without_save_or_audit(self):
        self.certificate.revoked_at = timezone.now()
        with self.mocks() as (_, audit, deferred, _):
            self.assertEqual(views.revoke_certificate(self.request(), 7).status_code, 409)
            self.certificate.save.assert_not_called()
            audit.assert_not_called()
            deferred.assert_not_called()

    def test_certificate_validation_failure_returns_400_without_audit(self):
        self.certificate.save.side_effect = ValidationError("Historical data is immutable")
        with self.mocks() as (_, audit, deferred, _):
            self.assertEqual(views.revoke_certificate(self.request(), 7).status_code, 400)
            audit.assert_not_called()
            deferred.assert_not_called()

    def test_permission_loss_or_deactivation_after_lock_wait_denies_mutation(self):
        for actor in (None, SimpleNamespace(is_superuser=False, has_perm=lambda permission: False)):
            with self.subTest(actor=actor), self.mocks() as (_, audit, _, users):
                users.objects.filter.return_value.first.return_value = actor
                with self.assertRaises(PermissionDenied):
                    views.revoke_certificate(self.request(), 7)
                self.certificate.save.assert_not_called()
                audit.assert_not_called()

    def test_initial_denial_and_invalid_reasons_do_not_resolve_certificate(self):
        unauthorized = SimpleNamespace(is_authenticated=True, is_superuser=False, has_perm=lambda permission: False)
        with self.mocks() as (lookup, audit, _, _):
            with self.assertRaises(PermissionDenied):
                views.revoke_certificate(self.request(actor=unauthorized), 7)
            for reason in ("", "   ", "x" * 1001):
                self.assertEqual(views.revoke_certificate(self.request(reason), 7).status_code, 400)
            lookup.assert_not_called()
            audit.assert_not_called()


class WebsiteRevocationDatabaseTests(CurriculumTestCase):
    def setUp(self):
        self.actor = self.user
        self.actor.user_permissions.add(Permission.objects.get(
            content_type__app_label="certifications", codename="change_certificate",
        ))
        attempt = self.complete_assignment()
        self.certificate = Certificate.objects.create(
            certificate_number="GN-WEB-ATOMIC", assignment=self.assignment, training_version=self.version,
            qualifying_final_attempt=attempt, issued_at=timezone.now(),
            employee_code_snapshot=self.employee.employee_code, employee_name_snapshot=self.employee.display_name,
            training_title_snapshot=self.version.title, version_number_snapshot=self.version.version_number,
        )
        self.url = f"/certificates/{self.certificate.pk}/revoke/"
        self.client.force_login(self.actor)

    def events(self):
        return AuditLog.objects.filter(action="certifications.certificate.revoked", entity_id=str(self.certificate.pk))

    def snapshot(self):
        return Certificate.objects.filter(pk=self.certificate.pk).values().get()

    def test_success_audit_is_immediate_and_history_is_unchanged(self):
        before = self.snapshot()
        assignment = TrainingAssignment.objects.filter(pk=self.assignment.pk).values().get()
        attempts = list(AssessmentAttempt.objects.filter(assignment=self.assignment).order_by("pk").values())
        with self.captureOnCommitCallbacks(execute=False) as callbacks:
            self.assertEqual(self.client.post(self.url, {"reason": " First reason "}).status_code, 302)
            self.assertEqual(self.events().count(), 1)
        self.assertEqual(callbacks, [])
        after = self.snapshot()
        for field in set(before) - {"revoked_at", "revoked_by_id", "revocation_reason", "updated_at"}:
            self.assertEqual(after[field], before[field], field)
        self.assertEqual(TrainingAssignment.objects.filter(pk=self.assignment.pk).values().get(), assignment)
        self.assertEqual(list(AssessmentAttempt.objects.filter(assignment=self.assignment).order_by("pk").values()), attempts)
        event = self.events().get()
        self.assertEqual(event.reason, "First reason")
        self.assertEqual(event.actor_id, self.actor.pk)
        self.assertEqual(event.before_data, {"revoked_at": None})
        self.assertEqual(event.after_data, {"revoked_at": after["revoked_at"].isoformat(), "revoked_by_id": self.actor.pk})

    def test_audit_insert_failure_rolls_back_certificate(self):
        before = self.snapshot()
        with patch.object(AuditLog.objects, "create", side_effect=DatabaseError("Audit unavailable")):
            with self.assertRaisesRegex(DatabaseError, "Audit unavailable"):
                self.client.post(self.url, {"reason": "Issued in error"})
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.events().exists())

    def test_outer_rollback_removes_revocation_and_audit(self):
        before = self.snapshot()
        with self.assertRaisesRegex(RuntimeError, "Abort outer transaction"):
            with transaction.atomic():
                self.client.post(self.url, {"reason": "Issued in error"})
                self.assertTrue(self.snapshot()["revoked_at"])
                self.assertEqual(self.events().count(), 1)
                raise RuntimeError("Abort outer transaction")
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.events().exists())

    def test_duplicate_preserves_first_state_and_single_audit(self):
        self.assertEqual(self.client.post(self.url, {"reason": "First"}).status_code, 302)
        before = self.snapshot()
        self.assertEqual(self.client.post(self.url, {"reason": "Second"}).status_code, 409)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.events().count(), 1)

    def test_employee_and_ordinary_manager_cannot_revoke(self):
        manager = get_user_model().objects.create_user(username="web-revocation-manager")
        group, _ = Group.objects.get_or_create(name="Manager")
        manager.groups.add(group)
        for actor in (self.employee_user, manager):
            self.client.force_login(actor)
            self.assertEqual(self.client.post(self.url, {"reason": "Denied"}).status_code, 403)
        self.assertFalse(self.snapshot()["revoked_at"])
        self.assertFalse(self.events().exists())

    def test_invalid_reason_missing_id_and_get_do_not_mutate(self):
        before = self.snapshot()
        for data in ({}, {"reason": "  "}, {"reason": "x" * 1001}):
            self.assertEqual(self.client.post(self.url, data).status_code, 400)
        self.assertEqual(self.client.post("/certificates/999999999/revoke/", {"reason": "Missing"}).status_code, 404)
        self.assertEqual(self.client.get(self.url).status_code, 405)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.events().exists())

    def test_change_permission_does_not_require_global_view_or_employee_link(self):
        self.assertFalse(self.actor.has_perm("certifications.view_certificate"))
        self.assertFalse(hasattr(self.actor, "employee"))
        self.assertEqual(self.client.post(self.url, {"reason": "Authorized"}).status_code, 302)

    def test_anonymous_inactive_and_csrf_denials(self):
        self.client.logout()
        self.assertEqual(self.client.post(self.url, {"reason": "Denied"}).status_code, 302)
        self.actor.is_active = False
        self.actor.save(update_fields=["is_active"])
        self.client.force_login(self.actor)
        self.assertEqual(self.client.post(self.url, {"reason": "Denied"}).status_code, 302)
        self.actor.is_active = True
        self.actor.save(update_fields=["is_active"])
        csrf_client = Client(enforce_csrf_checks=True)
        csrf_client.force_login(self.actor)
        self.assertEqual(csrf_client.post(self.url, {"reason": "Denied"}).status_code, 403)
        self.assertFalse(self.events().exists())


class WebsiteRevocationConcurrencyTests(MySQLConcurrencyFixtures):
    """Real row locks and commits; exact owned cleanup, never TransactionTestCase.flush."""

    def setUp(self):
        super().setUp()
        self.owned = []
        self.addCleanup(self.cleanup_curriculum)
        self.actor = self.create_user("revoker", is_superuser=True)
        self.second_actor = self.create_user("revoker-two", is_superuser=True)
        now = timezone.now() - timedelta(minutes=1)
        training = self.remember(Training.objects.create(code=self.marker, catalog_title="Revocation fixture", created_by=self.actor))
        version = self.remember(TrainingVersion.objects.create(training=training, version_number=1, title="Fixture v1", created_by=self.actor))
        module = self.remember(Module.objects.create(training_version=version, title="Read", position=1))
        lesson = self.remember(Lesson.objects.create(module=module, title="Read", position=1, content_type="TEXT", body="Fixture"))
        question = self.remember(Question.objects.create(code=self.marker, created_by=self.actor))
        revision = self.remember(QuestionRevision.objects.create(question=question, revision_number=1, prompt="Fixture?", created_by=self.actor))
        correct = self.remember(QuestionOption.objects.create(question_revision=revision, text="Yes", position=1, is_correct=True))
        self.remember(QuestionOption.objects.create(question_revision=revision, text="No", position=2))
        revision.status, revision.frozen_at = "FROZEN", now
        revision.save()
        assessment = self.remember(Assessment.objects.create(training_version=version, kind="FINAL", title="Final"))
        item = self.remember(AssessmentQuestion.objects.create(assessment=assessment, question_revision=revision, position=1))
        version.status, version.published_at, version.published_by = "PUBLISHED", now, self.actor
        version.save()
        assignment = self.remember(TrainingAssignment.objects.create(
            employee=self.employee, training_version=version, department_at_assignment_id=self.department_id,
            job_role_at_assignment_id=self.role_id, assigned_at=now, started_at=now, status="IN_PROGRESS",
        ))
        self.remember(LessonProgress.objects.create(assignment=assignment, lesson=lesson, started_at=now,
                                                  last_accessed_at=now, completed_at=now))
        attempt = self.remember(AssessmentAttempt.objects.create(
            assignment=assignment, assessment=assessment, attempt_number=1, started_at=now,
            maximum_points=1, pass_percentage_snapshot=80,
        ))
        self.remember(AttemptAnswer.objects.create(
            attempt=attempt, assessment_question=item, selected_option=correct, presented_position=1,
            answered_at=now, points_possible=1, points_awarded=1, is_correct=True,
        ))
        attempt.status, attempt.submitted_at, attempt.score_points, attempt.passed = "SUBMITTED", now, 1, True
        attempt.save()
        assignment.status, assignment.completed_at = "COMPLETED", now
        assignment.save()
        self.certificate = self.remember(Certificate.objects.create(
            certificate_number=self.marker, assignment=assignment, training_version=version,
            qualifying_final_attempt=attempt, issued_at=now,
            employee_code_snapshot=self.employee.employee_code, employee_name_snapshot=self.employee.display_name,
            training_title_snapshot=version.title, version_number_snapshot=1,
        ))

    def remember(self, instance):
        self.owned.append((type(instance), instance.pk))
        return instance

    def cleanup_curriculum(self):
        for model, pk in reversed(self.owned):
            models.QuerySet(model, using="default").filter(pk=pk)._raw_delete("default")

    def revoke(self, actor, reason):
        request = RequestFactory().post(f"/certificates/{self.certificate.pk}/revoke/", {"reason": reason})
        request.user = actor
        return views.revoke_certificate(request, self.certificate.pk)

    def test_simultaneous_revocations_serialize_and_keep_one_event_and_first_state(self):
        held, boundary, finished, release = (Event() for _ in range(4))

        def hold_audit(execute, sql, params, many, context):
            result = execute(sql, params, many, context)
            if sql.upper().lstrip().startswith("INSERT INTO `AUDIT_AUDITLOG`"):
                held.set()
                if not release.wait(15):
                    raise AssertionError("First revocation was not released")
            return result

        def observe_lock(execute, sql, params, many, context):
            if "FOR UPDATE" in sql.upper() and "training_trainingassignment" in sql.lower():
                boundary.set()
            return execute(sql, params, many, context)

        def second_request():
            try:
                return self.worker(lambda: self.revoke(self.second_actor, "Second"), observe_lock)
            finally:
                finished.set()

        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(self.worker, lambda: self.revoke(self.actor, "First"), hold_audit)
            try:
                self.assertTrue(held.wait(15), "First transaction did not insert its audit")
                second = pool.submit(second_request)
                self.assertTrue(boundary.wait(15), "Second request did not attempt the assignment lock")
                finished_while_locked = finished.wait(1)
            finally:
                release.set()
            responses = first.result(20), second.result(20)
        self.assertFalse(finished_while_locked)
        self.assertEqual(tuple(response.status_code for response in responses), (302, 409))
        self.certificate.refresh_from_db()
        self.assertEqual(self.certificate.revocation_reason, "First")
        self.assertEqual(self.certificate.revoked_by_id, self.actor.pk)
        events = AuditLog.objects.filter(action="certifications.certificate.revoked", entity_id=str(self.certificate.pk))
        self.assertEqual(events.count(), 1)
        self.assertEqual(events.get().actor_id, self.actor.pk)

    def test_account_disabled_during_lock_wait_is_denied_without_revocation(self):
        boundary = Event()

        def observe(execute, sql, params, many, context):
            if "FOR UPDATE" in sql.upper() and "training_trainingassignment" in sql.lower():
                boundary.set()
            return execute(sql, params, many, context)

        with ThreadPoolExecutor(max_workers=1) as pool:
            with transaction.atomic():
                TrainingAssignment.objects.select_for_update().get(pk=self.certificate.assignment_id)
                pending = pool.submit(self.worker, lambda: self.revoke(self.actor, "Denied"), observe)
                self.assertTrue(boundary.wait(15), "Request did not reach the held assignment lock")
                current = get_user_model().objects.get(pk=self.actor.pk)
                current.is_active = False
                current.save(update_fields=["is_active"])
            with self.assertRaises(PermissionDenied):
                pending.result(20)
        self.certificate.refresh_from_db()
        self.assertIsNone(self.certificate.revoked_at)
        self.assertFalse(AuditLog.objects.filter(action="certifications.certificate.revoked", entity_id=str(self.certificate.pk)).exists())
