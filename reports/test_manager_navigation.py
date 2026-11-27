"""Regression tests for Django Manager reports navigation and CSV export contract.

Validates management dashboard quick actions, scope headers, incomplete employee links,
assignment report breadcrumbs, header actions, and query-preserving CSV export.
Database-free tests using SimpleTestCase and template rendering.
"""

from django.template import loader
from django.test import SimpleTestCase
from django.urls import reverse


class _DummyRecord:
    """Lightweight duck-typed object supporting attribute and dict access for template rendering."""

    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)

    def __getitem__(self, item):
        return getattr(self, item)


def _make_dummy_user(pk=1, username="testmanager", full_name="Test Manager", is_superuser=False):
    return _DummyRecord(
        pk=pk,
        id=pk,
        username=username,
        is_authenticated=True,
        is_active=True,
        is_superuser=is_superuser,
        get_full_name=lambda: full_name,
        get_username=lambda: username,
    )


class DashboardNavigationTests(SimpleTestCase):
    """Database-free regression tests for templates/reports/dashboard.html."""

    def setUp(self):
        self.template = loader.get_template("reports/dashboard.html")
        self.default_metrics = {
            "overdue": 2,
            "total": 12,
            "completed": 6,
            "assigned": 3,
            "in_progress": 3,
            "completion_percent": 50.0,
        }

    def _render(self, context):
        defaults = {
            "role": "manager",
            "metrics": self.default_metrics,
            "employees_in_scope": 4,
            "certificates_issued": 2,
            "incomplete_employees": [],
            "perms": {"organization": {"view_employee": True}},
            "user": _make_dummy_user(),
        }
        defaults.update(context)
        return self.template.render(defaults)

    def test_manager_dashboard_quick_actions(self):
        html = self._render({
            "role": "manager",
            "perms": {"organization": {"view_employee": True}},
        })
        self.assertIn('<nav class="dashboard-quick-actions" aria-label="Management quick actions">', html)
        self.assertIn(f'href="{reverse("organization:employee-list")}"', html)
        self.assertIn("Employee directory", html)
        self.assertIn(f'href="{reverse("training:assignment-list")}"', html)
        self.assertIn("Team assignments", html)
        self.assertIn(f'href="{reverse("reports:assignment-report")}"', html)
        self.assertIn("Assignment report", html)

    def test_manager_dashboard_quick_actions_suppresses_employee_directory_without_permission(self):
        html = self._render({
            "role": "manager",
            "perms": {"organization": {"view_employee": False}},
        })
        self.assertIn('<nav class="dashboard-quick-actions" aria-label="Management quick actions">', html)
        self.assertNotIn(reverse("organization:employee-list"), html)
        self.assertIn(f'href="{reverse("training:assignment-list")}"', html)
        self.assertIn(f'href="{reverse("reports:assignment-report")}"', html)

    def test_company_admin_dashboard_scope_and_quick_actions(self):
        html = self._render({
            "role": "company",
            "active_employee_count": 50,
            "department_count": 8,
            "published_training_count": 15,
        })
        self.assertIn("Company workspace", html)
        self.assertIn("company-wide.", html)
        self.assertIn('<nav class="dashboard-quick-actions" aria-label="Management quick actions">', html)
        self.assertIn(f'href="{reverse("organization:employee-list")}"', html)
        self.assertIn(f'href="{reverse("training:assignment-list")}"', html)
        self.assertIn(f'href="{reverse("reports:assignment-report")}"', html)

    def test_manager_dashboard_scope_label_and_overdue_indicator(self):
        html = self._render({
            "role": "manager",
            "metrics": {"overdue": 3, "total": 10, "completed": 5, "assigned": 2, "in_progress": 3, "completion_percent": 50.0},
        })
        self.assertIn("Team workspace", html)
        self.assertIn("employees in your authorized reporting team.", html)
        self.assertIn("is-overdue", html)
        self.assertIn("3 overdue assignments", html)

    def test_manager_dashboard_incomplete_employees_list(self):
        incomplete = [
            _DummyRecord(
                pk=7,
                display_name="Charlie Chaplin",
                incomplete_assignment_count=2,
                overdue_assignment_count=1,
            )
        ]
        html = self._render({
            "role": "manager",
            "incomplete_employees": incomplete,
        })
        self.assertIn('id="incomplete-employees-heading"', html)
        self.assertIn("Employees with incomplete training", html)
        self.assertIn("Charlie Chaplin", html)
        self.assertIn("<dd>2</dd>", html)
        self.assertIn("<dd>1</dd>", html)
        emp_detail_url = reverse("organization:employee-detail", kwargs={"pk": 7})
        self.assertIn(f'href="{emp_detail_url}"', html)
        self.assertIn('aria-label="View employee: Charlie Chaplin"', html)

    def test_manager_dashboard_incomplete_employees_empty_state(self):
        html = self._render({
            "role": "manager",
            "incomplete_employees": [],
        })
        self.assertIn("No employees in your reporting scope currently have incomplete training.", html)

    def test_employee_dashboard_role_boundary(self):
        html = self._render({
            "role": "employee",
            "assigned_training": [],
            "in_progress_training": [],
            "certificates": [],
            "recent_attempts": [],
        })
        # Learner view must NOT render management workspace or quick actions
        self.assertNotIn("Team workspace", html)
        self.assertNotIn("Company workspace", html)
        self.assertNotIn("Management quick actions", html)
        self.assertNotIn(reverse("reports:assignment-report"), html)
        self.assertIn("My training", html)

    def test_unavailable_dashboard_role_boundary(self):
        html = self._render({
            "role": "unavailable",
        })
        self.assertIn("Dashboard unavailable", html)
        self.assertNotIn("Management quick actions", html)


