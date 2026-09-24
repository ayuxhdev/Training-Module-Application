from django.core.exceptions import ValidationError
from django.db import IntegrityError, transaction
from django.test import TestCase

from .models import AuditLog


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
