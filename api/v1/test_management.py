from datetime import timedelta

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from assessments.models import AssessmentAttempt, AttemptAnswer
from audit.models import AuditLog
from certifications.models import Certificate
from config.model_test_utils import CurriculumTestCase
from notifications.models import Notification
from organization.models import Department, Employee, JobRole
from reports.queries import assignment_metrics, assignment_queryset_for_user
from training.models import LessonProgress, TrainingAssignment, VideoWatchSession


class ManagementReadAPITests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.admin = get_user_model().objects.create_user(username="read-admin")
        cls.admin.groups.add(Group.objects.get(name="Administrator"))
        cls.manager = get_user_model().objects.create_user(username="read-manager")
        cls.manager.groups.add(Group.objects.get(name="Manager"))
        cls.manager_employee = Employee.objects.create(
            user=cls.manager, employee_code="MGR", display_name="Manager",
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(),
        )
        cls.employee_user.groups.add(Group.objects.get(name="Employee"))
        cls.employee.reporting_manager = cls.manager_employee
        cls.employee.save()
        cls.descendant = Employee.objects.create(
            employee_code="DESC", display_name="Employee Two", reporting_manager=cls.employee,
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(),
        )
        cls.foreign = Employee.objects.create(
            employee_code="FOREIGN", display_name="Outside Team",
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(),
        )
        cls.descendant_assignment = cls.assignment_for(cls.descendant, due_at=timezone.now() - timedelta(minutes=1))
        cls.foreign_assignment = cls.assignment_for(cls.foreign)

    @classmethod
    def assignment_for(cls, employee, **kwargs):
        return TrainingAssignment.objects.create(
            employee=employee, training_version=cls.version, department_at_assignment=cls.department,
            job_role_at_assignment=cls.role, assigned_by=cls.user, assigned_at=cls.now, **kwargs,
        )

    def setUp(self):
        self.client = APIClient()

    def authenticate(self, user):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + str(RefreshToken.for_user(user).access_token))

    def get(self, path, user=None):
        self.authenticate(user or self.admin)
        return self.client.get("/api/v1/management/" + path)

    def test_company_dashboard_matches_existing_reporting_and_supports_no_employee_account(self):
        response = self.get("dashboard/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["scope"], "company")
        self.assertEqual(response.data["metrics"], assignment_metrics(assignment_queryset_for_user(self.admin)))
        self.assertEqual(response.data["summary"], {
            "active_employee_count": 4, "department_count": 1,
            "published_training_count": 1, "certificates_issued": 0,
        })
        self.assertEqual(response.data["incomplete_employees"], [])
        self.assertEqual(self.client.get("/api/v1/assignments/").status_code, 403)

    def test_team_dashboard_includes_self_and_recursive_descendants_only(self):
        response = self.get("dashboard/?scope=company&employee_id=" + str(self.foreign.pk), self.manager)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["scope"], "team")
        self.assertEqual(response.data["metrics"], assignment_metrics(assignment_queryset_for_user(self.manager)))
        self.assertEqual(response.data["metrics"]["total"], 2)
        self.assertEqual(response.data["metrics"]["overdue"], 1)
        self.assertEqual(response.data["summary"]["employees_in_scope"], 3)
        self.assertEqual({row["employee_id"] for row in response.data["incomplete_employees"]},
                         {self.employee.pk, self.descendant.pk})
        # Management visibility never grants another person's learning access.
        self.assertEqual(self.client.get(f"/api/v1/assignments/{self.assignment.pk}/").status_code, 404)

    def test_company_precedes_team_for_combined_permissions(self):
        self.manager.groups.add(Group.objects.get(name="Administrator"))
        response = self.get("dashboard/", self.manager)
        self.assertEqual(response.data["scope"], "company")
        self.assertEqual(response.data["metrics"]["total"], 3)
        self.assertIn(self.foreign.pk, {row["id"] for row in self.client.get("/api/v1/management/employees/").data["results"]})

    def test_employee_directory_and_details_follow_portal_scope(self):
        for user, expected in ((self.admin, {self.manager_employee.pk, self.employee.pk, self.descendant.pk, self.foreign.pk}),
                               (self.manager, {self.manager_employee.pk, self.employee.pk, self.descendant.pk}),
                               (self.employee_user, {self.employee.pk})):
            with self.subTest(user=user.username):
                response = self.get("employees/?employee_id=" + str(self.foreign.pk), user)
                self.assertEqual(response.status_code, 200)
                self.assertEqual({row["id"] for row in response.data["results"]}, expected)
        response = self.get(f"employees/{self.descendant.pk}/", self.manager)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["reporting_manager"], self.employee.display_name)
        self.assertEqual(response.data["date_joined"], self.descendant.date_joined.isoformat())
        self.assertEqual(response.data["login_status"], "NOT_LINKED")
        self.assertNotIn("user", response.data)
        self.assertNotIn("deactivation_reason", response.data)

    def test_foreign_and_unknown_employee_ids_are_hidden(self):
        for user in (self.manager, self.employee_user):
            for employee_id in (self.foreign.pk, 999999, 0):
                with self.subTest(user=user.username, employee=employee_id):
                    response = self.get(f"employees/{employee_id}/", user)
                    self.assertEqual(response.status_code, 404)
                    self.assertIn("error", response.data)

    def test_direct_permissions_match_existing_global_employee_management_gate(self):
        self.manager.user_permissions.add(Permission.objects.get(codename="change_employee", content_type__app_label="organization"))
        response = self.get("employees/", self.manager)
        self.assertIn(self.foreign.pk, {row["id"] for row in response.data["results"]})
        # Employee management and company reporting use different portal gates.
        self.assertEqual(self.client.get("/api/v1/management/dashboard/").data["scope"], "team")

    def test_directory_pagination_is_stable_and_does_not_expand_scope(self):
        first = self.get("employees/?page_size=1", self.manager)
        repeated = self.client.get("/api/v1/management/employees/?page_size=1")
        self.assertEqual(first.data, repeated.data)
        self.assertEqual(first.data["count"], 3)
        ids = []
        for page in range(1, 4):
            response = self.client.get(f"/api/v1/management/employees/?page_size=1&page={page}")
            ids += [row["id"] for row in response.data["results"]]
        self.assertEqual(len(set(ids)), 3)
        self.assertNotIn(self.foreign.pk, ids)
        self.assertEqual(self.client.get("/api/v1/management/employees/?page=999999").status_code, 404)

    def test_directory_tie_breaks_equal_names_by_primary_key(self):
        self.descendant.display_name = self.employee.display_name
        self.descendant.save()
        rows = self.get("employees/", self.manager).data["results"]
        equal_names = [row["id"] for row in rows if row["display_name"] == self.employee.display_name]
        self.assertEqual(equal_names, sorted((self.employee.pk, self.descendant.pk)))

    def test_reference_lists_are_authorized_global_and_include_inactive_entries(self):
        Department.objects.create(code="INACTIVE", name="Inactive department", is_active=False)
        JobRole.objects.create(code="INACTIVE", name="Inactive role", is_active=False)
        for path in ("departments/", "job-roles/"):
            for user in (self.admin, self.manager, self.employee_user):
                with self.subTest(path=path, user=user.username):
                    response = self.get(path, user)
                    self.assertEqual(response.status_code, 200)
                    self.assertEqual(response.data["count"], 2)
                    inactive = next(row for row in response.data["results"] if not row["is_active"])
                    self.assertEqual(inactive["code"], "INACTIVE")
                    self.assertEqual(set(inactive), {"id", "code", "name", "description", "is_active"})

    def test_reference_pagination_uses_stable_name_and_pk_order(self):
        for model, path in ((Department, "departments/"), (JobRole, "job-roles/")):
            with self.subTest(path=path):
                first = model.objects.create(code="TIE1", name="Same")
                second = model.objects.create(code="TIE2", name="Same")
                ids = []
                for page in (1, 2, 3):
                    response = self.get(f"{path}?page_size=1&page={page}")
                    self.assertEqual(response.data["count"], 3)
                    ids += [row["id"] for row in response.data["results"]]
                self.assertLess(ids.index(first.pk), ids.index(second.pk))

    def test_permission_loss_takes_effect_with_existing_jwt(self):
        self.authenticate(self.manager)
        self.manager.groups.clear()
        for path in ("dashboard/", "employees/", f"employees/{self.descendant.pk}/", "departments/", "job-roles/"):
            with self.subTest(path=path):
                response = self.client.get("/api/v1/management/" + path)
                self.assertEqual(response.status_code, 403)
                self.assertIn("error", response.data)
        self.assertEqual(self.client.get("/api/v1/assignments/").status_code, 200)

    def test_management_only_account_needs_each_requested_permission(self):
        viewer = get_user_model().objects.create_user(username="audit-only")
        viewer.user_permissions.add(Permission.objects.get(codename="view_auditlog", content_type__app_label="audit"))
        for path in ("dashboard/", "employees/", "departments/", "job-roles/"):
            self.assertEqual(self.get(path, viewer).status_code, 403)

    def test_employee_cannot_access_company_or_team_dashboard(self):
        self.assertEqual(self.get("dashboard/", self.employee_user).status_code, 403)
        self.assertEqual(self.client.get("/api/v1/dashboard/").status_code, 200)

    def test_jwt_is_required_and_inactive_accounts_are_denied(self):
        paths = ("dashboard/", "employees/", f"employees/{self.employee.pk}/", "departments/", "job-roles/")
        self.client.force_login(self.admin)
        for path in paths:
            self.assertEqual(self.client.get("/api/v1/management/" + path).status_code, 401)
        self.authenticate(self.manager)
        self.manager_employee.is_active = False
        self.manager_employee.deactivation_reason = "Isolated test"
        self.manager_employee.save()
        for path in paths:
            self.assertEqual(self.client.get("/api/v1/management/" + path).status_code, 401)

    def test_inactive_employee_does_not_bypass_with_reenabled_user(self):
        self.authenticate(self.manager)
        self.manager_employee.is_active = False
        self.manager_employee.deactivation_reason = "Isolated test"
        self.manager_employee.save()
        self.manager.is_active = True
        self.manager.save()
        self.assertEqual(self.client.get("/api/v1/management/employees/").status_code, 403)

    def test_all_management_endpoints_reject_mutations(self):
        self.authenticate(self.admin)
        for path in ("dashboard/", "employees/", f"employees/{self.employee.pk}/", "departments/", "job-roles/"):
            for method in ("post", "put", "patch", "delete"):
                with self.subTest(path=path, method=method):
                    response = getattr(self.client, method)("/api/v1/management/" + path, {}, format="json")
                    self.assertEqual(response.status_code, 405)
                    self.assertIn("error", response.data)

    def test_dashboard_failure_information_is_scoped_and_has_no_answer_content(self):
        self.complete_lessons()
        self.finish_attempt(correct=False)
        foreign_attempt = AssessmentAttempt.objects.create(
            assignment=self.foreign_assignment, assessment=self.quiz, attempt_number=1,
            started_at=self.now, deadline_at=self.now + timedelta(minutes=1),
            maximum_points="2.00", pass_percentage_snapshot=self.quiz.pass_percentage,
        )
        AttemptAnswer.objects.create(
            attempt=foreign_attempt, assessment_question=self.quiz_item, selected_option=self.wrong_option,
            presented_position=1, answered_at=self.now + timedelta(seconds=1),
            points_possible="2.00", points_awarded="0.00", is_correct=False,
        )
        foreign_attempt.status = "SUBMITTED"
        foreign_attempt.submitted_at = self.now + timedelta(seconds=2)
        foreign_attempt.score_points = "0.00"
        foreign_attempt.passed = False
        foreign_attempt.save()
        response = self.get("dashboard/", self.manager)
        self.assertEqual(len(response.data["recent_failures"]), 1)
        failure = response.data["recent_failures"][0]
        self.assertEqual(failure["employee_name"], self.employee.display_name)
        self.assertEqual(set(failure), {"assessment_title", "employee_name", "score_points", "maximum_points", "submitted_at"})

    def test_get_requests_do_not_mutate_business_records(self):
        models = (Employee, Department, JobRole, TrainingAssignment, LessonProgress, VideoWatchSession,
                  AssessmentAttempt, Certificate, Notification, AuditLog)
        counts = [model.objects.count() for model in models]
        for path in ("dashboard/", "employees/", f"employees/{self.employee.pk}/", "departments/", "job-roles/"):
            self.assertEqual(self.get(path).status_code, 200)
        self.assertEqual([model.objects.count() for model in models], counts)
