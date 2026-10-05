from datetime import timedelta
from decimal import Decimal
from django.contrib.auth import get_user_model
from django.db import models
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from assessments.models import AssessmentAttempt
from certifications.models import Certificate
from config.model_test_utils import CurriculumTestCase
from organization.models import Department, Employee, JobRole
from training.models import Training, TrainingAssignment, TrainingVersion

User = get_user_model()


class EmployeeDashboardAPITests(CurriculumTestCase):
    def setUp(self):
        self.client = APIClient()
        self.dashboard_url = reverse("api:v1:dashboard")
        self.employee_user.is_active = True
        self.employee_user.set_password("password")
        self.employee_user.save()
        self.employee.is_active = True
        self.employee.deactivated_at = None
        self.employee.deactivation_reason = ""
        self.employee.save()

    def get_token_for(self, user):
        refresh = RefreshToken.for_user(user)
        return str(refresh.access_token)

    def auth_as(self, user):
        token = self.get_token_for(user)
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
        return token

    def create_extra_training(self, code_suffix=""):
        t = Training(
            code=f"TR-{code_suffix}",
            catalog_title=f"Training {code_suffix}",
            created_by=self.user,
        )
        models.Model.save(t, force_insert=True)
        v = TrainingVersion(
            training=t,
            version_number=1,
            title=f"Training {code_suffix} v1",
            created_by=self.user,
            status=TrainingVersion.Status.PUBLISHED,
            published_at=self.now,
            published_by=self.user,
        )
        models.Model.save(v, force_insert=True)
        return t, v

    def create_assignment(
        self,
        employee=None,
        version=None,
        status=TrainingAssignment.Status.ASSIGNED,
        due_at=None,
        started_at=None,
    ):
        if employee is None:
            employee = self.employee
        if version is None:
            _, version = self.create_extra_training(f"EXTRA-{TrainingAssignment.objects.count() + 1}")

        assigned_at = self.now - timedelta(days=2)
        values = {
            "employee": employee,
            "training_version": version,
            "status": status,
            "department_at_assignment": employee.department,
            "job_role_at_assignment": employee.job_role,
            "assigned_by": self.user,
            "assigned_at": assigned_at,
            "due_at": due_at,
        }
        if status == TrainingAssignment.Status.IN_PROGRESS:
            values["started_at"] = started_at or assigned_at
        elif status == TrainingAssignment.Status.CANCELLED:
            values["cancelled_at"] = timezone.now()
            values["cancellation_reason"] = "Test cancellation"
        elif status == TrainingAssignment.Status.COMPLETED:
            values["started_at"] = started_at or assigned_at
            values["completed_at"] = (started_at or assigned_at) + timedelta(hours=1)
            assignment = TrainingAssignment.objects.create(
                employee=employee,
                training_version=version,
                status=TrainingAssignment.Status.ASSIGNED,
                department_at_assignment=employee.department,
                job_role_at_assignment=employee.job_role,
                assigned_by=self.user,
                assigned_at=assigned_at,
                due_at=due_at,
            )
            assignment.status = TrainingAssignment.Status.COMPLETED
            assignment.started_at = values["started_at"]
            assignment.completed_at = values["completed_at"]
            assignment.save()
            return assignment

        return TrainingAssignment.objects.create(**values)

    def create_standalone_certificate(self, assignment, certificate_number, issued_at=None, revoked=False):
        issued = issued_at or timezone.now()
        attempt = AssessmentAttempt(
            assignment=assignment,
            assessment=self.final,
            attempt_number=AssessmentAttempt.objects.filter(assignment=assignment).count() + 1,
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
            certificate_number=certificate_number,
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

    # ==========================================
    # 1. AUTHENTICATION & PERMISSION TESTS
    # ==========================================

    def test_unauthenticated_request_returns_401(self):
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertEqual(response.data["error"]["code"], "not_authenticated")

    def test_valid_active_employee_returns_200(self):
        self.auth_as(self.employee_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("metrics", response.data)
        self.assertIn("action_required", response.data)
        self.assertIn("recent_certificates", response.data)

    def test_valid_active_employee_with_session_auth_returns_200(self):
        self.client.force_login(self.employee_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("metrics", response.data)

    def test_missing_employee_relation_returns_403(self):
        orphan_user = User.objects.create_user(username="orphan", password="password")
        self.auth_as(orphan_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(response.data["error"]["code"], "permission_denied")

    def test_inactive_employee_returns_403(self):
        deact_user = User.objects.create_user(username="deact_emp_usr", password="password")
        Employee.objects.create(
            employee_code="GN-DEACT-E",
            display_name="Deactivated Emp",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=deact_user,
            is_active=False,
            deactivated_at=timezone.now(),
            deactivation_reason="Left company",
        )
        self.client.force_authenticate(user=deact_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(response.data["error"]["code"], "permission_denied")

    def test_inactive_django_user_returns_auth_error(self):
        inact_user = User.objects.create_user(username="inact_user", password="password", is_active=False)
        Employee.objects.create(
            employee_code="GN-INACT-U",
            display_name="Inactive User Emp",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=inact_user,
        )
        token = str(RefreshToken.for_user(inact_user).access_token)
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
        response = self.client.get(self.dashboard_url)
        self.assertIn(
            response.status_code,
            [status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN],
        )

    # ==========================================
    # 2. IDOR PROTECTION & SCOPE TESTS
    # ==========================================

    def test_employee_a_cannot_see_employee_b_assignments(self):
        # Create Employee B with distinct assignments
        user_b = User.objects.create_user(username="emp_b_user", password="password")
        emp_b = Employee.objects.create(
            employee_code="GN-B01",
            display_name="Employee B",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=user_b,
        )
        _, v_b = self.create_extra_training("B_TRAIN")
        self.create_assignment(employee=emp_b, version=v_b, status=TrainingAssignment.Status.ASSIGNED)

        # Log in as Employee A
        self.auth_as(self.employee_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        # Employee A should not see Employee B's assignments in action_required
        train_ids = [item["training_id"] for item in response.data["action_required"]]
        self.assertNotIn(v_b.training_id, train_ids)

    def test_query_parameter_employee_id_does_not_alter_scope(self):
        # Create Employee B
        user_b = User.objects.create_user(username="emp_b_tamper", password="password")
        emp_b = Employee.objects.create(
            employee_code="GN-B02",
            display_name="Employee B Tamper",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=user_b,
        )
        _, v_b = self.create_extra_training("B_TAMPER")
        assign_b = self.create_assignment(employee=emp_b, version=v_b, status=TrainingAssignment.Status.ASSIGNED)

        # Log in as Employee A, tamper with query params
        self.auth_as(self.employee_user)
        response = self.client.get(f"{self.dashboard_url}?employee_id={emp_b.pk}&user_id={user_b.pk}")
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        action_ids = [item["id"] for item in response.data["action_required"]]
        self.assertNotIn(assign_b.pk, action_ids)

    def test_employee_a_cannot_see_employee_b_certificates(self):
        user_b = User.objects.create_user(username="cert_b_user", password="password")
        emp_b = Employee.objects.create(
            employee_code="GN-B-CERT",
            display_name="Employee B Cert",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=user_b,
        )
        assign_b = self.create_assignment(employee=emp_b, status=TrainingAssignment.Status.COMPLETED)
        self.create_standalone_certificate(assign_b, "GN-B-CERT-001")

        # Log in as Employee A (who has 0 certificates)
        self.auth_as(self.employee_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        cert_numbers = [c["certificate_number"] for c in response.data["recent_certificates"]]
        self.assertNotIn("GN-B-CERT-001", cert_numbers)
        self.assertEqual(response.data["metrics"]["certificates_count"], 0)

    # ==========================================
    # 3. METRICS ACCURACY TESTS
    # ==========================================

    def test_metrics_zero_assignments(self):
        clean_user = User.objects.create_user(username="clean_user", password="password")
        Employee.objects.create(
            employee_code="GN-CLEAN",
            display_name="Clean Employee",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=clean_user,
        )
        self.auth_as(clean_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        expected_metrics = {
            "total": 0,
            "assigned": 0,
            "in_progress": 0,
            "completed": 0,
            "cancelled": 0,
            "overdue": 0,
            "completion_percent": 0.0,
            "certificates_count": 0,
        }
        self.assertEqual(response.data["metrics"], expected_metrics)
        self.assertEqual(response.data["action_required"], [])
        self.assertEqual(response.data["recent_certificates"], [])

    def test_metrics_assigned_assignments_counted(self):
        self.create_assignment(status=TrainingAssignment.Status.ASSIGNED)
        self.auth_as(self.employee_user)
        response = self.client.get(self.dashboard_url)
        # self.assignment is IN_PROGRESS (1) + new ASSIGNED (1) = 2 total
        self.assertEqual(response.data["metrics"]["assigned"], 1)
        self.assertEqual(response.data["metrics"]["total"], 2)

    def test_metrics_in_progress_assignments_counted(self):
        self.auth_as(self.employee_user)
        response = self.client.get(self.dashboard_url)
        # self.assignment is IN_PROGRESS
        self.assertEqual(response.data["metrics"]["in_progress"], 1)

    def test_metrics_completed_assignments_counted(self):
        self.create_assignment(status=TrainingAssignment.Status.COMPLETED)
        self.auth_as(self.employee_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.data["metrics"]["completed"], 1)

    def test_metrics_cancelled_assignments_counted(self):
        self.create_assignment(status=TrainingAssignment.Status.CANCELLED)
        self.auth_as(self.employee_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.data["metrics"]["cancelled"], 1)

    def test_metrics_overdue_assignments_counted(self):
        # Overdue: status in (ASSIGNED, IN_PROGRESS) and due_at < now
        self.create_assignment(
            status=TrainingAssignment.Status.ASSIGNED,
            due_at=timezone.now() - timedelta(days=1),
        )
        self.auth_as(self.employee_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.data["metrics"]["overdue"], 1)

    def test_metrics_completion_percent_calculated(self):
        pct_user = User.objects.create_user(username="pct_user", password="password")
        pct_emp = Employee.objects.create(
            employee_code="GN-PCT",
            display_name="Percent Employee",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=pct_user,
        )
        self.create_assignment(employee=pct_emp, status=TrainingAssignment.Status.COMPLETED)
        self.create_assignment(employee=pct_emp, status=TrainingAssignment.Status.ASSIGNED)

        self.auth_as(pct_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.data["metrics"]["total"], 2)
        self.assertEqual(response.data["metrics"]["completed"], 1)
        self.assertEqual(response.data["metrics"]["completion_percent"], 50.0)

    def test_metrics_mixed_statuses_accurate(self):
        mix_user = User.objects.create_user(username="mix_user", password="password")
        mix_emp = Employee.objects.create(
            employee_code="GN-MIX",
            display_name="Mixed Employee",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=mix_user,
        )
        # 1 assigned (future due)
        self.create_assignment(employee=mix_emp, status=TrainingAssignment.Status.ASSIGNED, due_at=timezone.now() + timedelta(days=5))
        # 1 assigned (overdue)
        self.create_assignment(employee=mix_emp, status=TrainingAssignment.Status.ASSIGNED, due_at=timezone.now() - timedelta(days=2))
        # 1 in progress (future due)
        self.create_assignment(employee=mix_emp, status=TrainingAssignment.Status.IN_PROGRESS, due_at=timezone.now() + timedelta(days=3))
        # 1 completed
        self.create_assignment(employee=mix_emp, status=TrainingAssignment.Status.COMPLETED)
        # 1 cancelled
        self.create_assignment(employee=mix_emp, status=TrainingAssignment.Status.CANCELLED)

        self.auth_as(mix_user)
        response = self.client.get(self.dashboard_url)
        m = response.data["metrics"]
        self.assertEqual(m["total"], 5)
        self.assertEqual(m["assigned"], 2)
        self.assertEqual(m["in_progress"], 1)
        self.assertEqual(m["completed"], 1)
        self.assertEqual(m["cancelled"], 1)
        self.assertEqual(m["overdue"], 1)
        # eligible = 2 assigned + 1 in_progress + 1 completed = 4. 1 / 4 = 25.0%
        self.assertEqual(m["completion_percent"], 25.0)

    def test_revoked_certificate_excluded_from_count_and_list(self):
        cert_user = User.objects.create_user(username="cert_user", password="password")
        cert_emp = Employee.objects.create(
            employee_code="GN-CERT-EMP",
            display_name="Cert Employee",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=cert_user,
        )
        a1 = self.create_assignment(employee=cert_emp, status=TrainingAssignment.Status.COMPLETED)
        a2 = self.create_assignment(employee=cert_emp, status=TrainingAssignment.Status.COMPLETED)

        # 1 active certificate, 1 revoked certificate
        self.create_standalone_certificate(a1, "GN-ACTIVE-001", revoked=False)
        self.create_standalone_certificate(a2, "GN-REVOKED-002", revoked=True)

        self.auth_as(cert_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.data["metrics"]["certificates_count"], 1)
        cert_numbers = [c["certificate_number"] for c in response.data["recent_certificates"]]
        self.assertIn("GN-ACTIVE-001", cert_numbers)
        self.assertNotIn("GN-REVOKED-002", cert_numbers)

    def test_active_certificates_counted(self):
        cert_user = User.objects.create_user(username="count_cert_user", password="password")
        cert_emp = Employee.objects.create(
            employee_code="GN-CNT-EMP",
            display_name="Count Cert Employee",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=cert_user,
        )
        a1 = self.create_assignment(employee=cert_emp, status=TrainingAssignment.Status.COMPLETED)
        a2 = self.create_assignment(employee=cert_emp, status=TrainingAssignment.Status.COMPLETED)
        self.create_standalone_certificate(a1, "GN-C1", revoked=False)
        self.create_standalone_certificate(a2, "GN-C2", revoked=False)

        self.auth_as(cert_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.data["metrics"]["certificates_count"], 2)
        self.assertEqual(len(response.data["recent_certificates"]), 2)

    # ==========================================
    # 4. ORDERING & LIMIT TESTS
    # ==========================================

    def test_action_required_ordered_by_nearest_due_date(self):
        ord_user = User.objects.create_user(username="ord_user", password="password")
        ord_emp = Employee.objects.create(
            employee_code="GN-ORD-EMP",
            display_name="Order Employee",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=ord_user,
        )
        now = timezone.now()
        # Create with different due dates: day+5, day+1, day+3
        a_late = self.create_assignment(employee=ord_emp, status=TrainingAssignment.Status.ASSIGNED, due_at=now + timedelta(days=5))
        a_early = self.create_assignment(employee=ord_emp, status=TrainingAssignment.Status.ASSIGNED, due_at=now + timedelta(days=1))
        a_mid = self.create_assignment(employee=ord_emp, status=TrainingAssignment.Status.ASSIGNED, due_at=now + timedelta(days=3))

        self.auth_as(ord_user)
        response = self.client.get(self.dashboard_url)
        returned_ids = [item["id"] for item in response.data["action_required"]]
        self.assertEqual(returned_ids, [a_early.pk, a_mid.pk, a_late.pk])

    def test_recent_certificates_ordered_newest_first(self):
        ord_user = User.objects.create_user(username="cert_ord_user", password="password")
        ord_emp = Employee.objects.create(
            employee_code="GN-C-ORD-EMP",
            display_name="Cert Order Employee",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=ord_user,
        )
        a1 = self.create_assignment(employee=ord_emp, status=TrainingAssignment.Status.COMPLETED)
        a2 = self.create_assignment(employee=ord_emp, status=TrainingAssignment.Status.COMPLETED)
        a3 = self.create_assignment(employee=ord_emp, status=TrainingAssignment.Status.COMPLETED)

        now = timezone.now()
        c_old = self.create_standalone_certificate(a1, "CERT-OLD", issued_at=now - timedelta(days=10))
        c_new = self.create_standalone_certificate(a2, "CERT-NEW", issued_at=now - timedelta(days=1))
        c_mid = self.create_standalone_certificate(a3, "CERT-MID", issued_at=now - timedelta(days=5))

        self.auth_as(ord_user)
        response = self.client.get(self.dashboard_url)
        returned_numbers = [item["certificate_number"] for item in response.data["recent_certificates"]]
        self.assertEqual(returned_numbers, ["CERT-NEW", "CERT-MID", "CERT-OLD"])

    def test_action_required_limit_10(self):
        lim_user = User.objects.create_user(username="lim_user", password="password")
        lim_emp = Employee.objects.create(
            employee_code="GN-LIM-EMP",
            display_name="Limit Employee",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=lim_user,
        )
        now = timezone.now()
        # Create 12 actionable assignments
        for i in range(12):
            self.create_assignment(
                employee=lim_emp,
                status=TrainingAssignment.Status.ASSIGNED,
                due_at=now + timedelta(days=i + 1),
            )

        self.auth_as(lim_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(len(response.data["action_required"]), 10)

    def test_recent_certificates_limit_5(self):
        lim_user = User.objects.create_user(username="cert_lim_user", password="password")
        lim_emp = Employee.objects.create(
            employee_code="GN-CLIM-EMP",
            display_name="Cert Limit Employee",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=lim_user,
        )
        now = timezone.now()
        # Create 7 certificates
        for i in range(7):
            a = self.create_assignment(employee=lim_emp, status=TrainingAssignment.Status.COMPLETED)
            self.create_standalone_certificate(a, f"CERT-LIM-{i}", issued_at=now - timedelta(days=7 - i))

        self.auth_as(lim_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(len(response.data["recent_certificates"]), 5)
        self.assertEqual(response.data["metrics"]["certificates_count"], 7)

    def test_action_required_excludes_completed_and_cancelled_assignments(self):
        filter_user = User.objects.create_user(username="filter_user", password="password")
        filter_emp = Employee.objects.create(
            employee_code="GN-FLT-EMP",
            display_name="Filter Employee",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=filter_user,
        )
        a_assigned = self.create_assignment(employee=filter_emp, status=TrainingAssignment.Status.ASSIGNED)
        a_inprog = self.create_assignment(employee=filter_emp, status=TrainingAssignment.Status.IN_PROGRESS)
        a_completed = self.create_assignment(employee=filter_emp, status=TrainingAssignment.Status.COMPLETED)
        a_cancelled = self.create_assignment(employee=filter_emp, status=TrainingAssignment.Status.CANCELLED)

        self.auth_as(filter_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        action_ids = [item["id"] for item in response.data["action_required"]]
        self.assertIn(a_assigned.pk, action_ids)
        self.assertIn(a_inprog.pk, action_ids)
        self.assertNotIn(a_completed.pk, action_ids)
        self.assertNotIn(a_cancelled.pk, action_ids)
        self.assertEqual(len(action_ids), 2)

    def test_action_required_is_overdue_flag_accuracy(self):
        od_user = User.objects.create_user(username="od_user", password="password")
        od_emp = Employee.objects.create(
            employee_code="GN-OD-EMP",
            display_name="Overdue Flag Employee",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=od_user,
        )
        now = timezone.now()
        a_overdue = self.create_assignment(
            employee=od_emp,
            status=TrainingAssignment.Status.ASSIGNED,
            due_at=now - timedelta(days=2),
        )
        a_future = self.create_assignment(
            employee=od_emp,
            status=TrainingAssignment.Status.ASSIGNED,
            due_at=now + timedelta(days=2),
        )

        self.auth_as(od_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        action_map = {item["id"]: item["is_overdue"] for item in response.data["action_required"]}
        self.assertIs(action_map[a_overdue.pk], True)
        self.assertIs(action_map[a_future.pk], False)

    def test_deterministic_tie_breaker_ordering(self):
        tie_user = User.objects.create_user(username="tie_user", password="password")
        tie_emp = Employee.objects.create(
            employee_code="GN-TIE-EMP",
            display_name="Tie Employee",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=tie_user,
        )
        same_due = timezone.now() + timedelta(days=3)
        # Create two assignments with identical due_at; lower pk must precede higher pk (due_at ASC, pk ASC)
        a1 = self.create_assignment(employee=tie_emp, status=TrainingAssignment.Status.ASSIGNED, due_at=same_due)
        a2 = self.create_assignment(employee=tie_emp, status=TrainingAssignment.Status.ASSIGNED, due_at=same_due)

        same_issued = timezone.now() - timedelta(days=1)
        # Create two certificates with identical issued_at; higher pk must precede lower pk (-issued_at, -pk)
        c_assign1 = self.create_assignment(employee=tie_emp, status=TrainingAssignment.Status.COMPLETED)
        c_assign2 = self.create_assignment(employee=tie_emp, status=TrainingAssignment.Status.COMPLETED)
        c1 = self.create_standalone_certificate(c_assign1, "CERT-TIE-1", issued_at=same_issued)
        c2 = self.create_standalone_certificate(c_assign2, "CERT-TIE-2", issued_at=same_issued)

        self.auth_as(tie_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        action_ids = [item["id"] for item in response.data["action_required"]]
        self.assertEqual(action_ids, [a1.pk, a2.pk])

        cert_ids = [item["id"] for item in response.data["recent_certificates"]]
        self.assertEqual(cert_ids, [c2.pk, c1.pk])

    # ==========================================
    # 5. DATA EXPOSURE TESTS
    # ==========================================

    def test_dashboard_response_contains_only_intended_fields(self):
        # Create a completed assignment and certificate to populate recent_certificates
        cert_assign = self.create_assignment(status=TrainingAssignment.Status.COMPLETED)
        self.create_standalone_certificate(cert_assign, "GN-EXPOSURE-CERT")

        self.auth_as(self.employee_user)
        response = self.client.get(self.dashboard_url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        # Check top-level keys
        self.assertEqual(set(response.data.keys()), {"metrics", "action_required", "recent_certificates"})

        # Check metrics keys
        expected_metric_keys = {
            "total",
            "assigned",
            "in_progress",
            "completed",
            "cancelled",
            "overdue",
            "completion_percent",
            "certificates_count",
        }
        self.assertEqual(set(response.data["metrics"].keys()), expected_metric_keys)

        # Check action_required item keys
        expected_action_keys = {
            "id",
            "training_id",
            "training_title",
            "version_number",
            "status",
            "due_at",
            "is_overdue",
            "started_at",
        }
        if response.data["action_required"]:
            item = response.data["action_required"][0]
            self.assertEqual(set(item.keys()), expected_action_keys)
            self.assertNotIn("assigned_by", item)
            self.assertNotIn("department_at_assignment", item)

        # Check recent_certificates item keys
        expected_cert_keys = {
            "id",
            "certificate_number",
            "training_title",
            "version_number",
            "issued_at",
        }
        self.assertTrue(len(response.data["recent_certificates"]) > 0)
        cert_item = response.data["recent_certificates"][0]
        self.assertEqual(set(cert_item.keys()), expected_cert_keys)
        self.assertNotIn("qualifying_final_attempt", cert_item)
        self.assertNotIn("employee_code_snapshot", cert_item)
        self.assertNotIn("revocation_reason", cert_item)

        # Ensure no sensitive user fields anywhere in content
        content_str = str(response.content)
        self.assertNotIn("password", content_str)
        self.assertNotIn("is_staff", content_str)
        self.assertNotIn("is_superuser", content_str)
        self.assertNotIn("deactivation_reason", content_str)

    # ==========================================
    # 6. QUERY PERFORMANCE TEST
    # ==========================================

    def test_query_performance_with_assert_num_queries(self):
        perf_user = User.objects.create_user(username="perf_user", password="password")
        perf_emp = Employee.objects.create(
            employee_code="GN-PERF-EMP",
            display_name="Perf Employee",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
            user=perf_user,
        )
        for i in range(3):
            self.create_assignment(employee=perf_emp, status=TrainingAssignment.Status.ASSIGNED)
            a = self.create_assignment(employee=perf_emp, status=TrainingAssignment.Status.COMPLETED)
            self.create_standalone_certificate(a, f"GN-PERF-CERT-{i}")

        self.client.force_authenticate(user=perf_user)

        # With force_authenticate:
        # 1: assignment_metrics aggregate
        # 2: Certificate.count()
        # 3: action_required select_related
        # 4: recent_certificates list
        # Total = exactly 4 queries, zero N+1.
        with self.assertNumQueries(4):
            response = self.client.get(self.dashboard_url)
            self.assertEqual(response.status_code, status.HTTP_200_OK)
