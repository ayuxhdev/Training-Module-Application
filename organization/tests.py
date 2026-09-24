from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.exceptions import ValidationError
from django.db.models.deletion import ProtectedError
from django.test import Client
from django.test import TestCase

from config.model_test_utils import CurriculumTestCase
from .models import Department, Employee, JobRole


class EmployeeTests(CurriculumTestCase):
    def test_builtin_user_model_retained(self):
        self.assertEqual(get_user_model()._meta.label, "auth.User")

    def test_deactivation_disables_login_and_preserves_assignment(self):
        self.employee.is_active = False
        self.employee.deactivation_reason = "Employment ended"
        self.employee.save()
        self.employee_user.refresh_from_db()
        self.assertFalse(self.employee_user.is_active)
        self.assertIsNotNone(self.employee.deactivated_at)
        self.assertEqual(self.employee.training_assignments.count(), 1)

    def test_deactivation_requires_reason(self):
        self.employee.is_active = False
        with self.assertRaises(ValidationError):
            self.employee.save()
        self.employee_user.refresh_from_db()
        self.assertTrue(self.employee_user.is_active)

    def test_employee_and_user_deletion_protected(self):
        with self.assertRaises(ValidationError):
            self.employee.delete()
        with self.assertRaises(ValidationError):
            Employee.objects.filter(pk=self.employee.pk).delete()
        with self.assertRaises(ProtectedError):
            self.employee_user.delete()

    def test_self_reporting_and_longer_cycles_rejected(self):
        manager = Employee.objects.create(employee_code="GN-002", display_name="Manager", department=self.department,
                                         job_role=self.role, date_joined=self.now.date())
        self.employee.reporting_manager = self.employee
        with self.assertRaises(ValidationError):
            self.employee.save()
        self.employee.reporting_manager = manager
        self.employee.save()
        manager.reporting_manager = self.employee
        with self.assertRaises(ValidationError):
            manager.save()

    def test_assignment_role_snapshot_survives_transfer(self):
        self.employee.job_role = JobRole.objects.create(code="QC", name="Quality inspector")
        self.employee.save()
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.job_role_at_assignment, self.role)

    def test_employee_code_cannot_be_reused_by_renaming(self):
        self.employee.employee_code = "CHANGED"
        with self.assertRaises(ValidationError):
            self.employee.save()


class OrganizationViewTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.department = Department.objects.create(code="PROD", name="Production")
        cls.other_department = Department.objects.create(code="WH", name="Warehouse")
        cls.role = JobRole.objects.create(code="OP", name="Operator")
        cls.manager_user = get_user_model().objects.create_user(username="manager", password="password")
        cls.employee_user = get_user_model().objects.create_user(username="employee", password="password")
        cls.other_user = get_user_model().objects.create_user(username="other", password="password")
        cls.admin_user = get_user_model().objects.create_user(username="admin", password="password")
        cls.coordinator_user = get_user_model().objects.create_user(username="coordinator", password="password")
        cls.bare_user = get_user_model().objects.create_user(username="bare", password="password")
        Group.objects.get(name="Administrator").user_set.add(cls.admin_user)
        Group.objects.get(name="Training Coordinator").user_set.add(cls.coordinator_user)
        Group.objects.get(name="Manager").user_set.add(cls.manager_user)
        Group.objects.get(name="Employee").user_set.add(cls.employee_user)
        Group.objects.get(name="Employee").user_set.add(cls.other_user)
        cls.manager = Employee.objects.create(employee_code="GN-100", display_name="Manager",
            department=cls.department, job_role=cls.role, date_joined="2026-01-01", user=cls.manager_user)
        cls.report = Employee.objects.create(employee_code="GN-101", display_name="Report",
            department=cls.department, job_role=cls.role, date_joined="2026-01-01", user=cls.employee_user,
            reporting_manager=cls.manager)
        cls.grandchild = Employee.objects.create(employee_code="GN-103", display_name="Grandchild",
            department=cls.department, job_role=cls.role, date_joined="2026-01-01",
            reporting_manager=cls.report)
        cls.other = Employee.objects.create(employee_code="GN-102", display_name="Other",
            department=cls.other_department, job_role=cls.role, date_joined="2026-01-01", user=cls.other_user)

    def test_manager_can_only_view_recursive_scope(self):
        client = Client()
        self.assertTrue(client.login(username="manager", password="password"))
        response = client.get("/employees/")
        self.assertContains(response, "Manager")
        self.assertContains(response, "Report")
        self.assertContains(response, "Grandchild")
        self.assertNotContains(response, "Other")
        self.assertEqual(client.get(f"/employees/{self.grandchild.pk}/").status_code, 200)
        self.assertEqual(client.get(f"/employees/{self.other.pk}/").status_code, 404)

    def test_employee_with_reports_can_only_view_own_record(self):
        client = Client()
        self.assertTrue(client.login(username="employee", password="password"))
        response = client.get("/employees/")
        self.assertContains(response, "Report")
        self.assertNotContains(response, "Grandchild")
        self.assertEqual(client.get(f"/employees/{self.grandchild.pk}/").status_code, 404)
        self.assertEqual(client.get(f"/employees/{self.manager.pk}/").status_code, 404)

    def test_employee_without_reports_can_only_view_own_record(self):
        client = Client()
        self.assertTrue(client.login(username="other", password="password"))
        response = client.get("/employees/")
        self.assertContains(response, "Other")
        self.assertNotContains(response, "Manager")
        self.assertNotContains(response, "Report")
        self.assertEqual(client.get(f"/employees/{self.other.pk}/").status_code, 200)
        self.assertEqual(client.get(f"/employees/{self.report.pk}/").status_code, 404)

    def test_unauthenticated_access_redirects_to_login(self):
        client = Client()
        for path in ("/employees/", f"/employees/{self.report.pk}/", "/departments/", "/job-roles/"):
            response = client.get(path)
            self.assertEqual(response.status_code, 302)
            self.assertTrue(response.url.startswith("/accounts/login/"))

    def test_normal_employee_cannot_deactivate_another_employee(self):
        client = Client()
        self.assertTrue(client.login(username="employee", password="password"))
        response = client.post(f"/employees/{self.manager.pk}/deactivate/", {"reason": "Unauthorized attempt"})
        self.assertEqual(response.status_code, 403)
        self.manager.refresh_from_db()
        self.assertTrue(self.manager.is_active)

    def test_manager_cannot_edit_employees(self):
        client = Client()
        self.assertTrue(client.login(username="manager", password="password"))
        get_response = client.get(f"/employees/{self.report.pk}/edit/")
        self.assertEqual(get_response.status_code, 404)
        post_response = client.post(f"/employees/{self.report.pk}/edit/", {
            "employee_code": self.report.employee_code,
            "display_name": "Attempted Edit",
            "department": self.report.department_id,
            "job_role": self.report.job_role_id,
            "date_joined": str(self.report.date_joined),
            "user": self.report.user_id,
        })
        self.assertEqual(post_response.status_code, 404)

    def test_manager_cannot_access_employees_outside_reporting_scope(self):
        client = Client()
        self.assertTrue(client.login(username="manager", password="password"))
        response = client.get(f"/employees/{self.other.pk}/")
        self.assertEqual(response.status_code, 404)

    def test_deactivation_requires_reason(self):
        client = Client()
        self.assertTrue(client.login(username="admin", password="password"))
        response = client.post(f"/employees/{self.report.pk}/deactivate/", {"reason": "   "})
        self.assertEqual(response.status_code, 400)
        self.report.refresh_from_db()
        self.assertTrue(self.report.is_active)
        self.assertIsNone(self.report.deactivated_at)

    def test_deactivation_reason_over_1000_characters_is_rejected(self):
        client = Client()
        self.assertTrue(client.login(username="admin", password="password"))
        long_reason = "r" * 1001
        response = client.post(f"/employees/{self.report.pk}/deactivate/", {"reason": long_reason})
        self.assertEqual(response.status_code, 400)
        self.report.refresh_from_db()
        self.assertTrue(self.report.is_active)

    def test_normal_employee_form_cannot_modify_activation_state(self):
        client = Client()
        self.assertTrue(client.login(username="admin", password="password"))
        edit_data = {
            "employee_code": self.report.employee_code,
            "display_name": "Updated Report Name",
            "department": self.report.department_id,
            "job_role": self.report.job_role_id,
            "date_joined": str(self.report.date_joined),
            "user": self.report.user_id,
            "is_active": "",
            "deactivation_reason": "Trying to deactivate via edit form",
        }
        response = client.post(f"/employees/{self.report.pk}/edit/", edit_data)
        self.assertEqual(response.status_code, 302)
        self.report.refresh_from_db()
        self.assertEqual(self.report.display_name, "Updated Report Name")
        self.assertTrue(self.report.is_active)
        self.assertIsNone(self.report.deactivated_at)

        deact_response = client.post(f"/employees/{self.report.pk}/deactivate/", {"reason": "Proper deactivation"})
        self.assertEqual(deact_response.status_code, 302)
        self.report.refresh_from_db()
        self.assertFalse(self.report.is_active)

        reactivate_data = {
            "employee_code": self.report.employee_code,
            "display_name": "Reactivated Name Attempt",
            "department": self.report.department_id,
            "job_role": self.report.job_role_id,
            "date_joined": str(self.report.date_joined),
            "user": self.report.user_id,
            "is_active": "on",
            "deactivation_reason": "",
        }
        response = client.post(f"/employees/{self.report.pk}/edit/", reactivate_data)
        self.assertEqual(response.status_code, 302)
        self.report.refresh_from_db()
        self.assertEqual(self.report.display_name, "Reactivated Name Attempt")
        self.assertFalse(self.report.is_active)

    def test_department_and_job_role_list_permissions(self):
        client = Client()
        self.assertTrue(client.login(username="bare", password="password"))
        for path in ("/departments/", "/job-roles/"):
            response = client.get(path)
            self.assertEqual(response.status_code, 403)

        self.assertTrue(client.login(username="employee", password="password"))
        for path in ("/departments/", "/job-roles/"):
            response = client.get(path)
            self.assertEqual(response.status_code, 200)

    def employee_data(self, code, user=None):
        return {
            "employee_code": code,
            "display_name": code,
            "user": user.pk if user else "",
            "department": self.department.pk,
            "job_role": self.role.pk,
            "date_joined": "2026-01-01",
        }

    def test_coordinator_cannot_link_superuser_or_administrator(self):
        superuser = get_user_model().objects.create_superuser(username="superuser", password="password", email="admin@example.test")
        administrator = get_user_model().objects.create_user(username="administrator")
        Group.objects.get(name="Administrator").user_set.add(administrator)
        self.client.force_login(self.coordinator_user)
        for code, user in (("GN-SUPER", superuser), ("GN-ADMIN", administrator)):
            with self.subTest(user=user.username):
                response = self.client.post("/employees/new/", self.employee_data(code, user))
                self.assertEqual(response.status_code, 200)
                self.assertIn("user", response.context["form"].errors)
                self.assertFalse(Employee.objects.filter(employee_code=code).exists())

    def test_coordinator_cannot_link_privileged_user_by_editing(self):
        superuser = get_user_model().objects.create_superuser(username="edit-superuser", password="password", email="edit@example.test")
        employee = Employee.objects.create(employee_code="GN-UNLINKED", display_name="Unlinked",
            department=self.department, job_role=self.role, date_joined="2026-01-01")
        self.client.force_login(self.coordinator_user)
        response = self.client.post(f"/employees/{employee.pk}/edit/", self.employee_data(employee.employee_code, superuser))
        self.assertEqual(response.status_code, 200)
        self.assertIn("user", response.context["form"].errors)
        employee.refresh_from_db()
        self.assertIsNone(employee.user_id)

    def test_coordinator_cannot_deactivate_privileged_linked_users(self):
        superuser = get_user_model().objects.create_superuser(username="linked-superuser", password="password", email="linked@example.test")
        administrator = get_user_model().objects.create_user(username="linked-administrator")
        Group.objects.get(name="Administrator").user_set.add(administrator)
        self.client.force_login(self.coordinator_user)
        for code, user in (("GN-LINKED-SUPER", superuser), ("GN-LINKED-ADMIN", administrator)):
            with self.subTest(user=user.username):
                employee = Employee.objects.create(employee_code=code, display_name=code,
                    department=self.department, job_role=self.role, date_joined="2026-01-01", user=user)
                response = self.client.post(f"/employees/{employee.pk}/deactivate/", {"reason": "Attempted"})
                self.assertEqual(response.status_code, 403)
                employee.refresh_from_db()
                user.refresh_from_db()
                self.assertTrue(employee.is_active)
                self.assertTrue(user.is_active)

    def test_staff_account_is_privileged(self):
        staff = get_user_model().objects.create_user(username="staff", is_staff=True)
        self.client.force_login(self.coordinator_user)
        response = self.client.post("/employees/new/", self.employee_data("GN-STAFF", staff))
        self.assertEqual(response.status_code, 200)
        self.assertIn("user", response.context["form"].errors)
        employee = Employee.objects.create(employee_code="GN-STAFF", display_name="Staff",
            department=self.department, job_role=self.role, date_joined="2026-01-01", user=staff)
        self.assertEqual(self.client.post(f"/employees/{employee.pk}/deactivate/", {"reason": "Attempted"}).status_code, 403)
        staff.refresh_from_db()
        self.assertTrue(staff.is_active)

    def test_administrator_can_manage_privileged_employee_account(self):
        superuser = get_user_model().objects.create_superuser(username="admin-target", password="password", email="target@example.test")
        self.client.force_login(self.admin_user)
        response = self.client.post("/employees/new/", self.employee_data("GN-ADMIN-TARGET", superuser))
        self.assertEqual(response.status_code, 302)
        employee = Employee.objects.get(employee_code="GN-ADMIN-TARGET")
        self.assertEqual(employee.user_id, superuser.pk)
        response = self.client.post(f"/employees/{employee.pk}/deactivate/", {"reason": "Approved deactivation"})
        self.assertEqual(response.status_code, 302)
        superuser.refresh_from_db()
        self.assertFalse(superuser.is_active)

    def test_coordinator_can_manage_ordinary_employee_accounts(self):
        ordinary = get_user_model().objects.create_user(username="ordinary")
        self.client.force_login(self.coordinator_user)
        self.assertEqual(self.client.post("/employees/new/", self.employee_data("GN-NO-LOGIN")).status_code, 302)
        self.assertIsNone(Employee.objects.get(employee_code="GN-NO-LOGIN").user_id)
        self.assertEqual(self.client.post("/employees/new/", self.employee_data("GN-ORDINARY", ordinary)).status_code, 302)
        employee = Employee.objects.get(employee_code="GN-ORDINARY")
        self.assertEqual(employee.user_id, ordinary.pk)
        self.assertEqual(self.client.post(f"/employees/{employee.pk}/deactivate/", {"reason": "Left company"}).status_code, 302)
        ordinary.refresh_from_db()
        self.assertFalse(ordinary.is_active)
