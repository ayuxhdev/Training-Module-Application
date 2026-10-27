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

    def test_read_only_endpoints_and_reference_collections_reject_unsupported_mutations(self):
        self.authenticate(self.admin)
        for path in ("dashboard/", "employees/", f"employees/{self.employee.pk}/", "departments/", "job-roles/"):
            for method in ("post", "put", "patch", "delete"):
                if method == "post" and path in ("departments/", "job-roles/", "employees/"):
                    continue  # Explicitly authorized collection creation.
                if method == "patch" and path == f"employees/{self.employee.pk}/":
                    continue  # Batch 3B permits profile-only updates with change_employee.
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


class EmployeeDirectoryFilterAPITests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.admin = get_user_model().objects.create_user(username="filter-admin")
        cls.admin.groups.add(Group.objects.get(name="Administrator"))

        cls.manager_user = get_user_model().objects.create_user(username="filter-manager")
        cls.manager_user.groups.add(Group.objects.get(name="Manager"))

        cls.no_perm_user = get_user_model().objects.create_user(username="filter-noperm")

        cls.dept_prod = cls.department
        cls.dept_sales = Department.objects.create(code="FILTER-SALES", name="Sales")

        cls.role_op = cls.role
        cls.role_lead = JobRole.objects.create(code="FILTER-LEAD", name="Team Lead")

        cls.manager_emp = Employee.objects.create(
            user=cls.manager_user, employee_code="MGR-01", display_name="Alice Manager",
            department=cls.dept_prod, job_role=cls.role_lead, date_joined=cls.now.date(),
            is_active=True,
        )

        cls.sub_bob = Employee.objects.create(
            employee_code="SUB-BOB", display_name="Bob Operator", reporting_manager=cls.manager_emp,
            department=cls.dept_prod, job_role=cls.role_op, date_joined=cls.now.date(),
            is_active=True,
        )

        cls.sub_charlie = Employee.objects.create(
            employee_code="SUB-CHARLIE", display_name="Charlie Lead", reporting_manager=cls.manager_emp,
            department=cls.dept_sales, job_role=cls.role_lead, date_joined=cls.now.date(),
            is_active=True,
        )

        cls.sub_diana = Employee.objects.create(
            employee_code="SUB-DIANA", display_name="Diana Inactive", reporting_manager=cls.manager_emp,
            department=cls.dept_prod, job_role=cls.role_op, date_joined=cls.now.date(),
            is_active=False, deactivated_at=cls.now, deactivation_reason="Resigned",
        )

        cls.foreign_evan = Employee.objects.create(
            employee_code="FOR-EVAN", display_name="Evan Foreign",
            department=cls.dept_sales, job_role=cls.role_op, date_joined=cls.now.date(),
            is_active=True,
        )

    def setUp(self):
        self.client = APIClient()

    def authenticate(self, user):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + str(RefreshToken.for_user(user).access_token))

    def get_employees(self, query="", user=None):
        self.authenticate(user or self.admin)
        path = "/api/v1/management/employees/"
        if query:
            path += "?" + query.lstrip("?")
        return self.client.get(path)

    def test_unfiltered_directory_preserves_scope_and_returns_all_employees_including_inactive(self):
        admin_resp = self.get_employees(user=self.admin)
        self.assertEqual(admin_resp.status_code, 200)
        self.assertEqual(set(admin_resp.data), {"count", "next", "previous", "results"})
        admin_ids = {row["id"] for row in admin_resp.data["results"]}
        self.assertIn(self.foreign_evan.pk, admin_ids)
        self.assertIn(self.sub_diana.pk, admin_ids)
        self.assertIn(self.sub_bob.pk, admin_ids)
        self.assertIn(self.sub_charlie.pk, admin_ids)
        self.assertIn(self.manager_emp.pk, admin_ids)

        manager_resp = self.get_employees(user=self.manager_user)
        self.assertEqual(manager_resp.status_code, 200)
        manager_ids = {row["id"] for row in manager_resp.data["results"]}
        self.assertEqual(manager_ids, {self.manager_emp.pk, self.sub_bob.pk, self.sub_charlie.pk, self.sub_diana.pk})
        self.assertNotIn(self.foreign_evan.pk, manager_ids)

    def test_search_by_partial_display_name_case_insensitive(self):
        response = self.get_employees("search=bob")
        self.assertEqual(response.status_code, 200)
        matched_ids = {row["id"] for row in response.data["results"]}
        self.assertEqual(matched_ids, {self.sub_bob.pk})

        response = self.get_employees("search=CHARLIE")
        self.assertEqual(response.status_code, 200)
        matched_ids = {row["id"] for row in response.data["results"]}
        self.assertEqual(matched_ids, {self.sub_charlie.pk})

        response = self.get_employees("search=Lead")
        self.assertEqual(response.status_code, 200)
        matched_ids = {row["id"] for row in response.data["results"]}
        self.assertIn(self.sub_charlie.pk, matched_ids)

    def test_search_by_partial_employee_code_case_insensitive(self):
        response = self.get_employees("search=SUB-BOB")
        self.assertEqual(response.status_code, 200)
        matched_ids = {row["id"] for row in response.data["results"]}
        self.assertEqual(matched_ids, {self.sub_bob.pk})

        response = self.get_employees("search=sub-")
        self.assertEqual(response.status_code, 200)
        matched_ids = {row["id"] for row in response.data["results"]}
        self.assertEqual(matched_ids, {self.sub_bob.pk, self.sub_charlie.pk, self.sub_diana.pk})

        response = self.get_employees("search=mgr")
        self.assertEqual(response.status_code, 200)
        matched_ids = {row["id"] for row in response.data["results"]}
        self.assertIn(self.manager_emp.pk, matched_ids)

    def test_search_whitespace_handling(self):
        response = self.get_employees("search=%20Bob%20")
        self.assertEqual(response.status_code, 200)
        matched_ids = {row["id"] for row in response.data["results"]}
        self.assertEqual(matched_ids, {self.sub_bob.pk})

        blank_resp = self.get_employees("search=%20%20%20")
        self.assertEqual(blank_resp.status_code, 200)
        unfiltered_resp = self.get_employees()
        self.assertEqual(blank_resp.data["count"], unfiltered_resp.data["count"])

    def test_search_empty_results_when_no_match(self):
        response = self.get_employees("search=nonexistent_xyz")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["count"], 0)
        self.assertEqual(response.data["results"], [])

    def test_filter_by_department_id(self):
        response = self.get_employees(f"department_id={self.dept_sales.pk}")
        self.assertEqual(response.status_code, 200)
        matched_ids = {row["id"] for row in response.data["results"]}
        self.assertEqual(matched_ids, {self.sub_charlie.pk, self.foreign_evan.pk})

        empty_resp = self.get_employees("department_id=999999")
        self.assertEqual(empty_resp.status_code, 200)
        self.assertEqual(empty_resp.data["count"], 0)
        self.assertEqual(empty_resp.data["results"], [])

    def test_filter_by_job_role_id(self):
        response = self.get_employees(f"job_role_id={self.role_lead.pk}")
        self.assertEqual(response.status_code, 200)
        matched_ids = {row["id"] for row in response.data["results"]}
        self.assertEqual(matched_ids, {self.manager_emp.pk, self.sub_charlie.pk})

        empty_resp = self.get_employees("job_role_id=999999")
        self.assertEqual(empty_resp.status_code, 200)
        self.assertEqual(empty_resp.data["count"], 0)
        self.assertEqual(empty_resp.data["results"], [])

    def test_filter_by_is_active(self):
        active_resp = self.get_employees("is_active=true")
        self.assertEqual(active_resp.status_code, 200)
        for row in active_resp.data["results"]:
            self.assertTrue(row["is_active"])
        active_ids = {row["id"] for row in active_resp.data["results"]}
        self.assertNotIn(self.sub_diana.pk, active_ids)

        inactive_resp = self.get_employees("is_active=false")
        self.assertEqual(inactive_resp.status_code, 200)
        for row in inactive_resp.data["results"]:
            self.assertFalse(row["is_active"])
        inactive_ids = {row["id"] for row in inactive_resp.data["results"]}
        self.assertEqual(inactive_ids, {self.sub_diana.pk})

        one_resp = self.get_employees("is_active=1")
        self.assertEqual(one_resp.status_code, 200)
        self.assertEqual(one_resp.data["count"], active_resp.data["count"])

        zero_resp = self.get_employees("is_active=0")
        self.assertEqual(zero_resp.status_code, 200)
        self.assertEqual(zero_resp.data["count"], inactive_resp.data["count"])

    def test_combined_filters_narrow_results_correctly(self):
        query = f"department_id={self.dept_prod.pk}&job_role_id={self.role_op.pk}&is_active=true&search=Bob"
        response = self.get_employees(query)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["count"], 1)
        self.assertEqual(response.data["results"][0]["id"], self.sub_bob.pk)

        query_inactive = f"department_id={self.dept_prod.pk}&job_role_id={self.role_op.pk}&is_active=false"
        response_inactive = self.get_employees(query_inactive)
        self.assertEqual(response_inactive.status_code, 200)
        self.assertEqual(response_inactive.data["count"], 1)
        self.assertEqual(response_inactive.data["results"][0]["id"], self.sub_diana.pk)

        query_nomatch = f"department_id={self.dept_sales.pk}&job_role_id={self.role_op.pk}&is_active=false"
        response_nomatch = self.get_employees(query_nomatch)
        self.assertEqual(response_nomatch.status_code, 200)
        self.assertEqual(response_nomatch.data["count"], 0)
        self.assertEqual(response_nomatch.data["results"], [])

    def test_combined_filters_with_pagination(self):
        query = f"department_id={self.dept_prod.pk}&page_size=2&page=1"
        response_p1 = self.get_employees(query)
        self.assertEqual(response_p1.status_code, 200)
        self.assertGreater(response_p1.data["count"], 2)
        self.assertEqual(len(response_p1.data["results"]), 2)
        self.assertIsNotNone(response_p1.data["next"])
        self.assertIsNone(response_p1.data["previous"])

        response_p2 = self.get_employees(f"department_id={self.dept_prod.pk}&page_size=2&page=2")
        self.assertEqual(response_p2.status_code, 200)
        self.assertIsNotNone(response_p2.data["previous"])
        p1_ids = [r["id"] for r in response_p1.data["results"]]
        p2_ids = [r["id"] for r in response_p2.data["results"]]
        self.assertEqual(set(p1_ids).intersection(set(p2_ids)), set())

    def test_manager_scope_isolation_with_search_and_filters(self):
        resp_name = self.get_employees("search=Evan", user=self.manager_user)
        self.assertEqual(resp_name.status_code, 200)
        self.assertEqual(resp_name.data["count"], 0)
        self.assertEqual(resp_name.data["results"], [])

        resp_code = self.get_employees("search=FOR-EVAN", user=self.manager_user)
        self.assertEqual(resp_code.status_code, 200)
        self.assertEqual(resp_code.data["count"], 0)
        self.assertEqual(resp_code.data["results"], [])

        resp_dept = self.get_employees(f"department_id={self.dept_sales.pk}", user=self.manager_user)
        self.assertEqual(resp_dept.status_code, 200)
        self.assertEqual(resp_dept.data["count"], 1)
        self.assertEqual(resp_dept.data["results"][0]["id"], self.sub_charlie.pk)

        resp_active = self.get_employees("is_active=true", user=self.manager_user)
        self.assertEqual(resp_active.status_code, 200)
        mgr_active_ids = {r["id"] for r in resp_active.data["results"]}
        self.assertEqual(mgr_active_ids, {self.manager_emp.pk, self.sub_bob.pk, self.sub_charlie.pk})
        self.assertNotIn(self.foreign_evan.pk, mgr_active_ids)

    def test_invalid_query_parameters_return_400(self):
        invalid_cases = [
            ("department_id=invalid", "department_id"),
            ("department_id=-1", "department_id"),
            ("department_id=0", "department_id"),
            ("job_role_id=invalid", "job_role_id"),
            ("job_role_id=-1", "job_role_id"),
            ("job_role_id=0", "job_role_id"),
            ("is_active=not_a_bool", "is_active"),
            ("search=" + ("x" * 151), "search"),
        ]
        for query, field in invalid_cases:
            with self.subTest(query=query, field=field):
                response = self.get_employees(query)
                self.assertEqual(response.status_code, 400)
                self.assertIn("error", response.data)
                self.assertEqual(response.data["error"]["code"], "validation_error")
                self.assertIn(field, response.data["error"]["fields"])

    def test_unauthenticated_and_unauthorized_requests(self):
        unauth_client = APIClient()
        response = unauth_client.get("/api/v1/management/employees/")
        self.assertEqual(response.status_code, 401)

        noperm_resp = self.get_employees(user=self.no_perm_user)
        self.assertEqual(noperm_resp.status_code, 403)

    def test_unrecognized_query_parameters_are_ignored(self):
        response = self.get_employees("unrecognized_param=123")
        self.assertEqual(response.status_code, 200)
        unfiltered = self.get_employees()
        self.assertEqual(response.data["count"], unfiltered.data["count"])
