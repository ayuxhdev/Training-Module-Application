from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import ValidationError
from django.db import IntegrityError, transaction
from rest_framework.test import APIClient
from rest_framework.validators import UniqueValidator
from rest_framework_simplejwt.tokens import RefreshToken

from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from organization.forms import DepartmentForm, JobRoleForm
from organization.models import Department, Employee, JobRole
from training.models import RoleTrainingRequirement

from .management_serializers import DepartmentWriteSerializer, JobRoleWriteSerializer


class OrganizationManagementAPITests(CurriculumTestCase):
    resources = ((Department, "departments", DepartmentWriteSerializer, DepartmentForm),
                 (JobRole, "job-roles", JobRoleWriteSerializer, JobRoleForm))

    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.admin = get_user_model().objects.create_user(username="organization-admin")
        cls.admin.groups.add(Group.objects.get(name="Administrator"))
        cls.user.groups.add(Group.objects.get(name="Training Coordinator"))
        cls.employee_user.groups.add(Group.objects.get(name="Employee"))
        cls.manager = get_user_model().objects.create_user(username="organization-manager")
        cls.manager.groups.add(Group.objects.get(name="Manager"))
        cls.manager_employee = Employee.objects.create(
            user=cls.manager, employee_code="ORG-MGR", display_name="Manager",
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(),
        )
        cls.requirement = RoleTrainingRequirement.objects.create(
            job_role=cls.role, training_version=cls.version, created_by=cls.user,
        )

    def setUp(self):
        self.client = APIClient()

    def authenticate(self, user):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + str(RefreshToken.for_user(user).access_token))

    def target(self, model):
        return self.department if model is Department else self.role

    def write(self, path, data, *, method="post", user=None):
        self.authenticate(user or self.admin)
        with self.captureOnCommitCallbacks(execute=True):
            return getattr(self.client, method)("/api/v1/management/" + path, data, format="json")

    def assert_error(self, response, status, field=None):
        self.assertEqual(response.status_code, status, response.data)
        self.assertEqual(set(response.data), {"error"})
        self.assertEqual(set(response.data["error"]), {"code", "message", "fields"})
        if field:
            self.assertEqual(response.data["error"]["code"], "validation_error")
            self.assertIn(field, response.data["error"]["fields"])

    def test_missing_and_invalid_jwt_are_rejected(self):
        for model, path, _, _ in self.resources:
            for method, suffix in (("post", "/"), ("patch", f"/{self.target(model).pk}/")):
                for token in (None, "invalid-token"):
                    self.client.credentials(**({"HTTP_AUTHORIZATION": "Bearer " + token} if token else {}))
                    response = getattr(self.client, method)(f"/api/v1/management/{path}{suffix}", {}, format="json")
                    self.assert_error(response, 401)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_read_only_manager_and_employee_cannot_write_or_claim_a_role(self):
        for user in (self.manager, self.employee_user):
            for model, path, _, _ in self.resources:
                self.assert_error(self.write(path + "/", {"code": "NEW", "name": "New", "role": "Administrator"}, user=user), 403)
                response = self.write(f"{path}/{self.target(model).pk}/", {"name": "Changed"}, method="patch", user=user)
                self.assert_error(response, 403)
                self.assertEqual(model.objects.count(), 1)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_administrator_without_employee_creates_normalized_records(self):
        self.assertFalse(Employee.objects.filter(user=self.admin).exists())
        for model, path, _, _ in self.resources:
            response = self.write(path + "/", {"code": " NEW ", "name": " New reference "})
            self.assertEqual(response.status_code, 201, response.data)
            self.assertEqual(set(response.data), {"id", "code", "name", "description", "is_active"})
            self.assertEqual(response.data["code"], "NEW")
            self.assertEqual(response.data["name"], "New reference")
            self.assertEqual(response.data["description"], "")
            self.assertIs(response.data["is_active"], True)
            self.assertTrue(model.objects.filter(pk=response.data["id"], code="NEW").exists())

    def test_permissioned_coordinator_without_employee_can_create_and_edit(self):
        for model, path, _, _ in self.resources:
            self.assertEqual(self.write(path + "/", {"code": "COORD", "name": "Created"}, user=self.user).status_code, 201)
            response = self.write(f"{path}/{self.target(model).pk}/", {"name": "Updated"}, method="patch", user=self.user)
            self.assertEqual(response.status_code, 200, response.data)

    def test_effective_action_permissions_work_without_view_or_employee_and_revoke_immediately(self):
        writer = get_user_model().objects.create_user(username="direct-reference-writer")
        for model, path, _, _ in self.resources:
            suffix = model._meta.model_name
            add = Permission.objects.get(content_type__app_label="organization", codename=f"add_{suffix}")
            change = Permission.objects.get(content_type__app_label="organization", codename=f"change_{suffix}")
            writer.user_permissions.add(add)
            self.assertEqual(self.write(path + "/", {"code": "DIRECT", "name": "Direct"}, user=writer).status_code, 201)
            self.assert_error(self.client.get(f"/api/v1/management/{path}/"), 403)
            self.assert_error(self.write(f"{path}/{self.target(model).pk}/", {"name": "Blocked"}, method="patch", user=writer), 403)
            writer.user_permissions.remove(add)
            writer.user_permissions.add(change)
            # The existing JWT is retained; permissions come from the current user.
            with self.captureOnCommitCallbacks(execute=True):
                response = self.client.patch(f"/api/v1/management/{path}/{self.target(model).pk}/", {"name": "Allowed"}, format="json")
            self.assertEqual(response.status_code, 200, response.data)
            self.assert_error(self.client.post(f"/api/v1/management/{path}/", {"code": "DENIED", "name": "Denied"}, format="json"), 403)
            capabilities = self.client.get("/api/v1/auth/me/").data["capabilities"]
            self.assertIn(f"organization.change_{suffix}", capabilities)
            self.assertNotIn(f"organization.add_{suffix}", capabilities)

    def test_combined_manager_and_administrator_groups_allow_writes(self):
        self.manager.groups.add(Group.objects.get(name="Administrator"))
        for model, path, _, _ in self.resources:
            self.assertEqual(self.write(path + "/", {"code": "COMBINED", "name": "Combined"}, user=self.manager).status_code, 201)
            self.assertEqual(self.write(f"{path}/{self.target(model).pk}/", {"name": "Combined update"}, method="patch", user=self.manager).status_code, 200)

    def test_inactive_linked_employee_cannot_bypass_with_management_permissions(self):
        self.manager.groups.add(Group.objects.get(name="Administrator"))
        self.manager_employee.is_active = False
        self.manager_employee.deactivation_reason = "Isolated fixture"
        self.manager_employee.save()
        self.manager.is_active = True
        self.manager.save()
        for model, path, _, _ in self.resources:
            self.assert_error(self.write(path + "/", {"code": "NEW", "name": "New"}, user=self.manager), 403)
            self.assert_error(self.write(f"{path}/{self.target(model).pk}/", {"name": "Changed"}, method="patch", user=self.manager), 403)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_missing_blank_oversized_and_invalid_fields_do_not_create_records(self):
        payloads = ({}, {"code": "NEW"}, {"name": "Name"}, {"code": " ", "name": "Name"},
                    {"code": "x" * 31, "name": "Name"}, {"code": "NEW", "name": "x" * 121},
                    {"code": "NEW", "name": None}, {"code": "NEW", "name": "Name", "description": None},
                    {"code": "NEW", "name": "Name", "is_active": None},
                    {"code": "NEW", "name": "Name", "is_active": "not-a-boolean"})
        for model, path, _, _ in self.resources:
            for payload in payloads:
                with self.subTest(path=path, payload=payload):
                    response = self.write(path + "/", payload)
                    self.assert_error(response, 400)
                    self.assertTrue(response.data["error"]["fields"])
            self.assertEqual(model.objects.count(), 1)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_duplicate_codes_are_rejected_but_duplicate_names_are_allowed(self):
        for model, path, _, _ in self.resources:
            target = self.target(model)
            for code in (target.code, target.code.lower()):
                self.assert_error(self.write(path + "/", {"code": code, "name": "Duplicate"}), 400, "code")
            response = self.write(path + "/", {"code": "DISTINCT", "name": target.name})
            self.assertEqual(response.status_code, 201, response.data)

    def test_malformed_payloads_use_the_shared_error_envelope(self):
        self.authenticate(self.admin)
        for _, path, _, _ in self.resources:
            for payload in ('[1, 2]', 'null', '"text"', '{broken'):
                response = self.client.post(f"/api/v1/management/{path}/", payload, content_type="application/json")
                self.assert_error(response, 400)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_unknown_and_read_only_fields_are_rejected_on_create_and_update(self):
        fields = ("id", "created_at", "updated_at", "permissions", "employee", "user", "owner", "is_superuser")
        for model, path, _, _ in self.resources:
            for field in fields:
                self.assert_error(self.write(path + "/", {"code": "NEW", "name": "New", field: 1}), 400, field)
                self.assert_error(self.write(f"{path}/{self.target(model).pk}/", {"name": "Changed", field: 1}, method="patch"), 400, field)
            self.assertEqual(model.objects.count(), 1)
            original = self.target(model)
            self.assertEqual(model.objects.get(pk=original.pk).name, original.name)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_partial_update_preserves_unsupplied_attributes(self):
        for model, path, _, _ in self.resources:
            target = self.target(model)
            target.description = "Keep this description"
            target.save()
            response = self.write(f"{path}/{target.pk}/", {"name": "Renamed"}, method="patch")
            self.assertEqual(response.status_code, 200, response.data)
            self.assertEqual(response.data, {"id": target.pk, "code": target.code, "name": "Renamed",
                "description": "Keep this description", "is_active": True})

    def test_invalid_patch_does_not_partially_mutate_a_record(self):
        for model, path, _, _ in self.resources:
            model.objects.create(code="TAKEN", name="Conflict")
            target = self.target(model)
            response = self.write(f"{path}/{target.pk}/", {"code": "TAKEN", "name": "Must not persist"}, method="patch")
            self.assert_error(response, 400, "code")
            self.assertEqual(model.objects.get(pk=target.pk).name, target.name)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_nonexistent_ids_return_404_to_authorized_users(self):
        for _, path, _, _ in self.resources:
            for pk in (0, 999999999, 10 ** 100):
                self.assert_error(self.write(f"{path}/{pk}/", {"name": "Missing"}, method="patch"), 404)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_updates_preserve_employee_assignment_and_requirement_references(self):
        for model, path, _, _ in self.resources:
            response = self.write(f"{path}/{self.target(model).pk}/", {"code": "RENAMED", "name": "Historical reference", "is_active": False}, method="patch")
            self.assertEqual(response.status_code, 200, response.data)
        self.employee.refresh_from_db()
        self.assignment.refresh_from_db()
        self.requirement.refresh_from_db()
        self.assertEqual(self.employee.department_id, self.department.pk)
        self.assertEqual(self.employee.job_role_id, self.role.pk)
        self.assertTrue(self.employee.is_active)
        self.assertEqual(self.assignment.department_at_assignment_id, self.department.pk)
        self.assertEqual(self.assignment.job_role_at_assignment_id, self.role.pk)
        self.assertEqual(self.assignment.training_version_id, self.version.pk)
        self.assertEqual(self.assignment.status, "IN_PROGRESS")
        self.assertEqual(self.requirement.job_role_id, self.role.pk)
        self.assertTrue(self.requirement.is_active)

    def test_equivalent_patch_does_not_duplicate_audit_events(self):
        for model, path, _, _ in self.resources:
            for _ in range(2):
                self.assertEqual(self.write(f"{path}/{self.target(model).pk}/", {"name": "Same update"}, method="patch").status_code, 200)
            self.assertEqual(AuditLog.objects.filter(entity_type=model._meta.label_lower, action__endswith=".updated").count(), 1)

    def test_audit_uses_authenticated_actor_and_existing_snapshots(self):
        for model, path, _, _ in self.resources:
            response = self.write(path + "/", {"code": "AUDIT", "name": "Before", "description": "Notes"})
            event = AuditLog.objects.get(entity_type=model._meta.label_lower, entity_id=str(response.data["id"]))
            self.assertEqual(event.actor_id, self.admin.pk)
            self.assertEqual(event.action, f"{model._meta.label_lower}.created")
            self.assertEqual(event.before_data, {})
            self.assertEqual(event.after_data["code"], "AUDIT")
            self.assertIn("description", event.after_data["changed_fields"])
            self.write(f"{path}/{response.data['id']}/", {"name": "After"}, method="patch")
            event = AuditLog.objects.filter(entity_type=model._meta.label_lower, action__endswith=".updated").get()
            self.assertEqual(event.before_data["name"], "Before")
            self.assertEqual(event.after_data["name"], "After")
            self.assertEqual(event.after_data["changed_fields"], ["name"])

    def test_model_validation_errors_remain_field_errors(self):
        for model, path, _, _ in self.resources:
            with patch.object(model, "save", side_effect=ValidationError({"name": ["Rejected by model validation."]})):
                self.assert_error(self.write(path + "/", {"code": "MODEL", "name": "Name"}), 400, "name")
            self.assertEqual(model.objects.count(), 1)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_expected_duplicate_integrity_error_is_mapped_without_hiding_other_failures(self):
        for model, path, _, _ in self.resources:
            # Simulate uniqueness validation succeeding just before another writer wins.
            with patch.object(UniqueValidator, "__call__", return_value=None):
                with patch.object(model, "save", side_effect=IntegrityError(1062, "Duplicate code")):
                    self.assert_error(self.write(path + "/", {"code": self.target(model).code, "name": "Race"}), 400, "code")
            for error in (IntegrityError(1452, "Unrelated constraint"), IntegrityError(1062, "Unrelated unique key")):
                with patch.object(model, "save", side_effect=error):
                    with self.assertLogs("django.request", level="ERROR"), self.assertRaises(IntegrityError):
                        self.write(path + "/", {"code": "NOT-A-COLLISION", "name": "Name"})
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_outer_rollback_discards_record_and_pending_audit(self):
        self.authenticate(self.admin)
        for model, path, _, _ in self.resources:
            with self.captureOnCommitCallbacks(execute=True) as callbacks:
                with self.assertRaises(RuntimeError):
                    with transaction.atomic():
                        response = self.client.post(f"/api/v1/management/{path}/", {"code": "ROLLBACK", "name": "Rollback"}, format="json")
                        self.assertEqual(response.status_code, 201)
                        raise RuntimeError("Rollback fixture")
            self.assertEqual(callbacks, [])
            self.assertFalse(model.objects.filter(code="ROLLBACK").exists())
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_patch_refreshes_locked_record_before_applying_changes(self):
        for model, path, serializer_class, _ in self.resources:
            target = self.target(model)

            def concurrent_change(serializer, attrs):
                latest = model.objects.get(pk=target.pk)
                latest.description = "Changed before the write lock"
                latest.save()
                return attrs

            with patch.object(serializer_class, "validate", concurrent_change):
                response = self.write(f"{path}/{target.pk}/", {"name": "Patched name"}, method="patch")
            self.assertEqual(response.status_code, 200, response.data)
            self.assertEqual(response.data["description"], "Changed before the write lock")

    def test_unsupported_methods_do_not_modify_references(self):
        self.authenticate(self.admin)
        for model, path, _, _ in self.resources:
            for suffix, methods in (("/", ("put", "patch", "delete")),
                                    (f"/{self.target(model).pk}/", ("get", "post", "put", "delete"))):
                for method in methods:
                    self.assert_error(getattr(self.client, method)(f"/api/v1/management/{path}{suffix}", {}, format="json"), 405)
            self.assertEqual(model.objects.count(), 1)
        self.assertEqual(AuditLog.objects.count(), 0)

    def test_string_validation_matches_existing_web_forms(self):
        for model, _, serializer_class, form_class in self.resources:
            for payload in ({"code": "FORM", "name": "Name", "is_active": True},
                            {"code": " ", "name": "Name"}, {"code": "FORM"},
                            {"code": "FORM", "name": "x" * 121},
                            {"code": self.target(model).code, "name": "Name"}):
                self.assertEqual(serializer_class(data=payload).is_valid(), form_class(data=payload).is_valid())
