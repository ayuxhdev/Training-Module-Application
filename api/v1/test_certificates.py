from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.db import models
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient, APIRequestFactory, force_authenticate
from rest_framework_simplejwt.tokens import RefreshToken

from assessments.models import AssessmentAttempt
from certifications.models import Certificate
from certifications.services import issue_completed_assignment_certificate
from config.model_test_utils import CurriculumTestCase
from organization.models import Employee
from training.models import Training, TrainingAssignment, TrainingVersion

from .certificate_views import CertificateDetailView, CertificateListView

User = get_user_model()


# ---------------------------------------------------------------------------
# Shared test helpers
# ---------------------------------------------------------------------------

class _CertificateTestMixin:
    """Shared setup and data-creation helpers for certificate API tests."""

    def setUp(self):
        super().setUp()
        self.factory = APIRequestFactory()
        self.list_view = CertificateListView.as_view()
        self.detail_view = CertificateDetailView.as_view()

    # ------------------------------------------------------------------
    # Request helpers
    # ------------------------------------------------------------------

    def _list(self, user):
        """GET /api/v1/certificates/ as the given user (None = unauthenticated)."""
        request = self.factory.get("/api/v1/certificates/")
        if user is not None:
            force_authenticate(request, user=user)
        return self.list_view(request)

    def _detail(self, user, certificate_id):
        """GET /api/v1/certificates/<id>/ as the given user (None = unauthenticated)."""
        request = self.factory.get(f"/api/v1/certificates/{certificate_id}/")
        if user is not None:
            force_authenticate(request, user=user)
        return self.detail_view(request, certificate_id=certificate_id)

    # ------------------------------------------------------------------
    # Data-creation helpers
    # ------------------------------------------------------------------

    def _create_employee(
        self,
        code,
        name="Extra Employee",
        is_active=True,
        deactivation_reason="",
    ):
        """Create an independent active or inactive employee with a fresh Django user."""
        user = User.objects.create_user(
            username=f"u_{code.lower().replace('-', '_')}",
            password="password",
        )
        emp_kwargs = {
            "employee_code": code,
            "display_name": name,
            "department": self.department,
            "job_role": self.role,
            "date_joined": self.now.date(),
            "user": user,
            "is_active": is_active,
        }
        if not is_active:
            emp_kwargs["deactivated_at"] = timezone.now()
            emp_kwargs["deactivation_reason"] = deactivation_reason or "Left company"
        emp = Employee.objects.create(**emp_kwargs)
        return user, emp

    def _create_completed_assignment(self, employee=None):
        """Create a COMPLETED assignment on a freshly minted training version.

        Each call creates a new Training+TrainingVersion so that the unique
        (employee, training_version) constraint is never violated.
        """
        if employee is None:
            employee = self.employee

        suffix = Training.objects.count() + 1
        t = Training(
            code=f"CERT-TR-{suffix}",
            catalog_title=f"Certificate Training {suffix}",
            created_by=self.user,
        )
        models.Model.save(t, force_insert=True)

        v = TrainingVersion(
            training=t,
            version_number=1,
            title=f"Cert Training {suffix} v1",
            created_by=self.user,
            status=TrainingVersion.Status.PUBLISHED,
            published_at=self.now,
            published_by=self.user,
        )
        models.Model.save(v, force_insert=True)

        base = self.now - timedelta(days=5)
        assignment = TrainingAssignment(
            employee=employee,
            training_version=v,
            status=TrainingAssignment.Status.COMPLETED,
            department_at_assignment=employee.department,
            job_role_at_assignment=employee.job_role,
            assigned_by=self.user,
            assigned_at=base,
            started_at=base + timedelta(hours=1),
            completed_at=base + timedelta(hours=2),
        )
        models.Model.save(assignment, force_insert=True)
        return assignment

    def _create_certificate(
        self,
        assignment,
        cert_number=None,
        revoked=False,
        issued_at=None,
    ):
        """Create a Certificate row, bypassing model clean() for test isolation."""
        if cert_number is None:
            cert_number = f"GN-TEST-{Certificate.objects.count() + 1}"
        issued = issued_at or timezone.now()

        attempt = AssessmentAttempt(
            assignment=assignment,
            assessment=self.final,
            attempt_number=(
                AssessmentAttempt.objects.filter(assignment=assignment).count() + 1
            ),
            started_at=self.now,
            submitted_at=self.now + timedelta(minutes=5),
            status=AssessmentAttempt.Status.SUBMITTED,
            passed=True,
            score_points=Decimal("2.00"),
            maximum_points=Decimal("2.00"),
            pass_percentage_snapshot=self.final.pass_percentage,
        )
        models.Model.save(attempt, force_insert=True)

        cert = Certificate(
            certificate_number=cert_number,
            assignment=assignment,
            training_version=assignment.training_version,
            qualifying_final_attempt=attempt,
            issued_at=issued,
            employee_code_snapshot=assignment.employee.employee_code,
            employee_name_snapshot=assignment.employee.display_name,
            training_title_snapshot=assignment.training_version.title,
            version_number_snapshot=assignment.training_version.version_number,
            issued_by=self.user,
        )
        if revoked:
            cert.revoked_at = issued + timedelta(hours=1)
            cert.revocation_reason = "Revoked for test"
            cert.revoked_by = self.user
        models.Model.save(cert, force_insert=True)
        return cert


