from importlib import import_module
import os
from pathlib import Path
import runpy
from unittest.mock import patch

from django.contrib import messages
from django.apps import apps
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.contrib.messages.storage.fallback import FallbackStorage
from django.contrib.staticfiles import finders
from django.core.exceptions import ImproperlyConfigured
from django.template.loader import render_to_string
from django.test import Client, RequestFactory, SimpleTestCase, TestCase
from django.urls import reverse
from django.utils import timezone

from organization.models import Department, Employee, JobRole


class ProductionSettingsTests(SimpleTestCase):
	def load_settings(self, environment):
		with patch.dict(os.environ, environment, clear=True), patch("dotenv.load_dotenv"):
			return runpy.run_path(str(Path(__file__).resolve().parents[1] / "config" / "settings.py"))

	def test_debug_defaults_off_and_production_cookies_cannot_be_disabled(self):
		values = self.load_settings({
			"DJANGO_SECRET_KEY": "test-only-settings-key",
			"SESSION_COOKIE_SECURE": "false", "CSRF_COOKIE_SECURE": "false",
		})
		self.assertFalse(values["DEBUG"])
		self.assertTrue(values["SESSION_COOKIE_SECURE"])
		self.assertTrue(values["CSRF_COOKIE_SECURE"])
		self.assertEqual(values["ALLOWED_HOSTS"], [])

	def test_missing_production_secret_fails_closed(self):
		with self.assertRaises(ImproperlyConfigured):
			self.load_settings({})

	def test_explicit_development_and_https_settings(self):
		values = self.load_settings({"DEBUG": "true"})
		self.assertTrue(values["DEBUG"])
		self.assertTrue(values["SECRET_KEY"])
		self.assertFalse(values["SESSION_COOKIE_SECURE"])
		values = self.load_settings({
			"DJANGO_SECRET_KEY": "test-only-settings-key", "SECURE_SSL_REDIRECT": "true",
			"SECURE_HSTS_SECONDS": "3600", "SECURE_HSTS_INCLUDE_SUBDOMAINS": "true",
			"SECURE_HSTS_PRELOAD": "true", "ALLOWED_HOSTS": "training.example.test",
		})
		self.assertTrue(values["SECURE_SSL_REDIRECT"])
		self.assertEqual(values["SECURE_HSTS_SECONDS"], 3600)
		self.assertTrue(values["SECURE_HSTS_INCLUDE_SUBDOMAINS"])
		self.assertTrue(values["SECURE_HSTS_PRELOAD"])
		self.assertEqual(values["ALLOWED_HOSTS"], ["training.example.test"])


class AuthenticationWorkflowTests(TestCase):
	def test_login_and_post_only_logout(self):
		get_user_model().objects.create_user(username="auth-workflow", password="test-password")
		client = Client()
		self.assertEqual(client.post("/accounts/login/", {
			"username": "auth-workflow", "password": "test-password",
		}).status_code, 302)
		self.assertEqual(client.get("/accounts/logout/").status_code, 405)
		self.assertEqual(client.get("/").status_code, 200)
		self.assertEqual(client.post("/accounts/logout/").status_code, 302)
		self.assertEqual(client.get("/").status_code, 302)


