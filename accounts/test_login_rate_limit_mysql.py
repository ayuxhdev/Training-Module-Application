"""Run only in a fresh schema owned by the guarded integration runner."""

from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from io import StringIO
from threading import Barrier, Event
from unittest import skipUnless
from unittest.mock import patch

from django.conf import settings
from django.contrib.auth import SESSION_KEY, get_user_model
from django.core.cache import cache
from django.core.management import call_command
from django.db import connection, connections
from django.test import Client, TransactionTestCase
from django.urls import reverse
from django.utils import timezone
from organization.models import Department, Employee, JobRole
from rest_framework.test import APIClient

from config.role_requirement_test_config import ENGINE, IntegrationConfig, validate_settings
from config.role_requirement_test_runner import require_authorized_connection

from . import login_rate_limit as limiter
from .models import LoginAttemptBucket


@skipUnless(
    settings.DATABASES.get("default", {}).get("ENGINE") == ENGINE
    and hasattr(settings, "INTEGRATION_TEST_CONFIG"),
    "Requires the explicitly approved integration test profile.",
)
class LoginAdmissionMySQLTests(TransactionTestCase):
    @classmethod
    def _pre_setup(cls):
        if type(validate_settings(settings)) is not IntegrationConfig:
            raise RuntimeError("These tests require the guarded integration profile.")
        require_authorized_connection(connection)
        super()._pre_setup()

    def setUp(self):
        self.now = timezone.now()
        mw = "accounts.login_rate_limit.LoginAdmissionMiddleware"
        self.enterContext(self.settings(CACHES={
            "default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache", "LOCATION": "mysql-login-suite"},
        }))
        self.addCleanup(cache.clear)
        self.enterContext(self.settings(
            MIDDLEWARE=[x for x in settings.MIDDLEWARE if x != mw] + [mw],
            LOGIN_LIMIT_SOURCE="30/60", LOGIN_LIMIT_SOURCE_ACCOUNT="5/5", LOGIN_LIMIT_ACCOUNT="20/4",
            LOGIN_LIMIT_TRUSTED_PROXIES="",
        ))
        self.enterContext(patch.object(limiter.timezone, "now", side_effect=lambda: self.now))
        self.rates = tuple(limiter.Rate.parse(x) for x in ("30/60", "5/5", "20/4"))

    def reserve(self, source, name):
        return limiter.reserve_login(source, name, *self.rates)

    def post(self, route, username, password, client=None, *, source="192.0.2.3", **extra):
        client = client or Client(enforce_csrf_checks=True)
        url = reverse(route)
        client.get(url)
        token = client.cookies["csrftoken"].value
        return client.post(url, {
            "username": username, "password": password, "csrfmiddlewaretoken": token, **extra,
        }, REMOTE_ADDR=source)

    def post_api(self, username, password, *, source="192.0.2.3"):
        return APIClient(enforce_csrf_checks=True).post(
            reverse("api:v1:auth-login"), {"username": username, "password": password},
            format="json", REMOTE_ADDR=source,
        )

    def test_additive_migration_has_unique_key_expiry_index_and_transactional_engine(self):
        table = LoginAttemptBucket._meta.db_table
        with connection.cursor() as cursor:
            indexes = connection.introspection.get_constraints(cursor, table)
            cursor.execute(
                "SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=%s", [table],
            )
            self.assertEqual(cursor.fetchone(), ("InnoDB",))
        self.assertTrue(any(i["primary_key"] and i["columns"] == ["key"] for i in indexes.values()))
        self.assertTrue(any(i["index"] and i["columns"] == ["expires_at"] for i in indexes.values()))

    def test_same_account_case_and_accent_aliases_share_mysql_comparison_budget(self):
        user = get_user_model().objects.create_user(username="Élodie")
        for alias in ("elodie", "ÉLODIE", "ELODIE"):
            self.assertEqual(get_user_model().objects.get(username=alias).pk, user.pk)
            self.assertEqual(limiter.account_weight(alias), limiter.account_weight(user.username))
        for i in range(5):
            self.assertEqual(self.reserve("192.0.2.2", ("elodie", "ÉLODIE")[i % 2]), 0)
        self.assertEqual(self.reserve("192.0.2.2", "ELODIE"), 12)

    def test_expiry_recovery_and_denials_do_not_extend_account_or_pair(self):
        for _ in range(5):
            self.assertEqual(self.reserve("192.0.2.2", "example"), 0)
        weight = limiter.account_weight("example")
        ids = [limiter.bucket_key("account", weight), limiter.bucket_key("source-account", "192.0.2.2", weight)]
        rows = LoginAttemptBucket.objects.filter(pk__in=ids).order_by("pk")
        before = list(rows.values())
        self.now += timedelta(seconds=11)
        self.assertEqual(self.reserve("192.0.2.2", "example"), 1)
        self.assertEqual(list(rows.values()), before)
        self.now += timedelta(seconds=1)
        self.assertEqual(self.reserve("192.0.2.2", "example"), 0)

    def test_shared_nat_caps_many_names_without_growing_new_account_rows_after_denial(self):
        for i in range(30):
            self.assertEqual(self.reserve("192.0.2.2", f"unknown-{i}"), 0)
        count = LoginAttemptBucket.objects.count()
        self.assertEqual(count, 61)
        self.assertEqual(self.reserve("192.0.2.2", "another"), 1)
        self.assertEqual(LoginAttemptBucket.objects.count(), count)

    def test_distributed_sources_share_account_budget(self):
        for i in range(1, 21):
            self.assertEqual(self.reserve(f"192.0.2.{i}", "target"), 0)
        self.assertEqual(self.reserve("192.0.2.21", "target"), 15)
        self.assertEqual(self.reserve("192.0.2.21", "someone-else"), 0)

    def test_simultaneous_first_use_with_separate_worker_connections_respects_exact_limit(self):
        gate = Barrier(8)

        def worker(_):
            try:
                gate.wait(timeout=15)
                return self.reserve("192.0.2.2", "target")
            finally:
                connections.close_all()

        with ThreadPoolExecutor(max_workers=8) as pool:
            outcomes = list(pool.map(worker, range(8), timeout=45))
        self.assertEqual(sorted(outcomes), [0] * 5 + [12] * 3)
        self.assertEqual(LoginAttemptBucket.objects.count(), 3)

    def test_admin_and_website_share_budget_and_unknown_credentials_stay_generic(self):
        get_user_model().objects.create_user(username="employee", password="sample-passphrase")
        existing = self.post("accounts:login", "employee", "incorrect")
        unknown = self.post("accounts:login", "missing", "incorrect")
        self.assertEqual(existing.status_code, 200)
        self.assertEqual(unknown.status_code, 200)
        self.assertEqual(existing.context["form"].errors.as_data().keys(), unknown.context["form"].errors.as_data().keys())
        self.assertEqual(list(existing.context["form"].non_field_errors()), list(unknown.context["form"].non_field_errors()))
        # Admin's ordinary staff gate stays in place even with correct credentials.
        admin = self.post("admin:login", "employee", "sample-passphrase")
        self.assertEqual(admin.status_code, 200)
        self.assertFalse(admin.wsgi_request.user.is_authenticated)
        for _ in range(3):
            self.assertEqual(self.post("admin:login", "employee", "incorrect").status_code, 200)
        denied = self.post("accounts:login", "employee", "sample-passphrase")
        self.assertEqual(denied.status_code, 429)
        self.assertEqual(denied["Retry-After"], "12")

    def test_success_after_failure_rotates_session_and_does_not_clear_source_budget(self):
        user = get_user_model().objects.create_user(username="employee", password="sample-passphrase")
        client = Client(enforce_csrf_checks=True)
        old_session = client.session
        self.assertEqual(self.post("accounts:login", user.username, "incorrect", client).status_code, 200)
        old_csrf = client.cookies["csrftoken"].value
        result = self.post("accounts:login", user.username, "sample-passphrase", client, next="/assignments/")
        self.assertEqual((result.status_code, result.url), (302, "/assignments/"))
        self.assertNotEqual(client.session.session_key, old_session.session_key)
        self.assertNotEqual(client.cookies["csrftoken"].value, old_csrf)
        self.assertEqual(client.session[SESSION_KEY], str(user.pk))
        bucket = LoginAttemptBucket.objects.get(pk=limiter.bucket_key("source", "192.0.2.3"))
        self.assertEqual(bucket.credit, 28 * limiter.UNIT)
        self.assertEqual(client.get(reverse("accounts:logout")).status_code, 405)
        self.assertEqual(client.post(reverse("accounts:logout"), {
            "csrfmiddlewaretoken": client.cookies["csrftoken"].value,
        }).status_code, 302)
        self.assertNotIn(SESSION_KEY, client.session)

    def test_prune_one_bounded_batch_keeps_live_bucket_and_hmac_keys(self):
        for i in range(2):
            self.assertEqual(self.reserve("192.0.2.2", f"test-{i}"), 0)
        self.now += timedelta(hours=1)
        self.assertEqual(self.reserve("192.0.2.3", "new"), 0)
        call_command("prune_login_attempt_buckets", limit=2)
        self.assertEqual(LoginAttemptBucket.objects.filter(expires_at__lte=self.now).count(), 3)
        self.assertEqual(LoginAttemptBucket.objects.filter(expires_at__gt=self.now).count(), 3)
        for key in LoginAttemptBucket.objects.values_list("pk", flat=True):
            self.assertRegex(key, r"^[0-9a-f]{64}$")

    def test_all_three_login_routes_share_pair_credit_and_collation(self):
        self.assertEqual(self.post("accounts:login", " \uff25lodie ", "wrong").status_code, 200)
        self.assertEqual(self.post_api(" \u00c9lodie ", "wrong").status_code, 401)
        self.assertEqual(self.post("admin:login", "ELODIE", "wrong").status_code, 200)
        self.assertEqual(self.post_api("elodie", "wrong").status_code, 401)
        self.assertEqual(self.post("accounts:login", "elodie", "wrong").status_code, 200)
        blocked = self.post_api("elodie", "wrong")
        self.assertEqual((blocked.status_code, blocked["Retry-After"]), (429, "12"))
        self.assertEqual(blocked["Cache-Control"], "no-store")
        self.assertEqual(LoginAttemptBucket.objects.count(), 3)

    def test_distributed_requests_on_all_surfaces_share_account_capacity(self):
        for index in range(1, 21):
            source = f"192.0.2.{index}"
            if index % 3 == 0:
                self.assertEqual(self.post_api("target", "wrong", source=source).status_code, 401)
            else:
                route = "admin:login" if index % 3 == 1 else "accounts:login"
                self.assertEqual(self.post(route, "target", "wrong", source=source).status_code, 200)
        blocked = self.post_api("TARGET", "wrong", source="192.0.2.21")
        self.assertEqual((blocked.status_code, blocked["Retry-After"]), (429, "15"))
        self.assertEqual(self.post_api("different", "wrong", source="192.0.2.21").status_code, 401)

    def test_shared_office_source_budget_covers_different_usernames(self):
        with self.settings(LOGIN_LIMIT_SOURCE="3/3"):
            self.assertEqual(self.post("accounts:login", "one", "wrong").status_code, 200)
            self.assertEqual(self.post_api("two", "wrong").status_code, 401)
            self.assertEqual(self.post("admin:login", "three", "wrong").status_code, 200)
            blocked = self.post_api("four", "wrong")
            self.assertEqual((blocked.status_code, blocked["Retry-After"]), (429, "20"))
            self.assertEqual(self.post_api("four", "wrong", source="192.0.2.5").status_code, 401)

    def test_concurrent_browser_and_api_requests_use_shared_rows_on_separate_connections(self):
        gate = Barrier(8)

        def worker(index):
            try:
                require_authorized_connection(connection)
                gate.wait(timeout=15)
                if index % 3 == 0:
                    return self.post_api("shared", "wrong").status_code
                route = "accounts:login" if index % 3 == 1 else "admin:login"
                return self.post(route, "shared", "wrong").status_code
            finally:
                connection.close()

        with ThreadPoolExecutor(max_workers=8) as pool:
            outcomes = list(pool.map(worker, range(8), timeout=45))
        self.assertEqual(sum(status in (200, 401) for status in outcomes), 5)
        self.assertEqual(outcomes.count(429), 3)
        self.assertEqual(LoginAttemptBucket.objects.count(), 3)

    def test_api_jwt_login_refresh_logout_and_inactive_employee(self):
        user = get_user_model().objects.create_user(username="demo-learner", password="synthetic-example")
        department = Department.objects.create(name="Login test", code="LOGIN")
        role = JobRole.objects.create(name="Login test", code="LOGIN")
        employee = Employee.objects.create(
            employee_code="LOGIN", display_name="Login test", user=user,
            department=department, job_role=role, date_joined="2026-01-01",
        )
        first = self.post_api(user.username, "bad-password")
        unknown = self.post_api("no-such-user", "bad-password")
        self.assertEqual((first.status_code, first.data), (unknown.status_code, unknown.data))
        self.assertEqual(first.status_code, 401)
        login = self.post_api(user.username, "synthetic-example")
        self.assertEqual(login.status_code, 200)
        self.assertEqual(set(login.data), {"access", "refresh"})
        api = APIClient()
        refreshed = api.post(reverse("api:v1:auth-refresh"), {"refresh": login.data["refresh"]})
        self.assertEqual(refreshed.status_code, 200)
        api.credentials(HTTP_AUTHORIZATION="Bearer " + refreshed.data["access"])
        self.assertEqual(api.post(reverse("api:v1:auth-logout"), {"refresh": refreshed.data["refresh"]}).status_code, 204)
        self.assertEqual(APIClient().post(
            reverse("api:v1:auth-refresh"), {"refresh": refreshed.data["refresh"]},
        ).status_code, 401)
        employee.is_active = False
        employee.deactivation_reason = "Test deactivation"
        employee.save()
        self.assertEqual(self.post_api(user.username, "synthetic-example").status_code, 401)

    def test_prune_rechecks_expiry_after_concurrent_reservation(self):
        source = "192.0.2.2"
        self.assertEqual(self.reserve(source, None), 0)
        key = limiter.bucket_key("source", source)
        self.now += timedelta(hours=1)
        selected, release = Event(), Event()

        def pause_selection(execute, sql, params, many, context):
            result = execute(sql, params, many, context)
            if LoginAttemptBucket._meta.db_table in sql and "ORDER BY" in sql and "LIMIT" in sql:
                selected.set()
                if not release.wait(15):
                    raise AssertionError("Pruner selection was not released.")
            return result

        def prune():
            try:
                require_authorized_connection(connection)
                with connection.execute_wrapper(pause_selection):
                    call_command("prune_login_attempt_buckets", limit=1, stdout=StringIO())
            finally:
                connection.close()

        with ThreadPoolExecutor(max_workers=1) as pool:
            pending = pool.submit(prune)
            try:
                self.assertTrue(selected.wait(15), "Pruner did not select the expired bucket.")
                self.assertEqual(self.reserve(source, None), 0)
            finally:
                release.set()
            pending.result(timeout=15)
        row = LoginAttemptBucket.objects.get(pk=key)
        self.assertEqual(row.credit, 29 * limiter.UNIT)
        self.assertGreater(row.expires_at, self.now)