class AssignmentReportNavigationTests(SimpleTestCase):
    """Database-free regression tests for templates/reports/assignment_report.html."""

    def setUp(self):
        self.template = loader.get_template("reports/assignment_report.html")

    def _render(self, context):
        defaults = {
            "role": "manager",
            "assignments": [],
            "filter_form": _DummyRecord(
                errors=None,
                non_field_errors=lambda: "",
                status=_DummyRecord(label_tag=lambda: "<label>Status</label>", errors=""),
                department=_DummyRecord(label_tag=lambda: "<label>Dept</label>", errors=""),
                job_role=_DummyRecord(label_tag=lambda: "<label>Role</label>", errors=""),
                training=_DummyRecord(label_tag=lambda: "<label>Training</label>", errors=""),
                training_version=_DummyRecord(label_tag=lambda: "<label>Version</label>", errors=""),
                overdue_only=_DummyRecord(label_tag=lambda: "<label>Overdue</label>", errors=""),
            ),
            "paginator": _DummyRecord(count=0, num_pages=1),
            "page_obj": _DummyRecord(start_index=0, end_index=0, number=1, has_other_pages=False),
            "user": _make_dummy_user(),
            "page_query": "",
            "export_limit_exceeded": False,
            "export_max_rows": 1000,
        }
        defaults.update(context)
        return self.template.render(defaults)

    def test_assignment_report_breadcrumbs(self):
        html = self._render({"role": "manager"})
        self.assertIn('<nav aria-label="Breadcrumb">', html)
        self.assertIn(f'<a href="{reverse("reports:dashboard")}">Dashboard</a>', html)
        self.assertIn('<li aria-current="page">Assignment report</li>', html)

    def test_assignment_report_header_actions(self):
        html = self._render({"role": "manager"})
        self.assertIn(f'href="{reverse("training:assignment-list")}"', html)
        self.assertIn("Team assignments", html)
        export_url = reverse("reports:assignment-report-export")
        self.assertIn(f'href="{export_url}"', html)
        self.assertIn("Download CSV", html)

    def test_assignment_report_csv_export_preserves_filter_query(self):
        html = self._render({
            "role": "manager",
            "page_query": "status=ASSIGNED&department=2",
        })
        export_url = reverse("reports:assignment-report-export")
        expected_export_href = f'{export_url}?status=ASSIGNED&amp;department=2'
        self.assertIn(f'href="{expected_export_href}"', html)

    def test_assignment_report_csv_export_without_query(self):
        html = self._render({
            "role": "manager",
            "page_query": "",
        })
        export_url = reverse("reports:assignment-report-export")
        # Should NOT contain ? after export_url
        self.assertIn(f'href="{export_url}"', html)
        self.assertNotIn(f'href="{export_url}?"', html)

    def test_assignment_report_export_limit_exceeded_alert(self):
        html = self._render({
            "role": "manager",
            "export_limit_exceeded": True,
            "export_max_rows": 500,
        })
        self.assertIn("This report contains more than 500 assignments, so no CSV was generated.", html)

    def test_assignment_report_scope_notice(self):
        html_mgr = self._render({"role": "manager"})
        self.assertIn("assignments for employees in your reporting team.", html_mgr)

        html_company = self._render({"role": "company"})
        self.assertIn("company-wide.", html_company)

    def test_assignment_report_empty_state(self):
        html = self._render({"assignments": []})
        self.assertIn("No assignments match the selected filters within your reporting scope.", html)
