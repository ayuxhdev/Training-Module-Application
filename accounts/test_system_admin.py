"""Read-only Superuser Center regressions using isolated transaction fixtures."""

import hashlib
import json
import re
from html.parser import HTMLParser
from unittest.mock import patch

from django.apps import apps
from django.contrib.auth import get_user_model
from django.contrib.auth.models import AnonymousUser, Group
from django.core.exceptions import PermissionDenied
from django.core.serializers.json import DjangoJSONEncoder
from django.db import connection
from django.template.loader import get_template
from django.test import Client, RequestFactory, TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import resolve, reverse
from django.utils import timezone

from organization.models import Department, Employee, JobRole

from .system_admin import SystemDashboardView, SystemUserDetailView, SystemUserListView


class SystemAdministrationTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        User = get_user_model()
        cls.root = User.objects.create_user(username="system-root", is_superuser=True, is_staff=True)
        cls.business_admin = User.objects.create_user(username="business-admin")
        cls.business_admin.groups.add(Group.objects.get(name="Administrator"))
        cls.manager = User.objects.create_user(username="system-manager")
        cls.manager.groups.add(Group.objects.get(name="Manager"))
        cls.learner = User.objects.create_user(username="system-learner")
        cls.learner.groups.add(Group.objects.get(name="Employee"))
        cls.staff = User.objects.create_user(username="system-staff", is_staff=True)
        cls.inactive = User.objects.create_user(username="system-inactive", is_superuser=True, is_staff=True, is_active=False)
        cls.target = User.objects.create_user(username="ada-account", first_name="Ada", last_name="Lovelace", email="ada@example.test")
        cls.target.groups.add(Group.objects.get(name="Trainer"), Group.objects.get(name="Employee"))
        cls.target.last_login = timezone.now()
        cls.target.save(update_fields=["last_login"])
        cls.department = Department.objects.create(code="SYS-DEP", name="Accounts test department")
        cls.role = JobRole.objects.create(code="SYS-ROLE", name="Accounts test role")
        cls.manager_employee = cls.link(cls.manager, "SYS-MGR", "Manager Employee")
        cls.learner_employee = cls.link(cls.learner, "SYS-EMP", "Learner Employee", manager=cls.manager_employee)
        cls.target_employee = cls.link(cls.target, "SYS-ADA", "Linked Ada Employee")

    @classmethod
    def link(cls, user, code, name, manager=None):
        return Employee.objects.create(
            user=user, employee_code=code, display_name=name,
            department=cls.department, job_role=cls.role,
            date_joined=timezone.now().date(), reporting_manager=manager,
        )

    def routes(self):
        return (
            reverse("accounts:system-dashboard"),
            reverse("accounts:system-user-list"),
            reverse("accounts:system-user-detail", args=[self.target.pk]),
        )

    def setUp(self):
        self.client.force_login(self.root)

    def test_active_superuser_accesses_all_routes_without_business_group(self):
        self.assertFalse(self.root.groups.exists())
        for url in self.routes():
            with self.subTest(url=url):
                self.assertEqual(self.client.get(url).status_code, 200)
        self.assertFalse(self.root.groups.exists())

    def test_dashboard_has_exact_account_statistics(self):
        response = self.client.get(reverse("accounts:system-dashboard"))
        self.assertEqual(response.context["account_stats"], {
            "total": 7, "active": 6, "inactive": 1, "staff": 3,
            "superusers": 2, "linked": 3, "unlinked": 4,
        })
        for label in ("Total user accounts", "Active accounts", "Inactive accounts", "Staff accounts", "Superuser accounts", "Linked to Employees", "Without Employee links"):
            self.assertContains(response, label)

    def test_business_administrator_manager_employee_and_staff_are_denied(self):
        for user in (self.business_admin, self.manager, self.learner, self.staff):
            self.client.force_login(user)
            for url in self.routes():
                with self.subTest(user=user.username, url=url):
                    response = self.client.get(url)
                    self.assertEqual(response.status_code, 403)
                    self.assertNotContains(response, self.target.email, status_code=403)

    def test_business_permissions_cannot_override_superuser_gate(self):
        self.assertTrue(self.business_admin.has_perm("training.add_trainingassignment"))
        self.assertTrue(self.business_admin.has_perm("organization.change_employee"))
        self.client.force_login(self.business_admin)
        for url in self.routes():
            self.assertEqual(self.client.get(url).status_code, 403)

    def test_anonymous_users_redirect_to_login_without_account_disclosure(self):
        client = Client()
        for url in self.routes():
            with self.subTest(url=url):
                response = client.get(url)
                self.assertEqual(response.status_code, 302)
                self.assertTrue(response.url.startswith(reverse("accounts:login") + "?next="))
                self.assertNotIn(self.target.email, response.content.decode())

    def test_anonymous_direct_view_does_not_query_user_accounts(self):
        request = RequestFactory().get(reverse("accounts:system-user-list"))
        request.user = AnonymousUser()
        with self.assertNumQueries(0), patch("accounts.system_admin.account_directory_queryset") as query:
            response = SystemUserListView.as_view()(request)
        self.assertEqual(response.status_code, 302)
        query.assert_not_called()

    def test_inactive_superuser_session_cannot_access_pages(self):
        self.client.force_login(self.inactive)
        for url in self.routes():
            response = self.client.get(url)
            self.assertEqual(response.status_code, 302)
            self.assertTrue(response.url.startswith(reverse("accounts:login")))

    def test_direct_view_gate_denies_inactive_user_without_querying_directory(self):
        factory = RequestFactory()
        request = factory.get(self.routes()[0])
        request.user = self.inactive
        with self.assertNumQueries(0), self.assertRaises(PermissionDenied):
            SystemDashboardView.as_view()(request)

    def test_superuser_without_staff_can_use_custom_center_without_admin_bypass(self):
        self.root.is_staff = False
        self.root.save(update_fields=["is_staff"])
        response = self.client.get(self.routes()[0])
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "additionally requires staff access")
        self.assertNotContains(response, 'href="/admin/"')
        self.assertEqual(self.client.get(reverse("admin:index")).status_code, 302)

    def test_search_username_name_full_name_email_and_employee_fields(self):
        url = reverse("accounts:system-user-list")
        for value in ("ADA-ACCOUNT", "Ada", "Lovelace", "Ada Lovelace", "ada@example.test", "SYS-ADA", "Linked Ada"):
            with self.subTest(value=value):
                response = self.client.get(url, {"q": value})
                self.assertEqual(response.status_code, 200)
                self.assertEqual([user.pk for user in response.context["accounts"]], [self.target.pk])
        self.assertEqual(self.client.get(url, {"q": "   Ada   "}).context["paginator"].count, 1)

    def test_empty_search_and_no_match_states(self):
        url = reverse("accounts:system-user-list")
        self.assertEqual(self.client.get(url, {"q": "  "}).context["paginator"].count, 7)
        response = self.client.get(url, {"q": "no-such-account"})
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "No user accounts match this search.")
        self.assertEqual(response.context["paginator"].count, 0)

    def test_oversized_search_is_controlled_and_returns_no_accounts(self):
        response = self.client.get(reverse("accounts:system-user-list"), {"q": "x" * 151})
        self.assertEqual(response.status_code, 400)
        self.assertTrue(response.context["search_form"].errors)
        self.assertEqual(response.context["paginator"].count, 0)
        self.assertContains(response, 'aria-invalid="true"', status_code=400)
        self.assertContains(response, 'id="account-search-errors"', status_code=400)

    def test_pagination_is_bounded_stable_and_keeps_search(self):
        User = get_user_model()
        for index in range(27):
            User.objects.create_user(username=f"paging-{index:02}")
        url = reverse("accounts:system-user-list")
        first = self.client.get(url, {"q": "paging-", "page_size": 1000})
        second = self.client.get(url, {"q": "paging-", "page": 2})
        self.assertEqual(first.context["paginator"].count, 27)
        self.assertEqual(len(first.context["accounts"]), 25)
        self.assertEqual(len(second.context["accounts"]), 2)
        self.assertContains(first, 'href="?q=paging-&amp;page=2"')
        self.assertContains(second, 'href="?q=paging-&amp;page=1"')
        ids = [user.pk for user in first.context["accounts"]] + [user.pk for user in second.context["accounts"]]
        expected = list(User.objects.filter(username__startswith="paging-").order_by("username", "pk").values_list("pk", flat=True))
        self.assertEqual(ids, expected)
        again = self.client.get(url, {"q": "paging-"})
        self.assertEqual([user.pk for user in again.context["accounts"]], ids[:25])
        self.assertEqual(self.client.get(url, {"q": "paging-", "page": 3}).status_code, 404)

    def test_directory_displays_groups_and_linked_and_unlinked_accounts(self):
        response = self.client.get(reverse("accounts:system-user-list"))
        for value in (self.target.username, "Ada Lovelace", self.target.email, "Trainer", "Employee", "SYS-ADA", "Linked Ada Employee", "Not linked", "Active", "Inactive", "Staff", "Superuser", "Never"):
            self.assertContains(response, value)
        self.assertContains(response, f'aria-label="View user account: {self.target.username}"')

    def test_read_only_detail_shows_the_requested_user_not_the_viewer(self):
        response = self.client.get(reverse("accounts:system-user-detail", args=[self.target.pk]))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.context["account"].pk, self.target.pk)
        for value in (self.target.username, "Ada Lovelace", self.target.email, "SYS-ADA", "Trainer", "Account created"):
            self.assertContains(response, value)

    def test_unlinked_detail_and_empty_optional_fields_are_explicit(self):
        response = self.client.get(reverse("accounts:system-user-detail", args=[self.staff.pk]))
        for value in ("Not linked", "Not provided", "Never"):
            self.assertContains(response, value)

    def test_unknown_detail_is_404_but_unauthorized_actor_gets_same_403(self):
        self.assertEqual(self.client.get(reverse("accounts:system-user-detail", args=[99999999])).status_code, 404)
        self.client.force_login(self.business_admin)
        known = self.client.get(reverse("accounts:system-user-detail", args=[self.target.pk]))
        missing = self.client.get(reverse("accounts:system-user-detail", args=[99999999]))
        self.assertEqual(known.status_code, 403)
        # Django deliberately masks the CSRF token differently per response.
        def without_csrf_mask(response):
            return re.sub(
                r'(name="csrfmiddlewaretoken" value=")[^"]*',
                r'\1[CSRF mask]', response.content.decode(),
            )
        self.assertEqual(without_csrf_mask(known), without_csrf_mask(missing))

    def test_read_pages_fetch_no_target_credential_columns(self):
        factory = RequestFactory()
        for view, url, kwargs in (
            (SystemUserListView, reverse("accounts:system-user-list"), {}),
            (SystemUserDetailView, reverse("accounts:system-user-detail", args=[self.target.pk]), {"pk": self.target.pk}),
        ):
            request = factory.get(url)
            request.user = self.root
            request.resolver_match = resolve(url)
            with CaptureQueriesContext(connection) as captured:
                response = view.as_view()(request, **kwargs)
                response.render()
            account = response.context_data.get("account")
            if account is not None:
                self.assertIn("password", account.get_deferred_fields())
            for query in captured:
                self.assertNotIn("`auth_user`.`password`", query["sql"])
                self.assertNotIn("token_blacklist", query["sql"])
                self.assertNotIn("django_session", query["sql"])
            self.assertNotContains(response, self.target.password)
            for field in ("session_data", "refresh_token", "recovery_code", "csrf_secret"):
                self.assertNotContains(response, field)

    def test_stored_text_is_escaped_in_directory_detail_and_search(self):
        self.target.first_name = '<script>alert("account")</script>'
        self.target.save(update_fields=["first_name"])
        for url in (reverse("accounts:system-user-list"), reverse("accounts:system-user-detail", args=[self.target.pk])):
            response = self.client.get(url)
            self.assertNotContains(response, self.target.first_name)
            self.assertContains(response, "&lt;script&gt;")
        response = self.client.get(reverse("accounts:system-user-list"), {"q": '<img src=x onerror=alert(1)>'})
        self.assertNotContains(response, '<img src=x')
        self.assertContains(response, "&lt;img")

    def test_navigation_is_superuser_only_and_existing_destinations_remain(self):
        for user in (self.root, self.business_admin, self.manager, self.learner):
            self.client.force_login(user)
            response = self.client.get(reverse("accounts:profile"))
            self.assertContains(response, 'href="/accounts/profile/"')
            self.assertContains(response, 'action="/accounts/logout/"')
            self.assertContains(response, 'href="/employees/"')
            self.assertContains(response, 'class="appearance-control"')
            if user.is_superuser:
                self.assertContains(response, 'href="/accounts/system/"')
            else:
                self.assertNotContains(response, 'href="/accounts/system/"')
            if user == self.business_admin:
                self.assertContains(response, 'href="/trainings/"')
            if user == self.manager:
                self.assertContains(response, 'href="/reports/assignments/"')

    def test_system_navigation_selected_state_and_technical_admin_fallback(self):
        for url in self.routes():
            response = self.client.get(url)
            self.assertContains(response, 'href="/accounts/system/" aria-current="page"')
            self.assertContains(response, 'href="/admin/"')
        self.assertEqual(resolve(reverse("admin:index")).namespace, "admin")

    def test_responses_are_private_and_not_cacheable_or_indexable(self):
        for url in self.routes():
            response = self.client.get(url)
            for directive in ("no-store", "private", "no-cache"):
                self.assertIn(directive, response["Cache-Control"])
            self.assertEqual(response["X-Robots-Tag"], "noindex, nofollow")

    def test_navigation_disappears_when_superuser_status_is_revoked(self):
        self.root.is_superuser = False
        self.root.save(update_fields=["is_superuser"])
        self.assertEqual(self.client.get(self.routes()[0]).status_code, 403)
        response = self.client.get(reverse("accounts:profile"))
        self.assertNotContains(response, 'href="/accounts/system/"')

    def test_reads_preserve_all_records_groups_and_audit_and_reject_mutations(self):
        def signature():
            state = {model._meta.label: list(model.objects.order_by("pk").values()) for model in apps.get_models()}
            return hashlib.sha256(json.dumps(state, cls=DjangoJSONEncoder, sort_keys=True).encode()).hexdigest()
        before = signature()
        with CaptureQueriesContext(connection) as queries:
            for url in self.routes():
                for method in ("get", "head", "options"):
                    self.assertEqual(getattr(self.client, method)(url).status_code, 200)
                for method in ("post", "patch", "put", "delete"):
                    self.assertEqual(getattr(self.client, method)(url, {}).status_code, 405)
        self.assertEqual(signature(), before)
        self.assertFalse(any(query["sql"].lstrip().split()[0].upper() in {"INSERT", "UPDATE", "DELETE", "REPLACE", "CREATE", "ALTER", "DROP", "TRUNCATE"} for query in queries))

    def test_directory_query_count_is_stable_as_accounts_and_groups_grow(self):
        url = reverse("accounts:system-user-list")
        with CaptureQueriesContext(connection) as small:
            self.assertEqual(self.client.get(url).status_code, 200)
        for index in range(10):
            user = get_user_model().objects.create_user(username=f"scale-{index:02}")
            user.groups.add(Group.objects.get(name="Employee"))
        with CaptureQueriesContext(connection) as large:
            self.assertEqual(self.client.get(url).status_code, 200)
        self.assertEqual(len(small), len(large))

    def test_templates_reuse_accessible_shell_table_and_existing_themes(self):
        for name in ("base", "dashboard", "user_list", "user_detail"):
            self.assertIsNotNone(get_template(f"accounts/system_admin/{name}.html"))
        response = self.client.get(reverse("accounts:system-user-list"))
        for marker in ('href="#main-content"', 'tabindex="0"', 'aria-describedby="account-table-help"', 'scope="col"', 'scope="row"', 'class="appearance-control"', 'class="org-table"'):
            self.assertContains(response, marker)
        class Headers(HTMLParser):
            count = 0

            def handle_starttag(self, tag, attrs):
                if tag == "th" and dict(attrs).get("scope") == "col":
                    self.count += 1

        headers = Headers()
        headers.feed(response.content.decode())
        self.assertEqual(headers.count, 9)
        self.assertContains(response, 'colspan="9"', count=0)
        self.assertNotContains(response, "Edit account")
        self.assertNotContains(response, "Create account")
