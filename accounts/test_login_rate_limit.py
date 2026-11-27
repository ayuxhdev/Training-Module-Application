from collections import OrderedDict
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, Mock, patch

from django.core.cache import cache
from django.contrib.auth import get_user_model
from django.core.exceptions import ImproperlyConfigured, ValidationError
from django.db import OperationalError
from django.http import QueryDict
from django.test import Client, SimpleTestCase
from django.urls import reverse
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import UntypedToken

from api.v1.auth_serializers import EmployeeTokenObtainPairSerializer, LoginAdmissionUnavailable

from . import login_rate_limit as limiter
from .management.commands.prune_login_attempt_buckets import Command


class LoginAdmissionPolicyTests(SimpleTestCase):
    def test_policy_defaults_exact_credit_and_refill(self):
        now = datetime(2026, 11, 24, tzinfo=timezone.utc)
        rate = limiter.Rate.parse("5/5")
        for seconds, expected in ((-1, 0), (0, 0), (11, 55_000_000), (12, limiter.UNIT), (60, 5 * limiter.UNIT)):
            with self.subTest(seconds=seconds):
                self.assertEqual(
                    limiter.available_credit(0, now, now + timedelta(seconds=seconds), rate), expected,
                )

    def test_invalid_rates_fail_configuration(self):
        for value in ("0/60", "30/0", "601/60", "30.0/60", "100/1", "01/60", "30/60\n", 60):
            with self.subTest(value=value), self.assertRaises(ImproperlyConfigured):
                limiter.Rate.parse(value)

    def test_forwarding_ignored_from_untrusted_peer(self):
        proxies = limiter.trusted_proxies("127.0.0.1")
        self.assertEqual(limiter.client_ip({
            "REMOTE_ADDR": "::ffff:192.0.2.2", "HTTP_X_FORWARDED_FOR": "spoof",
        }, proxies), "192.0.2.2")

    def test_trusted_forwarding_uses_rightmost_untrusted_address(self):
        self.assertEqual(limiter.client_ip({
            "REMOTE_ADDR": "127.0.0.1",
            "HTTP_X_FORWARDED_FOR": "192.0.2.99, 2001:0db8:0:0::2, 127.0.0.2",
        }, limiter.trusted_proxies("127.0.0.1,127.0.0.2")), "2001:db8::2")

    def test_malformed_or_unbounded_trusted_chain_is_rejected(self):
        proxies = limiter.trusted_proxies("127.0.0.1")
        for header in (None, "", "192.0.2.1,", "127.0.0.1", "a" * 513, ",".join(["192.0.2.1"] * 9)):
            with self.subTest(header=header), self.assertRaises(ValueError):
                limiter.client_ip({"REMOTE_ADDR": "127.0.0.1", "HTTP_X_FORWARDED_FOR": header}, proxies)
        with self.assertRaises(ImproperlyConfigured):
            limiter.trusted_proxies("127.0.0.0/8")

    def test_username_parsing_matches_django_form_and_bounds_input(self):
        expected = "Alice"
        self.assertEqual(limiter.cleaned_username(QueryDict("username=wrong&username=+%EF%BC%A1lice+")), expected)
        with self.assertRaises(ValidationError):
            limiter.cleaned_username({"username": "x" * 151})
        self.assertIsNone(limiter.cleaned_username({}))

    def test_hmac_domains_and_composite_identity_are_distinct(self):
        values = {
            limiter.bucket_key("source", "same"),
            limiter.bucket_key("account", "same"),
            limiter.bucket_key("source-account", "same", "other"),
            limiter.bucket_key("source-account", "other", "same"),
        }
        self.assertEqual(len(values), 4)
        for key in values:
            self.assertRegex(key, r"^[0-9a-f]{64}$")

    def test_source_exhaustion_short_circuits_account_work(self):
        rates = (limiter.Rate(30, 60), limiter.Rate(5, 5), limiter.Rate(20, 4))
        with patch.object(limiter, "connection", Mock(vendor="mysql", in_atomic_block=False)), \
                patch.object(limiter, "_reserve", return_value=1) as reserve, \
                patch.object(limiter, "account_weight") as weight:
            self.assertEqual(limiter.reserve_login("192.0.2.1", "someone", *rates), 1)
        reserve.assert_called_once_with([(limiter.bucket_key("source", "192.0.2.1"), rates[0])])
        weight.assert_not_called()

    def test_requires_real_commit_boundary(self):
        with patch.object(limiter, "connection", Mock(vendor="mysql", in_atomic_block=True)), \
                patch.object(limiter, "_reserve") as reserve, self.assertRaises(limiter.AdmissionUnavailable):
            limiter.reserve_login("192.0.2.1", "someone", None, None, None)
        reserve.assert_not_called()

    def test_unsupported_collation_fails_before_weight_query(self):
        db = MagicMock()
        cursor = db.cursor.return_value.__enter__.return_value
        cursor.fetchone.return_value = None
        with patch.object(limiter, "connection", db), self.assertRaises(limiter.AdmissionUnavailable):
            limiter.account_weight("someone")
        cursor.execute.assert_called_once()

    def test_pruner_rejects_invalid_batch_before_database_use(self):
        from django.core.management.base import CommandError

        with self.assertRaises(CommandError):
            Command().handle(limit=501)


