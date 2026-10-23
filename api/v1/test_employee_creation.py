from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import ValidationError
from django.db import connection, IntegrityError, transaction
from django.test.utils import CaptureQueriesContext
from rest_framework.test import APIClient
from rest_framework.validators import UniqueValidator
from rest_framework_simplejwt.tokens import RefreshToken

from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from organization.forms import EmployeeForm
from organization.models import Department, Employee, JobRole


class EmployeeCreationAPITests(CurriculumTestCase):
    url = "/api/v1/management/employees/"

    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.admin = get_user_model().objects.create_user(username="create-admin")
        cls.admin.groups.add(Group.objects.get(name="Administrator"))
        cls.user.groups.add(Group.objects.get(name="Training Coordinator"))
        cls.employee_user.groups.add(Group.objects.get(name="Employee"))
        cls.manager_user = get_user_model().objects.create_user(username="create-manager")
        cls.manager_user.groups.add(Group.objects.get(name="Manager"))
        cls.manager = Employee.objects.create(
            employee_code="CREATE-MGR", display_name="Manager", user=cls.manager_user,
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(),
        )
        cls.login = get_user_model().objects.create_user(username="unlinked-login")

    def setUp(self):
        self.client = APIClient()

    def payload(self, **changes):
        return {
            "employee_code": "NEW-EMPLOYEE", "display_name": "New employee",
            "department": self.department.pk, "job_role": self.role.pk,
            "date_joined": "2026-10-01", **changes,
        }

    def authenticate(self, user):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + str(RefreshToken.for_user(user).access_token))

    def create(self, payload=None, *, actor=None):
        self.authenticate(actor or self.admin)
        with self.captureOnCommitCallbacks(execute=True):
            return self.client.post(self.url, self.payload() if payload is None else payload, format="json")

    def assert_error(self, response, status, field=None):
        self.assertEqual(response.status_code, status, response.data)
        self.assertEqual(set(response.data), {"error"})
        self.assertEqual(set(response.data["error"]), {"code", "message", "fields"})
        if field:
            self.assertIn(field, response.data["error"]["fields"])

    def test_jwt_required_and_session_authentication_does_not_authorize_creation(self):
        for token in (None, "invalid-token"):
            self.client.credentials(**({"HTTP_AUTHORIZATION": "Bearer " + token} if token else {}))
            self.assert_error(self.client.post(self.url, self.payload(), format="json"), 401)
        self.client.credentials()
        self.client.force_login(self.admin)
        self.assert_error(self.client.post(self.url, self.payload(), format="json"), 401)
        self.assertEqual(Employee.objects.count(), 2)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_default_manager_employee_and_change_only_accounts_cannot_create(self):
        editor = get_user_model().objects.create_user(username="change-only")
        editor.user_permissions.add(Permission.objects.get(content_type__app_label="organization", codename="change_employee"))
        for actor in (self.manager_user, self.employee_user, editor):
            self.assert_error(self.create(self.payload(), actor=actor), 403)
        self.assertEqual(Employee.objects.count(), 2)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_management_only_administrator_creates_active_employee_without_provisioning(self):
        self.assertFalse(Employee.objects.filter(user=self.admin).exists())
        users_before = list(get_user_model().objects.order_by("pk").values())
        assignment_before = type(self.assignment).objects.values().get(pk=self.assignment.pk)
        response = self.create(self.payload(employee_code=" NEW-EMPLOYEE ", display_name=" New employee "))
        self.assertEqual(response.status_code, 201, response.data)
        employee = Employee.objects.get(pk=response.data["id"])
        self.assertEqual(employee.employee_code, "NEW-EMPLOYEE")
        self.assertEqual(employee.display_name, "New employee")
        self.assertTrue(employee.is_active)
        self.assertIsNone(employee.user_id)
        self.assertIsNone(employee.reporting_manager_id)
        self.assertIsNone(employee.deactivated_at)
        self.assertEqual(response.data["login_status"], "NOT_LINKED")
        self.assertIsNone(response.data["reporting_manager_id"])
        self.assertEqual(list(get_user_model().objects.order_by("pk").values()), users_before)
        self.assertEqual(type(self.assignment).objects.values().get(pk=self.assignment.pk), assignment_before)
        self.assertEqual(self.client.get(self.url + str(employee.pk) + "/").data, response.data)

    def test_coordinator_links_existing_ordinary_user_and_existing_profile_references(self):
        department = Department.objects.create(code="CREATE-D", name="Inactive department", is_active=False)
        role = JobRole.objects.create(code="CREATE-R", name="Inactive role", is_active=False)
        login_before = get_user_model().objects.values().get(pk=self.login.pk)
        response = self.create(self.payload(
            user=self.login.pk, department=department.pk, job_role=role.pk, reporting_manager=self.manager.pk,
        ), actor=self.user)
        self.assertEqual(response.status_code, 201, response.data)
        employee = Employee.objects.get(pk=response.data["id"])
        self.assertEqual(employee.user_id, self.login.pk)
        self.assertEqual(response.data["department"]["id"], department.pk)
        self.assertEqual(response.data["job_role"]["id"], role.pk)
        self.assertEqual(response.data["reporting_manager_id"], self.manager.pk)
        self.assertEqual(response.data["reporting_manager"], self.manager.display_name)
        self.assertEqual(response.data["login_status"], "ACTIVE")
        self.assertEqual(get_user_model().objects.values().get(pk=self.login.pk), login_before)

    def test_optional_null_user_and_manager_are_supported(self):
        response = self.create(self.payload(user=None, reporting_manager=None))
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data["login_status"], "NOT_LINKED")
        self.assertIsNone(response.data["reporting_manager"])
        self.assertIsNone(response.data["reporting_manager_id"])

    def test_add_only_grant_requires_neither_view_change_nor_employee_link_and_can_be_revoked(self):
        creator = get_user_model().objects.create_user(username="add-only")
        permission = Permission.objects.get(content_type__app_label="organization", codename="add_employee")
        creator.user_permissions.add(permission)
        response = self.create(actor=creator)
        self.assertEqual(response.status_code, 201, response.data)
        detail_url = self.url + str(response.data["id"]) + "/"
        self.assert_error(self.client.get(detail_url), 403)
        self.assert_error(self.client.patch(detail_url, {"display_name": "Denied"}, format="json"), 403)
        creator.user_permissions.remove(permission)
        self.assert_error(self.client.post(self.url, self.payload(employee_code="REVOKED"), format="json"), 403)

    def test_explicit_manager_add_grant_follows_existing_web_creation_authority(self):
        self.manager_user.user_permissions.add(Permission.objects.get(content_type__app_label="organization", codename="add_employee"))
        response = self.create(actor=self.manager_user)
        self.assertEqual(response.status_code, 201, response.data)
        # Creation does not silently expand recursive read scope.
        self.assert_error(self.client.get(self.url + str(response.data["id"]) + "/"), 404)

    def test_inactive_actor_cannot_bypass_mobile_eligibility(self):
        self.manager_user.groups.add(Group.objects.get(name="Administrator"))
        self.manager.is_active = False
        self.manager.deactivation_reason = "Isolated fixture"
        self.manager.save()
        self.assert_error(self.create(actor=self.manager_user), 401)
        self.manager_user.is_active = True
        self.manager_user.save()
        self.assert_error(self.create(actor=self.manager_user), 403)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_required_and_invalid_profile_fields_are_controlled_errors(self):
        for field in ("employee_code", "display_name", "department", "job_role", "date_joined"):
            payload = self.payload()
            del payload[field]
            self.assert_error(self.create(payload), 400, field)
        invalid = (
            ("employee_code", " "), ("employee_code", "x" * 31), ("employee_code", None),
            ("display_name", " "), ("display_name", "x" * 151), ("display_name", None),
            ("department", None), ("department", True), ("department", 999999999),
            ("job_role", None), ("job_role", "invalid"), ("job_role", 999999999),
            ("reporting_manager", False), ("reporting_manager", "Manager"), ("reporting_manager", 999999999),
            ("date_joined", None), ("date_joined", "2026-02-30"),
        )
        for field, value in invalid:
            with self.subTest(field=field, value=value):
                self.assert_error(self.create(self.payload(**{field: value})), 400, field)
        self.assertEqual(Employee.objects.count(), 2)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_unexpected_security_and_technical_fields_are_rejected(self):
        users_before = list(get_user_model().objects.order_by("pk").values())
        for field in ("id", "user_id", "username", "password", "groups", "user_permissions", "permissions",
                      "is_staff", "is_superuser", "capabilities", "is_active", "deactivated_at",
                      "deactivation_reason", "department_id", "job_role_id", "reporting_manager_id",
                      "created_at", "updated_at", "actor", "role"):
            self.assert_error(self.create(self.payload(**{field: "untrusted"})), 400, field)
        self.assertEqual(Employee.objects.count(), 2)
        self.assertEqual(list(get_user_model().objects.order_by("pk").values()), users_before)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_invalid_account_references_cannot_provision_users(self):
        before = get_user_model().objects.count()
        for value in (True, 999999999, "unlinked-login", {"username": "injected", "password": "not-a-credential"}):
            self.assert_error(self.create(self.payload(user=value)), 400, "user")
        self.assertEqual(get_user_model().objects.count(), before)
        self.assertEqual(Employee.objects.count(), 2)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_coordinator_cannot_link_staff_superuser_or_administrator_accounts(self):
        for index, flags in enumerate(({"is_staff": True}, {"is_superuser": True}, {})):
            login = get_user_model().objects.create_user(username=f"privileged-{index}", **flags)
            if not flags:
                login.groups.add(Group.objects.get(name="Administrator"))
            self.assert_error(self.create(self.payload(user=login.pk), actor=self.user), 400, "user")
            self.assertFalse(Employee.objects.filter(user=login).exists())
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_authorized_actors_can_link_existing_privileged_users_without_changing_their_authority(self):
        super_actor = get_user_model().objects.create_superuser(username="creation-super-actor")
        for index, flags in enumerate(({"is_staff": True}, {"is_superuser": True}, {})):
            login = get_user_model().objects.create_user(username=f"authorized-privileged-{index}", **flags)
            if not flags:
                login.groups.add(Group.objects.get(name="Administrator"))
            before = get_user_model().objects.values().get(pk=login.pk)
            groups = list(login.groups.values_list("pk", flat=True))
            actor = super_actor if login.is_superuser else self.admin
            response = self.create(self.payload(employee_code=f"PRIV-{index}", user=login.pk), actor=actor)
            self.assertEqual(response.status_code, 201, response.data)
            self.assertEqual(get_user_model().objects.values().get(pk=login.pk), before)
            self.assertEqual(list(login.groups.values_list("pk", flat=True)), groups)

    def test_ordinary_administrator_cannot_link_superuser_account(self):
        login = get_user_model().objects.create_superuser(username="creation-super-target")
        self.assert_error(self.create(self.payload(user=login.pk)), 400, "user")
        self.assertFalse(Employee.objects.filter(user=login).exists())
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_linking_disabled_existing_login_does_not_enable_it(self):
        self.login.is_active = False
        self.login.save()
        response = self.create(self.payload(user=self.login.pk), actor=self.user)
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data["login_status"], "INACTIVE")
        self.login.refresh_from_db()
        self.assertFalse(self.login.is_active)

    def test_duplicate_identity_and_repeated_post_do_not_create_duplicate_records_or_audits(self):
        first = self.create()
        self.assertEqual(first.status_code, 201, first.data)
        for code in ("NEW-EMPLOYEE", "new-employee", " NEW-EMPLOYEE "):
            self.assert_error(self.create(self.payload(employee_code=code)), 400, "employee_code")
        self.assertEqual(Employee.objects.count(), 3)
        self.assertEqual(AuditLog.objects.count(), 1)

    def test_existing_account_link_cannot_be_reassigned(self):
        before = Employee.objects.values().get(pk=self.employee.pk)
        self.assert_error(self.create(self.payload(user=self.employee_user.pk)), 400, "user")
        self.assertEqual(Employee.objects.values().get(pk=self.employee.pk), before)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_expected_unique_races_return_field_errors(self):
        for field, value in (("employee_code", self.employee.employee_code), ("user", self.employee_user.pk)):
            with patch.object(UniqueValidator, "__call__", return_value=None), \
                 patch.object(Employee, "save", side_effect=IntegrityError(1062, "Expected unique conflict")):
                self.assert_error(self.create(self.payload(**{field: value})), 400, field)
        self.assertEqual(Employee.objects.count(), 2)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_unrelated_integrity_errors_are_not_disguised_as_validation(self):
        for error in (IntegrityError(1452, "Unexpected constraint"), IntegrityError(1062, "Unrelated unique key")):
            with patch.object(Employee, "save", side_effect=error):
                with self.assertLogs("django.request", level="ERROR"), self.assertRaises(IntegrityError):
                    self.create()
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_model_validation_failures_do_not_persist_or_audit(self):
        with patch.object(Employee, "save", side_effect=ValidationError({"employee_code": ["Rejected by model."]})):
            self.assert_error(self.create(), 400, "employee_code")
        self.assertEqual(Employee.objects.count(), 2)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_creation_and_audit_are_discarded_on_outer_rollback(self):
        self.authenticate(self.admin)
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            with self.assertRaises(RuntimeError):
                with transaction.atomic():
                    response = self.client.post(self.url, self.payload(user=self.login.pk), format="json")
                    self.assertEqual(response.status_code, 201, response.data)
                    raise RuntimeError("Rollback fixture")
        self.assertEqual(callbacks, [])
        self.assertFalse(Employee.objects.filter(user=self.login).exists())
        self.assertEqual(Employee.objects.count(), 2)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_creation_audit_is_server_derived_and_uses_existing_snapshots(self):
        response = self.create(self.payload(user=self.login.pk, reporting_manager=self.manager.pk))
        self.assertEqual(response.status_code, 201, response.data)
        event = AuditLog.objects.get(entity_id=str(response.data["id"]), action="organization.employee.created")
        self.assertEqual(event.actor_id, self.admin.pk)
        self.assertEqual(event.before_data, {})
        self.assertEqual(event.after_data["employee_code"], "NEW-EMPLOYEE")
        self.assertEqual(event.after_data["reporting_manager_id"], self.manager.pk)
        self.assertIn("user", event.after_data["changed_fields"])
        self.assertNotIn("password", event.after_data)
        self.assertNotIn("user_id", event.after_data)

    def test_account_privilege_is_rechecked_after_validation_under_the_user_lock(self):
        from .management_serializers import EmployeeCreateSerializer

        def promote_during_validation(serializer, attrs):
            login = get_user_model().objects.get(pk=self.login.pk)
            login.is_staff = True
            login.save()
            return attrs

        with patch.object(EmployeeCreateSerializer, "validate", promote_during_validation):
            self.assert_error(self.create(self.payload(user=self.login.pk), actor=self.user), 400, "user")
        self.assertFalse(Employee.objects.filter(user=self.login).exists())
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_account_disappearing_after_validation_is_a_controlled_field_error(self):
        from .management_serializers import EmployeeCreateSerializer

        def delete_during_validation(serializer, attrs):
            get_user_model().objects.get(pk=self.login.pk).delete()
            return attrs

        with patch.object(EmployeeCreateSerializer, "validate", delete_during_validation):
            self.assert_error(self.create(self.payload(user=self.login.pk)), 400, "user")
        self.assertEqual(Employee.objects.count(), 2)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_hierarchy_is_locked_before_linked_user_to_preserve_lock_order(self):
        with CaptureQueriesContext(connection) as queries:
            response = self.create(self.payload(user=self.login.pk, reporting_manager=self.manager.pk))
        self.assertEqual(response.status_code, 201, response.data)
        locks = [item["sql"] for item in queries if "FOR UPDATE" in item["sql"]]
        self.assertIn("organization_employee", locks[0])
        self.assertRegex(locks[0], r"ORDER BY (?:1|`organization_employee`\.`id`) ASC")
        self.assertIn("auth_user", locks[1])

    def test_api_creation_validation_matches_existing_employee_form(self):
        for index, changes in enumerate(({}, {"display_name": " "}, {"date_joined": "2026-02-30"},
                                         {"user": self.employee_user.pk}, {"employee_code": self.employee.employee_code})):
            payload = self.payload(employee_code=f"FORM-{index}") | changes
            form = EmployeeForm(data=payload, actor=self.admin)
            expected = 201 if form.is_valid() else 400
            self.assertEqual(self.create(payload).status_code, expected)

    def test_malformed_json_and_unsupported_mutations_remain_rejected(self):
        self.authenticate(self.admin)
        for payload in ('[1,2]', 'null', '"text"', '{broken'):
            self.assert_error(self.client.post(self.url, payload, content_type="application/json"), 400)
        for method in ("put", "patch", "delete"):
            self.assert_error(getattr(self.client, method)(self.url, {}, format="json"), 405)
        self.assertEqual(Employee.objects.count(), 2)
        self.assertEqual(AuditLog.objects.count(), 0)
