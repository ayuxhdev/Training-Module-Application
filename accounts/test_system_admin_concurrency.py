"""Real MySQL linking races, with exact committed-fixture cleanup and no flush."""

from concurrent.futures import ThreadPoolExecutor
from threading import Event, local
from unittest import skipUnless
from unittest.mock import patch
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.exceptions import ValidationError
from django.db import close_old_connections, connection, models
from django.test import SimpleTestCase

from audit.models import AuditLog
from organization.models import Department, Employee, JobRole

from . import system_admin_services as services


@skipUnless(connection.vendor == "mysql", "MySQL row-lock concurrency tests require MySQL.")
class SystemAccountLinkConcurrencyTests(SimpleTestCase):
    databases = {"default"}

    def setUp(self):
        self.assertEqual(connection.vendor, "mysql")
        self.assertEqual(connection.settings_dict["NAME"], "test_gardens_training")
        self.assertTrue(connection.get_autocommit())
        self.marker = "st2-" + uuid4().hex[:16]
        self.user_ids = []
        self.employee_ids = []
        self.department_id = self.role_id = None
        self.groups_before = list(Group.objects.order_by("pk").values())
        self.grants_before = list(Group.permissions.through.objects.order_by("pk").values())
        self.addCleanup(self.cleanup_fixtures)
        self.first_actor = self.user("root-a", is_superuser=True)
        self.second_actor = self.user("root-b", is_superuser=True)
        self.target = self.user("target", is_active=False)
        self.other_target = self.user("other-target", is_active=False)
        department = Department.objects.create(code=self.marker, name="Isolated Stage 2")
        self.department_id = department.pk
        role = JobRole.objects.create(code=self.marker, name="Isolated Stage 2")
        self.role_id = role.pk
        self.first_employee = self.employee("a", department, role)
        self.second_employee = self.employee("b", department, role)

    def user(self, suffix, **kwargs):
        user = get_user_model().objects.create_user(username=f"{self.marker}-{suffix}", **kwargs)
        self.user_ids.append(user.pk)
        return user

    def employee(self, suffix, department, role):
        employee = Employee.objects.create(
            employee_code=f"{self.marker}-{suffix}", display_name="Isolated linking Employee",
            department=department, job_role=role, date_joined="2026-01-01",
        )
        self.employee_ids.append(employee.pk)
        return employee

    def cleanup_fixtures(self):
        # Delete only this test's exact newly committed records. Never flush,
        # reset sequences, touch role bootstrap or remove existing QA records.
        self.assertEqual(connection.settings_dict["NAME"], "test_gardens_training")
        created = get_user_model().objects.filter(username=self.marker + "-created").values_list("pk", flat=True)
        self.user_ids.extend(created)
        for model, filters in (
            (AuditLog, {"actor_id__in": self.user_ids}),
            (Employee, {"pk__in": self.employee_ids}),
            (get_user_model(), {"pk__in": self.user_ids}),
            (Department, {"pk": self.department_id}),
            (JobRole, {"pk": self.role_id}),
        ):
            models.QuerySet(model, using="default").filter(**filters)._raw_delete("default")
        self.assertEqual(list(Group.objects.order_by("pk").values()), self.groups_before)
        self.assertEqual(list(Group.permissions.through.objects.order_by("pk").values()), self.grants_before)
        connection.close()

    def race(self, first_operation, second_operation, second_lock_table):
        first_linked, second_boundary, second_finished, release = (Event() for _ in range(4))
        thread = local()
        original = services._link_employee

        def hold_first_link(*args, **kwargs):
            result = original(*args, **kwargs)
            if thread.role == "first":
                first_linked.set()
                if not release.wait(15):
                    raise AssertionError("The first linking transaction was not released")
            return result

        def observe(execute, sql, params, many, context):
            if "FOR UPDATE" in sql.upper() and second_lock_table in sql.lower():
                second_boundary.set()
            return execute(sql, params, many, context)

        def run(role, operation):
            thread.role = role
            close_old_connections()
            try:
                self.assertEqual(connection.settings_dict["NAME"], "test_gardens_training")
                with connection.cursor() as cursor:
                    cursor.execute("SET SESSION innodb_lock_wait_timeout=10")
                try:
                    if role == "second":
                        with connection.execute_wrapper(observe):
                            operation()
                    else:
                        operation()
                    return "linked"
                except ValidationError:
                    return "rejected"
            finally:
                if role == "second":
                    second_finished.set()
                connection.close()

        with patch.object(services, "_link_employee", hold_first_link), ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(run, "first", first_operation)
            try:
                self.assertTrue(first_linked.wait(15), "First link never reached its uncommitted boundary")
                second = pool.submit(run, "second", second_operation)
                self.assertTrue(second_boundary.wait(15), "Second request never attempted the expected row lock")
                # Observe while the first transaction still holds its locks.
                finished_while_locked = second_finished.wait(1)
            finally:
                release.set()
            results = first.result(20), second.result(20)
        self.assertFalse(finished_while_locked, "Competing linking request was not serialized by a real row lock")
        self.assertEqual(results, ("linked", "rejected"))
        return results

    def test_same_employee_cannot_link_to_two_accounts_concurrently(self):
        self.race(
            lambda: services.link_system_user_employee(self.first_actor, self.target.pk, self.first_employee.pk),
            lambda: services.link_system_user_employee(self.second_actor, self.other_target.pk, self.first_employee.pk),
            "organization_employee",
        )
        self.first_employee.refresh_from_db()
        self.assertEqual(self.first_employee.user_id, self.target.pk)
        self.assertFalse(Employee.objects.filter(user_id=self.other_target.pk).exists())
        self.assertEqual(AuditLog.objects.filter(action="accounts.user.employee_linked").count(), 1)

    def test_same_account_cannot_link_to_two_employees_concurrently(self):
        self.race(
            lambda: services.link_system_user_employee(self.first_actor, self.target.pk, self.first_employee.pk),
            lambda: services.link_system_user_employee(self.second_actor, self.target.pk, self.second_employee.pk),
            "auth_user",
        )
        self.first_employee.refresh_from_db()
        self.second_employee.refresh_from_db()
        self.assertEqual(self.first_employee.user_id, self.target.pk)
        self.assertIsNone(self.second_employee.user_id)
        self.assertEqual(Employee.objects.filter(user_id=self.target.pk).count(), 1)
        self.assertEqual(AuditLog.objects.filter(action="accounts.user.employee_linked").count(), 1)

    def test_creation_losing_a_concurrent_employee_link_rolls_back_the_new_account(self):
        data = {
            "username": self.marker + "-created", "first_name": "", "last_name": "",
            "email": "", "groups": [], "employee": self.first_employee,
        }
        self.race(
            lambda: services.link_system_user_employee(self.first_actor, self.target.pk, self.first_employee.pk),
            lambda: services.create_system_user(self.second_actor, data),
            "organization_employee",
        )
        self.assertFalse(get_user_model().objects.filter(username=data["username"]).exists())
        self.assertFalse(AuditLog.objects.filter(action="accounts.user.created").exists())
        self.assertEqual(AuditLog.objects.filter(action="accounts.user.employee_linked").count(), 1)
