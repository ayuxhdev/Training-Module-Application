from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.exceptions import ValidationError
from django.db.models.deletion import ProtectedError
from django.test import Client
from django.test import TestCase

from audit.models import AuditLog
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
        self.assertNotContains(response, "Add employee")
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
        self.assertNotContains(response, self.report.employee_code)
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
        self.assertContains(response, "This field is required.", status_code=400)
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
            self.assertNotContains(response, ">Add department<")
            self.assertNotContains(response, ">Add job role<")

    def test_coordinator_reference_pages_link_to_existing_edit_routes(self):
        client = Client()
        client.force_login(self.coordinator_user)
        departments = client.get("/departments/")
        job_roles = client.get("/job-roles/")
        self.assertContains(departments, f"/departments/{self.department.pk}/edit/")
        self.assertContains(job_roles, f"/job-roles/{self.role.pk}/edit/")
        self.assertContains(departments, ">Add department</a>")
        self.assertContains(job_roles, ">Add job role</a>")
        self.assertEqual(client.get(f"/departments/{self.department.pk}/edit/").status_code, 200)
        self.assertEqual(client.get(f"/job-roles/{self.role.pk}/edit/").status_code, 200)

    def test_employee_detail_shows_existing_profile_fields_without_edit_actions(self):
        client = Client()
        self.assertTrue(client.login(username="employee", password="password"))
        response = client.get(f"/employees/{self.report.pk}/")
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, self.report.employee_code)
        self.assertContains(response, self.department.name)
        self.assertContains(response, self.role.name)
        self.assertContains(response, "Login account")
        self.assertNotContains(response, "Edit employee")
        self.assertNotContains(response, "Deactivate employee")

    def test_duplicate_department_and_job_role_codes_are_form_errors(self):
        client = Client()
        client.force_login(self.coordinator_user)
        for path, data, model, code in (
            ("/departments/new/", {"code": self.department.code, "name": "Duplicate department"}, Department, self.department.code),
            ("/job-roles/new/", {"code": self.role.code, "name": "Duplicate role"}, JobRole, self.role.code),
        ):
            with self.subTest(path=path):
                response = client.post(path, data)
                self.assertEqual(response.status_code, 200)
                self.assertIn("code", response.context["form"].errors)
                self.assertEqual(model.objects.filter(code=code).count(), 1)

    def test_management_forms_preserve_fields_values_and_accessible_errors(self):
        client = Client()
        client.force_login(self.coordinator_user)
        pages = (
            ("/employees/new/", "Employee information"),
            (f"/employees/{self.report.pk}/edit/", "Employee information"),
            ("/departments/new/", "Department information"),
            (f"/departments/{self.department.pk}/edit/", "Department information"),
            ("/job-roles/new/", "Job role information"),
            (f"/job-roles/{self.role.pk}/edit/", "Job role information"),
        )
        for path, heading in pages:
            with self.subTest(path=path):
                response = client.get(path)
                self.assertEqual(response.status_code, 200)
                self.assertContains(response, heading)
                self.assertContains(response, 'class="org-workspace"')
                self.assertContains(response, 'method="post"')
                self.assertContains(response, 'name="csrfmiddlewaretoken"', count=2)  # Logout and editor.
                for field in response.context["form"]:
                    self.assertContains(response, f'name="{field.name}"', count=1)
                    self.assertContains(response, f'id="{field.auto_id}"', count=1)
                invalid = client.post(path, {})
                self.assertEqual(invalid.status_code, 200)
                self.assertContains(invalid, 'class="org-validation" role="alert"')
                self.assertContains(invalid, 'aria-invalid="true"')
                self.assertContains(invalid, 'aria-describedby="id_' )
                self.assertContains(invalid, 'class="errorlist"')

    def test_employee_editor_create_and_edit_still_persist_validated_data(self):
        client = Client()
        client.force_login(self.coordinator_user)
        data = self.employee_data("ORG-UI-01")
        data["reporting_manager"] = self.manager.pk
        self.assertEqual(client.post("/employees/new/", data).status_code, 302)
        employee = Employee.objects.get(employee_code="ORG-UI-01")
        self.assertEqual(employee.reporting_manager_id, self.manager.pk)
        data["display_name"] = "Updated employee presentation fixture"
        self.assertEqual(client.post(f"/employees/{employee.pk}/edit/", data).status_code, 302)
        employee.refresh_from_db()
        self.assertEqual(employee.display_name, data["display_name"])
        self.assertTrue(employee.is_active)
        self.assertIsNone(employee.deactivated_at)

    def test_reference_editors_create_and_edit_without_changing_workflows(self):
        client = Client()
        client.force_login(self.coordinator_user)
        for path, model in (("departments", Department), ("job-roles", JobRole)):
            with self.subTest(path=path):
                data = {"code": "ORG-UI", "name": "Organization UI fixture", "description": "Description", "is_active": "on"}
                self.assertEqual(client.post(f"/{path}/new/", data).status_code, 302)
                record = model.objects.get(code="ORG-UI")
                data["name"] = "Updated reference fixture"
                self.assertEqual(client.post(f"/{path}/{record.pk}/edit/", data).status_code, 302)
                record.refresh_from_db()
                self.assertEqual(record.name, data["name"])
                self.assertTrue(record.is_active)

    def test_compact_tables_and_detail_preserve_semantics_escaping_and_role_actions(self):
        self.report.display_name = "<script>unsafe employee</script>"
        self.report.save()
        for user, can_edit in ((self.admin_user, True), (self.manager_user, False), (self.employee_user, False)):
            with self.subTest(user=user.username):
                client = Client()
                client.force_login(user)
                listing = client.get("/employees/")
                self.assertContains(listing, 'class="table-scroll org-table-scroll" role="region" aria-label="Employees" tabindex="0"')
                self.assertContains(listing, '<th scope="col">Employee</th>')
                self.assertContains(listing, '<th scope="row">')
                self.assertContains(listing, '&lt;script&gt;unsafe employee&lt;/script&gt;')
                self.assertNotContains(listing, self.report.display_name)
                self.assertContains(listing, self.report.employee_code)
                self.assertContains(listing, 'status-badge--success')
                detail = client.get(f"/employees/{self.report.pk}/")
                self.assertContains(detail, "Reporting manager")
                self.assertContains(detail, self.manager.display_name)
                self.assertEqual("Edit employee" in detail.content.decode(), can_edit)
                self.assertEqual("Deactivate employee" in detail.content.decode(), can_edit)
                self.assertNotContains(detail, f'href="/employees/{self.manager.pk}/"')

    def test_deactivation_validation_is_accessible_preserves_input_and_requires_csrf(self):
        client = Client()
        client.force_login(self.coordinator_user)
        reason = "<unsafe>" + "r" * 1001
        response = client.post(f"/employees/{self.report.pk}/deactivate/", {"reason": reason})
        self.assertEqual(response.status_code, 400)
        self.assertContains(response, 'class="org-validation" role="alert"', status_code=400)
        self.assertContains(response, 'id="id_reason"', status_code=400)
        self.assertContains(response, 'aria-describedby="id_reason_error"', status_code=400)
        self.assertContains(response, '&lt;unsafe&gt;', status_code=400)
        self.report.refresh_from_db()
        self.assertTrue(self.report.is_active)
        csrf_client = Client(enforce_csrf_checks=True)
        csrf_client.force_login(self.coordinator_user)
        for path in ("/employees/new/", "/departments/new/", "/job-roles/new/", f"/employees/{self.report.pk}/deactivate/"):
            self.assertEqual(csrf_client.post(path, {}).status_code, 403)

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
        admin_target = get_user_model().objects.create_user(username="admin-target")
        Group.objects.get(name="Administrator").user_set.add(admin_target)
        self.client.force_login(self.admin_user)
        response = self.client.post("/employees/new/", self.employee_data("GN-ADMIN-TARGET", admin_target))
        self.assertEqual(response.status_code, 302)
        employee = Employee.objects.get(employee_code="GN-ADMIN-TARGET")
        self.assertEqual(employee.user_id, admin_target.pk)
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(f"/employees/{employee.pk}/deactivate/", {"reason": "Approved deactivation"})
        self.assertEqual(response.status_code, 302)
        admin_target.refresh_from_db()
        self.assertFalse(admin_target.is_active)
        self.assertTrue(
            AuditLog.objects.filter(
                action="organization.employee.deactivated", entity_id=str(employee.pk),
            ).exists()
        )

    def test_ordinary_administrator_cannot_manage_or_deactivate_superuser(self):
        superuser = get_user_model().objects.create_superuser(
            username="super-target", password="password", email="supertarget@example.test"
        )
        self.client.force_login(self.admin_user)
        response = self.client.post("/employees/new/", self.employee_data("GN-SUPER-TARGET", superuser))
        self.assertEqual(response.status_code, 200)
        self.assertIn("user", response.context["form"].errors)
        self.assertFalse(Employee.objects.filter(employee_code="GN-SUPER-TARGET").exists())

        employee = Employee.objects.create(
            employee_code="GN-SUPER-TARGET", display_name="Super Target",
            department=self.department, job_role=self.role, date_joined="2026-01-01", user=superuser
        )
        audit_count_before = AuditLog.objects.filter(entity_id=str(employee.pk)).count()
        deact_response = self.client.post(f"/employees/{employee.pk}/deactivate/", {"reason": "Unauthorized attempt"})
        self.assertEqual(deact_response.status_code, 403)
        employee.refresh_from_db()
        superuser.refresh_from_db()
        self.assertTrue(employee.is_active)
        self.assertTrue(superuser.is_active)
        self.assertEqual(AuditLog.objects.filter(entity_id=str(employee.pk)).count(), audit_count_before)

    def test_superuser_can_manage_and_deactivate_superuser(self):
        actor_superuser = get_user_model().objects.create_superuser(
            username="super-actor", password="password", email="actor@example.test"
        )
        target_superuser = get_user_model().objects.create_superuser(
            username="super-target-2", password="password", email="target2@example.test"
        )
        self.client.force_login(actor_superuser)
        response = self.client.post("/employees/new/", self.employee_data("GN-SUPER-LINKED", target_superuser))
        self.assertEqual(response.status_code, 302)
        employee = Employee.objects.get(employee_code="GN-SUPER-LINKED")
        self.assertEqual(employee.user_id, target_superuser.pk)
        with self.captureOnCommitCallbacks(execute=True):
            deact_response = self.client.post(f"/employees/{employee.pk}/deactivate/", {"reason": "Superuser deactivation"})
        self.assertEqual(deact_response.status_code, 302)
        employee.refresh_from_db()
        target_superuser.refresh_from_db()
        self.assertFalse(employee.is_active)
        self.assertFalse(target_superuser.is_active)
        self.assertTrue(
            AuditLog.objects.filter(
                action="organization.employee.deactivated", entity_id=str(employee.pk),
            ).exists()
        )

    def test_administrator_cannot_deactivate_own_employee_record(self):
        admin_employee = Employee.objects.create(
            employee_code="GN-ADMIN-SELF", display_name="Admin Self",
            department=self.department, job_role=self.role, date_joined="2026-01-01", user=self.admin_user
        )
        self.client.force_login(self.admin_user)
        detail_response = self.client.get(f"/employees/{admin_employee.pk}/")
        self.assertEqual(detail_response.status_code, 200)
        self.assertNotContains(detail_response, "Deactivate employee")
        self.assertNotContains(detail_response, f"/employees/{admin_employee.pk}/deactivate/")

        audit_count_before = AuditLog.objects.filter(entity_id=str(admin_employee.pk)).count()
        response = self.client.post(f"/employees/{admin_employee.pk}/deactivate/", {"reason": "Self-deactivation attempt"})
        self.assertEqual(response.status_code, 403)
        admin_employee.refresh_from_db()
        self.admin_user.refresh_from_db()
        self.assertTrue(admin_employee.is_active)
        self.assertTrue(self.admin_user.is_active)
        self.assertEqual(AuditLog.objects.filter(entity_id=str(admin_employee.pk)).count(), audit_count_before)

    def test_coordinator_can_manage_ordinary_employee_accounts(self):
        ordinary = get_user_model().objects.create_user(username="ordinary")
        self.client.force_login(self.coordinator_user)
        self.assertEqual(self.client.post("/employees/new/", self.employee_data("GN-NO-LOGIN")).status_code, 302)
        self.assertIsNone(Employee.objects.get(employee_code="GN-NO-LOGIN").user_id)
        self.assertEqual(self.client.post("/employees/new/", self.employee_data("GN-ORDINARY", ordinary)).status_code, 302)
        employee = Employee.objects.get(employee_code="GN-ORDINARY")
        self.assertEqual(employee.user_id, ordinary.pk)
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(f"/employees/{employee.pk}/deactivate/", {"reason": "Left company"})
        self.assertEqual(response.status_code, 302)
        ordinary.refresh_from_db()
        self.assertFalse(ordinary.is_active)
        self.assertTrue(
            AuditLog.objects.filter(
                action="organization.employee.deactivated", entity_id=str(employee.pk),
            ).exists()
        )


class EmptyOrganizationPageTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.coordinator = get_user_model().objects.create_user(username="empty-organization-coordinator")
        Group.objects.get(name="Training Coordinator").user_set.add(cls.coordinator)

    def test_empty_employee_department_and_job_role_lists_render(self):
        client = Client()
        client.force_login(self.coordinator)
        for path, empty_state in (
            ("/employees/", "No employees available."),
            ("/departments/", "No departments available."),
            ("/job-roles/", "No job roles available."),
        ):
            with self.subTest(path=path):
                response = client.get(path)
                self.assertEqual(response.status_code, 200)
                self.assertContains(response, empty_state)
