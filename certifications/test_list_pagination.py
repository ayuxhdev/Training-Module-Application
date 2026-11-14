"""Safe presentation tests and separately runnable disposable-MySQL regressions.

Only CertificateListPresentationTests is database-free. Never run the database
class against a preserved development, test or QA schema.
"""

from datetime import datetime, timedelta, timezone
from html import unescape
from html.parser import HTMLParser
from types import SimpleNamespace
from urllib.parse import parse_qs
from unittest.mock import Mock, patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import AnonymousUser, Group, Permission
from django.http import Http404, HttpResponse
from django.template.loader import render_to_string
from django.test import Client, RequestFactory, SimpleTestCase

from config.model_test_utils import CurriculumTestCase
from organization.models import Employee

from . import tests as existing_tests
from . import views
from .models import Certificate


def certificate_row(pk):
    return SimpleNamespace(
        pk=pk, certificate_number=f"GN-PAGE-{pk:04}",
        issued_at=datetime(2026, 11, 14, tzinfo=timezone.utc) - timedelta(seconds=pk // 3),
        employee_name_snapshot="Original <Learner & Name>", employee_code_snapshot="ORIGINAL-CODE",
        training_title_snapshot="Original <Training & Title>", version_number_snapshot=3,
        revoked_at=None, revocation_reason="PRIVATE-REASON", document_file="PRIVATE-STORAGE-PATH",
        assignment=SimpleNamespace(employee=SimpleNamespace(display_name="Current employee name")),
        training_version=SimpleNamespace(title="Current version title"),
    )


class BoundedCertificateRows:
    """Reject full evaluation so a count-plus-window regression cannot pass."""

    def __init__(self, count):
        self.rows = [certificate_row(pk) for pk in range(1, count + 1)]
        self.slices = []
        self.count_calls = 0
        self.ordering = None

    def order_by(self, *fields):
        self.ordering = fields
        return self

    def count(self):
        self.count_calls += 1
        return len(self.rows)

    def __iter__(self):
        raise AssertionError("The full certificate queryset must not be evaluated.")

    def __getitem__(self, window):
        if not isinstance(window, slice) or window.stop - window.start > 50:
            raise AssertionError("Only bounded certificate windows may be retrieved.")
        self.slices.append((window.start, window.stop))
        return self.rows[window]


class PageLinks(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "a" and values.get("rel") in ("prev", "next"):
            self.links.append(values)


class CertificateListPresentationTests(SimpleTestCase):
    databases = set()

    def setUp(self):
        self.user = SimpleNamespace(is_authenticated=True, is_superuser=False, has_perm=Mock(return_value=False))
        self.factory = RequestFactory()

    def context(self, count, query=""):
        rows = BoundedCertificateRows(count)
        request = self.factory.get("/certificates/" + query)
        request.user = self.user
        with patch.object(views, "_certificate_queryset", return_value=rows) as scope, \
                patch.object(views, "render", return_value=HttpResponse()) as render:
            views.certificate_list(request)
        scope.assert_called_once_with(self.user)
        self.assertEqual(rows.ordering, ("-issued_at", "pk"))
        return render.call_args.args[2], rows

    def html(self, context):
        # No request/context processors: render the actual inherited template
        # without querying shell navigation or accessing authenticated services.
        return render_to_string("certifications/certificate_list.html", context)

    def test_first_page_uses_one_count_and_only_fifty_rows(self):
        context, rows = self.context(201)
        self.assertEqual(rows.count_calls, 1)
        self.assertEqual(rows.slices, [(0, 50)])
        self.assertEqual(len(context["certificates"]), 50)
        self.assertEqual(context["paginator"].count, 201)
        html = self.html(context)
        self.assertIn("Showing 1-50 of 201 certificates.", html)
        self.assertIn("Page 1 of 5", html)
        self.assertIn('aria-label="Certificate pages"', html)
        self.assertIn('rel="next"', html)
        self.assertNotIn('rel="prev"', html)
        self.assertNotIn("GN-PAGE-0051", html)

    def test_final_page_remains_accessible_beyond_two_hundred_records(self):
        context, rows = self.context(201, "?page=5")
        self.assertEqual(rows.slices, [(200, 201)])
        html = self.html(context)
        self.assertIn("Showing 201-201 of 201 certificates.", html)
        self.assertIn("Page 5 of 5", html)
        self.assertIn("GN-PAGE-0201", html)
        self.assertIn('rel="prev"', html)
        self.assertNotIn('rel="next"', html)

    def test_all_pages_cover_every_certificate_once_with_stable_ordering(self):
        ids = []
        for page in range(1, 6):
            context, _ = self.context(201, f"?page={page}")
            ids.extend(row.pk for row in context["certificates"])
        self.assertEqual(ids, list(range(1, 202)))

    def test_empty_list_has_safe_page_and_no_navigation(self):
        context, rows = self.context(0)
        self.assertEqual(rows.slices, [(0, 0)])
        html = self.html(context)
        self.assertIn("Showing 0 certificates.", html)
        self.assertIn("Page 1 of 1", html)
        self.assertIn("No certificates are available.", html)
        self.assertNotIn('aria-label="Certificate pages"', html)

    def test_exactly_one_page_has_no_dead_previous_or_next_links(self):
        context, _ = self.context(50)
        html = self.html(context)
        self.assertIn("Showing 1-50 of 50 certificates.", html)
        self.assertIn("Page 1 of 1", html)
        self.assertNotIn('rel="next"', html)
        self.assertNotIn('rel="prev"', html)

    def test_malformed_negative_and_out_of_range_pages_use_django_fallbacks(self):
        for value, expected in (("bad", 1), ("1.5", 1), ("", 1), ("-1", 5), ("0", 5), ("999999", 5)):
            with self.subTest(value=value):
                context, rows = self.context(201, f"?page={value}")
                self.assertEqual(context["page_obj"].number, expected)
                self.assertLessEqual(len(context["certificates"]), 50)
                self.assertEqual(rows.count_calls, 1)

    def test_page_links_preserve_repeated_parameters_and_escape_values(self):
        context, _ = self.context(201, "?page=2&page=3&search=A%26B&tag=one&tag=two&extra=%3Cscript%3E")
        self.assertNotIn("page=", context["page_query"])
        parser = PageLinks()
        html = self.html(context)
        parser.feed(html)
        self.assertEqual(len(parser.links), 2)
        for link in parser.links:
            query = parse_qs(unescape(link["href"]).lstrip("?"))
            self.assertEqual(query["search"], ["A&B"])
            self.assertEqual(query["tag"], ["one", "two"])
            self.assertEqual(query["extra"], ["<script>"])
            self.assertEqual(query["page"], ["2" if link["rel"] == "prev" else "4"])
            self.assertIn(link["aria-label"], ("Previous page", "Next page"))
        self.assertNotIn("<script>", html)

    def test_snapshot_fields_status_and_detail_links_are_preserved(self):
        context, _ = self.context(1)
        context["certificates"][0].revoked_at = context["certificates"][0].issued_at
        html = self.html(context)
        self.assertIn("Original &lt;Learner &amp; Name&gt;", html)
        self.assertIn("Original &lt;Training &amp; Title&gt;", html)
        self.assertIn("Original", html)
        self.assertIn("Version 3", html)
        self.assertIn("Revoked", html)
        self.assertIn('href="/certificates/1/"', html)
        self.assertIn('aria-label="View certificate: GN-PAGE-0001"', html)
        for private in ("PRIVATE-REASON", "PRIVATE-STORAGE-PATH", "Current employee name", "Current version title"):
            self.assertNotIn(private, html)
        self.assertNotIn("/revoke/", html)
        self.assertIn('role="region" aria-label="Certificates" tabindex="0"', html)
        self.assertEqual(html.count('scope="col"'), 6)

    def test_personal_queryset_is_still_filtered_by_active_linked_employee(self):
        employee = Employee(pk=17)
        with patch.object(views, "get_object_or_404", return_value=employee) as lookup:
            queryset = views._certificate_queryset(self.user)
        lookup.assert_called_once_with(Employee, user=self.user, is_active=True)
        self.assertEqual(queryset.query.where.children[0].rhs, 17)
        self.assertEqual(queryset.query.where.children[0].lhs.target.name, "employee")
        self.assertEqual(queryset.query.select_related, {"assignment": {"employee": {}}, "training_version": {}})

    def test_effective_read_permission_allows_global_queryset_without_employee_lookup(self):
        self.user.has_perm.return_value = True
        with patch.object(views, "get_object_or_404") as lookup:
            queryset = views._certificate_queryset(self.user)
        lookup.assert_not_called()
        self.assertFalse(queryset.query.where.children)
        self.user.has_perm.assert_called_once_with("certifications.view_certificate")

    def test_no_active_employee_without_permission_remains_not_found(self):
        with patch.object(views, "get_object_or_404", side_effect=Http404):
            with self.assertRaises(Http404):
                views._certificate_queryset(self.user)

    def test_anonymous_redirects_before_querying_certificates(self):
        request = self.factory.get("/certificates/")
        request.user = AnonymousUser()
        with patch.object(views, "_certificate_queryset") as scope:
            response = views.certificate_list(request)
        self.assertEqual(response.status_code, 302)
        self.assertIn("next=", response.url)
        scope.assert_not_called()


class CertificateListDatabaseTests(CurriculumTestCase):
    """Pending real disposable MySQL: actual scope, grants and query budget."""

    def setUp(self):
        self.own = existing_tests.CertificateWorkflowTests.certificate(self, self.complete_assignment())
        self.own.save()
        self.foreign = existing_tests.CertificateWorkflowTests.other_employee_certificate(self)

    def client_for(self, user):
        client = Client()
        client.force_login(user)
        return client

    def test_employee_and_ordinary_manager_never_list_another_employees_certificate(self):
        client = self.client_for(self.employee_user)
        for manager in (False, True):
            if manager:
                self.employee_user.groups.add(Group.objects.get(name="Manager"))
            response = client.get("/certificates/")
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.context["paginator"].count, 1)
            self.assertContains(response, self.own.certificate_number)
            self.assertNotContains(response, self.foreign.certificate_number)
            self.assertEqual(client.get(f"/certificates/{self.foreign.pk}/").status_code, 404)

    def test_direct_group_and_default_management_read_grants_preserve_global_visibility(self):
        permission = Permission.objects.get(content_type__app_label="certifications", codename="view_certificate")
        reviewers = Group.objects.create(name="Certificate pagination reviewers")
        reviewers.permissions.add(permission)
        for grant in ("direct", "group", "Administrator", "Training Coordinator"):
            user = get_user_model().objects.create_user(username=f"certificate-pages-{grant}")
            if grant == "direct":
                user.user_permissions.add(permission)
            else:
                user.groups.add(reviewers if grant == "group" else Group.objects.get(name=grant))
            response = self.client_for(user).get("/certificates/")
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.context["paginator"].count, 2)
            self.assertContains(response, self.own.certificate_number)
            self.assertContains(response, self.foreign.certificate_number)

    def test_paginated_rows_remain_joined_and_do_not_mutate_historical_snapshots(self):
        user = get_user_model().objects.create_user(username="certificate-pages-company", is_superuser=True)
        request = RequestFactory().get("/certificates/")
        request.user = user
        before = list(Certificate.objects.order_by("pk").values())

        def consume_page(request, template, context):
            for certificate in context["certificates"]:
                self.assertTrue(certificate.assignment.employee.employee_code)
                self.assertTrue(certificate.training_version.title)
            return HttpResponse()

        with patch.object(views, "render", side_effect=consume_page), self.assertNumQueries(2):
            views.certificate_list(request)
        self.assertEqual(before, list(Certificate.objects.order_by("pk").values()))
