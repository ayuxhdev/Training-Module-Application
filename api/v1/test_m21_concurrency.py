"""Real MySQL races with exact fixture cleanup, never database-wide flushes."""

from concurrent.futures import ThreadPoolExecutor
from threading import Event, local
from unittest import skipUnless
from unittest.mock import patch
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import close_old_connections, connection, models
from django.test import RequestFactory, SimpleTestCase
from django.test.utils import CaptureQueriesContext
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken
from rest_framework_simplejwt.token_blacklist.models import BlacklistedToken, OutstandingToken

from audit.models import AuditLog
from organization.models import Department, Employee, JobRole
from organization.forms import EmployeeForm
from organization.views import EmployeeUpdateView, deactivate_employee


@skipUnless(connection.vendor == "mysql", "MySQL row-lock concurrency tests require MySQL.")
class MySQLConcurrencyFixtures(SimpleTestCase):
    databases = {"default"}

    def setUp(self):
        self.assertEqual(connection.vendor, "mysql")
        self.assertTrue(connection.settings_dict["NAME"].startswith("test_"))
        self.assertTrue(connection.get_autocommit())
        self.users = []
        self.employee_ids = []
        self.department_id = self.role_id = None
        self.grants = list(Group.permissions.through.objects.order_by("pk").values_list())
        self.groups = list(Group.objects.order_by("pk").values_list("pk", "name"))
        # TransactionTestCase teardown can flush migration-created groups before
        # this class runs. These fixtures use their own learner and superuser,
        # so preserve the current group baseline without requiring seeded roles.
        self.marker = "m21-" + uuid4().hex[:16]
        self.addCleanup(self.cleanup_fixtures)
        self.user = self.create_user("learner")
        department = Department.objects.create(code=self.marker, name="Isolated M21 test")
        self.department_id = department.pk
        role = JobRole.objects.create(code=self.marker, name="Isolated M21 test")
        self.role_id = role.pk
        self.employee = Employee.objects.create(
            employee_code=self.marker, display_name="Isolated learner", user=self.user,
            department=department, job_role=role, date_joined="2026-01-01",
        )
        self.employee_ids.append(self.employee.pk)

    def create_user(self, suffix, **kwargs):
        user = get_user_model().objects.create_user(username=f"{self.marker}-{suffix}", **kwargs)
        self.users.append(user.pk)
        return user

    def cleanup_fixtures(self):
        # Only these newly committed fixtures need removal. Model history guards
        # remain unchanged; no live records, groups, permissions or sequences reset.
        for model, filters in (
            (AuditLog, {"actor_id__in": self.users}),
            (BlacklistedToken, {"token__user_id__in": self.users}),
            (OutstandingToken, {"user_id__in": self.users}),
            (Employee, {"pk__in": self.employee_ids}),
            (get_user_model(), {"pk__in": self.users}),
            (Department, {"pk": self.department_id}),
            (JobRole, {"pk": self.role_id}),
        ):
            models.QuerySet(model, using="default").filter(**filters)._raw_delete("default")
        self.assertEqual(list(Group.objects.order_by("pk").values_list("pk", "name")), self.groups)
        self.assertEqual(list(Group.permissions.through.objects.order_by("pk").values_list()), self.grants)
        connection.close()

    def worker(self, operation, observe=None):
        close_old_connections()
        try:
            with connection.cursor() as cursor:
                cursor.execute("SET SESSION innodb_lock_wait_timeout=10")
            if observe is None:
                return operation()
            with connection.execute_wrapper(observe):
                return operation()
        finally:
            connection.close()


class RefreshConcurrencyTests(MySQLConcurrencyFixtures):
    def setUp(self):
        super().setUp()
        self.parent = RefreshToken.for_user(self.user)
        self.encoded = str(self.parent)
        self.access = str(self.parent.access_token)

    def request(self, action):
        client = APIClient()
        if action == "logout":
            client.credentials(HTTP_AUTHORIZATION="Bearer " + self.access)
        return client.post(f"/api/v1/auth/{action}/", {"refresh": self.encoded}, format="json")

    def overlap(self, first_action, second_action):
        first_consuming, second_boundary, second_consuming, release = (Event() for _ in range(4))
        thread = local()
        blacklist = RefreshToken.blacklist

        def consume(token):
            if thread.role == "first":
                first_consuming.set()
                if not release.wait(15):
                    raise AssertionError("First consumer was not released")
            else:
                second_consuming.set()
                second_boundary.set()
            return blacklist(token)

        def observe(execute, sql, params, many, context):
            if "FOR UPDATE" in sql.upper() and "token_blacklist_outstandingtoken" in sql.lower():
                second_boundary.set()
            return execute(sql, params, many, context)

        def call(role, action):
            thread.role = role
            return self.worker(lambda: self.request(action), observe if role == "second" else None)

        with patch.object(RefreshToken, "blacklist", consume), ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(call, "first", first_action)
            try:
                self.assertTrue(first_consuming.wait(15), "First request did not reach consumption")
                second = pool.submit(call, "second", second_action)
                self.assertTrue(second_boundary.wait(15), "Second request did not reach the lock/consumption boundary")
                serialized = not second_consuming.is_set()
            finally:
                release.set()
            responses = first.result(20), second.result(20)
        self.assertTrue(serialized, f"Concurrent consumption was not serialized: {[r.status_code for r in responses]}")
        return responses

    def test_concurrent_refreshes_create_only_one_successor(self):
        first, second = self.overlap("refresh", "refresh")
        self.assertEqual((first.status_code, second.status_code), (200, 401))
        self.assertEqual(OutstandingToken.objects.filter(user=self.user).count(), 2)
        self.assertEqual(BlacklistedToken.objects.filter(token__user=self.user).count(), 1)
        RefreshToken(first.data["refresh"])

    def test_logout_winning_the_lock_prevents_refresh(self):
        logout, refresh = self.overlap("logout", "refresh")
        self.assertEqual((logout.status_code, refresh.status_code), (204, 401))
        self.assertEqual(OutstandingToken.objects.filter(user=self.user).count(), 1)
        self.assertTrue(BlacklistedToken.objects.filter(token__jti=self.parent["jti"]).exists())

    def test_refresh_winning_the_lock_preserves_rotated_token_logout_contract(self):
        refresh, logout = self.overlap("refresh", "logout")
        self.assertEqual((refresh.status_code, logout.status_code), (200, 204))
        self.assertEqual(OutstandingToken.objects.filter(user=self.user).count(), 2)
        # Logout of an already consumed parent is idempotent, not logout of every
        # session. The client must use its current rotated refresh to revoke it.
        child = refresh.data["refresh"]
        RefreshToken(child)
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION="Bearer " + self.access)
        self.assertEqual(client.post("/api/v1/auth/logout/", {"refresh": child}).status_code, 204)


