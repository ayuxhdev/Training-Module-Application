"""Read-only profile routing/rendering tests; no database setup or access."""

from types import SimpleNamespace
from unittest.mock import Mock, patch

from django.contrib.auth.models import AnonymousUser, User
from django.test import RequestFactory, SimpleTestCase
from django.urls import resolve, reverse

from .views import ProfileView


class ProfileTests(SimpleTestCase):
    databases = set()

    def setUp(self):
        self.factory = RequestFactory()
        self.user = User(pk=1, username="learner-one")
        # Permission checks in the shared shell are unrelated to profile access.
        self.user.has_perm = Mock(return_value=True)

    def request(self, user, method="get", suffix=""):
        request = getattr(self.factory, method)(reverse("accounts:profile") + suffix)
        request.user = user
        request.resolver_match = resolve(reverse("accounts:profile"))
        return request

    def test_anonymous_profile_redirects_to_login_before_loading_data(self):
        with patch("accounts.views.Employee.objects.filter") as query:
            response = ProfileView.as_view()(self.request(AnonymousUser()))
        self.assertEqual(response.status_code, 302)
        self.assertEqual(response.url, reverse("accounts:login") + "?next=/accounts/profile/")
        query.assert_not_called()

    def test_profile_uses_only_authenticated_owner_even_with_foreign_identifiers(self):
        for user_id in (1, 2):
            with self.subTest(user_id=user_id):
                user = User(pk=user_id, username=f"learner-{user_id}")
                user.has_perm = Mock(return_value=True)
                employee = SimpleNamespace(
                    employee_code=f"EMP-{user_id}",
                    department=SimpleNamespace(name=f"Department {user_id}"),
                    job_role=SimpleNamespace(name=f"Role {user_id}"),
                )
                with patch("accounts.views.Employee.objects.filter") as query:
                    query.return_value.select_related.return_value.first.return_value = employee
                    response = ProfileView.as_view()(self.request(user, suffix="?employee_id=999&user_id=999"))
                    query.assert_called_once_with(user=user)
                    query.return_value.select_related.assert_called_once_with("department", "job_role")
                    response.render()
                self.assertEqual(response.status_code, 200)
                self.assertIs(response.context_data["profile_employee"], employee)
                for value in (user.username, employee.employee_code, employee.department.name, employee.job_role.name):
                    self.assertContains(response, value)
                self.assertNotContains(response, "EMP-999")
                self.assertNotContains(response, "Edit employee")

    def test_missing_employee_and_optional_details_render_gracefully(self):
        for employee in (None, SimpleNamespace(employee_code="", department=None, job_role=None)):
            with self.subTest(employee=employee), patch("accounts.views.Employee.objects.filter") as query:
                query.return_value.select_related.return_value.first.return_value = employee
                response = ProfileView.as_view()(self.request(self.user))
                response.render()
                self.assertContains(response, "Not assigned", count=3)
                self.assertContains(response, self.user.username)

    def test_profile_order_escaping_navigation_and_existing_account_actions(self):
        employee = SimpleNamespace(
            employee_code="EMP-ONE", department=SimpleNamespace(name="<script>unsafe</script>"),
            job_role=SimpleNamespace(name="Engineer"),
        )
        with patch("accounts.views.Employee.objects.filter") as query:
            query.return_value.select_related.return_value.first.return_value = employee
            response = ProfileView.as_view()(self.request(self.user))
            response.render()
        html = response.content.decode()
        labels = ("Username", "Employee Code", "Department", "Job Role")
        indices = [html.index(f"<dt>{label}</dt>") for label in labels]
        self.assertEqual(indices, sorted(indices))
        self.assertIn("&lt;script&gt;unsafe&lt;/script&gt;", html)
        self.assertIn('href="/accounts/profile/" aria-current="page">Profile</a>', html)
        self.assertIn('action="/accounts/logout/"', html)
        self.assertIn('class="appearance-control"', html)
        self.assertIn('aria-labelledby="account-details-heading"', html)

    def test_profile_rejects_mutations_without_loading_employee(self):
        for method in ("post", "patch", "delete", "put"):
            with self.subTest(method=method), patch("accounts.views.Employee.objects.filter") as query:
                response = ProfileView.as_view()(self.request(self.user, method))
                self.assertEqual(response.status_code, 405)
                query.assert_not_called()

    def test_login_has_no_private_profile_link(self):
        from django.template.loader import render_to_string

        request = self.factory.get(reverse("accounts:login"))
        request.user = AnonymousUser()
        html = render_to_string("base.html", request=request)
        self.assertNotIn('href="/accounts/profile/"', html)
