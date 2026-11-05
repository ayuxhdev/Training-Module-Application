from datetime import timedelta
from decimal import Decimal
from pathlib import Path

from django.conf import settings
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.exceptions import ValidationError
from django.db import IntegrityError, models, transaction
from django.test import Client
from django.utils import timezone

from assessments.models import Assessment, AssessmentAttempt, AssessmentQuestion, AttemptAnswer
from assessments.views import _try_complete_assignment
from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from organization.models import Employee
from training.models import Lesson, LessonProgress, Module, Training, TrainingAssignment, TrainingVersion
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

    def test_learner_certificate_pages_and_completed_assignment_link(self):
        Group.objects.get(name="Employee").user_set.add(self.employee_user)
        certificate = self.certificate(self.complete_assignment())
        certificate.save()
        client = self.client_for(self.employee_user)

        listing = client.get("/certificates/")
        self.assertContains(listing, certificate.certificate_number)
        self.assertContains(listing, 'aria-label="Certificates"')
        assignment_page = client.get(f"/assignments/{self.assignment.pk}/")
        self.assertContains(assignment_page, f"/certificates/{certificate.pk}/")
        detail = client.get(f"/certificates/{certificate.pk}/")
        self.assertContains(detail, certificate.employee_name_snapshot)
        self.assertContains(detail, certificate.training_title_snapshot)
        self.assertContains(detail, "Valid")
        self.assertNotContains(detail, "Revoke certificate")
        self.assertContains(client.get(f"/certificates/{certificate.pk}/"), certificate.certificate_number)

        coordinator = get_user_model().objects.create_user(username="certificate-frontend-coordinator")
        Group.objects.get(name="Training Coordinator").user_set.add(coordinator)
        coordinator_client = self.client_for(coordinator)
        self.assertContains(coordinator_client.get(f"/certificates/{certificate.pk}/"), "Revoke certificate")
        self.assertEqual(coordinator_client.post(
            f"/certificates/{certificate.pk}/revoke/", {"reason": "Issued in error"},
        ).status_code, 302)
        revoked = client.get(f"/certificates/{certificate.pk}/")
        self.assertContains(revoked, "Revoked")
        self.assertContains(revoked, "Issued in error")
        self.assertContains(client.get("/certificates/"), "Revoked")
        self.assertNotContains(coordinator_client.get(f"/certificates/{certificate.pk}/"), "Revoke certificate")

    def test_manager_team_assignment_does_not_link_to_private_certificate(self):
        certificate = self.certificate(self.complete_assignment())
        certificate.save()
        manager_user = get_user_model().objects.create_user(username="certificate-team-manager")
        Group.objects.get(name="Manager").user_set.add(manager_user)
        manager_employee = Employee.objects.create(
            employee_code="GN-MGR", display_name="Team manager", user=manager_user,
            department=self.department, job_role=self.role, date_joined=self.now.date(),
        )
        self.employee.reporting_manager = manager_employee
        self.employee.save()
        client = self.client_for(manager_user)
        assignment_page = client.get(f"/assignments/{self.assignment.pk}/")
        self.assertEqual(assignment_page.status_code, 200)
        self.assertNotContains(assignment_page, f"/certificates/{certificate.pk}/")
        self.assertNotContains(client.get("/certificates/"), certificate.certificate_number)
        self.assertEqual(client.get(f"/certificates/{certificate.pk}/").status_code, 404)

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

    def test_repeated_revocation_preserves_reason_and_one_event(self):
        certificate = self.certificate(self.complete_assignment())
        certificate.save()
        coordinator = get_user_model().objects.create_user(username="revocation-retry")
        Group.objects.get(name="Training Coordinator").user_set.add(coordinator)
        client = self.client_for(coordinator)
        path = f"/certificates/{certificate.pk}/revoke/"
        with self.captureOnCommitCallbacks(execute=True):
            self.assertEqual(client.post(path, {"reason": "Issued in error"}).status_code, 302)
        with self.captureOnCommitCallbacks(execute=True):
            self.assertEqual(client.post(path, {"reason": "Retry changed reason"}).status_code, 409)
        certificate.refresh_from_db()
        self.assertEqual(certificate.revocation_reason, "Issued in error")
        self.assertEqual(AuditLog.objects.filter(
            action="certifications.certificate.revoked", entity_id=str(certificate.pk),
        ).count(), 1)

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


