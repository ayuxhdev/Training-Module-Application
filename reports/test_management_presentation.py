"""Batch 5 presentation checks. No database setup, writes, or bootstrap required."""

from datetime import date
from html.parser import HTMLParser
from types import SimpleNamespace

from django.contrib.auth.models import AnonymousUser
from django.forms.utils import ErrorDict
from django.template.loader import render_to_string
from django.test import RequestFactory, SimpleTestCase

from organization.forms import EmployeeDeactivateForm, EmployeeForm
from training.forms import TrainingVersionForm
from training.models import Training, TrainingAssignment, TrainingVersion

from .forms import AssignmentReportFilterForm


class Controls(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.fields = []
        self.in_form = False
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "form":
            self.in_form = True
        if self.in_form and tag in {"input", "select", "textarea"} and attrs.get("name"):
            if attrs["name"] != "csrfmiddlewaretoken":
                self.fields.append(attrs)

    def handle_endtag(self, tag):
        if tag == "form":
            self.in_form = False


class ManagementPresentationTests(SimpleTestCase):
    databases = set()

    def setUp(self):
        self.request = RequestFactory().get("/")
        self.request.user = AnonymousUser()
        self.permissions = {
            "organization": {
                "add_employee": True, "change_employee": True,
                "add_department": True, "change_department": True,
                "add_jobrole": True, "change_jobrole": True,
            },
        }

    def render(self, name, **context):
        return render_to_string(name, {"perms": self.permissions, **context}, request=self.request)

    def employee_form(self, *, edit=False):
        form = EmployeeForm(data={
            "employee_code": "QA-TEST", "display_name": "Garden Learner",
            "user": "7", "department": "1", "job_role": "1",
            "reporting_manager": "9", "date_joined": "2020-01-02",
        })
        # Render the real ModelForm without invoking database validation. Choice
        # labels stand in for server-provided querysets; business tests stay separate.
        for name in ("user", "department", "job_role", "reporting_manager"):
            field = form.fields[name]
            field.queryset = field.queryset.none()
            value = form.data[name]
            field.widget.choices = [("", "---------"), (value, "Selected " + name)]
        form._errors = ErrorDict()
        form.cleaned_data = {}
        if edit:
            form.instance.pk = 42
        return form

    def test_employee_create_and_edit_keep_field_order_values_csrf_and_sections(self):
        for edit in (False, True):
            with self.subTest(edit=edit):
                form = self.employee_form(edit=edit)
                html = self.render("organization/employee_form.html", form=form)
                self.assertEqual([field["name"] for field in Controls(html).fields], list(form.fields))
                for title in ("Identity and account", "Organization and reporting", "Employment details"):
                    self.assertIn(f"<legend>{title}</legend>", html)
                self.assertIn('name="csrfmiddlewaretoken"', html)
                self.assertIn('method="post"', html)
                self.assertIn('value="Garden Learner"', html)
                self.assertIn('value="2020-01-02"', html)
                self.assertIn('<option value="9" selected>', html)
                self.assertIn('for="id_display_name"', html)
                self.assertIn('<span class="visually-hidden"> (required)</span>', html)
                self.assertNotIn('name="is_active"', html)
                self.assertNotIn('name="deactivation_reason"', html)

    def test_field_and_summary_errors_remain_visible_and_associated(self):
        form = self.employee_form()
        form.fields["display_name"].help_text = "Use the employee's display name."
        form.add_error("display_name", "Enter the employee name.")
        form.add_error(None, "Please review the profile.")
        html = self.render("organization/employee_form.html", form=form)
        self.assertIn('role="alert"', html)
        self.assertIn("Enter the employee name.", html)
        self.assertIn("Please review the profile.", html)
        self.assertIn('aria-invalid="true"', html)
        self.assertIn('id="id_display_name_helptext"', html)
        control = next(field for field in Controls(html).fields if field["name"] == "display_name")
        self.assertEqual(set(control["aria-describedby"].split()),
                         {"id_display_name_helptext", "id_display_name_error"})
        self.assertIn('value="Garden Learner"', html)

    def test_version_editor_keeps_original_fields_in_order_and_draft_actions(self):
        version = TrainingVersion(
            pk=3, training=Training(pk=1, catalog_title="Safety"), version_number=2,
        )
        form = TrainingVersionForm(instance=version, data={
            "version_number": "2", "title": "Safety draft",
            "description": "Introduction", "learning_objectives": "Work safely",
            "change_summary": "Updated introduction",
        })
        form._errors = ErrorDict()
        html = self.render("training/version_form.html", form=form)
        self.assertEqual([field["name"] for field in Controls(html).fields], list(form.fields))
        for title in ("Version identity", "Learning content", "Revision notes"):
            self.assertIn(f"<legend>{title}</legend>", html)
        self.assertIn("Save draft", html)
        self.assertIn('name="csrfmiddlewaretoken"', html)
        self.assertNotIn('name="status"', html)
        self.assertNotIn('name="published_at"', html)

    def test_version_detail_keeps_published_and_retired_content_read_only(self):
        self.permissions["training"] = {"change_trainingversion": True, "add_module": True}
        for status in ("DRAFT", "PUBLISHED", "RETIRED"):
            with self.subTest(status=status):
                version = SimpleNamespace(
                    pk=3, training_id=1, training=SimpleNamespace(catalog_title="Safety"),
                    title="Safety", version_number=2, status=status, get_status_display=status,
                    modules=SimpleNamespace(all=lambda: []),
                )
                html = self.render("training/version_detail.html", version=version)
                if status == "DRAFT":
                    self.assertIn("Edit draft", html)
                    self.assertIn("Publish version", html)
                    self.assertIn("Add module", html)
                else:
                    self.assertNotIn("Edit draft", html)
                    self.assertNotIn("Publish version", html)
                    self.assertNotIn("Add module", html)
                    self.assertIn("Published and retired content cannot be edited.", html)

    def test_company_team_identity_and_overdue_counts_use_only_supplied_scope(self):
        metrics = dict(total=4, assigned=1, in_progress=1, completed=1, cancelled=1,
                       overdue=1, completion_percent=33.3)
        for role in ("company", "manager"):
            with self.subTest(role=role):
                html = self.render("reports/dashboard.html", role=role, metrics=metrics,
                                   active_employee_count=987654, department_count=2,
                                   published_training_count=3, certificates_issued=1,
                                   employees_in_scope=4, incomplete_employees=[], recent_attempts=[])
                self.assertIn(f"management-dashboard--{role}", html)
                self.assertIn("1 overdue assignment</span>", html)
                self.assertIn("33.3", html)
                if role == "manager":
                    self.assertIn("Team dashboard", html)
                    self.assertNotIn("Company dashboard", html)
                    self.assertNotIn("987654", html)
                else:
                    self.assertIn("Company dashboard", html)
                    self.assertIn("987654", html)
        metrics["overdue"] = 0
        html = self.render("reports/dashboard.html", role="manager", metrics=metrics)
        self.assertIn("0 overdue assignments</span>", html)
        self.assertNotIn('management-overdue-count is-overdue', html)

    def test_tables_keep_accessible_scroll_regions_columns_actions_and_escaping(self):
        employee = SimpleNamespace(pk=1, display_name="<unsafe>", employee_code="QA-1",
                                   department=SimpleNamespace(name="Operations"),
                                   job_role=SimpleNamespace(name="Operator"), reporting_manager=None,
                                   is_active=True)
        html = self.render("organization/employee_list.html", employees=[employee])
        self.assertIn('aria-describedby="employee-table-help"', html)
        self.assertIn('tabindex="0"', html)
        self.assertRegex(
            html,
            r'<div(?=[^>]*\bclass="[^"]*\borg-table-scroll\b)(?=[^>]*\brole="region")'
            r'(?=[^>]*\baria-label="Employees")(?=[^>]*\baria-describedby="employee-table-help")'
            r'(?=[^>]*\btabindex="0")[^>]*>',
        )
        self.assertIn("&lt;unsafe&gt;", html)
        self.assertEqual(html.count('scope="col"'), 5)
        item = SimpleNamespace(pk=1, code="OPS", name="Operations", description="Team", is_active=True)
        for title in ("Departments", "Job roles"):
            html = self.render("organization/reference_list.html", title=title, items=[item],
                               create_url="organization:department-create")
            self.assertIn('aria-describedby="reference-table-help"', html)
            self.assertIn('aria-label="Edit ', html)
            self.assertIn("management-table-region", html)
        self.permissions = {"organization": {}}
        html = self.render("organization/reference_list.html", title="Departments", items=[item])
        self.assertNotIn('aria-label="Edit department:', html)

    def test_report_keeps_all_columns_filters_and_scroll_description(self):
        form = AssignmentReportFilterForm(assignment_queryset=TrainingAssignment.objects.none())
        html = self.render("reports/assignment_report.html", role="manager", assignments=[], filter_form=form)
        self.assertEqual(html.count('scope="col"'), 11)
        self.assertIn('method="get"', html)
        self.assertIn("Apply filters", html)
        self.assertIn("Clear filters", html)
        self.assertIn('aria-describedby="report-table-help"', html)
        self.assertNotIn('id="report-table-help" aria-hidden="true"', html)
        self.assertEqual([field["name"] for field in Controls(html).fields], list(form.fields))

    def test_deactivation_reason_validation_and_presentation_are_preserved(self):
        for reason in ("", " " * 3, "x" * 1001):
            self.assertFalse(EmployeeDeactivateForm({"reason": reason}).is_valid())
        valid = EmployeeDeactivateForm({"reason": "  Employment ended  "})
        self.assertTrue(valid.is_valid())
        self.assertEqual(valid.cleaned_data["reason"], "Employment ended")
        employee = SimpleNamespace(pk=1, user_id=2, display_name="Learner", employee_code="QA-1",
                                   department=SimpleNamespace(name="Operations"),
                                   job_role=SimpleNamespace(name="Operator"), reporting_manager=None,
                                   date_joined=date(2020, 1, 2), is_active=True, user=None)
        html = self.render("organization/employee_detail.html", employee=employee,
                           user=SimpleNamespace(id=3, is_authenticated=False))
        self.assertIn('name="reason"', html)
        self.assertIn('maxlength="1000"', html)
        self.assertIn("Deactivate employee", html)
        self.permissions = {"organization": {}}
        html = self.render("organization/employee_detail.html", employee=employee)
        self.assertNotIn('name="reason"', html)
