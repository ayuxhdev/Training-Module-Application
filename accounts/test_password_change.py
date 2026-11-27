"""Database-free password policy/contract tests and disposable-MySQL regressions.

Run DatabaseTests only in explicitly approved disposable infrastructure.
"""

from contextlib import nullcontext
from types import SimpleNamespace
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.hashers import make_password
from django.contrib.auth.models import AnonymousUser
from django.core.cache import cache
from django.core.exceptions import PermissionDenied, ValidationError
from django.http import HttpResponse
from django.middleware.csrf import CsrfViewMiddleware
from django.template.loader import render_to_string
from django.test import Client, RequestFactory, SimpleTestCase, TestCase, override_settings
from django.urls import reverse
from rest_framework.exceptions import AuthenticationFailed, ValidationError as DRFValidationError
from rest_framework.test import APIClient
from rest_framework_simplejwt.authentication import JWTAuthentication
from rest_framework_simplejwt.serializers import TokenRefreshSerializer
from rest_framework_simplejwt.settings import api_settings
from rest_framework_simplejwt.token_blacklist.models import BlacklistedToken
from rest_framework_simplejwt.tokens import AccessToken, RefreshToken
from rest_framework_simplejwt.utils import get_md5_hash_password

from api.v1 import auth_serializers
from api.v1.password_serializers import PasswordChangeSerializer
from organization.models import Department, Employee, JobRole

from . import password_services, password_views
from .password_forms import OwnPasswordChangeForm

OLD = "Prior-test-passphrase!42"
NEW = "Different-test-passphrase!93"


def password_data(**changes):
    return {"old_password": OLD, "new_password1": NEW, "new_password2": NEW, **changes}


def test_user(pk=41):
    user = get_user_model()(pk=pk, username=f"password-test-{pk}", is_active=True)
    user.password = make_password(OLD)
    user._state.fields_cache["employee"] = None
    return user


