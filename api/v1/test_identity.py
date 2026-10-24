from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.token_blacklist.models import OutstandingToken

from api.capabilities import mobile_capabilities
from organization.models import Department, Employee, JobRole


class MobileIdentityTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.department = Department.objects.create(code="IDENTITY", name="Identity QA")
        self.job_role = JobRole.objects.create(code="IDENTITY", name="Employment classification")

    def tearDown(self):
        cache.clear()

    def account(self, username, groups=(), employee=True):
        user = get_user_model().objects.create_user(username=username, password="test-password")
        user.groups.add(*Group.objects.filter(name__in=groups))
        if employee:
            Employee.objects.create(
                user=user, employee_code=username.upper(), display_name=username,
                department=self.department, job_role=self.job_role, date_joined=timezone.now().date(),
            )
        return user

    def login(self, user):
        return self.client.post("/api/v1/auth/login/", {"username": user.username, "password": "test-password"})

    def identity(self, user):
        response = self.login(user)
        self.assertEqual(response.status_code, 200)
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + response.data["access"])
        return self.client.get("/api/v1/auth/me/").data, response.data

    def test_employee_identity_is_additive_and_contains_no_management_or_framework_grants(self):
        user = self.account("employee", ("Employee",))
        identity, _ = self.identity(user)
        self.assertEqual(identity["employee_code"], identity["employee"]["employee_code"])
        self.assertEqual(identity["user"]["id"], user.pk)
        self.assertIn("personal_learning", identity["capabilities"])
        self.assertNotIn("management_workspace", identity["capabilities"])
        self.assertNotIn("team_workspace", identity["capabilities"])
        self.assertNotIn("is_staff", identity)
        self.assertNotIn("auth.change_user", identity["capabilities"])
        self.assertNotIn("password", str(identity))
        self.assertEqual(identity["capabilities"], sorted(set(identity["capabilities"])))
        self.assertEqual(identity["capabilities"], sorted(set(identity["capabilities"])))

    def test_manager_has_team_and_personal_access_without_mutation_grants(self):
        identity, _ = self.identity(self.account("manager", ("Manager",)))
        self.assertIn("team_workspace", identity["capabilities"])
        self.assertIn("assignment_report", identity["capabilities"])
        self.assertIn("personal_learning", identity["capabilities"])
        for forbidden in ("training.add_trainingassignment", "training.change_trainingversion",
                          "certifications.change_certificate", "management_workspace"):
            self.assertNotIn(forbidden, identity["capabilities"])

    def test_administrator_with_employee_keeps_both_contexts(self):
        identity, _ = self.identity(self.account("administrator", ("Administrator",)))
        for capability in ("management_workspace", "company_dashboard", "personal_learning",
                           "training.add_trainingassignment", "certifications.change_certificate"):
            self.assertIn(capability, identity["capabilities"])
        self.assertIsNotNone(identity["employee"])

    def test_management_only_login_me_refresh_rotation_and_logout(self):
        user = self.account("management", ("Administrator",), employee=False)
        identity, tokens = self.identity(user)
        self.assertIsNone(identity["employee"])
        self.assertNotIn("employee_code", identity)
        self.assertNotIn("personal_learning", identity["capabilities"])
        rotated = self.client.post("/api/v1/auth/refresh/", {"refresh": tokens["refresh"]})
        self.assertEqual(rotated.status_code, 200)
        self.assertEqual(self.client.post("/api/v1/auth/refresh/", {"refresh": tokens["refresh"]}).status_code, 401)
        self.assertEqual(self.client.post("/api/v1/auth/logout/", {"refresh": rotated.data["refresh"]}).status_code, 204)
        self.assertEqual(self.client.post("/api/v1/auth/refresh/", {"refresh": rotated.data["refresh"]}).status_code, 401)

    def test_management_only_cannot_enter_any_personal_endpoint(self):
        self.identity(self.account("management", ("Administrator",), employee=False))
        requests = (
            ("get", "/api/v1/dashboard/"), ("get", "/api/v1/assignments/"),
            ("get", "/api/v1/assignments/1/"), ("get", "/api/v1/certificates/"),
            ("get", "/api/v1/notifications/"), ("get", "/api/v1/notifications/unread-count/"),
            ("post", "/api/v1/notifications/read-all/"),
            ("get", "/api/v1/assignments/1/assessments/"),
            ("post", "/api/v1/assignments/1/assessments/1/attempts/"),
            ("get", "/api/v1/assessment-attempts/1/"),
            ("post", "/api/v1/assessment-attempts/1/submit/"),
            ("post", "/api/v1/assignments/1/lessons/1/complete/"),
            ("get", "/api/v1/assignments/1/lessons/1/progress/"),
            ("post", "/api/v1/assignments/1/lessons/1/sessions/"),
            ("get", "/api/v1/assignments/1/lessons/1/sessions/1/media/"),
            ("get", "/api/v1/assignments/1/lessons/1/replay/media/"),
            ("post", "/api/v1/assignments/1/lessons/1/sessions/1/end/"),
        )
        for method, url in requests:
            with self.subTest(method=method, url=url):
                self.assertEqual(getattr(self.client, method)(url).status_code, 403)

    def test_combined_groups_and_direct_permissions_preserve_effective_grants(self):
        user = self.account("combined", ("Manager", "Training Coordinator", "Employee"))
        identity, _ = self.identity(user)
        self.assertTrue({"team_workspace", "management_workspace", "personal_learning"}.issubset(identity["capabilities"]))
        direct = self.account("direct", employee=False)
        direct.user_permissions.add(Permission.objects.get(codename="view_auditlog", content_type__app_label="audit"))
        self.client.credentials()
        identity, _ = self.identity(direct)
        self.assertIn("audit.view_auditlog", identity["capabilities"])
        self.assertNotIn("training.add_trainingassignment", identity["capabilities"])

    def test_trainer_and_supervisor_keep_existing_personal_access(self):
        for group in ("Trainer", "Supervisor"):
            with self.subTest(group=group):
                self.client.credentials()
                identity, _ = self.identity(self.account(group.lower(), (group,)))
                self.assertIn("personal_learning", identity["capabilities"])
                self.assertNotIn("management_workspace", identity["capabilities"])

    def test_manager_without_employee_has_no_team_scope_or_management_login(self):
        user = self.account("manager", ("Manager",), employee=False)
        self.assertEqual(self.login(user).status_code, 401)
        self.assertNotIn("team_workspace", mobile_capabilities(user))
        self.assertFalse(OutstandingToken.objects.filter(user=user).exists())

    def test_employment_job_role_does_not_confer_authorization(self):
        self.job_role.name = "Manager"
        self.job_role.save()
        identity, _ = self.identity(self.account("employee", ("Employee",)))
        self.assertEqual(identity["employee"]["job_role"], "Manager")
        self.assertNotIn("team_workspace", identity["capabilities"])
        self.assertNotIn("management_workspace", identity["capabilities"])

    def test_role_or_staff_label_without_effective_permissions_is_not_authorization(self):
        user = self.account("staff", employee=False)
        user.is_staff = True
        user.save()
        self.assertEqual(self.login(user).status_code, 401)
        user.groups.add(Group.objects.get(name="Administrator"))
        # Even a superuser flag cannot bypass the effective-permission evaluation.
        user.is_superuser = True
        with patch.object(type(user), "has_perm", return_value=False):
            self.assertEqual(mobile_capabilities(user), [])
        Group.objects.get(name="Administrator").permissions.clear()
        self.assertEqual(self.login(user).status_code, 401)
        self.assertFalse(OutstandingToken.objects.filter(user=user).exists())

    def test_inactive_linked_employee_cannot_bypass_with_management_permissions(self):
        user = self.account("inactive", ("Administrator",))
        user.employee.is_active = False
        user.employee.deactivation_reason = "Isolated test"
        user.employee.save()
        # Simulate independently re-enabled login; the Employee gate still applies.
        user.is_active = True
        user.save()
        self.assertEqual(self.login(user).status_code, 401)
        self.assertFalse(OutstandingToken.objects.filter(user=user).exists())

    def test_inactive_management_user_is_denied(self):
        user = self.account("inactive", ("Administrator",), employee=False)
        _, tokens = self.identity(user)
        user.is_active = False
        user.save()
        self.assertEqual(self.client.get("/api/v1/auth/me/").status_code, 401)
        self.assertEqual(self.client.post("/api/v1/auth/refresh/", {"refresh": tokens["refresh"]}).status_code, 401)

    def test_capability_loss_is_rechecked_and_logout_remains_available(self):
        user = self.account("management", ("Administrator",), employee=False)
        _, tokens = self.identity(user)
        user.groups.clear()
        self.assertEqual(self.client.get("/api/v1/auth/me/").status_code, 403)
        self.assertEqual(self.client.post("/api/v1/auth/refresh/", {"refresh": tokens["refresh"]}).status_code, 401)
        self.assertEqual(self.client.post("/api/v1/auth/logout/", {"refresh": tokens["refresh"]}).status_code, 204)

    def test_employee_capability_loss_keeps_personal_context_only(self):
        user = self.account("combined", ("Administrator", "Manager"))
        self.identity(user)
        user.groups.clear()
        identity = self.client.get("/api/v1/auth/me/").data
        self.assertEqual(identity["capabilities"], ["personal_learning"])

    def test_management_logout_cannot_blacklist_another_users_refresh(self):
        first = self.account("first", ("Administrator",), employee=False)
        second = self.account("second", ("Administrator",), employee=False)
        _, first_tokens = self.identity(first)
        self.client.credentials()
        _, second_tokens = self.identity(second)
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + first_tokens["access"])
        self.assertEqual(self.client.post("/api/v1/auth/logout/", {"refresh": second_tokens["refresh"]}).status_code, 403)
        self.assertEqual(self.client.post("/api/v1/auth/refresh/", {"refresh": second_tokens["refresh"]}).status_code, 200)

    def test_identity_is_authenticated_read_only(self):
        self.assertEqual(self.client.get("/api/v1/auth/me/").status_code, 401)
        self.identity(self.account("employee"))
        self.assertEqual(self.client.post("/api/v1/auth/me/", {"capabilities": ["management_workspace"]}).status_code, 405)
