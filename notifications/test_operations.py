from io import StringIO
from unittest.mock import patch

from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import override_settings
from django.utils import timezone
from datetime import timedelta, timezone as datetime_timezone

from config.model_test_utils import CurriculumTestCase
from organization.models import Employee
from training.models import TrainingAssignment
from .models import Notification
from .services import create_deadline_notification


class ReminderOperationsTests(CurriculumTestCase):
    def setUp(self):
        self.now = timezone.now()
        self.cutoff = self.now - timedelta(hours=1)
        self.assignment.due_at = self.now + timedelta(hours=1)
        self.assignment.save()

    def run_command(self, **options):
        call_command("generate_training_notifications", stdout=StringIO(), **options)

    def test_persisted_cutoff_survives_repeated_execution_and_timezone_equivalence(self):
        with override_settings(NOTIFICATIONS_ACTIVATED_AT=self.cutoff.isoformat()):
            self.run_command()
            self.run_command(activation_cutoff=self.cutoff.astimezone(datetime_timezone(timedelta(hours=5, minutes=30))).isoformat())
        self.assertEqual(Notification.objects.count(), 1)

    def test_missing_invalid_future_or_mismatched_persisted_cutoff_fails_before_events(self):
        for value in ("", "invalid", "2026-01-01", (self.now + timedelta(days=1)).isoformat()):
            with override_settings(NOTIFICATIONS_ACTIVATED_AT=value), self.assertRaises(CommandError):
                self.run_command()
        with override_settings(NOTIFICATIONS_ACTIVATED_AT=self.cutoff.isoformat()), self.assertRaises(CommandError):
            self.run_command(activation_cutoff=(self.cutoff + timedelta(minutes=1)).isoformat())
        self.assertFalse(Notification.objects.exists())

    def test_interrupted_scan_can_resume_without_losing_or_duplicating_events(self):
        employee = Employee.objects.create(employee_code="OPS-REMINDER", display_name="Operations fixture",
            department=self.department, job_role=self.role, date_joined=self.now.date())
        TrainingAssignment.objects.create(employee=employee, training_version=self.version,
            department_at_assignment=self.department, job_role_at_assignment=self.role, assigned_by=self.user,
            due_at=self.now + timedelta(hours=1))
        calls = 0

        def interrupt(assignment_id, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise RuntimeError("isolated interruption")
            return create_deadline_notification(assignment_id, **kwargs)

        with override_settings(NOTIFICATIONS_ACTIVATED_AT=self.cutoff.isoformat()):
            with patch("notifications.management.commands.generate_training_notifications.create_deadline_notification", side_effect=interrupt):
                with self.assertRaises(RuntimeError):
                    self.run_command()
            self.assertEqual(Notification.objects.count(), 1)
            self.run_command()
            self.run_command()
        self.assertEqual(Notification.objects.count(), 2)

    def test_scheduler_logs_safe_counts_and_failure_events(self):
        with override_settings(NOTIFICATIONS_ACTIVATED_AT=self.cutoff.isoformat()), self.assertLogs("operations", "INFO") as logs:
            self.run_command()
        self.assertEqual([record.event for record in logs.records], ["reminders_started", "reminders_completed"])
        self.assertEqual(logs.records[-1].created_count, 1)
        self.assertGreaterEqual(logs.records[-1].duration_ms, 0)
        with override_settings(NOTIFICATIONS_ACTIVATED_AT="invalid"), self.assertLogs("operations", "ERROR") as failed:
            with self.assertRaises(CommandError):
                self.run_command()
        self.assertEqual(failed.records[-1].event, "reminders_failed")