# ---------------------------------------------------------------------------
# 1. Certificate list endpoint
# ---------------------------------------------------------------------------

class CertificateListViewTests(_CertificateTestMixin, CurriculumTestCase):
    """Tests for GET /api/v1/certificates/."""

    # ---- Authentication & permissions ----------------------------------

    def test_unauthenticated_returns_401(self):
        response = self._list(user=None)
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_no_employee_relation_returns_403(self):
        orphan = User.objects.create_user(username="orphan_cert", password="pw")
        response = self._list(user=orphan)
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_inactive_employee_returns_403(self):
        inact_user, _ = self._create_employee(
            "GN-INACT-CERT",
            "Inactive Cert Emp",
            is_active=False,
            deactivation_reason="Left company",
        )
        response = self._list(user=inact_user)
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_active_employee_with_no_certificates_returns_empty_list(self):
        fresh_user, _ = self._create_employee("GN-EMPTY-CERT")
        response = self._list(user=fresh_user)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["results"], [])
        self.assertEqual(response.data["count"], 0)

    # ---- Own certificate visibility ------------------------------------

    def test_own_active_certificate_appears_in_list(self):
        assignment = self._create_completed_assignment()
        cert = self._create_certificate(assignment, cert_number="GN-OWN-001")

        response = self._list(user=self.employee_user)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        numbers = [c["certificate_number"] for c in response.data["results"]]
        self.assertIn("GN-OWN-001", numbers)

    def test_own_revoked_certificate_appears_with_is_revoked_true(self):
        assignment = self._create_completed_assignment()
        self._create_certificate(assignment, cert_number="GN-REV-001", revoked=True)

        response = self._list(user=self.employee_user)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        certs = {c["certificate_number"]: c for c in response.data["results"]}
        self.assertIn("GN-REV-001", certs)
        self.assertTrue(certs["GN-REV-001"]["is_revoked"])

    def test_own_active_certificate_has_is_revoked_false(self):
        assignment = self._create_completed_assignment()
        self._create_certificate(assignment, cert_number="GN-ACTIVE-LIST")

        response = self._list(user=self.employee_user)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        cert = next(c for c in response.data["results"] if c["certificate_number"] == "GN-ACTIVE-LIST")
        self.assertFalse(cert["is_revoked"])

    # ---- IDOR & scope isolation ----------------------------------------

    def test_employee_cannot_see_other_employee_certificate(self):
        other_user, other_emp = self._create_employee("GN-OTHER-C1")
        other_assign = self._create_completed_assignment(employee=other_emp)
        self._create_certificate(other_assign, cert_number="GN-OTHER-CERT-001")

        response = self._list(user=self.employee_user)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        numbers = [c["certificate_number"] for c in response.data["results"]]
        self.assertNotIn("GN-OTHER-CERT-001", numbers)

    def test_cannot_broaden_scope_via_query_params(self):
        other_user, other_emp = self._create_employee("GN-OTHER-C2")
        other_assign = self._create_completed_assignment(employee=other_emp)
        other_cert = self._create_certificate(other_assign, cert_number="GN-TAMPER-CERT")

        # Attempt injection via query parameters
        request = self.factory.get(
            f"/api/v1/certificates/?employee_id={other_emp.pk}&assignment_id={other_assign.pk}"
        )
        force_authenticate(request, user=self.employee_user)
        response = self.list_view(request)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        ids = [c["id"] for c in response.data["results"]]
        self.assertNotIn(other_cert.pk, ids)

    # ---- Ordering -------------------------------------------------------

    def test_certificates_ordered_newest_issued_first(self):
        now = timezone.now()
        a1 = self._create_completed_assignment()
        a2 = self._create_completed_assignment()
        a3 = self._create_completed_assignment()
        c_old = self._create_certificate(a1, cert_number="CERT-OLD", issued_at=now - timedelta(days=10))
        c_new = self._create_certificate(a2, cert_number="CERT-NEW", issued_at=now - timedelta(days=1))
        c_mid = self._create_certificate(a3, cert_number="CERT-MID", issued_at=now - timedelta(days=5))

        response = self._list(user=self.employee_user)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        numbers = [c["certificate_number"] for c in response.data["results"]]
        self.assertEqual(numbers, ["CERT-NEW", "CERT-MID", "CERT-OLD"])

    def test_tie_broken_by_pk_descending(self):
        same_issued = timezone.now() - timedelta(days=3)
        a1 = self._create_completed_assignment()
        a2 = self._create_completed_assignment()
        c1 = self._create_certificate(a1, cert_number="CERT-TIE-A", issued_at=same_issued)
        c2 = self._create_certificate(a2, cert_number="CERT-TIE-B", issued_at=same_issued)

        response = self._list(user=self.employee_user)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        ids = [c["id"] for c in response.data["results"]]
        self.assertGreater(c2.pk, c1.pk)
        self.assertEqual(ids.index(c2.pk), 0)
        self.assertEqual(ids.index(c1.pk), 1)

    # ---- Response fields -----------------------------------------------

    def test_list_item_contains_only_expected_fields(self):
        assignment = self._create_completed_assignment()
        self._create_certificate(assignment, cert_number="GN-FIELDS-TEST")

        response = self._list(user=self.employee_user)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(len(response.data["results"]) > 0)
        item = response.data["results"][0]
        expected = {"id", "certificate_number", "training_title", "version_number", "issued_at", "is_revoked"}
        self.assertEqual(set(item.keys()), expected)

    def test_sensitive_fields_absent_from_list(self):
        assignment = self._create_completed_assignment()
        self._create_certificate(assignment, cert_number="GN-SENSITIVE-LIST", revoked=True)

        response = self._list(user=self.employee_user)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        content = str(response.data)
        self.assertNotIn("revocation_reason", content)
        self.assertNotIn("revoked_by", content)
        self.assertNotIn("document_file", content)
        self.assertNotIn("qualifying_final_attempt", content)
        self.assertNotIn("employee_code_snapshot", content)

    def test_snapshot_fields_mapped_correctly(self):
        assignment = self._create_completed_assignment()
        cert = self._create_certificate(assignment, cert_number="GN-SNAP-TEST")

        response = self._list(user=self.employee_user)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        item = next(c for c in response.data["results"] if c["certificate_number"] == "GN-SNAP-TEST")
        self.assertEqual(item["training_title"], cert.training_title_snapshot)
        self.assertEqual(item["version_number"], cert.version_number_snapshot)

    # ---- Pagination -----------------------------------------------------

    def test_list_response_is_paginated(self):
        """Response must have pagination envelope even with no results."""
        response = self._list(user=self.employee_user)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("count", response.data)
        self.assertIn("results", response.data)


