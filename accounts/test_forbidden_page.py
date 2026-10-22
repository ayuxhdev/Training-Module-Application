from types import SimpleNamespace
from unittest.mock import patch

from django.contrib.auth.models import AnonymousUser
from django.core.exceptions import PermissionDenied
from django.template.loader import get_template
from django.test import RequestFactory, SimpleTestCase
from django.urls import reverse
from django.views.defaults import permission_denied
from rest_framework import status
from rest_framework.exceptions import PermissionDenied as DRFPermissionDenied
from rest_framework.test import APIRequestFactory

from api.exceptions import custom_exception_handler


class ForbiddenPageRegressionTests(SimpleTestCase):
    """
    Focused regression coverage for the Django 403 Forbidden page (templates/403.html).

    Verifies:
      1. HTTP 403 status code preservation.
      2. Accessible main landmark and semantic headings.
      3. Authenticated user navigation (Dashboard, My training).
      4. Unauthenticated user navigation (Sign in).
      5. Protection against internal information disclosure (no codenames, stack traces, or exception text).
      6. Preservation of API JSON error contracts (DRF endpoints return JSON envelopes, not HTML).
    """

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.factory = RequestFactory()
        cls.api_factory = APIRequestFactory()

    def test_template_compiles_cleanly(self):
        """Verifies that templates/403.html parses and compiles without template syntax errors."""
        template = get_template("403.html")
        self.assertIsNotNone(template)
        self.assertEqual(template.template.name, "403.html")

    def test_http_403_status_preserved(self):
        """Default permission_denied view returns an HTTP 403 status code."""
        request = self.factory.get("/restricted/")
        request.user = AnonymousUser()
        response = permission_denied(request, exception=PermissionDenied("Forbidden"))
        self.assertEqual(response.status_code, 403)

    def test_accessible_landmarks_and_semantic_headings(self):
        """Page includes main landmark, labelled error panel section, and meaningful h1."""
        request = self.factory.get("/restricted/")
        request.user = AnonymousUser()
        response = permission_denied(request, exception=PermissionDenied())
        content = response.content.decode("utf-8")

        # Accessible document title
        self.assertIn("<title>Access denied | Garden's Need Training</title>", content)

        # Skip link targets main landmark
        self.assertIn('<a class="skip-link" href="#main-content">Skip to content</a>', content)

        # Accessible main landmark
        self.assertIn('<main id="main-content" class="page-content" tabindex="-1">', content)

        # Accessible error section with aria-labelledby matching h1
        self.assertIn('<section class="empty-state error-panel" aria-labelledby="error-heading"', content)
        self.assertIn('<h1 id="error-heading"', content)
        self.assertIn("Access denied</h1>", content)

        # Visual status badge
        self.assertIn("403 Forbidden", content)

    def test_unauthenticated_user_navigation(self):
        """Anonymous visitor sees Sign in link and standard unauthenticated header."""
        request = self.factory.get("/restricted/")
        request.user = AnonymousUser()
        response = permission_denied(request, exception=PermissionDenied())
        content = response.content.decode("utf-8")

        login_url = reverse("accounts:login")
        self.assertIn(f'<a class="btn btn-primary" href="{login_url}">Sign in</a>', content)
        self.assertNotIn("Return to dashboard", content)
        self.assertNotIn("My training", content)
        self.assertIn('<header class="site-header">', content)

    def test_authenticated_user_navigation(self):
        """Authenticated user sees Return to dashboard and no Sign in link."""
        request = self.factory.get("/restricted/")
        request.user = SimpleNamespace(
            is_authenticated=True,
            get_full_name=lambda: "Alex Auditor",
            get_username=lambda: "alex",
            has_perm=lambda permission: False,
            has_module_perms=lambda app: False,
        )

        with patch("config.context_processors.dashboard_role", return_value="manager"), \
             patch("organization.models.Employee.objects.filter") as mock_emp:
            mock_emp.return_value.exists.return_value = False
            response = permission_denied(request, exception=PermissionDenied())
            content = response.content.decode("utf-8")

        dashboard_url = reverse("reports:dashboard")
        self.assertIn(f'<a class="btn btn-primary" href="{dashboard_url}">Return to dashboard</a>', content)
        self.assertNotIn(reverse("accounts:login"), content)
        self.assertIn("Signed in as Alex Auditor", content)

    def test_authenticated_employee_navigation_includes_my_training(self):
        """Authenticated learner/employee sees secondary My training link."""
        request = self.factory.get("/restricted/")
        request.user = SimpleNamespace(
            is_authenticated=True,
            get_full_name=lambda: "Sam Learner",
            get_username=lambda: "sam",
            has_perm=lambda permission: False,
            has_module_perms=lambda app: False,
        )

        with patch("config.context_processors.dashboard_role", return_value="employee"), \
             patch("organization.models.Employee.objects.filter") as mock_emp:
            mock_emp.return_value.exists.return_value = True
            response = permission_denied(request, exception=PermissionDenied())
            content = response.content.decode("utf-8")

        dashboard_url = reverse("reports:dashboard")
        assignment_url = reverse("training:assignment-list")
        self.assertIn(f'<a class="btn btn-primary" href="{dashboard_url}">Return to dashboard</a>', content)
        self.assertIn(f'<a class="btn btn-secondary" href="{assignment_url}">My training</a>', content)
        self.assertIn("Signed in as Sam Learner", content)

    def test_no_information_disclosure_of_internal_permissions_or_exception(self):
        """Exception messages, permission codenames, and stack traces are not leaked in the HTML."""
        sensitive_reason = "Permission organization.change_employee or training.add_training required for resource #999"
        request = self.factory.get("/restricted/")
        request.user = AnonymousUser()

        response = permission_denied(request, exception=PermissionDenied(sensitive_reason))
        content = response.content.decode("utf-8")

        # Must not disclose the exception text or sensitive permission identifiers
        self.assertNotIn(sensitive_reason, content)
        self.assertNotIn("organization.change_employee", content)
        self.assertNotIn("training.add_training", content)
        self.assertNotIn("resource #999", content)
        self.assertNotIn("Traceback", content)

        # Must display generic, accessible guidance
        self.assertIn("You do not have permission to access or manage this page.", content)
        self.assertIn(
            "If you believe you should have access to this resource, please contact your training coordinator, manager, or system administrator.",
            content,
        )

    def test_api_json_error_contract_preserved(self):
        """DRF API requests producing 403 return standard JSON envelopes and do not use the HTML template."""
        exc = DRFPermissionDenied("You do not have permission to perform this action.")
        context = {"request": self.api_factory.get("/api/v1/management/employees/")}
        response = custom_exception_handler(exc, context)

        self.assertIsNotNone(response)
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertIn("error", response.data)
        self.assertEqual(response.data["error"]["code"], "permission_denied")
        self.assertEqual(response.data["error"]["fields"], {})
        # Ensure it is a DRF Response object containing a structured dictionary, not rendered HTML
        self.assertIsInstance(response.data, dict)
        self.assertNotIn("<html", str(response.data))
