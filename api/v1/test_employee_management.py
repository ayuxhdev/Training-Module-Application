from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import ValidationError
from django.db import connection, transaction
from django.test.utils import CaptureQueriesContext
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from organization.forms import EmployeeForm
from organization.models import Department, Employee, JobRole

from .management_serializers import EmployeeDirectoryDetailSerializer, EmployeeDirectorySerializer


class EmployeeProfileAPITests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.admin = get_user_model().objects.create_user(username="profile-admin")
        cls.admin.groups.add(Group.objects.get(name="Administrator"))
        cls.user.groups.add(Group.objects.get(name="Training Coordinator"))
        cls.employee_user.groups.add(Group.objects.get(name="Employee"))
        cls.manager_user = get_user_model().objects.create_user(username="profile-manager")
        cls.manager_user.groups.add(Group.objects.get(name="Manager"))
        cls.manager = Employee.objects.create(
            employee_code="PROFILE-MGR", display_name="Manager", user=cls.manager_user,
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(),
        )
        cls.employee.reporting_manager = cls.manager
        cls.employee.save()
        cls.descendant = Employee.objects.create(
            employee_code="PROFILE-DESC", display_name="Descendant", reporting_manager=cls.employee,
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(),
        )
        cls.foreign = Employee.objects.create(
            employee_code="PROFILE-FOREIGN", display_name="Outside team",
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(),
        )
        cls.other_department = Department.objects.create(code="PROFILE-DEPT", name="Other department", is_active=False)
        cls.other_role = JobRole.objects.create(code="PROFILE-ROLE", name="Other role", is_active=False)

    def setUp(self):
        self.client = APIClient()

    def authenticate(self, user):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + str(RefreshToken.for_user(user).access_token))

    def url(self, employee=None):
        return f"/api/v1/management/employees/{(employee or self.employee).pk}/"

    def update(self, data, *, user=None, employee=None):
        self.authenticate(user or self.admin)
        with self.captureOnCommitCallbacks(execute=True):
            return self.client.patch(self.url(employee), data, format="json")

    def assert_error(self, response, status, field=None):
        self.assertEqual(response.status_code, status, response.data)
        self.assertEqual(set(response.data), {"error"})
        self.assertEqual(set(response.data["error"]), {"code", "message", "fields"})
        if field:
            self.assertIn(field, response.data["error"]["fields"])

    def test_missing_invalid_and_session_only_authentication_are_rejected(self):
        for token in (None, "invalid-token"):
            self.client.credentials(**({"HTTP_AUTHORIZATION": "Bearer " + token} if token else {}))
            self.assert_error(self.client.patch(self.url(), {"display_name": "Denied"}, format="json"), 401)
        self.client.credentials()
        self.client.force_login(self.admin)
        self.assert_error(self.client.patch(self.url(), {"display_name": "Denied"}, format="json"), 401)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_default_manager_and_employee_cannot_update_any_record(self):
        for actor in (self.manager_user, self.employee_user):
            for target in (self.manager, self.employee, self.descendant, self.foreign):
                self.assert_error(self.update({"display_name": "Denied"}, user=actor, employee=target), 403)
        self.employee.refresh_from_db()
        self.assertEqual(self.employee.display_name, "Employee One")
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_administrator_without_employee_can_update_supported_profile_fields(self):
        self.assertFalse(Employee.objects.filter(user=self.admin).exists())
        response = self.update({
            "display_name": " Updated employee ", "department": self.other_department.pk,
            "job_role": self.other_role.pk, "reporting_manager": self.foreign.pk,
            "date_joined": "2026-01-15",
        })
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["id"], self.employee.pk)
        self.assertEqual(response.data["display_name"], "Updated employee")
        self.assertEqual(response.data["department"]["id"], self.other_department.pk)
        self.assertEqual(response.data["job_role"]["id"], self.other_role.pk)
        self.assertEqual(response.data["reporting_manager"], self.foreign.display_name)
        self.assertEqual(response.data["reporting_manager_id"], self.foreign.pk)
        self.assertEqual(response.data["date_joined"], "2026-01-15")
        self.assertEqual(response.data["login_status"], "ACTIVE")

    def test_coordinator_uses_existing_effective_edit_permission(self):
        response = self.update({"display_name": "Coordinator edit"}, user=self.user)
        self.assertEqual(response.status_code, 200, response.data)

    def test_direct_change_grant_needs_neither_view_permission_nor_employee_link(self):
        writer = get_user_model().objects.create_user(username="profile-direct-writer")
        permission = Permission.objects.get(content_type__app_label="organization", codename="change_employee")
        writer.user_permissions.add(permission)
        self.assertEqual(self.update({"display_name": "Direct edit"}, user=writer).status_code, 200)
        self.assert_error(self.client.get(self.url()), 403)
        writer.user_permissions.remove(permission)
        # Retain the JWT; every request must evaluate current effective grants.
        self.assert_error(self.client.patch(self.url(), {"display_name": "Denied"}, format="json"), 403)

    def test_explicit_manager_change_grant_preserves_established_company_scope(self):
        permission = Permission.objects.get(content_type__app_label="organization", codename="change_employee")
        self.manager_user.user_permissions.add(permission)
        response = self.update({"display_name": "Authorized global edit"}, user=self.manager_user, employee=self.foreign)
        self.assertEqual(response.status_code, 200, response.data)
        self.manager_user.user_permissions.remove(permission)
        self.assert_error(self.client.patch(self.url(self.foreign), {"display_name": "Denied"}, format="json"), 403)
        self.assert_error(self.client.get(self.url(self.foreign)), 404)

    def test_combined_manager_administrator_groups_keep_company_access(self):
        self.manager_user.groups.add(Group.objects.get(name="Administrator"))
        response = self.update({"display_name": "Combined edit"}, user=self.manager_user, employee=self.foreign)
        self.assertEqual(response.status_code, 200, response.data)

    def test_inactive_actor_cannot_bypass_via_management_permissions(self):
        self.manager_user.groups.add(Group.objects.get(name="Administrator"))
        self.manager.is_active = False
        self.manager.deactivation_reason = "Isolated fixture"
        self.manager.save()
        self.assert_error(self.update({"display_name": "Denied"}, user=self.manager_user), 401)
        self.manager_user.is_active = True
        self.manager_user.save()
        self.assert_error(self.update({"display_name": "Denied"}, user=self.manager_user), 403)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_unknown_employee_returns_404_after_authorization(self):
        self.authenticate(self.admin)
        self.assert_error(self.client.patch("/api/v1/management/employees/999999999/", {}, format="json"), 404)

    def test_privileged_immutable_and_unknown_fields_are_rejected_atomically(self):
        before = Employee.objects.values().get(pk=self.employee.pk)
        login_before = get_user_model().objects.values().get(pk=self.employee_user.pk)
        groups_before = list(self.employee_user.groups.values_list("pk", flat=True))
        fields = (
            "id", "employee_code", "user", "user_id", "username", "password", "email",
            "groups", "user_permissions", "permissions", "capabilities", "is_staff", "is_superuser",
            "is_active", "deactivated_at", "deactivation_reason", "created_at", "updated_at", "owner",
            "reporting_manager_id", "department_id", "job_role_id",
        )
        for field in fields:
            with self.subTest(field=field):
                self.assert_error(self.update({"display_name": "Must not persist", field: "untrusted"}), 400, field)
        self.assertEqual(Employee.objects.values().get(pk=self.employee.pk), before)
        self.assertEqual(get_user_model().objects.values().get(pk=self.employee_user.pk), login_before)
        self.assertEqual(list(self.employee_user.groups.values_list("pk", flat=True)), groups_before)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_invalid_profile_fields_do_not_partially_save_or_audit(self):
        invalid = (
            ("display_name", " "), ("display_name", None), ("display_name", "x" * 151),
            ("department", None), ("department", 999999999), ("department", True),
            ("job_role", None), ("job_role", "invalid"), ("job_role", 999999999),
            ("reporting_manager", 999999999), ("reporting_manager", False),
            ("reporting_manager", self.manager.display_name),
            ("date_joined", None), ("date_joined", "2026-02-30"), ("date_joined", "not-a-date"),
        )
        before = Employee.objects.values().get(pk=self.employee.pk)
        for field, value in invalid:
            with self.subTest(field=field, value=value):
                self.assert_error(self.update({"display_name": "Must not persist", field: value}), 400, field)
        self.assertEqual(Employee.objects.values().get(pk=self.employee.pk), before)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_malformed_payloads_use_standard_error_envelope(self):
        self.authenticate(self.admin)
        for payload in ('[1,2]', 'null', '"text"', '{broken'):
            self.assert_error(self.client.patch(self.url(), payload, content_type="application/json"), 400)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_self_and_recursive_reporting_cycles_are_rejected(self):
        for manager in (self.employee, self.descendant):
            self.assert_error(self.update({"reporting_manager": manager.pk}), 400, "non_field_errors")
        self.employee.refresh_from_db()
        self.assertEqual(self.employee.reporting_manager_id, self.manager.pk)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_reporting_manager_can_be_cleared_and_read_scope_follows_hierarchy(self):
        response = self.update({"reporting_manager": None})
        self.assertEqual(response.status_code, 200)
        self.assertIsNone(response.data["reporting_manager_id"])
        self.assertIsNone(response.data["reporting_manager"])
        self.authenticate(self.manager_user)
        self.assert_error(self.client.get(self.url()), 404)
        self.assert_error(self.client.get(self.url(self.descendant)), 404)
        self.assertEqual(self.client.get(self.url(self.manager)).status_code, 200)

    def test_partial_update_preserves_other_fields_and_assignment_snapshots(self):
        before = Employee.objects.values().get(pk=self.employee.pk)
        assignment_before = type(self.assignment).objects.values().get(pk=self.assignment.pk)
        response = self.update({"department": self.other_department.pk, "job_role": self.other_role.pk})
        self.assertEqual(response.status_code, 200, response.data)
        after = Employee.objects.values().get(pk=self.employee.pk)
        for field in before.keys() - {"department_id", "job_role_id", "updated_at"}:
            self.assertEqual(after[field], before[field], field)
        self.assertEqual(type(self.assignment).objects.values().get(pk=self.assignment.pk), assignment_before)

    def test_profile_edit_does_not_modify_privileged_linked_login(self):
        self.employee_user.is_staff = True
        self.employee_user.is_superuser = True
        self.employee_user.save()
        before = get_user_model().objects.values().get(pk=self.employee_user.pk)
        self.assertEqual(self.update({"display_name": "Profile only"}, user=self.user).status_code, 200)
        self.assertEqual(get_user_model().objects.values().get(pk=self.employee_user.pk), before)

    def test_successful_changes_use_existing_audit_snapshots_and_actor(self):
        response = self.update({"display_name": "Audited edit", "date_joined": "2026-01-15"})
        self.assertEqual(response.status_code, 200, response.data)
        event = AuditLog.objects.get(action="organization.employee.updated", entity_id=str(self.employee.pk))
        self.assertEqual(event.actor_id, self.admin.pk)
        self.assertEqual(event.before_data["display_name"], "Employee One")
        self.assertEqual(event.after_data["display_name"], "Audited edit")
        self.assertEqual(set(event.after_data["changed_fields"]), {"display_name", "date_joined"})
        self.assertNotIn("user", event.after_data)

    def test_noop_and_repeated_updates_do_not_create_extra_audit_events(self):
        before = Employee.objects.values().get(pk=self.employee.pk)
        self.assertEqual(self.update({}).status_code, 200)
        self.assertEqual(Employee.objects.values().get(pk=self.employee.pk), before)
        for _ in range(2):
            self.assertEqual(self.update({"display_name": "Same name"}).status_code, 200)
        self.assertEqual(AuditLog.objects.count(), 1)

    def test_outer_transaction_rollback_discards_profile_and_audit(self):
        self.authenticate(self.admin)
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            with self.assertRaises(RuntimeError):
                with transaction.atomic():
                    response = self.client.patch(self.url(), {"display_name": "Rollback"}, format="json")
                    self.assertEqual(response.status_code, 200)
                    raise RuntimeError("Rollback fixture")
        self.assertEqual(callbacks, [])
        self.employee.refresh_from_db()
        self.assertEqual(self.employee.display_name, "Employee One")
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_model_validation_failures_remain_controlled_field_errors(self):
        with patch.object(Employee, "save", side_effect=ValidationError({"display_name": ["Rejected by model."]})):
            self.assert_error(self.update({"display_name": "Invalid"}), 400, "display_name")
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_hierarchy_lock_order_matches_employee_model(self):
        with CaptureQueriesContext(connection) as queries:
            response = self.update({"reporting_manager": self.foreign.pk})
        self.assertEqual(response.status_code, 200, response.data)
        locks = [query["sql"] for query in queries if "FOR UPDATE" in query["sql"] and "organization_employee" in query["sql"]]
        self.assertRegex(locks[0], r"ORDER BY (?:1|`organization_employee`\.`id`) ASC")
        self.assertNotIn("WHERE", locks[0])
        self.assertIn("WHERE", locks[1])

    def test_get_shape_and_recursive_scope_remain_unchanged(self):
        self.authenticate(self.manager_user)
        response = self.client.get(self.url(self.descendant))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(set(response.data), {
            "id", "employee_code", "display_name", "department", "job_role", "reporting_manager",
            "reporting_manager_id", "is_active", "date_joined", "login_status",
        })
        self.assert_error(self.client.get(self.url(self.foreign)), 404)
        self.authenticate(self.employee_user)
        own = self.client.get(self.url())
        self.assertEqual(own.status_code, 200)
        self.assertEqual(own.data["reporting_manager_id"], self.manager.pk)
        self.assert_error(self.client.get(self.url(self.manager)), 404)
        self.assert_error(self.client.get(self.url(self.descendant)), 404)

    def test_detail_serializer_adds_only_nullable_manager_id(self):
        for employee, manager_id in ((self.employee, self.manager.pk), (self.foreign, None)):
            with self.subTest(employee=employee.pk):
                legacy = {
                    **EmployeeDirectorySerializer(employee).data,
                    "date_joined": employee.date_joined.isoformat(),
                    "login_status": "ACTIVE" if employee.user_id else "NOT_LINKED",
                }
                detail = EmployeeDirectoryDetailSerializer(employee).data
                self.assertEqual(detail, {**legacy, "reporting_manager_id": manager_id})
                self.authenticate(self.admin)
                response = self.client.get(self.url(employee))
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.data, detail)

    def test_detail_relationship_ids_can_prepopulate_patch_for_populated_or_null_manager(self):
        self.authenticate(self.admin)
        for employee in (self.employee, self.foreign):
            with self.subTest(employee=employee.pk):
                loaded = self.client.get(self.url(employee)).data
                response = self.update({
                    "display_name": "Edited " + loaded["display_name"],
                    "department": loaded["department"]["id"],
                    "job_role": loaded["job_role"]["id"],
                    "reporting_manager": loaded["reporting_manager_id"],
                    "date_joined": loaded["date_joined"],
                }, employee=employee)
                self.assertEqual(response.status_code, 200, response.data)
                self.assertEqual(response.data, {**loaded, "display_name": "Edited " + loaded["display_name"]})
                event = AuditLog.objects.get(entity_id=str(employee.pk), action="organization.employee.updated")
                self.assertEqual(event.after_data["changed_fields"], ["display_name"])

    def test_employee_list_keeps_existing_display_name_only_manager_contract(self):
        self.authenticate(self.admin)
        response = self.client.get("/api/v1/management/employees/")
        self.assertEqual(response.status_code, 200)
        for row in response.data["results"]:
            employee = Employee.objects.get(pk=row["id"])
            self.assertEqual(row, EmployeeDirectorySerializer(employee).data)
            self.assertNotIn("reporting_manager_id", row)

    def test_deletion_full_replacement_and_detail_post_remain_unsupported(self):
        self.authenticate(self.admin)
        for path, methods in (("/api/v1/management/employees/", ("put", "patch", "delete")),
                              (self.url(), ("post", "put", "delete"))):
            for method in methods:
                self.assert_error(getattr(self.client, method)(path, {}, format="json"), 405)
        self.assertEqual(Employee.objects.count(), 4)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_profile_values_follow_existing_web_form_validation(self):
        payload = {
            "employee_code": self.employee.employee_code, "display_name": "Valid name",
            "user": self.employee_user.pk, "department": self.department.pk,
            "job_role": self.role.pk, "reporting_manager": self.manager.pk,
            "date_joined": self.employee.date_joined.isoformat(),
        }
        for field, value in (("display_name", "Normalized name"), ("display_name", " "),
                             ("date_joined", "2026-02-30"), ("department", self.other_department.pk)):
            form = EmployeeForm(data={**payload, field: value}, instance=Employee.objects.get(pk=self.employee.pk), actor=self.admin)
            expected = 200 if form.is_valid() else 400
            self.assertEqual(self.update({field: value}).status_code, expected)