# ---------------------------------------------------------------------------
# 2. Certificate detail endpoint
# ---------------------------------------------------------------------------

class CertificateDetailViewTests(_CertificateTestMixin, CurriculumTestCase):
    """Tests for GET /api/v1/certificates/<id>/."""

    # ---- Authentication & permissions ----------------------------------

    def test_unauthenticated_returns_401(self):
        assignment = self._create_completed_assignment()
        cert = self._create_certificate(assignment)
        response = self._detail(user=None, certificate_id=cert.pk)
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_no_employee_relation_returns_403(self):
        orphan = User.objects.create_user(username="orphan_det", password="pw")
        assignment = self._create_completed_assignment()
        cert = self._create_certificate(assignment)
        response = self._detail(user=orphan, certificate_id=cert.pk)
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_inactive_employee_returns_403(self):
        inact_user, inact_emp = self._create_employee(
            "GN-INACT-DET",
            "Inactive Det Emp",
            is_active=False,
            deactivation_reason="Left company",
        )
        assignment = self._create_completed_assignment(employee=inact_emp)
        cert = self._create_certificate(assignment)
        response = self._detail(user=inact_user, certificate_id=cert.pk)
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    # ---- Own certificate retrieval -------------------------------------

    def test_own_active_certificate_returns_200(self):
        assignment = self._create_completed_assignment()
        cert = self._create_certificate(assignment, cert_number="GN-DET-001")

        response = self._detail(user=self.employee_user, certificate_id=cert.pk)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["certificate_number"], "GN-DET-001")

    def test_own_revoked_certificate_accessible_with_correct_flags(self):
        assignment = self._create_completed_assignment()
        cert = self._create_certificate(assignment, cert_number="GN-DET-REV", revoked=True)

        response = self._detail(user=self.employee_user, certificate_id=cert.pk)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data["is_revoked"])
        self.assertIsNotNone(response.data["revoked_at"])

    def test_active_certificate_revoked_at_is_null(self):
        assignment = self._create_completed_assignment()
        cert = self._create_certificate(assignment, cert_number="GN-DET-ACT")

        response = self._detail(user=self.employee_user, certificate_id=cert.pk)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(response.data["is_revoked"])
        self.assertIsNone(response.data["revoked_at"])

    # ---- IDOR & 404 protection -----------------------------------------

    def test_other_employee_certificate_returns_404(self):
        other_user, other_emp = self._create_employee("GN-OTHER-DET")
        other_assign = self._create_completed_assignment(employee=other_emp)
        other_cert = self._create_certificate(other_assign, cert_number="GN-OTHER-DET-001")

        # Logged in as self.employee_user but requesting other employee's cert
        response = self._detail(user=self.employee_user, certificate_id=other_cert.pk)
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_nonexistent_certificate_returns_404(self):
        response = self._detail(user=self.employee_user, certificate_id=999999)
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    # ---- Response fields -----------------------------------------------

    def test_detail_contains_expected_fields(self):
        assignment = self._create_completed_assignment()
        cert = self._create_certificate(assignment, cert_number="GN-FLDS-DET")

        response = self._detail(user=self.employee_user, certificate_id=cert.pk)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        expected = {
            "id",
            "certificate_number",
            "training_title",
            "version_number",
            "employee_name",
            "employee_code",
            "issued_at",
            "is_revoked",
            "revoked_at",
            "assignment_id",
            "has_document",
        }
        self.assertEqual(set(response.data.keys()), expected)

    def test_detail_snapshot_fields_correct(self):
        assignment = self._create_completed_assignment()
        cert = self._create_certificate(assignment, cert_number="GN-SNAP-DET")

        response = self._detail(user=self.employee_user, certificate_id=cert.pk)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["training_title"], cert.training_title_snapshot)
        self.assertEqual(response.data["version_number"], cert.version_number_snapshot)
        self.assertEqual(response.data["employee_name"], cert.employee_name_snapshot)
        self.assertEqual(response.data["employee_code"], cert.employee_code_snapshot)
        self.assertEqual(response.data["assignment_id"], assignment.pk)

    def test_detail_has_document_false_when_no_file(self):
        assignment = self._create_completed_assignment()
        cert = self._create_certificate(assignment, cert_number="GN-DOC-FALSE")

        response = self._detail(user=self.employee_user, certificate_id=cert.pk)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(response.data["has_document"])

    def test_sensitive_fields_absent_from_detail(self):
        assignment = self._create_completed_assignment()
        cert = self._create_certificate(
            assignment, cert_number="GN-SENSITIVE-DET", revoked=True
        )

        response = self._detail(user=self.employee_user, certificate_id=cert.pk)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        content = str(response.data)
        self.assertNotIn("revocation_reason", content)
        self.assertNotIn("revoked_by", content)
        self.assertNotIn("document_file", content)
        self.assertNotIn("qualifying_final_attempt", content)
        self.assertNotIn("employee_code_snapshot", content)
        self.assertNotIn("employee_name_snapshot", content)


