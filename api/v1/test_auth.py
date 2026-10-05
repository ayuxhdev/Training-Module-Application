from datetime import timedelta
import time
from django.test import TestCase
from django.contrib.auth import get_user_model
from django.urls import reverse
from rest_framework.test import APIClient
from rest_framework import status
from django.core.cache import cache
from organization.models import Employee, Department, JobRole
from django.utils import timezone
from rest_framework_simplejwt.tokens import RefreshToken
from rest_framework_simplejwt.token_blacklist.models import BlacklistedToken, OutstandingToken

User = get_user_model()


class MobileAuthTests(TestCase):
    def setUp(self):
        self.client = APIClient()

        # Base setup
        self.dept = Department.objects.create(name="Engineering", code="ENG")
        self.role = JobRole.objects.create(name="Engineer", code="ENG_ROLE")

        # Valid Active Employee
        self.active_user = User.objects.create_user(username="active", password="password")
        self.active_employee = Employee.objects.create(
            employee_code="EMP001",
            display_name="Active Emp",
            user=self.active_user,
            department=self.dept,
            job_role=self.role,
            date_joined="2020-01-01",
            is_active=True,
        )

        # Inactive User
        self.inactive_user = User.objects.create_user(username="inactive_usr", password="password", is_active=False)
        self.inactive_user_emp = Employee.objects.create(
            employee_code="EMP002",
            display_name="Inactive Usr Emp",
            user=self.inactive_user,
            department=self.dept,
            job_role=self.role,
            date_joined="2020-01-01",
            is_active=True,
        )

        # Inactive Employee
        self.inactive_emp_user = User.objects.create_user(username="inactive_emp", password="password")
        self.inactive_emp = Employee.objects.create(
            employee_code="EMP003",
            display_name="Inactive Emp",
            user=self.inactive_emp_user,
            department=self.dept,
            job_role=self.role,
            date_joined="2020-01-01",
            is_active=False,
            deactivation_reason="Left company",
        )

        # Staff without Employee
        self.staff_user = User.objects.create_user(username="staff", password="password", is_staff=True)

        # Superuser without Employee
        self.superuser = User.objects.create_superuser(username="admin", password="password")

        # Regular user without Employee
        self.regular_user = User.objects.create_user(username="regular", password="password")

        self.login_url = reverse("api:v1:auth-login")
        self.refresh_url = reverse("api:v1:auth-refresh")
        self.logout_url = reverse("api:v1:auth-logout")
        self.me_url = reverse("api:v1:auth-me")

    def tearDown(self):
        cache.clear()

    # --- LOGIN TESTS ---
    def test_valid_active_employee_login(self):
        response = self.client.post(self.login_url, {"username": "active", "password": "password"})
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("access", response.data)
        self.assertIn("refresh", response.data)

        # Ensure no sensitive data leaked in response
        self.assertNotIn("password", str(response.data))
        self.assertNotIn("is_staff", str(response.data))

    def test_wrong_password(self):
        response = self.client.post(self.login_url, {"username": "active", "password": "wrong"})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertIn("error", response.data)
        self.assertEqual(response.data["error"]["code"], "no_active_account")

    def test_nonexistent_username(self):
        response = self.client.post(self.login_url, {"username": "ghost", "password": "password"})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_inactive_user(self):
        response = self.client.post(self.login_url, {"username": "inactive_usr", "password": "password"})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_inactive_employee(self):
        response = self.client.post(self.login_url, {"username": "inactive_emp", "password": "password"})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertEqual(response.data["error"]["code"], "no_active_account")

    def test_user_without_employee(self):
        response = self.client.post(self.login_url, {"username": "regular", "password": "password"})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertEqual(response.data["error"]["code"], "inactive_employee")

    def test_staff_without_employee(self):
        response = self.client.post(self.login_url, {"username": "staff", "password": "password"})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertEqual(response.data["error"]["code"], "inactive_employee")

    def test_superuser_without_employee(self):
        response = self.client.post(self.login_url, {"username": "admin", "password": "password"})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertEqual(response.data["error"]["code"], "inactive_employee")

    def test_ineligible_user_login_does_not_create_outstanding_token(self):
        before_count = OutstandingToken.objects.filter(user=self.staff_user).count()
        response = self.client.post(self.login_url, {"username": "staff", "password": "password"})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertEqual(response.data["error"]["code"], "inactive_employee")
        after_count = OutstandingToken.objects.filter(user=self.staff_user).count()
        self.assertEqual(after_count, before_count)

    # --- ACCESS TOKEN TESTS ---
    def get_tokens(self, username="active", password="password"):
        resp = self.client.post(self.login_url, {"username": username, "password": password})
        return resp.data["access"], resp.data["refresh"]

    def test_access_token_authenticates_allowed_endpoint(self):
        access, _ = self.get_tokens()
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + access)
        response = self.client.get(self.me_url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_invalid_token_rejected(self):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer invalid_token_xyz")
        response = self.client.get(self.me_url)
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_malformed_token_rejected(self):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + "a" * 100)
        response = self.client.get(self.me_url)
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_deactivated_employee_with_previously_issued_token_denied(self):
        access, _ = self.get_tokens()
        # Deactivate employee
        self.active_employee.is_active = False
        self.active_employee.deactivation_reason = "Test"
        self.active_employee.save()

        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + access)
        response = self.client.get(self.me_url)
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_deactivated_user_with_previously_issued_token_denied(self):
        access, _ = self.get_tokens()
        # Deactivate user
        self.active_user.is_active = False
        self.active_user.save()

        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + access)
        response = self.client.get(self.me_url)
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    # --- REFRESH TESTS ---
    def test_valid_refresh_succeeds_and_rotates(self):
        _, refresh = self.get_tokens()
        response = self.client.post(self.refresh_url, {"refresh": refresh})
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("access", response.data)
        self.assertIn("refresh", response.data)
        self.assertNotEqual(refresh, response.data["refresh"])

    def test_old_refresh_rejected_after_rotation(self):
        _, refresh = self.get_tokens()
        # Rotate once
        self.client.post(self.refresh_url, {"refresh": refresh})
        # Try original again
        response = self.client.post(self.refresh_url, {"refresh": refresh})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_invalid_refresh_rejected(self):
        response = self.client.post(self.refresh_url, {"refresh": "bad_token"})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_inactive_employee_refresh_rejected(self):
        _, refresh = self.get_tokens()
        self.active_employee.is_active = False
        self.active_employee.deactivation_reason = "Test"
        self.active_employee.save()

        response = self.client.post(self.refresh_url, {"refresh": refresh})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertEqual(response.data["error"]["code"], "inactive_employee")

    def test_inactive_user_refresh_rejected(self):
        _, refresh = self.get_tokens(username="active", password="password")
        self.active_user.is_active = False
        self.active_user.save()

        response = self.client.post(self.refresh_url, {"refresh": refresh})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertEqual(response.data["error"]["code"], "no_active_account")

    def test_missing_employee_refresh_rejected(self):
        token = RefreshToken.for_user(self.regular_user)
        response = self.client.post(self.refresh_url, {"refresh": str(token)})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertEqual(response.data["error"]["code"], "inactive_employee")

    def test_deleted_user_refresh_rejected_safely(self):
        temp_user = User.objects.create_user(username="temp_del_usr", password="password")
        token = RefreshToken.for_user(temp_user)
        refresh = str(token)
        temp_user.delete()

        response = self.client.post(self.refresh_url, {"refresh": refresh})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertEqual(response.data["error"]["code"], "user_not_found")
        self.assertNotIn("Traceback", str(response.content))

    def test_malformed_or_missing_user_claim_refresh_rejected_safely(self):
        token = RefreshToken()
        token.payload.pop("user_id", None)
        token_str = str(token)

        response = self.client.post(self.refresh_url, {"refresh": token_str})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertIn(response.data["error"]["code"], ["token_not_valid", "user_not_found"])

    # --- LOGOUT TESTS ---
    def test_valid_logout_blacklists_refresh(self):
        access, refresh = self.get_tokens()
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + access)

        response = self.client.post(self.logout_url, {"refresh": refresh})
        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)

        # Try to refresh with it
        response2 = self.client.post(self.refresh_url, {"refresh": refresh})
        self.assertEqual(response2.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_repeated_logout_behaves_safely(self):
        access, refresh = self.get_tokens()
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + access)

        self.client.post(self.logout_url, {"refresh": refresh})
        response = self.client.post(self.logout_url, {"refresh": refresh})
        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)

    def test_logout_without_auth_fails(self):
        _, refresh = self.get_tokens()
        response = self.client.post(self.logout_url, {"refresh": refresh})
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_logout_missing_refresh_returns_400(self):
        access, _ = self.get_tokens()
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + access)
        response = self.client.post(self.logout_url, {})
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["error"]["code"], "validation_error")
        self.assertIn("refresh", response.data["error"]["fields"])

    def test_cross_user_refresh_token_cannot_be_revoked(self):
        # Create second active employee (Employee B)
        user_b = User.objects.create_user(username="active_b", password="password")
        Employee.objects.create(
            employee_code="EMP002_B",
            display_name="Active Emp B",
            user=user_b,
            department=self.dept,
            job_role=self.role,
            date_joined="2020-01-01",
            is_active=True,
        )
        access_a, _ = self.get_tokens(username="active", password="password")
        _, refresh_b = self.get_tokens(username="active_b", password="password")

        # Employee A authenticates with A's access token, but submits B's refresh token to logout
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + access_a)
        response = self.client.post(self.logout_url, {"refresh": refresh_b})
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(response.data["error"]["code"], "permission_denied")

        # Verify B's refresh token was NOT blacklisted and can still refresh successfully
        self.client.credentials()  # clear credentials
        refresh_resp = self.client.post(self.refresh_url, {"refresh": refresh_b})
        self.assertEqual(refresh_resp.status_code, status.HTTP_200_OK)
        self.assertIn("access", refresh_resp.data)

    # --- ME TESTS ---
    def test_me_returns_employee_identity(self):
        access, _ = self.get_tokens()
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + access)
        response = self.client.get(self.me_url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["username"], "active")
        self.assertEqual(response.data["employee_code"], "EMP001")
        self.assertNotIn("password", response.data)
        self.assertNotIn("is_staff", response.data)

    # --- THROTTLING TESTS ---
    def test_repeated_failed_login_throttled(self):
        # Limit is 5/min. Do 6.
        for _ in range(5):
            response = self.client.post(self.login_url, {"username": "ghost", "password": "bad"})
            self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

        response = self.client.post(self.login_url, {"username": "ghost", "password": "bad"})
        self.assertEqual(response.status_code, status.HTTP_429_TOO_MANY_REQUESTS)

    def test_refresh_throttled(self):
        # Limit is 20/min. Do 21.
        for _ in range(20):
            self.client.post(self.refresh_url, {"refresh": "dummy"})
        response = self.client.post(self.refresh_url, {"refresh": "dummy"})
        self.assertEqual(response.status_code, status.HTTP_429_TOO_MANY_REQUESTS)
