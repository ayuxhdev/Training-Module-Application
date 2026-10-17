from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta, timezone as datetime_timezone
from tempfile import TemporaryDirectory
from threading import Barrier
from unittest.mock import patch

from django.contrib.auth.models import Group
from django.core.exceptions import ValidationError
from django.db import IntegrityError, connection, connections, models, transaction
from django.test import TransactionTestCase, override_settings
from django.utils import timezone

from assessments.views import _try_complete_assignment
from certifications.models import Certificate
from config.model_test_utils import CurriculumTestCase
from organization.models import Employee
from training.forms import TrainingAssignmentForm
from training.models import RoleTrainingRequirement, TrainingAssignment

from .models import Notification, notification_key
from .services import create_assignment_notification


class NotificationTests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.recipient = Employee.objects.create(
            employee_code="NOTICE-002", display_name="Notification recipient",
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(),
        )

    def assignment_form(self, employee=None, version=None):
        return TrainingAssignmentForm(data={
            "employee": (employee or self.recipient).pk,
            "training_version": (version or self.version).pk,
        })

    def assign_manually(self):
        form = self.assignment_form()
        self.assertTrue(form.is_valid(), form.errors)
        return form.save(assigned_by=self.user)

    def prepare_completion(self):
        self.complete_lessons()
        self.finish_attempt(self.quiz)
        self.finish_attempt(self.final)

    def role_requirement(self):
        self.user.groups.add(Group.objects.get(name="Training Coordinator"))
        self.client.force_login(self.user)
        return RoleTrainingRequirement.objects.create(
            job_role=self.role, training_version=self.version, created_by=self.user, due_in_days=7,
        )

    def test_manual_assignment_uses_the_actual_employee_and_version(self):
        assignment = self.assign_manually()
        notification = Notification.objects.get()
        self.assertEqual(notification.employee_id, self.recipient.pk)
        self.assertEqual(notification.assignment_id, assignment.pk)
        self.assertEqual(notification.event_type, Notification.EventType.ASSIGNED)
        self.assertEqual(notification.deduplication_key, f"assignment:{assignment.pk}:ASSIGNED")
        self.assertEqual(notification.title, "New training assigned")
        self.assertEqual(notification.message, 'You have been assigned "Safety v1" (version 1).')
        self.assertIsNone(notification.read_at)
        self.assertEqual(assignment.training_version_id, self.version.pk)
        self.assertEqual(assignment.status, TrainingAssignment.Status.ASSIGNED)
        self.assertFalse(Notification.objects.filter(employee=self.employee).exists())

    def test_manual_commit_false_creates_neither_assignment_nor_notification(self):
        form = self.assignment_form()
        self.assertTrue(form.is_valid(), form.errors)
        assignment = form.save(commit=False, assigned_by=self.user)
        self.assertIsNone(assignment.pk)
        self.assertFalse(Notification.objects.exists())
        self.assertFalse(TrainingAssignment.objects.filter(employee=self.recipient).exists())

    def test_repeated_manual_assignment_does_not_create_another_event(self):
        self.assign_manually()
        form = self.assignment_form()
        self.assertFalse(form.is_valid())
        self.assertEqual(Notification.objects.count(), 1)
        self.assertEqual(TrainingAssignment.objects.filter(employee=self.recipient).count(), 1)

    def test_invalid_assignment_choices_create_no_event(self):
        draft = self.new_version()
        self.assertFalse(self.assignment_form(version=draft).is_valid())
        self.recipient.is_active = False
        self.recipient.deactivation_reason = "Test deactivation"
        self.recipient.save()
        self.assertFalse(self.assignment_form().is_valid())
        self.assertFalse(Notification.objects.exists())

    def test_manual_assignment_and_event_roll_back_together(self):
        with self.assertRaises(RuntimeError), transaction.atomic():
            self.assign_manually()
            self.assertEqual(Notification.objects.count(), 1)
            raise RuntimeError("Rollback")
        self.assertFalse(Notification.objects.exists())
        self.assertFalse(TrainingAssignment.objects.filter(employee=self.recipient).exists())

    def test_manual_event_failure_rolls_back_the_assignment(self):
        with patch("training.forms.create_assignment_notification", side_effect=IntegrityError("Test failure")):
            with self.assertRaises(IntegrityError):
                self.assign_manually()
        self.assertFalse(Notification.objects.exists())
        self.assertFalse(TrainingAssignment.objects.filter(employee=self.recipient).exists())

    def test_role_assignment_notifies_only_new_recipients_even_when_repeated(self):
        requirement = self.role_requirement()
        for _ in range(2):
            response = self.client.post("/assignments/role/new/", {"role_requirement": requirement.pk})
            self.assertEqual(response.status_code, 302)
        assignment = TrainingAssignment.objects.get(employee=self.recipient)
        notification = Notification.objects.get()
        self.assertEqual(notification.assignment_id, assignment.pk)
        self.assertEqual(notification.employee_id, self.recipient.pk)
        self.assertEqual(assignment.source, TrainingAssignment.Source.ROLE)
        self.assertFalse(Notification.objects.filter(assignment=self.assignment).exists())

    def test_role_event_failure_is_not_swallowed_as_duplicate_assignment(self):
        requirement = self.role_requirement()
        with patch("notifications.services.create_assignment_notification", side_effect=IntegrityError("Test failure")):
            with self.assertRaises(IntegrityError):
                self.client.post("/assignments/role/new/", {"role_requirement": requirement.pk})
        self.assertFalse(TrainingAssignment.objects.filter(employee=self.recipient).exists())
        self.assertFalse(Notification.objects.exists())

    def test_later_role_event_failure_rolls_back_the_whole_batch(self):
        requirement = self.role_requirement()
        another = Employee.objects.create(
            employee_code="NOTICE-003", display_name="Another recipient",
            department=self.department, job_role=self.role, date_joined=self.now.date(),
        )
        calls = 0

        def fail_second(*args):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise RuntimeError("Rollback entire batch")
            return create_assignment_notification(*args)

        with patch("notifications.services.create_assignment_notification", side_effect=fail_second):
            with self.assertRaises(RuntimeError):
                self.client.post("/assignments/role/new/", {"role_requirement": requirement.pk})
        self.assertEqual(calls, 2)
        self.assertFalse(TrainingAssignment.objects.filter(employee__in=[self.recipient, another]).exists())
        self.assertFalse(Notification.objects.exists())

    def test_completion_creates_one_event_and_preserves_certificate_behavior(self):
        self.prepare_completion()
        _try_complete_assignment(self.assignment, actor=self.employee_user)
        self.assignment.refresh_from_db()
        completed_at = self.assignment.completed_at
        notification = Notification.objects.get()
        self.assertEqual(notification.event_type, Notification.EventType.COMPLETED)
        self.assertEqual(notification.employee_id, self.employee.pk)
        self.assertEqual(notification.assignment_id, self.assignment.pk)
        self.assertEqual(notification.message, 'You have completed "Safety v1" (version 1).')
        self.assertEqual(self.assignment.status, TrainingAssignment.Status.COMPLETED)
        self.assertEqual(Certificate.objects.filter(assignment=self.assignment).count(), 1)
        _try_complete_assignment(self.assignment, actor=self.employee_user)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.completed_at, completed_at)
        self.assertEqual(Notification.objects.count(), 1)
        self.assertEqual(Certificate.objects.count(), 1)

    def test_failed_completion_validation_creates_no_event(self):
        _try_complete_assignment(self.assignment, actor=self.employee_user)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, TrainingAssignment.Status.IN_PROGRESS)
        self.assertFalse(Notification.objects.exists())
        self.assertFalse(Certificate.objects.exists())
        with self.assertRaises(ValidationError):
            create_assignment_notification(self.assignment.pk, Notification.EventType.COMPLETED)

    def test_completion_outer_rollback_removes_notification_and_certificate(self):
        self.prepare_completion()
        with self.assertRaises(RuntimeError), transaction.atomic():
            _try_complete_assignment(self.assignment, actor=self.employee_user)
            self.assertEqual(Notification.objects.count(), 1)
            raise RuntimeError("Rollback")
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, TrainingAssignment.Status.IN_PROGRESS)
        self.assertFalse(Notification.objects.exists())
        self.assertFalse(Certificate.objects.exists())

    def test_completion_event_failure_rolls_back_completion_and_certificate(self):
        self.prepare_completion()
        with patch("notifications.services.create_assignment_notification", side_effect=IntegrityError("Test failure")):
            with self.assertRaises(IntegrityError):
                _try_complete_assignment(self.assignment, actor=self.employee_user)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, TrainingAssignment.Status.IN_PROGRESS)
        self.assertFalse(Certificate.objects.exists())
        self.assertFalse(Notification.objects.exists())
        self.assertEqual(self.assignment.attempts.filter(passed=True).count(), 2)

    def test_service_duplicate_returns_the_existing_event(self):
        first, created = create_assignment_notification(self.assignment.pk, Notification.EventType.ASSIGNED)
        second, repeated = create_assignment_notification(self.assignment.pk, Notification.EventType.ASSIGNED)
        self.assertTrue(created)
        self.assertFalse(repeated)
        self.assertEqual(first.pk, second.pk)
        self.assertEqual(Notification.objects.count(), 1)

    def test_database_enforces_the_unique_key(self):
        notification, _ = create_assignment_notification(self.assignment.pk, Notification.EventType.ASSIGNED)
        notification.pk = None
        with self.assertRaises(IntegrityError), transaction.atomic():
            models.Model.save(notification, force_insert=True)

    def test_service_handles_only_the_expected_full_clean_uniqueness_race(self):
        original = Notification.objects.get_or_create

        def race(**kwargs):
            original(**kwargs)
            raise ValidationError({"deduplication_key": ValidationError("Duplicate", code="unique")})

        with patch.object(Notification.objects, "get_or_create", side_effect=race):
            notification, created = create_assignment_notification(self.assignment.pk, Notification.EventType.ASSIGNED)
        self.assertFalse(created)
        self.assertEqual(Notification.objects.get().pk, notification.pk)

    def test_service_does_not_hide_other_validation_even_when_an_event_exists(self):
        original = Notification.objects.get_or_create

        def invalid(**kwargs):
            original(**kwargs)
            raise ValidationError({"message": "Unrelated validation failure"})

        with patch.object(Notification.objects, "get_or_create", side_effect=invalid):
            with self.assertRaisesMessage(ValidationError, "Unrelated validation failure"):
                create_assignment_notification(self.assignment.pk, Notification.EventType.ASSIGNED)
        self.assertFalse(Notification.objects.exists())

    def test_model_rejects_wrong_owner_or_forged_key_and_freezes_event_content(self):
        notification, _ = create_assignment_notification(self.assignment.pk, Notification.EventType.ASSIGNED)
        for changes in ({"employee_id": self.recipient.pk}, {"message": "Forged"}, {"deduplication_key": "forged"}):
            with self.subTest(changes=changes):
                item = Notification.objects.get(pk=notification.pk)
                for field, value in changes.items():
                    setattr(item, field, value)
                with self.assertRaises(ValidationError):
                    item.save()
        with self.assertRaises(ValidationError):
            Notification.objects.create(
                employee=self.recipient, assignment=self.assignment, event_type=Notification.EventType.COMPLETED,
                title="Invalid owner", message="Invalid owner",
                deduplication_key=notification_key(self.assignment, Notification.EventType.COMPLETED),
            )
        notification.read_at = timezone.now()
        notification.save()
        notification.refresh_from_db()
        self.assertIsNotNone(notification.read_at)
        notification.read_at = notification.created_at - timedelta(seconds=1)
        with self.assertRaises(ValidationError):
            notification.save()

    def test_deadline_keys_are_stable_in_utc_and_change_only_for_distinct_deadlines_or_events(self):
        self.assignment.due_at = timezone.now()
        approaching = notification_key(self.assignment, Notification.EventType.APPROACHING)
        overdue = notification_key(self.assignment, Notification.EventType.OVERDUE)
        self.assertNotEqual(approaching, overdue)
        self.assignment.due_at = self.assignment.due_at.astimezone(datetime_timezone(timedelta(hours=5, minutes=30)))
        self.assertEqual(notification_key(self.assignment, Notification.EventType.APPROACHING), approaching)
        self.assignment.due_at += timedelta(seconds=1)
        self.assertNotEqual(notification_key(self.assignment, Notification.EventType.APPROACHING), approaching)
        self.assignment.due_at = None
        with self.assertRaises(ValidationError):
            notification_key(self.assignment, Notification.EventType.OVERDUE)
        with self.assertRaises(ValidationError):
            create_assignment_notification(self.assignment.pk, Notification.EventType.APPROACHING)
        self.assertFalse(Notification.objects.exists())


