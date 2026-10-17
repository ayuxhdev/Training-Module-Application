from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta, timezone as datetime_timezone
from io import StringIO
from tempfile import TemporaryDirectory
from threading import Barrier
from unittest.mock import patch

from django.core.management import call_command
from django.core.management.base import CommandError
from django.db import IntegrityError, connection, connections, transaction
from django.test import TransactionTestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.utils import timezone

from config.model_test_utils import CurriculumTestCase
from training.models import TrainingAssignment

from .models import Notification, notification_key
from .services import create_assignment_notification, create_deadline_notification


class DeadlineReminderTests(CurriculumTestCase):
    def setUp(self):
        self.as_of = timezone.now()
        self.cutoff = self.as_of - timedelta(minutes=2)
        clock_patch = patch("django.utils.timezone.now", return_value=self.as_of)
        self.clock = clock_patch.start()
        self.addCleanup(clock_patch.stop)

    def deadline(self, due_at):
        self.assignment.due_at = due_at
        self.assignment.save()

    def run_command(self, cutoff=None):
        output = StringIO()
        call_command("generate_training_notifications", activation_cutoff=(cutoff or self.cutoff).isoformat(), stdout=output)
        return output.getvalue()

    def test_exact_boundaries_and_approaching_window(self):
        for delta, expected in [
            (timedelta(hours=24), "APPROACHING"),
            (timedelta(hours=24, microseconds=1), None),
            (timedelta(hours=1), "APPROACHING"),
            (timedelta(0), None),
            (-timedelta(microseconds=1), "OVERDUE"),
        ]:
            with self.subTest(delta=delta):
                self.deadline(self.as_of + delta)
                before = Notification.objects.count()
                self.run_command()
                self.assertEqual(Notification.objects.count(), before + bool(expected))
                if expected:
                    item = Notification.objects.get(deduplication_key=notification_key(self.assignment, expected))
                    self.assertEqual(item.employee_id, self.employee.pk)
                    self.assertEqual(item.assignment_id, self.assignment.pk)
                    self.assertIn(self.version.title, item.message)
                    self.assertIn("+00:00", item.message)

    def test_missing_deadline_and_inactive_employee_are_excluded(self):
        self.run_command()
        self.assertFalse(Notification.objects.exists())
        self.deadline(self.as_of + timedelta(hours=1))
        self.employee.is_active = False
        self.employee.deactivation_reason = "Test deactivation"
        self.employee.save()
        self.run_command()
        self.assertFalse(Notification.objects.exists())

    def test_completed_and_cancelled_assignments_are_excluded(self):
        self.deadline(self.as_of + timedelta(hours=1))
        self.assignment.status = TrainingAssignment.Status.CANCELLED
        self.assignment.cancelled_at = self.as_of
        self.assignment.cancellation_reason = "Test cancellation"
        self.assignment.save()
        self.run_command()
        self.assertFalse(Notification.objects.exists())
        self.assignment.status = TrainingAssignment.Status.IN_PROGRESS
        self.assignment.cancelled_at = None
        self.assignment.cancellation_reason = ""
        self.assignment.save()
        self.complete_assignment()
        self.run_command()
        self.assertFalse(Notification.objects.exists())

    def test_assigned_and_retired_pinned_assignments_remain_eligible(self):
        self.deadline(self.as_of + timedelta(hours=1))
        self.assignment.status = TrainingAssignment.Status.ASSIGNED
        self.assignment.started_at = None
        self.assignment.save()
        self.version.status = "RETIRED"
        self.version.retired_at = self.as_of
        self.version.save()
        self.run_command()
        self.assertEqual(Notification.objects.get().event_type, "APPROACHING")

    def test_cutoff_is_required_explicit_aware_and_not_future(self):
        self.deadline(self.as_of + timedelta(hours=1))
        with self.assertRaises(CommandError):
            call_command("generate_training_notifications", stdout=StringIO())
        for value in ["bad-date", "2026-13-45T00:00:00Z", "2026-01-01T00:00:00", (self.as_of + timedelta(seconds=1)).isoformat()]:
            with self.subTest(value=value), self.assertRaises(CommandError):
                call_command("generate_training_notifications", activation_cutoff=value, stdout=StringIO())
        self.assertFalse(Notification.objects.exists())

    def test_fixed_cutoff_prevents_backfill_without_losing_later_overdue_events(self):
        self.deadline(self.cutoff - timedelta(microseconds=1))
        self.run_command()
        self.assertFalse(Notification.objects.exists())
        self.deadline(self.cutoff)
        self.run_command()
        self.assertEqual(Notification.objects.get().event_type, "OVERDUE")
        self.deadline(self.as_of + timedelta(hours=1))
        self.run_command()
        self.as_of += timedelta(hours=2)
        self.clock.return_value = self.as_of
        self.run_command()
        self.assertEqual(Notification.objects.count(), 3)
        self.run_command()
        self.assertEqual(Notification.objects.count(), 3)

    def test_changed_deadlines_get_distinct_canonical_utc_keys(self):
        self.deadline(self.as_of + timedelta(hours=1))
        self.assertIn("Created 1", self.run_command())
        first = Notification.objects.get()
        self.assertIn("Created 0", self.run_command())
        self.assertEqual(Notification.objects.get().pk, first.pk)
        self.assignment.due_at = self.assignment.due_at.astimezone(datetime_timezone(timedelta(hours=5, minutes=30)))
        self.assignment.save()
        self.run_command()
        self.assertEqual(Notification.objects.count(), 1)
        self.deadline(self.as_of + timedelta(hours=2))
        self.run_command()
        self.assertEqual(Notification.objects.count(), 2)
        self.assertNotEqual(*Notification.objects.values_list("deduplication_key", flat=True))

    def test_notified_overdue_candidates_do_not_reacquire_business_locks(self):
        self.deadline(self.as_of - timedelta(seconds=1))
        self.assertIn("Created 1", self.run_command())
        with patch(
            "notifications.management.commands.generate_training_notifications.create_deadline_notification",
            wraps=create_deadline_notification,
        ) as generate, CaptureQueriesContext(connection) as queries:
            self.assertIn("Created 0", self.run_command())
        generate.assert_not_called()
        self.assertFalse(any("FOR UPDATE" in query["sql"] for query in queries))
        self.assertEqual(Notification.objects.count(), 1)

    def test_overdue_prefilter_uses_canonical_deadline_and_allows_rescheduling(self):
        self.deadline(self.as_of - timedelta(minutes=1))
        self.run_command()
        self.deadline(self.assignment.due_at.astimezone(
            datetime_timezone(timedelta(hours=5, minutes=30)),
        ))
        with patch(
            "notifications.management.commands.generate_training_notifications.create_deadline_notification",
            wraps=create_deadline_notification,
        ) as generate:
            self.assertIn("Created 0", self.run_command())
            generate.assert_not_called()
            self.deadline(self.as_of - timedelta(seconds=1))
            self.assertIn("Created 1", self.run_command())
            generate.assert_called_once_with(self.assignment.pk, activation_cutoff=self.cutoff)
        self.assertEqual(Notification.objects.count(), 2)

    def test_old_overdue_notification_does_not_suppress_a_future_deadline(self):
        self.deadline(self.as_of - timedelta(seconds=1))
        self.run_command()
        self.deadline(self.as_of + timedelta(hours=1))
        self.assertIn("Created 1", self.run_command())
        self.assertEqual(set(Notification.objects.values_list("event_type", flat=True)),
                         {"OVERDUE", "APPROACHING"})

    def test_locked_recheck_observes_cancellation_after_candidate_scan(self):
        self.deadline(self.as_of + timedelta(hours=1))
        def cancel_before_recheck(assignment_id, **kwargs):
            self.assignment.status = "CANCELLED"
            self.assignment.cancelled_at = self.as_of
            self.assignment.cancellation_reason = "Cancelled during scan"
            self.assignment.save()
            return create_deadline_notification(assignment_id, **kwargs)
        with patch("notifications.management.commands.generate_training_notifications.create_deadline_notification", side_effect=cancel_before_recheck):
            self.run_command()
        self.assertFalse(Notification.objects.exists())

    def test_locked_recheck_observes_deadline_and_employee_changes(self):
        self.deadline(self.as_of + timedelta(hours=1))
        def defer_before_recheck(assignment_id, **kwargs):
            self.deadline(self.as_of + timedelta(days=2))
            return create_deadline_notification(assignment_id, **kwargs)
        with patch("notifications.management.commands.generate_training_notifications.create_deadline_notification", side_effect=defer_before_recheck):
            self.run_command()
        self.assertFalse(Notification.objects.exists())
        self.deadline(self.as_of + timedelta(hours=1))
        def deactivate_before_recheck(assignment_id, **kwargs):
            self.employee.is_active = False
            self.employee.deactivation_reason = "During scan"
            self.employee.save()
            return create_deadline_notification(assignment_id, **kwargs)
        with patch("notifications.management.commands.generate_training_notifications.create_deadline_notification", side_effect=deactivate_before_recheck):
            self.run_command()
        self.assertFalse(Notification.objects.exists())

    def test_deadline_crossing_to_overdue_is_reclassified_after_scan(self):
        self.deadline(self.as_of + timedelta(hours=1))
        def move_before_recheck(assignment_id, **kwargs):
            self.deadline(self.as_of - timedelta(seconds=1))
            return create_deadline_notification(assignment_id, **kwargs)
        with patch("notifications.management.commands.generate_training_notifications.create_deadline_notification", side_effect=move_before_recheck):
            self.run_command()
        self.assertEqual(Notification.objects.get().event_type, "OVERDUE")

    def test_parent_to_assignment_lock_order_and_no_business_updates(self):
        if connection.vendor != "mysql":
            self.skipTest("Requires MySQL FOR UPDATE SQL assertions.")
        self.deadline(self.as_of + timedelta(hours=1))
        with CaptureQueriesContext(connection) as queries:
            create_deadline_notification(self.assignment.pk, activation_cutoff=self.cutoff)
        locks = [query["sql"] for query in queries if "FOR UPDATE" in query["sql"]]
        self.assertEqual(len(locks), 3)
        for sql, table in zip(locks, ["organization_employee", "training_trainingversion", "training_trainingassignment"]):
            self.assertIn(f"FROM `{table}`", sql)
        self.assertFalse(any(query["sql"].startswith("UPDATE ") for query in queries))

    def test_rollback_and_unexpected_errors_are_not_suppressed(self):
        self.deadline(self.as_of + timedelta(hours=1))
        with self.assertRaises(RuntimeError), transaction.atomic():
            self.run_command()
            self.assertEqual(Notification.objects.count(), 1)
            raise RuntimeError("Rollback")
        self.assertFalse(Notification.objects.exists())
        with patch.object(Notification.objects, "get_or_create", side_effect=IntegrityError("Unexpected database failure")):
            with self.assertRaises(IntegrityError):
                self.run_command()
        self.assertFalse(Notification.objects.exists())

    def test_only_notifications_change_and_immediate_events_remain_independent(self):
        self.deadline(self.as_of + timedelta(hours=1))
        before = TrainingAssignment.objects.values().get(pk=self.assignment.pk)
        create_assignment_notification(self.assignment.pk, "ASSIGNED")
        self.run_command()
        self.assertEqual(TrainingAssignment.objects.values().get(pk=self.assignment.pk), before)
        self.assertEqual(set(Notification.objects.values_list("event_type", flat=True)), {"ASSIGNED", "APPROACHING"})
        self.assertFalse(self.assignment.lesson_progress.exists())
        self.assertFalse(self.assignment.attempts.exists())


class DeadlineReminderConcurrencyTests(TransactionTestCase):
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
            self.skipTest("Requires MySQL reminder concurrency.")
        CurriculumTestCase.setUpTestData.__func__(type(self))

    def test_concurrent_commands_create_one_notification(self):
        now = timezone.now()
        self.assignment.due_at = now + timedelta(hours=1)
        self.assignment.save()
        barrier = Barrier(2)
        def generate():
            try:
                barrier.wait(timeout=10)
                output = StringIO()
                call_command("generate_training_notifications", activation_cutoff=(now - timedelta(minutes=1)).isoformat(), stdout=output)
                return output.getvalue()
            finally:
                connections.close_all()
        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(generate) for _ in range(2)]
            outputs = [future.result(timeout=30) for future in futures]
        self.assertEqual(sorted(outputs), ["Created 0 deadline notifications.\n", "Created 1 deadline notifications.\n"])
        self.assertEqual(Notification.objects.count(), 1)
        self.assertEqual(Notification.objects.get().employee_id, self.employee.pk)
