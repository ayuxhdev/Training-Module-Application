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
from organization.models import Employee


class EmployeeDeactivationAPITests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.admin = get_user_model().objects.create_user(username="deactivate-admin")
        cls.admin.groups.add(Group.objects.get(name="Administrator"))
        cls.user.groups.add(Group.objects.get(name="Training Coordinator"))
        cls.employee_user.groups.add(Group.objects.get(name="Employee"))
        cls.manager_user = get_user_model().objects.create_user(username="deactivate-manager")
        cls.manager_user.groups.add(Group.objects.get(name="Manager"))
        cls.manager = Employee.objects.create(
            employee_code="DEACT-MGR", display_name="Manager", user=cls.manager_user,
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(),
        )

    def setUp(self):
        self.client = APIClient()

    def url(self, employee=None):
        return f"/api/v1/management/employees/{(employee or self.employee).pk}/deactivate/"

    def authenticate(self, actor):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + str(RefreshToken.for_user(actor).access_token))

    def deactivate(self, data=None, *, actor=None, employee=None):
        self.authenticate(actor or self.admin)
        with self.captureOnCommitCallbacks(execute=True):
            return self.client.post(self.url(employee), {"reason": "Left company"} if data is None else data, format="json")

    def assert_error(self, response, status, field=None):
        self.assertEqual(response.status_code, status, response.data)
        self.assertEqual(set(response.data), {"error"})
        self.assertEqual(set(response.data["error"]), {"code", "message", "fields"})
        if field:
            self.assertIn(field, response.data["error"]["fields"])

    def test_management_only_administrator_deactivates_employee_and_linked_login(self):
        response = self.deactivate({"reason": "  Left company  "})
        self.assertEqual(response.status_code, 200, response.data)
        self.employee.refresh_from_db()
        self.employee_user.refresh_from_db()
        self.assertFalse(self.employee.is_active)
        self.assertFalse(self.employee_user.is_active)
        self.assertIsNotNone(self.employee.deactivated_at)
        self.assertEqual(self.employee.deactivation_reason, "Left company")
        detail = self.client.get(f"/api/v1/management/employees/{self.employee.pk}/")
        self.assertEqual(response.data, detail.data)
        self.assertEqual(response.data["login_status"], "INACTIVE")

    def test_jwt_is_required_even_with_authenticated_web_session(self):
        for token in (None, "invalid-token"):
            self.client.credentials(**({"HTTP_AUTHORIZATION": "Bearer " + token} if token else {}))
            self.assert_error(self.client.post(self.url(), {"reason": "Rejected"}, format="json"), 401)
        self.client.credentials()
        self.client.force_login(self.admin)
        self.assert_error(self.client.post(self.url(), {"reason": "Rejected"}, format="json"), 401)
        self.assertFalse(AuditLog.objects.exists())

    def test_default_manager_and_employee_cannot_deactivate_foreign_or_own_records(self):
        for actor, employee in ((self.manager_user, self.employee), (self.manager_user, self.manager),
                                (self.employee_user, self.employee), (self.employee_user, self.manager)):
            self.assert_error(self.deactivate(actor=actor, employee=employee), 403)
        self.assertTrue(Employee.objects.get(pk=self.employee.pk).is_active)
        self.assertFalse(AuditLog.objects.exists())

    def test_direct_change_permission_needs_neither_view_permission_nor_employee_link(self):
        actor = get_user_model().objects.create_user(username="deactivate-change-only")
        actor.user_permissions.add(Permission.objects.get(content_type__app_label="organization", codename="change_employee"))
        self.assertEqual(self.deactivate(actor=actor).status_code, 200)

    def test_explicit_manager_change_grant_preserves_company_wide_authority(self):
        self.manager_user.user_permissions.add(Permission.objects.get(content_type__app_label="organization", codename="change_employee"))
        self.assertEqual(self.deactivate(actor=self.manager_user).status_code, 200)

    def test_inactive_employee_or_disabled_user_cannot_use_management_grants(self):
        self.manager.is_active = False
        self.manager.deactivation_reason = "Disabled fixture"
        self.manager.save()
        self.manager_user.refresh_from_db()
        self.authenticate(self.manager_user)
        self.assert_error(self.client.post(self.url(), {"reason": "Rejected"}, format="json"), 401)
        self.manager_user.is_active = True
        self.manager_user.save()
        self.manager_user.user_permissions.add(Permission.objects.get(content_type__app_label="organization", codename="change_employee"))
        self.assert_error(self.deactivate(actor=self.manager_user), 403)

    def test_self_deactivation_is_forbidden_even_for_superuser(self):
        for superuser in (False, True):
            self.manager_user.is_superuser = superuser
            self.manager_user.save()
            self.manager_user.groups.add(Group.objects.get(name="Administrator"))
            self.assert_error(self.deactivate(actor=self.manager_user, employee=self.manager), 403)
        self.assertTrue(Employee.objects.get(pk=self.manager.pk).is_active)
        self.assertTrue(get_user_model().objects.get(pk=self.manager_user.pk).is_active)
        self.assertFalse(AuditLog.objects.exists())

    def test_coordinator_cannot_deactivate_staff_administrator_or_superuser(self):
        for privileged in ("staff", "administrator", "superuser"):
            self.employee_user.is_staff = privileged == "staff"
            self.employee_user.is_superuser = privileged == "superuser"
            self.employee_user.save()
            if privileged == "administrator":
                self.employee_user.groups.add(Group.objects.get(name="Administrator"))
            else:
                self.employee_user.groups.remove(Group.objects.get(name="Administrator"))
            self.assert_error(self.deactivate(actor=self.user), 403)
        self.assertFalse(AuditLog.objects.exists())

    def test_ordinary_administrator_cannot_deactivate_superuser(self):
        self.employee_user.is_superuser = True
        self.employee_user.save()
        self.assert_error(self.deactivate(), 403)
        self.assertTrue(Employee.objects.get(pk=self.employee.pk).is_active)

    def test_superuser_can_deactivate_other_superuser(self):
        self.admin.is_superuser = True
        self.admin.save()
        self.employee_user.is_superuser = True
        self.employee_user.save()
        self.assertEqual(self.deactivate().status_code, 200)

    def test_administrator_can_deactivate_staff_or_administrator_accounts(self):
        self.employee_user.is_staff = True
        self.employee_user.save()
        self.employee_user.groups.add(Group.objects.get(name="Administrator"))
        self.assertEqual(self.deactivate().status_code, 200)

    def test_employee_without_login_can_be_deactivated(self):
        employee = Employee.objects.create(employee_code="DEACT-NO-LOGIN", display_name="No login",
            department=self.department, job_role=self.role, date_joined=self.now.date())
        response = self.deactivate(employee=employee)
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["login_status"], "NOT_LINKED")

    def test_reason_is_required_nonblank_and_limited_to_1000_characters(self):
        for data in ({}, {"reason": ""}, {"reason": " \n\t "}, {"reason": None}, {"reason": "x" * 1001}, {"reason": []}, {"reason": 123}):
            self.assert_error(self.deactivate(data), 400, "reason")
        self.assertTrue(Employee.objects.get(pk=self.employee.pk).is_active)
        self.assertFalse(AuditLog.objects.exists())
        self.assertEqual(self.deactivate({"reason": "x" * 1000}).status_code, 200)

    def test_unknown_fields_and_non_object_payloads_are_rejected(self):
        for data in ([], "invalid", {"reason": "Left", "is_active": False}, {"reason": "Left", "actor": self.admin.pk}):
            self.assert_error(self.deactivate(data), 400)
        self.assertFalse(AuditLog.objects.exists())

    def test_already_inactive_is_409_and_preserves_first_reason_timestamp_and_audit(self):
        self.assertEqual(self.deactivate().status_code, 200)
        before = Employee.objects.values().get(pk=self.employee.pk)
        self.assert_error(self.deactivate({"reason": "Second request"}), 409)
        self.assertEqual(Employee.objects.values().get(pk=self.employee.pk), before)
        self.assertEqual(AuditLog.objects.filter(action="organization.employee.deactivated").count(), 1)

    def test_unknown_id_is_404_only_after_authorization(self):
        self.authenticate(self.admin)
        self.assert_error(self.client.post("/api/v1/management/employees/999999999/deactivate/", {"reason": "Left"}, format="json"), 404)
        self.authenticate(self.employee_user)
        self.assert_error(self.client.post("/api/v1/management/employees/999999999/deactivate/", {"reason": "Left"}, format="json"), 403)

    def test_only_post_is_supported_and_patch_cannot_deactivate(self):
        self.authenticate(self.admin)
        for method in ("get", "head", "patch", "put", "delete"):
            response = getattr(self.client, method)(self.url())
            self.assertEqual(response.status_code, 405)
        response = self.client.patch(f"/api/v1/management/employees/{self.employee.pk}/", {"is_active": False}, format="json")
        self.assert_error(response, 400, "is_active")

    def test_audit_occurs_after_commit_with_server_actor_snapshots_and_reason(self):
        self.authenticate(self.admin)
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            response = self.client.post(self.url(), {"reason": "Left company"}, format="json")
            self.assertEqual(response.status_code, 200)
            self.assertFalse(AuditLog.objects.exists())
        self.assertEqual(len(callbacks), 1)
        event = AuditLog.objects.get(action="organization.employee.deactivated")
        self.assertEqual(event.actor_id, self.admin.pk)
        self.assertEqual(event.entity_id, str(self.employee.pk))
        self.assertEqual(event.reason, "Left company")
        self.assertTrue(event.before_data["is_active"])
        self.assertFalse(event.after_data["is_active"])

    def test_outer_rollback_restores_employee_login_and_discards_audit(self):
        self.authenticate(self.admin)
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            with self.assertRaises(RuntimeError):
                with transaction.atomic():
                    self.assertEqual(self.client.post(self.url(), {"reason": "Rollback"}, format="json").status_code, 200)
                    raise RuntimeError("Rollback fixture")
        self.assertEqual(callbacks, [])
        self.assertTrue(Employee.objects.get(pk=self.employee.pk).is_active)
        self.assertTrue(get_user_model().objects.get(pk=self.employee_user.pk).is_active)
        self.assertFalse(AuditLog.objects.exists())

    def test_model_validation_failure_does_not_disable_login_or_audit(self):
        with patch.object(Employee, "save", side_effect=ValidationError({"deactivation_reason": ["Rejected"]})):
            self.assert_error(self.deactivate(), 400, "deactivation_reason")
        self.assertTrue(Employee.objects.get(pk=self.employee.pk).is_active)
        self.assertTrue(get_user_model().objects.get(pk=self.employee_user.pk).is_active)
        self.assertFalse(AuditLog.objects.exists())

    def test_hierarchy_and_employee_locks_precede_linked_user_lock(self):
        self.employee.reporting_manager = self.manager
        self.employee.save()
        with CaptureQueriesContext(connection) as queries:
            self.assertEqual(self.deactivate().status_code, 200)
        locks = [q["sql"] for q in queries if "FOR UPDATE" in q["sql"]]
        self.assertIn("organization_employee", locks[0])
        user_lock = next(i for i, query in enumerate(locks) if "auth_user" in query)
        self.assertGreater(user_lock, 0)
        self.assertNotIn("JOIN", locks[0])

    def test_authority_is_rechecked_using_fresh_locked_linked_user(self):
        from api.v1.management_views import EmployeeDeactivationView
        original = EmployeeDeactivationView.get_object

        def promote_before_lock(view):
            employee = original(view)
            # Deterministic interleaving: authority changed before User lock/read.
            user = get_user_model().objects.get(pk=employee.user_id)
            user.is_superuser = True
            user.save()
            return employee

        with patch.object(EmployeeDeactivationView, "get_object", promote_before_lock):
            self.assert_error(self.deactivate(), 403)
        self.assertTrue(Employee.objects.get(pk=self.employee.pk).is_active)
        self.assertFalse(AuditLog.objects.exists())

    def test_competing_deactivation_observed_at_locked_read_returns_conflict(self):
        # Deterministic loser path: an earlier request changed the stored state,
        # while this caller still holds a stale active Employee instance.
        winner = Employee.objects.get(pk=self.employee.pk)
        winner.is_active = False
        winner.deactivation_reason = "Winning request"
        winner.save()
        self.assertTrue(self.employee.is_active)
        self.assert_error(self.deactivate(), 409)
        self.assertEqual(Employee.objects.get(pk=self.employee.pk).deactivation_reason, "Winning request")
        self.assertFalse(AuditLog.objects.exists())

    def test_history_and_subordinates_are_preserved_without_reassignment(self):
        final_attempt = self.complete_assignment()
        from certifications.models import Certificate
        from training.models import LessonProgress, TrainingAssignment
        from assessments.models import AssessmentAttempt
        Certificate.objects.create(
            certificate_number="DEACT-HISTORY", assignment=self.assignment, training_version=self.version,
            qualifying_final_attempt=final_attempt, employee_code_snapshot=self.employee.employee_code,
            employee_name_snapshot=self.employee.display_name, training_title_snapshot=self.version.title,
            version_number_snapshot=self.version.version_number,
        )
        child = Employee.objects.create(employee_code="DEACT-CHILD", display_name="Child",
            department=self.department, job_role=self.role, date_joined=self.now.date(), reporting_manager=self.employee)
        models = (TrainingAssignment, LessonProgress, AssessmentAttempt, Certificate)
        before = {model: list(model.objects.order_by("pk").values()) for model in models}
        self.assertEqual(self.deactivate().status_code, 200)
        for model, rows in before.items():
            self.assertEqual(list(model.objects.order_by("pk").values()), rows)
        child.refresh_from_db()
        self.assertEqual(child.reporting_manager_id, self.employee.pk)
        self.assertTrue(child.is_active)

    def test_malformed_json_is_rejected_without_changes(self):
        self.authenticate(self.admin)
        self.assert_error(self.client.post(self.url(), '{"reason":', content_type="application/json"), 400)
        self.assertTrue(Employee.objects.get(pk=self.employee.pk).is_active)
        self.assertFalse(AuditLog.objects.exists())

    def test_web_reason_validation_is_preserved(self):
        from organization.forms import EmployeeDeactivateForm
        from api.v1.management_serializers import EmployeeDeactivationSerializer
        for reason in ("", " \t", "a" * 1001, "  Left company  ", "a" * 1000):
            form = EmployeeDeactivateForm({"reason": reason})
            serializer = EmployeeDeactivationSerializer(data={"reason": reason})
            self.assertEqual(form.is_valid(), serializer.is_valid())
            if form.is_valid():
                self.assertEqual(form.cleaned_data["reason"], serializer.validated_data["reason"])