class LoginAdmissionRoutingTests(SimpleTestCase):
    def setUp(self):
        from django.conf import settings

        mw = "accounts.login_rate_limit.LoginAdmissionMiddleware"
        self.enterContext(self.settings(MIDDLEWARE=[x for x in settings.MIDDLEWARE if x != mw] + [mw]))
        self.enterContext(patch.object(limiter, "_log_admission_event"))
        self.client = Client(enforce_csrf_checks=True)

    def csrf_post(self, url, username="example"):
        self.client.get(url)
        token = self.client.cookies["csrftoken"].value
        return self.client.post(url, {"username": username, "password": "synthetic", "csrfmiddlewaretoken": token})

    def test_csrf_rejection_precedes_admission_for_both_routes(self):
        with patch.object(limiter, "reserve_login") as reserve:
            for route in ("accounts:login", "admin:login"):
                response = self.client.post(reverse(route), {"username": "example", "password": "synthetic"})
                self.assertEqual(response.status_code, 403)
        reserve.assert_not_called()

    def test_both_login_routes_share_admission_before_authentication(self):
        with patch.object(limiter, "reserve_login", return_value=12) as reserve, \
                patch("django.contrib.auth.forms.authenticate") as authenticate:
            for route in ("accounts:login", "admin:login"):
                response = self.csrf_post(reverse(route))
                self.assertEqual(response.status_code, 429)
                self.assertEqual(response["Retry-After"], "12")
                self.assertEqual(response["Cache-Control"], "no-store")
                self.assertNotContains(response, "example", status_code=429)
        authenticate.assert_not_called()
        self.assertEqual(reserve.call_args_list[0], reserve.call_args_list[1])

    def test_store_failure_returns_generic_503_without_authenticating(self):
        with patch.object(limiter, "reserve_login", side_effect=OperationalError("private-sentinel")), \
                patch("django.contrib.auth.forms.authenticate") as authenticate:
            response = self.csrf_post(reverse("accounts:login"))
        authenticate.assert_not_called()
        self.assertNotContains(response, "private-sentinel", status_code=503)
        self.assertEqual(response["Cache-Control"], "no-store")

    def test_admitted_failure_keeps_existing_generic_form(self):
        with patch.object(limiter, "reserve_login", return_value=0), \
                patch("django.contrib.auth.forms.authenticate", return_value=None) as authenticate:
            response = self.csrf_post(reverse("accounts:login"))
        authenticate.assert_called_once()
        self.assertContains(response, "correct username and password")

    def test_invalid_nonempty_name_cannot_use_a_source_only_reservation_to_authenticate(self):
        with patch.object(limiter, "reserve_login", return_value=0) as reserve, \
                patch("django.contrib.auth.forms.authenticate") as authenticate:
            response = self.csrf_post(reverse("accounts:login"), username="x" * 151)
        self.assertIsNone(reserve.call_args.args[1])
        authenticate.assert_not_called()
        self.assertContains(response, "correct username and password", status_code=400)