class EmployeeEditConcurrencyTests(MySQLConcurrencyFixtures):
    def setUp(self):
        super().setUp()
        self.actor = self.create_user("administrator", is_superuser=True)

    def request(self, action):
        if action == "deactivate":
            request = RequestFactory().post("/employees/deactivate/", {"reason": "Isolated M21 deactivation"})
            request.user = get_user_model().objects.get(pk=self.actor.pk)
            return deactivate_employee(request, pk=self.employee.pk)
        request = RequestFactory().post("/employees/edit/", {
            "employee_code": self.employee.employee_code, "display_name": "Edited profile",
            "user": self.user.pk, "department": self.department_id, "job_role": self.role_id,
            "date_joined": "2026-01-01", "reporting_manager": "",
            "is_active": "on", "deactivated_at": "", "deactivation_reason": "",
        })
        request.user = get_user_model().objects.get(pk=self.actor.pk)
        return EmployeeUpdateView.as_view()(request, pk=self.employee.pk)

    def overlap(self, first_action):
        first_saved, second_lock, release, edit_validated, second_saved = (Event() for _ in range(5))
        thread = local()
        save, is_valid = Employee.save, EmployeeForm.is_valid

        def hold_save(employee, *args, **kwargs):
            result = save(employee, *args, **kwargs)
            if thread.role == "first":
                first_saved.set()
                if not release.wait(15):
                    raise AssertionError("First Employee write was not released")
            else:
                second_saved.set()
            return result

        def validate(form):
            result = is_valid(form)
            if thread.role == "second":
                edit_validated.set()
            return result

        def observe(execute, sql, params, many, context):
            if "FOR UPDATE" in sql.upper() and "organization_employee" in sql.lower():
                second_lock.set()
            return execute(sql, params, many, context)

        def call(role, action):
            thread.role = role
            return self.worker(lambda: self.request(action), observe if role == "second" else None)

        second_action = "edit" if first_action == "deactivate" else "deactivate"
        with patch.object(Employee, "save", hold_save), patch.object(EmployeeForm, "is_valid", validate), ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(call, "first", first_action)
            try:
                self.assertTrue(first_saved.wait(15), "First write did not reach its commit boundary")
                second = pool.submit(call, "second", second_action)
                self.assertTrue(second_lock.wait(15), "Second write did not attempt its row lock")
                validated_before_lock = edit_validated.is_set()
                saved_before_commit = second_saved.is_set()
            finally:
                release.set()
            responses = first.result(20), second.result(20)
        self.assertEqual([r.status_code for r in responses], [302, 302])
        self.assertFalse(saved_before_commit)
        if first_action == "deactivate":
            self.assertFalse(validated_before_lock, "The edit validated a stale Employee before acquiring its lock")
        self.employee.refresh_from_db()
        self.user.refresh_from_db()
        self.assertFalse(self.employee.is_active)
        self.assertIsNotNone(self.employee.deactivated_at)
        self.assertEqual(self.employee.deactivation_reason, "Isolated M21 deactivation")
        self.assertEqual(self.employee.display_name, "Edited profile")
        self.assertFalse(self.user.is_active)
        self.assertEqual(AuditLog.objects.filter(actor=self.actor, action="organization.employee.deactivated").count(), 1)

    def test_deactivation_committing_during_edit_preserves_inactive_metadata(self):
        self.overlap("deactivate")

    def test_deactivation_waits_for_a_locked_profile_edit(self):
        self.overlap("edit")

    def test_hierarchy_locks_precede_target_lock_and_cycle_validation(self):
        request = RequestFactory().post("/employees/edit/", {
            "employee_code": self.employee.employee_code, "display_name": "Invalid cycle",
            "user": self.user.pk, "department": self.department_id, "job_role": self.role_id,
            "date_joined": "2026-01-01", "reporting_manager": self.employee.pk,
        })
        request.user = self.actor
        with CaptureQueriesContext(connection) as queries:
            response = EmployeeUpdateView.as_view()(request, pk=self.employee.pk)
        self.assertEqual(response.status_code, 200)
        locks = [item["sql"] for item in queries if "FOR UPDATE" in item["sql"].upper()]
        self.assertGreaterEqual(len(locks), 2)
        self.assertIn("ORDER BY", locks[0])
        self.assertNotIn("WHERE", locks[0])
        self.assertIn("WHERE", locks[1])
        self.employee.refresh_from_db()
        self.assertIsNone(self.employee.reporting_manager_id)
        self.assertEqual(self.employee.display_name, "Isolated learner")