class NotificationConcurrencyTests(TransactionTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        media = TemporaryDirectory()
        cls.addClassCleanup(media.cleanup)
        override = override_settings(MEDIA_ROOT=media.name)
        override.enable()
        cls.addClassCleanup(override.disable)

    def setUp(self):
        if connection.vendor != "mysql":
            self.skipTest("Requires MySQL unique-key concurrency.")
        CurriculumTestCase.setUpTestData.__func__(type(self))

    def test_concurrent_events_pass_validation_then_database_deduplicates_the_insert(self):
        barrier = Barrier(2)
        original = Notification.full_clean

        def synchronized_clean(instance, *args, **kwargs):
            original(instance, *args, **kwargs)
            barrier.wait(timeout=10)

        def create():
            try:
                notification, created = create_assignment_notification(self.assignment.pk, Notification.EventType.ASSIGNED)
                return notification.pk, created
            finally:
                connections.close_all()

        with patch.object(Notification, "full_clean", synchronized_clean), ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(create) for _ in range(2)]
            results = [future.result(timeout=20) for future in futures]
        self.assertEqual(len({pk for pk, _ in results}), 1)
        self.assertEqual(sorted(created for _, created in results), [False, True])
        self.assertEqual(Notification.objects.count(), 1)
        self.assertEqual(Notification.objects.get().employee_id, self.employee.pk)
