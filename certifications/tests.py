from datetime import timedelta

from django.core.exceptions import ValidationError
from django.db import IntegrityError, models, transaction

from config.model_test_utils import CurriculumTestCase
from .models import Certificate


class CertificateTests(CurriculumTestCase):
    def certificate(self, attempt, **kwargs):
        values = dict(certificate_number="GN-CERT-001", assignment=self.assignment, training_version=self.version,
                      qualifying_final_attempt=attempt, issued_at=self.now + timedelta(seconds=140),
                      employee_code_snapshot=self.employee.employee_code, employee_name_snapshot=self.employee.display_name,
                      training_title_snapshot=self.version.title, version_number_snapshot=1, issued_by=self.user)
        values.update(kwargs)
        return Certificate(**values)

    def test_completion_to_certificate_keeps_exact_version(self):
        attempt = self.complete_assignment()
        certificate = self.certificate(attempt)
        certificate.save()
        self.new_version()
        self.employee.display_name = "Updated name"
        self.employee.save()
        certificate.refresh_from_db()
        self.assertEqual(certificate.training_version_id, self.version.pk)
        self.assertEqual(certificate.employee_name_snapshot, "Employee One")
        self.assertEqual(certificate.qualifying_final_attempt_id, attempt.pk)

    def test_quiz_pass_does_not_qualify_for_certificate(self):
        self.complete_assignment()
        quiz_attempt = self.assignment.attempts.get(assessment=self.quiz)
        with self.assertRaises(ValidationError):
            self.certificate(quiz_attempt).save()

    def test_wrong_training_version_rejected(self):
        attempt = self.complete_assignment()
        with self.assertRaises(ValidationError):
            self.certificate(attempt, training_version=self.new_version()).save()

    def test_incomplete_assignment_cannot_be_certified(self):
        attempt = self.finish_attempt()
        with self.assertRaises(ValidationError):
            self.certificate(attempt).save()

    def test_database_prevents_duplicate_certificate(self):
        attempt = self.complete_assignment()
        self.certificate(attempt).save()
        with self.assertRaises(IntegrityError), transaction.atomic():
            models.Model.save(self.certificate(attempt, certificate_number="GN-CERT-002"), force_insert=True)

    def test_revocation_keeps_history_and_cannot_be_reversed(self):
        certificate = self.certificate(self.complete_assignment())
        certificate.save()
        certificate.revoked_at = self.now + timedelta(seconds=150)
        certificate.revoked_by = self.user
        certificate.revocation_reason = "Issued in error"
        certificate.save()
        certificate.revoked_at = None
        certificate.revocation_reason = ""
        certificate.revoked_by = None
        with self.assertRaises(ValidationError):
            certificate.save()
        with self.assertRaises(ValidationError):
            certificate.delete()

    def test_issued_certificate_content_is_immutable(self):
        certificate = self.certificate(self.complete_assignment())
        certificate.save()
        certificate.employee_name_snapshot = "Someone else"
        with self.assertRaises(ValidationError):
            certificate.save()