class LoginCollationCacheTests(SimpleTestCase):
    def setUp(self):
        self.enterContext(patch.object(limiter, "_collations", OrderedDict()))
        self.clock = self.enterContext(patch.object(limiter, "monotonic", return_value=0))
        self.db = MagicMock(alias="default", settings_dict={"NAME": "test_login", "HOST": "127.0.0.1"})
        self.enterContext(patch.object(limiter, "connection", self.db))
        self.cursor = self.db.cursor.return_value.__enter__.return_value
        self.origin = ("test-server", "test_login")
        self.metadata = (*self.origin, "utf8mb4_0900_ai_ci")
        self.weight = (*self.origin, "6162")

    def metadata_reads(self):
        return sum("information_schema.COLUMNS" in call.args[0] for call in self.cursor.execute.call_args_list)

    def test_hit_reuses_metadata_but_binds_and_weighs_each_username(self):
        self.cursor.fetchone.side_effect = [self.metadata, self.weight, (*self.origin, "6364")]
        self.assertEqual(limiter.account_weight("one"), "6162")
        self.assertEqual(limiter.account_weight("two"), "6364")
        self.assertEqual(self.metadata_reads(), 1)
        self.assertEqual(self.cursor.execute.call_args_list[1].args[1], ["one"])
        self.assertEqual(self.cursor.execute.call_args_list[2].args[1], ["two"])

    def test_expired_metadata_is_never_used_when_refresh_fails(self):
        self.cursor.fetchone.side_effect = [self.metadata, self.weight, None]
        self.assertEqual(limiter.account_weight("one"), "6162")
        self.clock.return_value = limiter.COLLATION_TTL_SECONDS
        with self.assertRaises(limiter.AdmissionUnavailable):
            limiter.account_weight("one")
        self.assertEqual(self.metadata_reads(), 2)
        self.assertFalse(limiter._collations)

    def test_changed_origin_discards_encoded_weight_and_reads_real_collation(self):
        origin = ("other-server", "test_login")
        self.cursor.fetchone.side_effect = [
            self.metadata, self.weight, (*origin, "wrong-weight"),
            (*origin, "utf8mb4_0900_as_cs"), (*origin, "6566"),
        ]
        self.assertEqual(limiter.account_weight("one"), "6162")
        self.assertEqual(limiter.account_weight("one"), "6566")
        self.assertIn("COLLATE utf8mb4_0900_as_cs", self.cursor.execute.call_args.args[0])
        self.assertEqual(self.metadata_reads(), 2)

    def test_alias_and_config_changes_miss_cache_and_size_is_bounded(self):
        self.enterContext(patch.object(limiter, "COLLATION_CACHE_LIMIT", 2))
        self.cursor.fetchone.side_effect = [self.metadata, self.weight] * 4
        limiter.account_weight("one")
        self.db.alias = "another"
        limiter.account_weight("one")
        self.db.settings_dict["HOST"] = "different.test"
        limiter.account_weight("one")
        self.db.alias = "default"
        self.db.settings_dict["HOST"] = "127.0.0.1"
        limiter.account_weight("one")
        self.assertEqual(self.metadata_reads(), 4)
        self.assertEqual(len(limiter._collations), 2)

    def test_failed_weight_query_invalidates_cached_metadata(self):
        self.cursor.fetchone.side_effect = [self.metadata, self.weight, self.metadata, self.weight]
        limiter.account_weight("one")
        self.cursor.execute.side_effect = OperationalError("test outage")
        with self.assertRaises(OperationalError):
            limiter.account_weight("one")
        self.cursor.execute.side_effect = None
        limiter.account_weight("one")
        self.assertEqual(self.metadata_reads(), 2)


