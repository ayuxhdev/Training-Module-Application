from django.contrib.auth import get_user_model
from django.test import Client, RequestFactory, TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.exceptions import NotFound, ValidationError
from rest_framework.request import Request
from rest_framework.test import APIClient
from rest_framework.views import APIView

from api.exceptions import custom_exception_handler
from api.pagination import StandardResultsSetPagination
from api.permissions import IsActiveEmployee
from organization.models import Department, Employee, JobRole
import types


class DummyValidationView(APIView):
    def post(self, request):
        raise ValidationError({"field_name": ["This field is invalid."]})


urlpatterns = [
    # Used for any inline testing if needed
]


class APIFoundationTests(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(username="api-user", password="password")
        self.department = Department.objects.create(code="DEPT", name="Department")
        self.role = JobRole.objects.create(code="ROLE", name="Role")
        self.employee = Employee.objects.create(
            employee_code="GN-API-001",
            display_name="API Employee",
            user=self.user,
            department=self.department,
            job_role=self.role,
            date_joined=timezone.now().date(),
        )
        self.client = APIClient()

    def test_api_v1_namespace_and_route_resolution(self):
        url = reverse("api:v1:status")
        self.assertEqual(url, "/api/v1/status/")

    def test_api_v1_status_authenticated_active_employee_allowed(self):
        self.client.force_authenticate(user=self.user)
        response = self.client.get(reverse("api:v1:status"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.json(), {
            "status": "ok",
            "version": "v1",
            "user": "api-user"
        })

    def test_api_v1_status_unauthenticated(self):
        response = self.client.get(reverse("api:v1:status"))
        # JWTAuthentication returns 401 when unauthenticated under default authentication classes
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
        data = response.json()
        self.assertIn("error", data)
        self.assertEqual(data["error"]["code"], "not_authenticated")
        self.assertEqual(data["error"]["message"], "Authentication credentials were not provided.")
        self.assertEqual(data["error"]["fields"], {})

    def test_api_v1_status_authenticated_without_employee_denied(self):
        user_no_emp = get_user_model().objects.create_user(username="no-emp-user", password="password")
        self.client.force_authenticate(user=user_no_emp)
        response = self.client.get(reverse("api:v1:status"))
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        data = response.json()
        self.assertIn("error", data)
        self.assertEqual(data["error"]["code"], "permission_denied")

    def test_api_v1_status_authenticated_inactive_employee_denied(self):
        user_inactive = get_user_model().objects.create_user(username="inactive-emp-user", password="password")
        Employee.objects.create(
            employee_code="GN-API-INACTIVE",
            display_name="Inactive Employee",
            user=user_inactive,
            department=self.department,
            job_role=self.role,
            date_joined=timezone.now().date(),
            is_active=False,
            deactivated_at=timezone.now(),
            deactivation_reason="Resigned",
        )
        self.client.force_authenticate(user=user_inactive)
        response = self.client.get(reverse("api:v1:status"))
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        data = response.json()
        self.assertIn("error", data)
        self.assertEqual(data["error"]["code"], "permission_denied")

    def test_api_v1_status_staff_or_superuser_without_active_employee_denied(self):
        staff_user = get_user_model().objects.create_user(
            username="staff-no-emp",
            password="password",
            is_staff=True,
            is_superuser=True,
        )
        self.client.force_authenticate(user=staff_user)
        response = self.client.get(reverse("api:v1:status"))
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        data = response.json()
        self.assertIn("error", data)
        self.assertEqual(data["error"]["code"], "permission_denied")

    def test_api_v1_unmatched_endpoint_returns_json_404(self):
        response = self.client.get("/api/v1/not-a-real-endpoint/", HTTP_ACCEPT="application/json")
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(response["Content-Type"], "application/json")
        self.assertEqual(response.json(), {
            "error": {
                "code": "not_found",
                "message": "Not found.",
                "fields": {}
            }
        })
        content_text = response.content.decode("utf-8")
        self.assertNotIn("urlpatterns", content_text)
        self.assertNotIn("<!doctype html>", content_text.lower())

    def test_api_v1_bare_root_returns_json_404(self):
        response = self.client.get("/api/v1/", HTTP_ACCEPT="application/json")
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(response["Content-Type"], "application/json")
        self.assertEqual(response.json(), {
            "error": {
                "code": "not_found",
                "message": "Not found.",
                "fields": {}
            }
        })
        content_text = response.content.decode("utf-8")
        self.assertNotIn("urlpatterns", content_text)
        self.assertNotIn("<!doctype html>", content_text.lower())

    def test_api_v1_anonymous_unmatched_path_returns_404_not_403(self):
        response = self.client.get("/api/v1/unmatched-random-route/", HTTP_ACCEPT="application/json")
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)
        data = response.json()
        self.assertEqual(data["error"]["code"], "not_found")
        self.assertEqual(data["error"]["message"], "Not found.")

    def test_api_v1_unmatched_post_anonymous_returns_404(self):
        web_client = Client(enforce_csrf_checks=True)
        response = web_client.post("/api/v1/not-a-real-endpoint/", HTTP_ACCEPT="application/json")
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(response["Content-Type"], "application/json")
        self.assertEqual(response.json()["error"]["code"], "not_found")

    def test_api_404_envelope(self):
        exc = NotFound("Resource not found.")
        response = custom_exception_handler(exc, None)
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(response.data["error"]["code"], "not_found")
        self.assertEqual(response.data["error"]["message"], "Resource not found.")
        self.assertEqual(response.data["error"]["fields"], {})

    def test_validation_error_envelope_dict(self):
        exc = ValidationError({"field_name": ["This field is invalid."]})
        response = custom_exception_handler(exc, None)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["error"]["code"], "validation_error")
        self.assertEqual(response.data["error"]["message"], "Invalid input.")
        self.assertEqual(response.data["error"]["fields"], {"field_name": ["This field is invalid."]})

    def test_validation_error_envelope_list_single(self):
        exc = ValidationError(["Non-field validation error."])
        response = custom_exception_handler(exc, None)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["error"]["code"], "validation_error")
        self.assertEqual(response.data["error"]["message"], "Non-field validation error.")
        self.assertEqual(response.data["error"]["fields"], {})

    def test_validation_error_envelope_list_multiple(self):
        exc = ValidationError(["First validation message.", "Second validation message."])
        response = custom_exception_handler(exc, None)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["error"]["code"], "validation_error")
        self.assertEqual(
            response.data["error"]["message"],
            "First validation message. Second validation message.",
        )
        self.assertEqual(response.data["error"]["fields"], {})

    def test_session_auth_csrf_enforcement(self):
        web_client = Client(enforce_csrf_checks=True)
        web_client.login(username="api-user", password="password")

        response = web_client.get(reverse("api:v1:status"))
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        response = web_client.post(reverse("api:v1:status"))
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        data = response.json()
        self.assertEqual(data["error"]["code"], "permission_denied")

    def test_pagination_foundation(self):
        factory = RequestFactory()
        drf_request = Request(factory.get("/api/v1/dummy/?page=1"))
        paginator = StandardResultsSetPagination()
        queryset_data = list(range(45))
        page = paginator.paginate_queryset(queryset_data, drf_request)
        response = paginator.get_paginated_response(page)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 45)
        self.assertEqual(len(response.data["results"]), 20)
        self.assertIn("next", response.data)
        self.assertIn("previous", response.data)

    def test_existing_web_routes_unaffected(self):
        web_client = Client()
        login_url = reverse("accounts:login")
        response = web_client.get(login_url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_existing_non_api_django_404_unaffected(self):
        web_client = Client()
        response = web_client.get("/not-a-real-web-route/")
        self.assertEqual(response.status_code, 404)
        self.assertIn("text/html", response["Content-Type"])


class APIPermissionTests(TestCase):
    def test_is_active_employee_permission(self):
        perm = IsActiveEmployee()

        # User with no employee record
        user_no_emp = get_user_model().objects.create_user(username="api-user3")
        req1 = types.SimpleNamespace(user=user_no_emp)
        self.assertFalse(perm.has_permission(req1, None))

        # User with inactive employee record
        user_inactive = get_user_model().objects.create_user(username="api-user4")
        department = Department.objects.create(code="D2", name="D2")
        role = JobRole.objects.create(code="R2", name="R2")
        Employee.objects.create(
            employee_code="GN-API-002",
            display_name="E2",
            user=user_inactive,
            department=department,
            job_role=role,
            date_joined=timezone.now().date(),
            is_active=False,
            deactivated_at=timezone.now(),
            deactivation_reason="Left company",
        )
        req2 = types.SimpleNamespace(user=user_inactive)
        self.assertFalse(perm.has_permission(req2, None))

        # User with active employee record
        user_active = get_user_model().objects.create_user(username="api-user5")
        Employee.objects.create(
            employee_code="GN-API-003",
            display_name="E3",
            user=user_active,
            department=department,
            job_role=role,
            date_joined=timezone.now().date(),
            is_active=True,
        )
        req3 = types.SimpleNamespace(user=user_active)
        self.assertTrue(perm.has_permission(req3, None))