class CertificateRouteTests(CurriculumTestCase):
    """Exercise registered URLs with real JWT authentication, not forced users."""

    def setUp(self):
        self.complete_assignment()
        self.certificate = issue_completed_assignment_certificate(self.assignment.pk)
        self.client = APIClient()
        self.token = str(RefreshToken.for_user(self.employee_user).access_token)
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {self.token}")
        self.list_url = reverse("api:v1:certificate-list")
        self.detail_url = reverse("api:v1:certificate-detail", args=[self.certificate.pk])

    def test_registered_routes_are_jwt_only_and_malformed_ids_use_error_envelope(self):
        self.assertEqual(self.client.get(self.list_url).status_code, 200)
        self.assertEqual(self.client.get(self.detail_url).status_code, 200)
        self.client.credentials()
        self.client.force_login(self.employee_user)
        for url in (self.list_url, self.detail_url):
            self.assertEqual(self.client.get(url).status_code, 401)
        for token in ("invalid", self._expired_token()):
            self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
            self.assertEqual(self.client.get(self.detail_url).status_code, 401)
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {self.token}")
        for url in ("/api/v1/certificates/bad/", "/api/v1/certificates/-1/", "/api/v1/certificates/0/"):
            response = self.client.get(url)
            self.assertEqual(response.status_code, 404)
            self.assertIn("error", response.data)

    def _expired_token(self):
        token = RefreshToken.for_user(self.employee_user).access_token
        token.set_exp(lifetime=timedelta(seconds=-1))
        return str(token)

    def test_other_employee_including_staff_cannot_escape_ownership_scope(self):
        user = User.objects.create_user(username="certificate-route-other", is_staff=True, is_superuser=True)
        Employee.objects.create(employee_code="CERT-ROUTE-OTHER", display_name="Other QA",
            department=self.department, job_role=self.role, date_joined=self.now.date(), user=user)
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {RefreshToken.for_user(user).access_token}")
        response = self.client.get(self.list_url, {"employee_id": self.employee.pk})
        self.assertEqual(response.data["results"], [])
        self.assertEqual(self.client.get(self.detail_url).status_code, 404)

    def test_inactive_user_or_employee_cannot_access_existing_certificate(self):
        self.employee.is_active = False
        self.employee.deactivation_reason = "QA inactive"
        self.employee.save()
        self.assertEqual(self.client.get(self.detail_url).status_code, 401)
        # Test the independent Employee permission guard with an enabled login.
        self.employee_user.is_active = True
        self.employee_user.save()
        self.assertEqual(self.client.get(self.list_url).status_code, 403)

    def test_snapshots_retired_version_and_revocation_remain_read_only(self):
        self.employee.display_name = "Changed current name"
        self.employee.save()
        self.training.catalog_title = "Changed catalog"
        self.training.save()
        self.version.status = TrainingVersion.Status.RETIRED
        self.version.save()
        self.certificate.revoked_at = timezone.now()
        self.certificate.revoked_by = self.user
        self.certificate.revocation_reason = "QA revoked"
        self.certificate.save()
        before = list(Certificate.objects.values())
        response = self.client.get(self.detail_url)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["employee_name"], self.certificate.employee_name_snapshot)
        self.assertEqual(response.data["training_title"], self.certificate.training_title_snapshot)
        self.assertTrue(response.data["is_revoked"])
        self.assertIsNotNone(response.data["revoked_at"])
        for url in (self.list_url, self.detail_url):
            for method in ("post", "put", "patch", "delete"):
                self.assertEqual(getattr(self.client, method)(url, {}).status_code, 405)
        self.assertEqual(list(Certificate.objects.values()), before)


class CertificatePaginationRouteTests(_CertificateTestMixin, CurriculumTestCase):
    def test_registered_pagination_keeps_scope_across_pages(self):
        first = self._create_certificate(self._create_completed_assignment(), cert_number="PAGE-A")
        second = self._create_certificate(self._create_completed_assignment(), cert_number="PAGE-B")
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION=f"Bearer {RefreshToken.for_user(self.employee_user).access_token}")
        page1 = client.get(reverse("api:v1:certificate-list"), {"page_size": 1})
        page2 = client.get(reverse("api:v1:certificate-list"), {"page": 2, "page_size": 1})
        self.assertEqual(page1.data["count"], 2)
        self.assertIsNotNone(page1.data["next"])
        self.assertEqual({page1.data["results"][0]["id"], page2.data["results"][0]["id"]}, {first.pk, second.pk})
