from importlib import import_module
import os
from pathlib import Path
import runpy
from unittest.mock import patch

from django.apps import apps
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import ImproperlyConfigured
from django.test import SimpleTestCase, TestCase


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
