"""Database-free regression checks for explicit website record navigation."""

from html.parser import HTMLParser
from pathlib import Path
from types import SimpleNamespace

from django.contrib.auth.forms import AuthenticationForm
from django.contrib.auth.models import AnonymousUser
from django.template import Context
from django.template.loader import get_template, render_to_string
from django.template.loader_tags import BlockNode
from django.test import RequestFactory, SimpleTestCase
from django.urls import resolve, reverse
from django.utils import timezone


class Markup(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.links = []
        self.buttons = []
        self.regions = []
        self.inputs = []
        self.tables = []
        self.row_header_links = []
        self._row_header = False
        self._row = None
        self.feed(html)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == "table":
            self.tables.append([])
        if tag == "tr":
            self._row = []
            self.tables[-1].append(self._row)
        if tag in {"th", "td"}:
            self._row.append(attrs)
        if tag == "th" and attrs.get("scope") == "row":
            self._row_header = True
        if tag == "a":
            self.links.append(attrs)
            if self._row_header:
                self.row_header_links.append(attrs)
        if tag == "button":
            self.buttons.append(attrs)
        if tag == "input":
            self.inputs.append(attrs)
        if attrs.get("role") == "region":
            self.regions.append(attrs)

    def handle_endtag(self, tag):
        if tag == "th":
            self._row_header = False


class WebsiteRecordActionsTests(SimpleTestCase):
    databases = set()

    def setUp(self):
        self.employee = SimpleNamespace(
            pk=21, display_name="Alex <QA>", employee_code="QA-21",
            department=SimpleNamespace(name="Operations"),
            job_role=SimpleNamespace(name="Technician"), reporting_manager=None,
            is_active=True,
        )
        self.training = SimpleNamespace(
            pk=31, catalog_title="Safety <QA>", description="Safe work", is_active=True,
        )
        self.version = SimpleNamespace(
            pk=41, title="Safety version", version_number=2, status="DRAFT",
            published_at=None, get_status_display="Draft",
        )
        self.assessment = SimpleNamespace(
            pk=51, title="Safety assessment", module=None, sequence=1,
            get_kind_display="Final", pass_percentage=80, time_limit_minutes=10,
            questions=SimpleNamespace(count=lambda: 3), is_required=True,
        )
        self.question = SimpleNamespace(
            pk=61, code="Q-61", topic="Safety", revision_count=1,
            latest_prompt="Work safely?", is_active=True,
        )
        self.certificate = SimpleNamespace(
            pk=71, certificate_number="CERT-71", training_title_snapshot="Safety",
            version_number_snapshot=2, employee_name_snapshot="Alex",
            employee_code_snapshot="QA-21", issued_at=timezone.now(), revoked_at=None,
        )

    def render(self, name, permissions=None, **context):
        return render_to_string(name, {
            "user": AnonymousUser(), "perms": permissions or {}, **context,
        })

    def assert_action(self, html, route, pk, label, present=True):
        url = reverse(route, args=[pk])
        matches = [link for link in Markup(html).links if link.get("href") == url]
        self.assertEqual(len(matches), int(present), (route, html))
        if present:
            self.assertEqual(matches[0]["aria-label"], label)
            self.assertIn("btn", matches[0]["class"].split())
            self.assertEqual(resolve(url).view_name, route)

    def test_employee_view_and_permission_dependent_edit_have_specific_names(self):
        for change in (False, True):
            with self.subTest(change=change):
                html = self.render("organization/employee_list.html",
                    {"organization": {"change_employee": change}}, employees=[self.employee])
                self.assert_action(html, "organization:employee-detail", 21,
                    "View employee: Alex <QA> (QA-21)")
                self.assert_action(html, "organization:employee-update", 21,
                    "Edit employee: Alex <QA> (QA-21)", change)
                self.assertEqual(Markup(html).row_header_links, [])
                self.assertIn("Alex &lt;QA&gt;", html)
                self.assertNotIn("Deactivate employee", html)

    def test_training_view_and_permission_dependent_edit(self):
        for change in (False, True):
            with self.subTest(change=change):
                html = self.render("training/training_list.html",
                    {"training": {"change_training": change}}, trainings=[self.training])
                self.assert_action(html, "training:training-detail", 31, "View training: Safety <QA>")
                self.assert_action(html, "training:training-update", 31,
                    "Edit training: Safety <QA>", change)
                self.assertEqual(Markup(html).row_header_links, [])

    def test_version_view_and_edit_respect_permissions_and_all_lifecycle_states(self):
        for status in ("DRAFT", "PUBLISHED", "RETIRED"):
            for view, change in ((True, False), (True, True), (False, True), (False, False)):
                with self.subTest(status=status, view=view, change=change):
                    self.version.status = status
                    html = self.render("training/components/version_table.html",
                        {"training": {"view_trainingversion": view, "change_trainingversion": change}},
                        versions=[self.version])
                    self.assert_action(html, "training:version-detail", 41,
                        "View version 2: Safety version", view)
                    self.assert_action(html, "training:version-update", 41,
                        "Edit draft version 2: Safety version", change and status == "DRAFT")
                    self.assertEqual(Markup(html).row_header_links, [])
                    self.assertNotIn("<form", html)

    def test_assessment_actions_preserve_draft_only_editing(self):
        for status in ("DRAFT", "PUBLISHED", "RETIRED"):
            for change in (False, True):
                with self.subTest(status=status, change=change):
                    self.version.status = status
                    html = self.render("assessments/assessment_list.html",
                        {"assessments": {"change_assessment": change}},
                        version=self.version, assessments=[self.assessment])
                    self.assert_action(html, "assessments:assessment-detail", 51,
                        "View assessment: Safety assessment")
                    self.assert_action(html, "assessments:assessment-update", 51,
                        "Edit assessment: Safety assessment", change and status == "DRAFT")
                    self.assertEqual(Markup(html).row_header_links, [])

    def test_question_bank_actions_keep_edit_permission_gate(self):
        for change in (False, True):
            with self.subTest(change=change):
                html = self.render("assessments/question_list.html",
                    {"assessments": {"change_question": change}}, questions=[self.question])
                self.assert_action(html, "assessments:question-detail", 61, "View question: Q-61")
                self.assert_action(html, "assessments:question-update", 61,
                    "Edit question: Q-61", change)
                self.assertEqual(Markup(html).row_header_links, [])

    def test_valid_and_revoked_certificates_have_view_only_actions(self):
        for revoked in (None, timezone.now()):
            with self.subTest(revoked=revoked):
                self.certificate.revoked_at = revoked
                html = self.render("certifications/certificate_list.html", certificates=[self.certificate])
                self.assert_action(html, "certifications:certificate-detail", 71, "View certificate: CERT-71")
                self.assertEqual(Markup(html).row_header_links, [])
                self.assertNotIn("Revoke certificate", html)
                self.assertNotIn(">Edit</a>", html)

    def test_tables_retain_keyboard_regions_and_matching_action_columns(self):
        cases = (
            ("organization/employee_list.html", {"employees": [self.employee]}, 6),
            ("training/training_list.html", {"trainings": [self.training]}, 5),
            ("training/components/version_table.html", {"versions": [self.version]}, 5),
            ("certifications/certificate_list.html", {"certificates": [self.certificate]}, 6),
            ("assessments/assessment_list.html", {"version": self.version, "assessments": [self.assessment]}, 9),
            ("assessments/question_list.html", {"questions": [self.question]}, 6),
        )
        for name, context, count in cases:
            with self.subTest(template=name):
                parsed = Markup(self.render(name, **context))
                self.assertTrue(any(r.get("tabindex") == "0" and r.get("aria-label") for r in parsed.regions))
                self.assertEqual([len(row) for row in parsed.tables[0]], [count, count])
                self.assertEqual(parsed.tables[0][0][-1]["scope"], "col")

    def test_empty_table_rows_span_all_columns(self):
        for name, count in (("organization/employee_list.html", 6),
                            ("training/training_list.html", 5),
                            ("training/components/version_table.html", 5),
                            ("certifications/certificate_list.html", 6),
                            ("assessments/question_list.html", 6)):
            with self.subTest(template=name):
                parsed = Markup(self.render(name))
                self.assertEqual(parsed.tables[0][1][0]["colspan"], str(count))

    def test_employee_actions_only_reference_records_supplied_by_scoped_view(self):
        html = self.render("organization/employee_list.html", employees=[self.employee])
        self.assertNotIn(reverse("organization:employee-detail", args=[999]), html)
        self.assertNotIn(reverse("organization:employee-update", args=[21]), html)


class WebsiteLoginAndTitlesTests(SimpleTestCase):
    databases = set()

    def test_login_keeps_masking_csrf_redirect_and_existing_appearance_control(self):
        request = RequestFactory().get(reverse("accounts:login"))
        request.user = AnonymousUser()
        html = render_to_string("registration/login.html", {
            "form": AuthenticationForm(request), "next": "/assignments/",
        }, request=request)
        parsed = Markup(html)
        password = next(i for i in parsed.inputs if i.get("name") == "password")
        toggle = next(b for b in parsed.buttons if "data-password-toggle" in b)
        self.assertEqual(password["type"], "password")
        self.assertEqual(password["autocomplete"], "current-password")
        self.assertEqual(toggle["type"], "button")
        self.assertEqual(toggle["aria-controls"], password["id"])
        self.assertNotIn("aria-pressed", toggle)
        self.assertIn("hidden", toggle)
        self.assertIn("Show password</button>", html)
        self.assertIn('name="csrfmiddlewaretoken"', html)
        self.assertIn('name="next" value="/assignments/"', html)
        self.assertIn("accounts/password_toggle.js", html)
        self.assertEqual(html.count('class="appearance-control"'), 1)
        self.assertIn("System Default", html)
        self.assertIn("Light Mode", html)
        self.assertIn("Dark Mode", html)
        self.assertIn('type="submit">Sign in</button>', html)

    def title(self, name, context):
        template = get_template(name).template
        block = next(b for b in template.nodelist.get_nodes_by_type(BlockNode) if b.name == "title")
        return block.nodelist.render(Context(context))

    def test_dashboard_and_assignment_titles_follow_existing_role_context(self):
        for role, label in (("company", "Company dashboard"), ("manager", "Team dashboard"), ("employee", "Dashboard")):
            with self.subTest(role=role):
                self.assertEqual(self.title("reports/dashboard.html", {"role": role}), label + " | Garden's Need Training")
        for role, label in (("manager", "Team assignments"), ("employee", "My assignments"), ("company", "Training assignments")):
            with self.subTest(role=role):
                self.assertEqual(self.title("training/assignment_list.html", {"shell_role": role}), label + " | Garden's Need Training")

    def test_create_edit_and_record_titles_are_descriptive_and_escaped(self):
        cases = (
            ("organization/employee_form.html", {"form": SimpleNamespace(instance=SimpleNamespace(pk=None))}, "Add employee"),
            ("organization/employee_form.html", {"form": SimpleNamespace(instance=SimpleNamespace(pk=1, display_name="Alex <QA>"))}, "Edit employee: Alex &lt;QA&gt;"),
            ("training/version_detail.html", {"version": SimpleNamespace(title="Safety", version_number=2)}, "Safety | Version 2"),
            ("certifications/certificate_detail.html", {"certificate": SimpleNamespace(certificate_number="CERT-71", training_title_snapshot="Safety")}, "CERT-71 | Safety certificate"),
            ("assessments/attempt.html", {"attempt": SimpleNamespace(assessment=SimpleNamespace(title="Safety"), attempt_number=2)}, "Safety | Attempt 2"),
        )
        for name, context, expected in cases:
            with self.subTest(template=name, expected=expected):
                self.assertEqual(self.title(name, context), expected + " | Garden's Need Training")

    def test_custom_portal_pages_compile_and_have_explicit_title_blocks(self):
        root = Path(__file__).resolve().parents[1] / "templates"
        for path in root.rglob("*.html"):
            source = path.read_text(encoding="utf-8")
            if '{% extends "base.html" %}' in source:
                with self.subTest(template=path):
                    template = get_template(path.relative_to(root).as_posix()).template
                    self.assertTrue(any(b.name == "title" for b in template.nodelist.get_nodes_by_type(BlockNode)))