class ApplicationShellTests(TestCase):
	@classmethod
	def setUpTestData(cls):
		cls.department = Department.objects.create(code="SHELL", name="Shell department")
		cls.job_role = JobRole.objects.create(code="SHELL", name="Shell role")

	@staticmethod
	def navigation(response):
		return response.content.decode().split('<nav class="primary-nav"', 1)[1].split("</nav>", 1)[0]

	def user_with_role(self, username, role, employee=False):
		user = get_user_model().objects.create_user(username=username)
		Group.objects.get(name=role).user_set.add(user)
		if employee:
			Employee.objects.create(
				employee_code=username.upper(), display_name=username,
				department=self.department, job_role=self.job_role,
				date_joined=timezone.localdate(), user=user,
			)
		return user

	def test_anonymous_login_uses_shell_without_private_navigation(self):
		response = Client().get(reverse("accounts:login"))
		self.assertEqual(response.status_code, 200)
		self.assertContains(response, 'href="/static/accounts/shell.css"')
		self.assertNotContains(response, 'aria-label="Primary navigation"')
		self.assertNotContains(response, 'action="/accounts/logout/"')
		self.assertIsNotNone(finders.find("accounts/shell.css"))

	def test_coordinator_navigation_links_to_existing_managed_sections(self):
		client = Client()
		client.force_login(self.user_with_role("shell-coordinator", "Training Coordinator"))
		response = client.get(reverse("reports:dashboard"))
		self.assertEqual(response.status_code, 200)
		navigation = self.navigation(response)
		for name in (
			"reports:dashboard", "organization:employee-list", "organization:department-list",
			"organization:job-role-list", "training:training-list", "training:assignment-list",
			"assessments:question-list", "certifications:certificate-list",
			"reports:assignment-report", "audit:audit-log-list",
		):
			with self.subTest(route=name):
				self.assertIn(f'href="{reverse(name)}"', navigation)
		self.assertContains(response, "Signed in as shell-coordinator")
		self.assertContains(response, 'method="post" action="/accounts/logout/"')

	def test_employee_and_manager_navigation_respects_role_boundaries(self):
		for role, expected_report in (("Employee", False), ("Manager", True)):
			with self.subTest(role=role):
				client = Client()
				client.force_login(self.user_with_role(f"shell-{role.lower()}", role, employee=True))
				navigation = self.navigation(client.get(reverse("reports:dashboard")))
				for name in ("organization:employee-list", "training:assignment-list", "certifications:certificate-list"):
					self.assertIn(f'href="{reverse(name)}"', navigation)
				for name in ("training:training-list", "assessments:question-list", "audit:audit-log-list"):
					self.assertNotIn(f'href="{reverse(name)}"', navigation)
				report_link = f'href="{reverse("reports:assignment-report")}"'
				self.assertEqual(report_link in navigation, expected_report)

	def test_account_without_employee_profile_has_no_assignment_or_certificate_links(self):
		client = Client()
		client.force_login(self.user_with_role("shell-trainer", "Trainer"))
		navigation = self.navigation(client.get(reverse("reports:dashboard")))
		for name in ("training:assignment-list", "certifications:certificate-list", "reports:assignment-report"):
			self.assertNotIn(f'href="{reverse(name)}"', navigation)

	def test_assignment_page_displays_shared_message_once(self):
		request = RequestFactory().get(reverse("training:assignment-list"))
		request.user = self.user_with_role("shell-message", "Training Coordinator")
		request.session = {}
		request._messages = FallbackStorage(request)
		messages.success(request, "Assignment batch finished")
		html = render_to_string("training/assignment_list.html", {"assignments": []}, request=request)
		self.assertEqual(html.count("Assignment batch finished"), 1)


class RoleBootstrapTests(TestCase):
	def test_initial_groups_have_organization_permissions(self):
		coordinator = Group.objects.get(name="Training Coordinator")
		self.assertTrue(coordinator.permissions.filter(codename="add_employee").exists())
		self.assertTrue(coordinator.permissions.filter(codename="change_department").exists())
		manager = Group.objects.get(name="Manager")
		self.assertTrue(manager.permissions.filter(codename="view_employee").exists())
		self.assertFalse(manager.permissions.filter(codename="change_employee").exists())

	def test_builtin_auth_user_is_used(self):
		self.assertEqual(get_user_model()._meta.label, "auth.User")

	def test_role_migration_preserves_existing_permissions_and_memberships(self):
		migration = import_module("accounts.migrations.0001_application_roles")
		group = Group.objects.get(name="Training Coordinator")
		unrelated = Permission.objects.get(content_type__app_label="auth", codename="view_group")
		member = get_user_model().objects.create_user(username="existing-member")
		group.permissions.add(unrelated)
		group.user_set.add(member)
		migration.create_roles(apps, None)
		migration.create_roles(apps, None)
		group.refresh_from_db()
		self.assertTrue(group.permissions.filter(pk=unrelated.pk).exists())
		self.assertTrue(group.permissions.filter(codename="add_employee").exists())
		self.assertTrue(group.permissions.filter(codename="change_department").exists())
		self.assertTrue(group.user_set.filter(pk=member.pk).exists())
		self.assertEqual(Group.objects.filter(name="Training Coordinator").count(), 1)

	def test_role_migration_reverse_preserves_groups_and_memberships(self):
		migration = import_module("accounts.migrations.0001_application_roles")
		group = Group.objects.get(name="Manager")
		unrelated = Permission.objects.get(content_type__app_label="auth", codename="view_group")
		member = get_user_model().objects.create_user(username="existing-manager")
		group.permissions.add(unrelated)
		group.user_set.add(member)
		migration.Migration.operations[0].reverse_code(apps, None)
		self.assertTrue(Group.objects.filter(pk=group.pk).exists())
		self.assertTrue(group.user_set.filter(pk=member.pk).exists())
		self.assertTrue(group.permissions.filter(pk=unrelated.pk).exists())
		self.assertTrue(group.permissions.filter(codename="view_employee").exists())