class CertificatePrintTests(CurriculumTestCase):
    def client_for(self, user):
        client = Client()
        client.force_login(user)
        return client

    def certificate(self, attempt, **kwargs):
        values = dict(
            certificate_number="GN-CERT-PRINT-001",
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
        values.update(kwargs)
        return Certificate.objects.create(**values)

    def test_certificate_detail_page_includes_print_button_and_scoped_workspace(self):
        attempt = self.complete_assignment()
        certificate = self.certificate(attempt)
        client = self.client_for(self.employee_user)
        response = client.get(f"/certificates/{certificate.pk}/")

        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'class="catalog-workspace certificate-workspace"')
        self.assertContains(response, 'onclick="window.print()"')
        self.assertContains(response, "Print certificate")
        self.assertContains(response, 'class="certificate-credential-card"')
        self.assertContains(response, 'class="certificate-header-title"')
        self.assertContains(response, 'class="certificate-print-seal"')
        self.assertContains(response, "Garden’s Need Training Academy")

    def test_certificate_detail_preserves_verification_metadata_in_credential_card(self):
        attempt = self.complete_assignment()
        certificate = self.certificate(attempt)
        client = self.client_for(self.employee_user)
        response = client.get(f"/certificates/{certificate.pk}/")

        self.assertEqual(response.status_code, 200)
        self.assertContains(response, certificate.certificate_number)
        self.assertContains(response, certificate.employee_name_snapshot)
        self.assertContains(response, certificate.employee_code_snapshot)
        self.assertContains(response, certificate.training_title_snapshot)
        self.assertContains(response, f"Version {certificate.version_number_snapshot}")
        self.assertContains(response, "Verified Record")

    def test_revoked_certificate_renders_revocation_banner_directly_on_card(self):
        attempt = self.complete_assignment()
        certificate = self.certificate(
            attempt,
            certificate_number="GN-CERT-REVOKED-001",
            revoked_at=self.now + timedelta(seconds=200),
            revoked_by=self.user,
            revocation_reason="Procedural re-certification required",
        )
        client = self.client_for(self.employee_user)
        response = client.get(f"/certificates/{certificate.pk}/")

        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'class="certificate-revocation-banner"')
        self.assertContains(response, 'class="certificate-revocation-badge"')
        self.assertContains(response, "REVOKED")
        self.assertContains(response, "Procedural re-certification required")
        self.assertContains(response, "This certificate was revoked on")
        self.assertContains(response, "Revoked")

    def test_long_recipient_name_and_long_training_title_render_safely(self):
        long_name = "Dr. Bartholomew Alexander Montgomery-Chamberlain III, Senior Agronomy Specialist"
        long_title = "Advanced Industrial Horticultural Chemical Formulation & Hazardous Material Handling Protocol"
        self.employee.display_name = long_name
        self.employee.save()

        long_training = Training.objects.create(code="TR-LONG", catalog_title=long_title, created_by=self.user)
        long_version = TrainingVersion.objects.create(
            training=long_training, version_number=1, title=long_title, created_by=self.user,
        )
        module = Module.objects.create(training_version=long_version, title="Core Module", position=1)
        lesson = Lesson.objects.create(module=module, title="Intro Lesson", position=1, content_type="TEXT", body="Content")
        final = Assessment.objects.create(training_version=long_version, kind="FINAL", title="Final Exam")
        final_item = AssessmentQuestion.objects.create(assessment=final, question_revision=self.revision, position=1, points=Decimal("2.00"))
        long_version.status = "PUBLISHED"
        long_version.published_at = self.now
        long_version.published_by = self.user
        long_version.save()

        assignment = TrainingAssignment.objects.create(
            employee=self.employee, training_version=long_version,
            department_at_assignment=self.department, job_role_at_assignment=self.role,
            assigned_by=self.user, assigned_at=self.now, started_at=self.now,
            status=TrainingAssignment.Status.IN_PROGRESS,
        )
        LessonProgress.objects.create(
            assignment=assignment,
            lesson=lesson,
            started_at=self.now,
            last_accessed_at=self.now + timedelta(seconds=110),
            completed_at=self.now + timedelta(seconds=110),
        )
        attempt = AssessmentAttempt.objects.create(
            assignment=assignment,
            assessment=final,
            attempt_number=1,
            started_at=self.now + timedelta(seconds=120),
            maximum_points=Decimal("2.00"),
            pass_percentage_snapshot=Decimal("80.00"),
        )
        AttemptAnswer.objects.create(
            attempt=attempt,
            assessment_question=final_item,
            selected_option=self.correct_option,
            presented_position=1,
            answered_at=attempt.started_at + timedelta(seconds=1),
            points_possible=Decimal("2.00"),
            points_awarded=Decimal("2.00"),
            is_correct=True,
        )
        attempt.status = "SUBMITTED"
        attempt.submitted_at = attempt.started_at + timedelta(seconds=2)
        attempt.score_points = Decimal("2.00")
        attempt.passed = True
        attempt.save()

        assignment.status = TrainingAssignment.Status.COMPLETED
        assignment.completed_at = self.now + timedelta(seconds=130)
        assignment.save()
        certificate = Certificate.objects.create(
            certificate_number="GN-CERT-LONG-001",
            assignment=assignment,
            training_version=long_version,
            qualifying_final_attempt=attempt,
            issued_at=self.now + timedelta(seconds=140),
            employee_code_snapshot=self.employee.employee_code,
            employee_name_snapshot=long_name,
            training_title_snapshot=long_title,
            version_number_snapshot=1,
            issued_by=self.user,
        )
        client = self.client_for(self.employee_user)
        response = client.get(f"/certificates/{certificate.pk}/")

        self.assertEqual(response.status_code, 200)
        self.assertContains(response, long_name)
        self.assertContains(response, "Advanced Industrial Horticultural Chemical Formulation &amp; Hazardous Material Handling Protocol")
        self.assertContains(response, 'class="certificate-recipient"')
        self.assertContains(response, 'class="certificate-training-title"')

    def test_print_css_rules_configured_for_single_page_a4(self):
        css_path = Path(settings.BASE_DIR) / "accounts" / "static" / "accounts" / "shell.css"
        self.assertTrue(css_path.exists(), "shell.css must exist")
        css_content = css_path.read_text(encoding="utf-8")

        self.assertIn("@media print", css_content)
        self.assertIn("size: A4 portrait", css_content)
        self.assertIn(".app-shell-header", css_content)
        self.assertIn(".app-topbar", css_content)
        self.assertIn(".app-sidebar", css_content)
        self.assertIn(".certificate-workspace > .page-header", css_content)
        self.assertIn(".certificate-workspace > .catalog-panel", css_content)
        self.assertIn(".certificate-credential-card", css_content)
        self.assertIn("page-break-inside: avoid", css_content)
        self.assertIn("break-inside: avoid", css_content)

        # Ensure card does not use overflow: hidden or max-height: 255mm which truncate long content
        card_start = css_content.find(".certificate-credential-card {", css_content.find("@media print"))
        self.assertNotEqual(card_start, -1, ".certificate-credential-card print rule should exist")
        card_block = css_content[card_start:css_content.find("}", card_start)]
        self.assertNotIn("overflow: hidden", card_block)
        self.assertNotIn("max-height: 255mm", card_block)
        self.assertIn("overflow: visible", card_block)

    def test_revoked_certificate_with_multiline_reason_renders_with_line_breaks(self):
        attempt = self.complete_assignment()
        multiline_reason = "First finding of violation.\nSecond finding on appeal.\nFinal determination."
        certificate = self.certificate(
            attempt,
            certificate_number="GN-CERT-REVOKED-MULTI",
            revoked_at=self.now + timedelta(seconds=200),
            revoked_by=self.user,
            revocation_reason=multiline_reason,
        )
        client = self.client_for(self.employee_user)
        response = client.get(f"/certificates/{certificate.pk}/")

        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'class="certificate-revocation-reason"')
        self.assertContains(response, "First finding of violation.<br>Second finding on appeal.<br>Final determination.")

    def test_multipage_capable_certificate_displays_all_required_metadata(self):
        long_reason = (
            "Comprehensive audit identified non-compliance with statutory biological pathogen "
            "containment protocols during Q3 field inspection.\nCorrective action plan was not submitted "
            "within mandatory 30-day reporting window.\nImmediate revocation required under workplace safety code. "
        ) * 5  # ~850 characters
        attempt = self.complete_assignment()
        certificate = self.certificate(
            attempt,
            certificate_number="GN-CERT-REVOKED-MAX",
            revoked_at=self.now + timedelta(seconds=250),
            revoked_by=self.user,
            revocation_reason=long_reason,
        )
        client = self.client_for(self.employee_user)
        response = client.get(f"/certificates/{certificate.pk}/")

        self.assertEqual(response.status_code, 200)
        self.assertContains(response, certificate.certificate_number)
        self.assertContains(response, certificate.employee_name_snapshot)
        self.assertContains(response, certificate.training_title_snapshot)
        self.assertContains(response, 'class="certificate-revocation-badge"')
        self.assertContains(response, "REVOKED")
        self.assertContains(response, "Revoked")
        self.assertContains(response, "Garden’s Need Training Academy")
        self.assertContains(response, "<br>")
        self.assertContains(response, "Comprehensive audit identified non-compliance")