@override_settings(PASSWORD_HASHERS=["django.contrib.auth.hashers.MD5PasswordHasher"])
class PasswordChangeContractTests(SimpleTestCase):
    databases = set()

    def setUp(self):
        self.user = test_user()

    def test_valid_form_uses_existing_django_password_policy(self):
        self.assertTrue(OwnPasswordChangeForm(self.user, data=password_data()).is_valid())

    def test_wrong_current_weak_confirmation_and_unchanged_password_are_rejected(self):
        for changes, field in (
            ({"old_password": "incorrect"}, "old_password"),
            ({"new_password1": "123", "new_password2": "123"}, "new_password2"),
            ({"new_password2": "mismatch"}, "new_password2"),
            ({"new_password1": OLD, "new_password2": OLD}, "new_password1"),
        ):
            with self.subTest(field=field, changes=list(changes)):
                form = OwnPasswordChangeForm(self.user, data=password_data(**changes))
                self.assertFalse(form.is_valid())
                self.assertIn(field, form.errors)

    def test_password_whitespace_is_not_trimmed(self):
        password = "  Different passphrase!92  "
        form = OwnPasswordChangeForm(self.user, data=password_data(new_password1=password, new_password2=password))
        self.assertTrue(form.is_valid(), form.errors)
        self.assertEqual(form.cleaned_data["new_password1"], password)

    def test_validation_never_saves_or_rehashes_unlocked_user(self):
        with patch.object(self.user, "save") as save:
            self.assertTrue(OwnPasswordChangeForm(self.user, data=password_data()).is_valid())
        save.assert_not_called()

    def test_password_fields_are_bounded_and_never_echo_bound_values(self):
        form = OwnPasswordChangeForm(self.user, data=password_data())
        html = render_to_string("accounts/password_change.html", {"form": form, "csrf_token": "render-only-token"})
        self.assertNotIn(OLD, html)
        self.assertNotIn(NEW, html)
        self.assertEqual(html.count('type="password"'), 3)
        self.assertIn('name="csrfmiddlewaretoken"', html)
        self.assertFalse(OwnPasswordChangeForm(self.user, data=password_data(old_password="x" * 4097)).is_valid())

    def test_serializer_is_write_only_strict_and_preserves_whitespace(self):
        data = {"current_password": OLD, "new_password": "  new test pass!93  ", "confirm_password": "  new test pass!93  "}
        serializer = PasswordChangeSerializer(data=data)
        self.assertTrue(serializer.is_valid(), serializer.errors)
        self.assertEqual(serializer.validated_data, data)
        self.assertEqual(serializer.data, {})
        for invalid in (["not-an-object"], {**data, "user_id": 999}, {**data, "is_active": True}):
            with self.assertRaises(DRFValidationError) as rejected:
                PasswordChangeSerializer(data=invalid).is_valid(raise_exception=True)
            self.assertEqual(set(rejected.exception.detail), {"non_field_errors"})
            self.assertNotIn(OLD, str(rejected.exception.detail))

    def test_disabled_accounts_fail_eligibility_before_password_validation(self):
        self.user.is_active = False
        with patch.object(password_services.Employee.objects, "filter") as employees:
            self.assertFalse(password_services.eligible_password_account(self.user))
            employees.assert_not_called()
        self.assertFalse(password_services.eligible_password_account(AnonymousUser()))

    def test_web_mutation_requires_csrf_and_anonymous_user_redirects(self):
        request = RequestFactory().post(reverse("accounts:password-change"), password_data())
        request.user = AnonymousUser()
        view = password_views.OwnPasswordChangeView.as_view()
        self.assertEqual(view(request).status_code, 302)
        response = CsrfViewMiddleware(lambda request: HttpResponse()).process_view(request, view, (), {})
        self.assertEqual(response.status_code, 403)
        self.assertFalse(getattr(view, "csrf_exempt", False))

    def test_locked_service_revalidates_and_revokes_tokens_without_sensitive_audit_data(self):
        locked = test_user()
        locked.password = self.user.password
        token = SimpleNamespace(pk=17)
        with patch.object(password_services.transaction, "atomic", return_value=nullcontext()), \
                patch.object(get_user_model().objects, "select_for_update") as users, \
                patch.object(password_services, "eligible_password_account", return_value=True), \
                patch.object(password_services.OutstandingToken.objects, "select_for_update") as outstanding, \
                patch.object(password_services.BlacklistedToken.objects, "get_or_create") as blacklist, \
                patch.object(get_user_model(), "save"), \
                patch.object(password_services, "record_event") as audit:
            users.return_value.get.return_value = locked
            outstanding.return_value.filter.return_value.order_by.return_value = [token]
            result = password_services.change_own_password(self.user, password_data())
        users.return_value.get.assert_called_once_with(pk=self.user.pk)
        blacklist.assert_called_once_with(token=token)
        self.assertTrue(result.check_password(NEW))
        self.assertEqual(audit.call_args.args[1], "auth.password.changed")
        self.assertEqual(audit.call_args.kwargs, {})

    def test_stale_actor_and_disabled_locked_account_cannot_save(self):
        for disabled in (False, True):
            locked = test_user()
            locked.set_password(NEW)
            with patch.object(password_services.transaction, "atomic", return_value=nullcontext()), \
                    patch.object(get_user_model().objects, "select_for_update") as users, \
                    patch.object(password_services, "eligible_password_account", return_value=not disabled), \
                    patch.object(password_services, "record_event") as audit, \
                    patch.object(get_user_model(), "save") as save:
                users.return_value.get.return_value = locked
                with self.assertRaises(PermissionDenied if disabled else ValidationError):
                    password_services.change_own_password(self.user, password_data())
                save.assert_not_called()
                audit.assert_not_called()

    def test_access_token_is_rejected_after_password_change(self):
        self.assertTrue(api_settings.CHECK_REVOKE_TOKEN)
        token = AccessToken.for_user(self.user)
        auth = JWTAuthentication()
        with patch.object(auth.user_model.objects, "get", return_value=self.user):
            self.assertEqual(auth.get_user(token), self.user)
            self.user.set_password(NEW)
            with self.assertRaises(AuthenticationFailed):
                auth.get_user(token)

    def test_pre_hardening_access_token_without_password_claim_is_rejected(self):
        token = AccessToken.for_user(self.user)
        del token[api_settings.REVOKE_TOKEN_CLAIM]
        with patch.object(get_user_model().objects, "get", return_value=self.user):
            with self.assertRaises(AuthenticationFailed):
                JWTAuthentication().get_user(token)

    def refresh(self, claim):
        token = RefreshToken()
        token[api_settings.USER_ID_CLAIM] = self.user.pk
        if claim is not None:
            token[api_settings.REVOKE_TOKEN_CLAIM] = claim
        with patch.object(auth_serializers, "RefreshToken", return_value=token), \
                patch.object(auth_serializers, "_lock_refresh_token"), \
                patch.object(auth_serializers, "can_use_mobile", return_value=True), \
                patch.object(get_user_model().objects, "select_for_update") as users, \
                patch.object(TokenRefreshSerializer, "validate", return_value={"access": "test-child"}) as issue:
            users.return_value.get.return_value = self.user
            # Exercise the real validation body; transaction/driver behavior is
            # reserved for disposable-MySQL tests, not simulated as verified here.
            result = auth_serializers.EmployeeTokenRefreshSerializer.validate.__wrapped__(
                auth_serializers.EmployeeTokenRefreshSerializer(), {"refresh": "test-parent"},
            )
            return result, issue.call_count

    def test_refresh_current_password_claim_can_issue_a_child(self):
        result, issued = self.refresh(get_md5_hash_password(self.user.password))
        self.assertEqual(result, {"access": "test-child"})
        self.assertEqual(issued, 1)

    def test_refresh_changed_or_missing_password_claim_cannot_issue_a_child(self):
        old_claim = get_md5_hash_password(self.user.password)
        self.user.set_password(NEW)
        for claim in (old_claim, None):
            with self.subTest(missing=claim is None), self.assertRaises(AuthenticationFailed):
                self.refresh(claim)

    def test_throttle_is_shared_between_website_and_api(self):
        request = RequestFactory().post("/accounts/password-change/")
        request.user = self.user
        throttle = password_services.PasswordChangeThrottle()
        key = throttle.get_cache_key(request, None)
        cache.delete(key)
        self.addCleanup(cache.delete, key)
        for _ in range(5):
            self.assertTrue(password_services.PasswordChangeThrottle().allow_request(request, None))
        request.path = "/api/v1/auth/password-change/"
        self.assertFalse(password_services.PasswordChangeThrottle().allow_request(request, None))


