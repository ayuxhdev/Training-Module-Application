from datetime import timedelta

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.exceptions import ValidationError
from django.db import IntegrityError, models, transaction
from django.test import Client
from django.utils import timezone

from assessments.views import _try_complete_assignment
from config.model_test_utils import CurriculumTestCase
from organization.models import Employee
from training.models import TrainingAssignment
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


class CertificateWorkflowTests(CurriculumTestCase):
    def client_for(self, user):
        client = Client()
        client.force_login(user)
        return client

    def certificate(self, attempt):
        return Certificate(
            certificate_number="GN-CERT-WORKFLOW",
            assignment=self.assignment,
            training_version=self.version,
            qualifying_final_attempt=attempt,
            issued_at=self.now + timedelta(seconds=140),
            employee_code_snapshot=self.employee.employee_code,
            employee_name_snapshot=self.employee.display_name,
            training_title_snapshot=self.version.title,
            version_number_snapshot=self.version.version_number,
            issued_by=self.user,
        )

    def other_employee_certificate(self):
        other_user = get_user_model().objects.create_user(username="certificate-other-employee")
        other_employee = Employee.objects.create(
            employee_code="GN-002", display_name="Employee Two", user=other_user,
            department=self.department, job_role=self.role, date_joined=self.now.date(),
        )
        other_assignment = TrainingAssignment.objects.create(
            employee=other_employee, training_version=self.version,
            department_at_assignment=self.department, job_role_at_assignment=self.role,
            assigned_at=self.now, started_at=self.now, status=TrainingAssignment.Status.IN_PROGRESS,
        )
        assignment = self.assignment
        self.assignment = other_assignment
        try:
            self.complete_lessons()
            self.finish_attempt(self.quiz)
            final_attempt = self.finish_attempt(self.final)
            other_assignment.status = TrainingAssignment.Status.COMPLETED
            other_assignment.completed_at = self.now + timedelta(seconds=130)
            other_assignment.save()
        finally:
            self.assignment = assignment
        return Certificate.objects.create(
            certificate_number="GN-CERT-OTHER",
            assignment=other_assignment,
            training_version=self.version,
            qualifying_final_attempt=final_attempt,
            issued_at=timezone.now(),
            employee_code_snapshot=other_employee.employee_code,
            employee_name_snapshot=other_employee.display_name,
            training_title_snapshot=self.version.title,
            version_number_snapshot=self.version.version_number,
        )

    def test_final_submission_automatically_issues_one_server_stamped_certificate(self):
        self.complete_lessons()
        self.finish_attempt(self.quiz)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, TrainingAssignment.Status.IN_PROGRESS)
        self.assertFalse(Certificate.objects.filter(assignment=self.assignment).exists())

        final_attempt = self.start_attempt(self.final)
        before_submission = timezone.now()
        response = self.client_for(self.employee_user).post(
            f"/attempts/{final_attempt.pk}/submit/",
            {
                f"answer_{self.final_item.pk}": self.correct_option.pk,
                "certificate_number": "CLIENT-CONTROLLED",
                "issued_at": "2000-01-01T00:00:00Z",
                "employee": "9999",
                "training_version": "9999",
            },
        )
        self.assertEqual(response.status_code, 302)

        self.assignment.refresh_from_db()
        final_attempt.refresh_from_db()
        certificate = Certificate.objects.get(assignment=self.assignment)
        self.assertEqual(self.assignment.status, TrainingAssignment.Status.COMPLETED)
        self.assertIsNotNone(self.assignment.completed_at)
        self.assertEqual(certificate.training_version_id, self.version.pk)
        self.assertEqual(certificate.qualifying_final_attempt_id, final_attempt.pk)
        self.assertNotEqual(certificate.certificate_number, "CLIENT-CONTROLLED")
        self.assertRegex(certificate.certificate_number, r"^GN-[0-9A-F]{32}$")
        self.assertGreaterEqual(certificate.issued_at, before_submission)
        self.assertGreaterEqual(certificate.issued_at, self.assignment.completed_at)
        self.assertGreaterEqual(certificate.issued_at, final_attempt.submitted_at)
        self.assertEqual(certificate.employee_name_snapshot, self.employee.display_name)
        self.assertEqual(certificate.training_title_snapshot, self.version.title)

        original_number = certificate.certificate_number
        _try_complete_assignment(self.assignment)
        self.assertEqual(Certificate.objects.filter(assignment=self.assignment).count(), 1)
        self.assertEqual(Certificate.objects.get(assignment=self.assignment).certificate_number, original_number)

        newer_version = self.new_version()
        self.employee.display_name = "Renamed Employee"
        self.employee.save()
        certificate.refresh_from_db()
        self.assertEqual(certificate.training_version_id, self.version.pk)
        self.assertEqual(certificate.version_number_snapshot, 1)
        self.assertEqual(certificate.training_title_snapshot, "Safety v1")
        self.assertEqual(certificate.employee_name_snapshot, "Employee One")
        self.assertNotEqual(newer_version.pk, certificate.training_version_id)

    def test_employee_certificate_access_is_owner_scoped_and_bad_ids_are_404(self):
        certificate = self.certificate(self.complete_assignment())
        certificate.save()
        other_certificate = self.other_employee_certificate()
        client = self.client_for(self.employee_user)

        self.assertEqual(client.get("/certificates/").status_code, 200)
        self.assertEqual(client.get(f"/certificates/{certificate.pk}/").status_code, 200)
        self.assertEqual(client.get(f"/certificates/{other_certificate.pk}/").status_code, 404)
        self.assertEqual(client.get("/certificates/99999999/").status_code, 404)
        self.assertEqual(client.get("/certificates/not-an-id/").status_code, 404)
        self.assertNotContains(client.get("/certificates/"), other_certificate.certificate_number)

    def test_only_administrator_and_coordinator_can_revoke(self):
        certificate = self.certificate(self.complete_assignment())
        certificate.save()
        employee_client = self.client_for(self.employee_user)
        manager = get_user_model().objects.create_user(username="certificate-manager")
        Group.objects.get(name="Manager").user_set.add(manager)

        self.assertEqual(employee_client.post(
            f"/certificates/{certificate.pk}/revoke/", {"reason": "Not authorized"},
        ).status_code, 403)
        self.assertEqual(self.client_for(manager).post(
            f"/certificates/{certificate.pk}/revoke/", {"reason": "Not authorized"},
        ).status_code, 403)

        coordinator = get_user_model().objects.create_user(username="certificate-coordinator")
        Group.objects.get(name="Training Coordinator").user_set.add(coordinator)
        response = self.client_for(coordinator).post(
            f"/certificates/{certificate.pk}/revoke/", {"reason": "Issued in error"},
        )
        self.assertEqual(response.status_code, 302)
        certificate.refresh_from_db()
        self.assertIsNotNone(certificate.revoked_at)
        self.assertEqual(certificate.revoked_by, coordinator)
        self.assertEqual(certificate.revocation_reason, "Issued in error")

    def test_manager_cannot_submit_another_employees_final_assessment(self):
        self.complete_lessons()
        self.finish_attempt(self.quiz)
        final_attempt = self.start_attempt(self.final)
        manager = get_user_model().objects.create_user(username="attempt-manager")
        Group.objects.get(name="Manager").user_set.add(manager)

        response = self.client_for(manager).post(
            f"/attempts/{final_attempt.pk}/submit/",
            {f"answer_{self.final_item.pk}": self.correct_option.pk},
        )
        self.assertEqual(response.status_code, 404)
        self.assertEqual(Certificate.objects.filter(assignment=self.assignment).count(), 0)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, TrainingAssignment.Status.IN_PROGRESS)