class APILoginAdmissionTests(SimpleTestCase):
    def setUp(self):
        self.enterContext(self.settings(CACHES={
            "default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache", "LOCATION": "test-login-batch4"},
        }))
        self.addCleanup(cache.clear)
        self.source = self.enterContext(patch.object(limiter, "reserve_login_source", return_value=0))
        self.account = self.enterContext(patch.object(limiter, "reserve_login_account", return_value=0))
        self.authenticate = self.enterContext(patch("rest_framework_simplejwt.serializers.authenticate", return_value=None))
        self.enterContext(patch.object(limiter, "_log_admission_event"))
        self.api = APIClient(enforce_csrf_checks=True)
        self.url = reverse("api:v1:auth-login")

    def post(self, name="sample", **extra):
        return self.api.post(self.url, {"username": name, "password": "synthetic"}, format="json", **extra)

    def test_source_and_matching_normalized_account_are_admitted_before_credentials(self):
        order = Mock()
        order.attach_mock(self.source, "source")
        order.attach_mock(self.account, "account")
        order.attach_mock(self.authenticate, "authenticate")
        result = self.post("  Ｓample  ", REMOTE_ADDR="::ffff:192.0.2.8", HTTP_X_FORWARDED_FOR="192.0.2.99")
        self.assertEqual(result.status_code, 401)
        self.assertEqual(result.data["error"]["code"], "no_active_account")
        self.assertEqual([call[0] for call in order.mock_calls], ["source", "account", "authenticate"])
        self.assertEqual(self.source.call_args.args[0], "192.0.2.8")
        self.assertEqual(self.account.call_args.args[:2], ("192.0.2.8", "Sample"))
        self.assertEqual(self.authenticate.call_args.kwargs["username"], "Sample")

    def test_success_uses_existing_jwt_shape_and_needs_no_browser_csrf_token(self):
        self.authenticate.return_value = get_user_model()(pk=41, username="sample")
        with patch("api.v1.auth_serializers.can_use_mobile", return_value=True), patch(
            "rest_framework_simplejwt.token_blacklist.models.OutstandingToken.objects.create"
        ):
            response = self.post()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(set(response.data), {"refresh", "access"})
        self.assertEqual(UntypedToken(response.data["refresh"])["token_type"], "refresh")
        self.assertEqual(UntypedToken(response.data["access"])["token_type"], "access")
        self.assertEqual(response["Cache-Control"], "no-store")

    def test_source_and_account_denials_share_envelope_and_retry_after(self):
        for reserve, wait in ((self.source, 1), (self.account, 15)):
            reserve.return_value = wait
            response = self.post()
            self.assertEqual(response.status_code, 429)
            self.assertEqual(response["Retry-After"], str(wait))
            self.assertEqual(response["Cache-Control"], "no-store")
            self.assertEqual(response.data["error"]["code"], "throttled")
            self.assertNotContains(response, "sample", status_code=429)
            reserve.return_value = 0
        self.authenticate.assert_not_called()

    def test_storage_outage_on_either_stage_is_generic_and_fail_closed(self):
        for reserve in (self.source, self.account):
            reserve.side_effect = OperationalError("private-sentinel")
            response = self.post()
            self.assertEqual(response.status_code, 503)
            self.assertEqual(response.data["error"]["code"], "service_unavailable")
            self.assertEqual(response["Cache-Control"], "no-store")
            self.assertNotContains(response, "private-sentinel", status_code=503)
            reserve.side_effect = None
        self.authenticate.assert_not_called()

    def test_invalid_empty_and_whitespace_identifiers_charge_source_only(self):
        for name in ("", "  ", ["sample"], "x" * 151, "test\x00"):
            with self.subTest(name=name):
                self.assertEqual(self.post(name).status_code, 400)
        self.assertEqual(self.source.call_count, 5)
        self.account.assert_not_called()
        self.authenticate.assert_not_called()

    def test_oversized_and_malformed_payloads_are_charged_without_authentication(self):
        self.assertEqual(self.api.post(self.url, {"username": "sample", "password": "x" * 17000},
                                       format="json").status_code, 413)
        self.assertEqual(self.api.post(self.url, b'{"username":', content_type="application/json").status_code, 400)
        self.assertEqual(self.source.call_count, 2)
        self.account.assert_not_called()
        self.authenticate.assert_not_called()

    def test_trusted_proxy_and_local_burst_use_the_same_validated_ip(self):
        with self.settings(LOGIN_LIMIT_TRUSTED_PROXIES="127.0.0.1"):
            for n in range(5):
                self.assertEqual(self.post(HTTP_X_FORWARDED_FOR=f"192.0.2.{n + 1}, 2001:db8::9").status_code, 401)
            response = self.post(HTTP_X_FORWARDED_FOR="192.0.2.99, 2001:0db8::9")
            self.assertEqual(response.status_code, 429)
            self.assertGreaterEqual(int(response["Retry-After"]), 1)
            self.assertEqual(response["Cache-Control"], "no-store")
            self.assertEqual(self.post(HTTP_X_FORWARDED_FOR="192.0.2.99, bad").status_code, 503)
        self.assertEqual(self.source.call_count, 5)
        self.assertTrue(all(call.args[0] == "2001:db8::9" for call in self.source.call_args_list))

    def test_serializer_direct_use_without_admission_fails_closed(self):
        serializer = EmployeeTokenObtainPairSerializer(data={"username": "sample", "password": "synthetic"})
        with self.assertRaises(LoginAdmissionUnavailable):
            serializer.is_valid(raise_exception=True)
        self.authenticate.assert_not_called()