@override_settings(PASSWORD_HASHERS=["django.contrib.auth.hashers.MD5PasswordHasher"])
class PasswordChangeDatabaseTests(TestCase):
    """Real password/session/token persistence; approved disposable MySQL only."""

    @classmethod
    def setUpTestData(cls):
        cls.user = get_user_model().objects.create_user(username="password-owner", password=OLD)
        cls.other = get_user_model().objects.create_user(username="password-other", password=OLD)
        department = Department.objects.create(code="PASS-DEPT", name="Password tests")
        role = JobRole.objects.create(code="PASS-ROLE", name="Password tests")
        cls.employee = Employee.objects.create(
            employee_code="PASS-OWNER", display_name="Password test employee", user=cls.user,
            department=department, job_role=role, date_joined="2026-01-01",
        )

    def setUp(self):
        self.client.force_login(self.user)
        self.api = APIClient()
        self.refresh = RefreshToken.for_user(self.user)
        self.api.credentials(HTTP_AUTHORIZATION=f"Bearer {self.refresh.access_token}")
        request = RequestFactory().post("/")
        request.user = self.user
        self.throttle_key = password_services.PasswordChangeThrottle().get_cache_key(request, None)
        cache.delete(self.throttle_key)
        self.addCleanup(cache.delete, self.throttle_key)

    def api_data(self, **changes):
        return {"current_password": OLD, "new_password": NEW, "confirm_password": NEW, **changes}

    def test_api_changes_only_own_password_and_revokes_access_and_refresh(self):
        response = self.api.post(reverse("api:v1:auth-password-change"), self.api_data(), format="json")
        self.assertEqual(response.status_code, 204)
        self.assertEqual(response.content, b"")
        self.user.refresh_from_db()
        self.other.refresh_from_db()
        self.assertTrue(self.user.check_password(NEW))
        self.assertTrue(self.other.check_password(OLD))
        self.assertTrue(BlacklistedToken.objects.filter(token__jti=self.refresh["jti"]).exists())
        self.assertEqual(self.api.get(reverse("api:v1:auth-me")).status_code, 401)
        self.assertEqual(APIClient().post(reverse("api:v1:auth-refresh"), {"refresh": str(self.refresh)}).status_code, 401)
        with patch("accounts.login_rate_limit.reserve_login_source", return_value=0), patch(
            "accounts.login_rate_limit.reserve_login_account", return_value=0,
        ):
            response = APIClient().post(reverse("api:v1:auth-login"), {"username": self.user.username, "password": NEW})
        self.assertEqual(response.status_code, 200)

    def test_web_keeps_current_session_rotates_key_and_invalidates_other_session(self):
        other_session = Client()
        other_session.force_login(self.user)
        old_key = self.client.session.session_key
        response = self.client.post(reverse("accounts:password-change"), password_data())
        self.assertRedirects(response, reverse("accounts:profile"))
        self.assertNotEqual(self.client.session.session_key, old_key)
        self.assertEqual(self.client.get(reverse("accounts:profile")).status_code, 200)
        self.assertEqual(other_session.get(reverse("accounts:profile")).status_code, 302)
        self.assertEqual(self.api.get(reverse("api:v1:auth-me")).status_code, 401)

    def test_wrong_weak_mismatch_and_reuse_leave_password_and_tokens_unchanged(self):
        for changes in (
            {"current_password": "incorrect"},
            {"new_password": "123", "confirm_password": "123"},
            {"confirm_password": "mismatch"},
            {"new_password": OLD, "confirm_password": OLD},
        ):
            response = self.api.post(reverse("api:v1:auth-password-change"), self.api_data(**changes), format="json")
            self.assertEqual(response.status_code, 400)
            self.assertNotIn(OLD, response.content.decode())
            self.assertNotIn(NEW, response.content.decode())
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password(OLD))
        self.assertFalse(BlacklistedToken.objects.filter(token__jti=self.refresh["jti"]).exists())

    def test_arbitrary_target_and_extra_fields_are_rejected(self):
        url = reverse("api:v1:auth-password-change")
        for data in (self.api_data(user_id=self.other.pk), [self.api_data()]):
            response = self.api.post(url, data, format="json")
            self.assertEqual(response.status_code, 400, response.data)
            self.assertEqual(response.data["error"]["code"], "validation_error")
            self.assertIn("non_field_errors", response.data["error"]["fields"])
        self.other.refresh_from_db()
        self.user.refresh_from_db()
        self.assertTrue(self.other.check_password(OLD))
        self.assertTrue(self.user.check_password(OLD))
        self.assertFalse(BlacklistedToken.objects.filter(token__jti=self.refresh["jti"]).exists())

    def test_anonymous_session_only_and_inactive_user_api_denied(self):
        url = reverse("api:v1:auth-password-change")
        self.assertEqual(APIClient().post(url, self.api_data(), format="json").status_code, 401)
        session_only = APIClient()
        session_only.force_login(self.user)
        self.assertEqual(session_only.post(url, self.api_data(), format="json").status_code, 401)
        self.user.is_active = False
        self.user.save()
        self.assertEqual(self.api.post(url, self.api_data(), format="json").status_code, 401)

    def test_inactive_employee_is_denied_even_with_active_login(self):
        self.employee.is_active = False
        self.employee.deactivation_reason = "Password isolation test"
        self.employee.save()
        self.user.refresh_from_db()
        self.assertFalse(self.user.is_active)
        self.user.is_active = True
        self.user.save()
        self.client.force_login(self.user)
        self.assertEqual(self.api.post(reverse("api:v1:auth-password-change"), self.api_data(), format="json").status_code, 403)
        self.assertEqual(self.client.get(reverse("accounts:password-change")).status_code, 403)

    def test_csrf_and_get_leave_password_unchanged(self):
        client = Client(enforce_csrf_checks=True)
        client.force_login(self.user)
        self.assertEqual(client.post(reverse("accounts:password-change"), password_data()).status_code, 403)
        self.assertEqual(self.client.get(reverse("accounts:password-change")).status_code, 200)
        self.assertEqual(self.api.get(reverse("api:v1:auth-password-change")).status_code, 405)
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password(OLD))

    def test_throttling_blocks_repeated_incorrect_current_password(self):
        url = reverse("api:v1:auth-password-change")
        for _ in range(5):
            self.assertEqual(self.api.post(url, self.api_data(current_password="wrong"), format="json").status_code, 400)
        self.assertEqual(self.api.post(url, self.api_data(current_password="wrong"), format="json").status_code, 429)

    def test_stale_second_change_and_failure_roll_back_without_false_audit(self):
        from audit.models import AuditLog
        first_actor = get_user_model().objects.get(pk=self.user.pk)
        stale_actor = get_user_model().objects.get(pk=self.user.pk)
        with self.captureOnCommitCallbacks(execute=True):
            password_services.change_own_password(first_actor, password_data(), mobile=True)
        self.assertEqual(AuditLog.objects.filter(action="auth.password.changed").count(), 1)
        with self.assertRaises(ValidationError):
            password_services.change_own_password(stale_actor, password_data(), mobile=True)
        self.assertEqual(AuditLog.objects.filter(action="auth.password.changed").count(), 1)
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password(NEW))
        with patch.object(password_services.BlacklistedToken.objects, "get_or_create", side_effect=RuntimeError("Test rollback")):
            with self.assertRaises(RuntimeError):
                password_services.change_own_password(self.user, password_data(old_password=NEW, new_password1=OLD, new_password2=OLD))
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password(NEW))
        self.assertEqual(AuditLog.objects.filter(action="auth.password.changed").count(), 1)
