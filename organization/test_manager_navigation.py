"""Regression tests for Django Manager organization navigation and role visibility.

Validates breadcrumbs, header actions, training oversight panels, and role boundaries
across employee list and employee detail templates.
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


def _make_dummy_employee(pk=1, display_name="John Doe", employee_code="EMP001", is_active=True, **kwargs):
    dept = kwargs.pop("department", _DummyRecord(name="Assembly"))
    role = kwargs.pop("job_role", _DummyRecord(name="Operator"))
    manager = kwargs.pop("reporting_manager", None)
    user = kwargs.pop("user", None)
    return _DummyRecord(
        pk=pk,
        display_name=display_name,
        employee_code=employee_code,
        is_active=is_active,
        department=dept,
        job_role=role,
        reporting_manager=manager,
        user=user,
        date_joined="2026-01-15",
        **kwargs,
    )


def _make_dummy_user(pk=1, username="testuser", full_name="Test User", is_superuser=False):
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


class EmployeeDirectoryNavigationTests(SimpleTestCase):
    """Database-free regression tests for templates/organization/employee_list.html."""

    def setUp(self):
        self.template = loader.get_template("organization/employee_list.html")
        self.default_employee = _make_dummy_employee(pk=42, display_name="Alice Smith", employee_code="EMP042")

    def _render(self, context):
        defaults = {
            "employees": [self.default_employee],
            "filter_form": [],
            "paginator": _DummyRecord(count=1, num_pages=1),
            "page_obj": _DummyRecord(start_index=1, end_index=1, number=1, has_other_pages=False),
            "user": _make_dummy_user(),
            "perms": {"organization": {"add_employee": False, "change_employee": False}},
            "shell_role": None,
        }
        defaults.update(context)
        return self.template.render(defaults)

    def test_employee_directory_breadcrumbs_render_dashboard_link_and_current_page(self):
        html = self._render({"shell_role": "manager"})
        self.assertIn('<nav aria-label="Breadcrumb">', html)
        self.assertIn(f'<a href="{reverse("reports:dashboard")}">Dashboard</a>', html)
        self.assertIn('<li aria-current="page">Employees</li>', html)

    def test_employee_directory_manager_header_actions(self):
        html = self._render({"shell_role": "manager"})
        self.assertIn(f'href="{reverse("training:assignment-list")}"', html)
        self.assertIn("Team assignments", html)
        self.assertIn(f'href="{reverse("reports:assignment-report")}"', html)
        self.assertIn("Assignment report", html)
        # Manager lacks add_employee permission; Add employee must not render
        self.assertNotIn(reverse("organization:employee-create"), html)

    def test_employee_directory_company_admin_header_actions(self):
        html = self._render({
            "shell_role": "company",
            "perms": {"organization": {"add_employee": True, "change_employee": True}},
        })
        self.assertIn(f'href="{reverse("training:assignment-list")}"', html)
        self.assertIn(f'href="{reverse("reports:assignment-report")}"', html)
        self.assertIn(f'href="{reverse("organization:employee-create")}"', html)
        self.assertIn("Add employee", html)

    def test_employee_directory_ordinary_employee_suppresses_management_links(self):
        html = self._render({"shell_role": "employee"})
        # Learner/employee role must not see manager links in header actions
        self.assertNotIn(f'href="{reverse("training:assignment-list")}"', html)
        self.assertNotIn(f'href="{reverse("reports:assignment-report")}"', html)
        self.assertNotIn(reverse("organization:employee-create"), html)

    def test_employee_directory_unknown_or_missing_role_fails_closed(self):
        html = self._render({"shell_role": None})
        self.assertNotIn(f'href="{reverse("training:assignment-list")}"', html)
        self.assertNotIn(f'href="{reverse("reports:assignment-report")}"', html)

    def test_employee_directory_empty_state(self):
        html = self._render({
            "employees": [],
            "paginator": _DummyRecord(count=0, num_pages=1),
            "page_obj": _DummyRecord(start_index=0, end_index=0, number=1, has_other_pages=False),
        })
        self.assertIn("No employees match the current filters.", html)

    def test_employee_directory_table_action_links(self):
        html = self._render({
            "employees": [self.default_employee],
            "perms": {"organization": {"change_employee": False}},
        })
        view_url = reverse("organization:employee-detail", kwargs={"pk": 42})
        self.assertIn(f'href="{view_url}"', html)
        self.assertIn('aria-label="View employee: Alice Smith (EMP042)"', html)
        # Without change_employee permission, Edit button must not render
        edit_url = reverse("organization:employee-update", kwargs={"pk": 42})
        self.assertNotIn(f'href="{edit_url}"', html)


class EmployeeDetailNavigationTests(SimpleTestCase):
    """Database-free regression tests for templates/organization/employee_detail.html."""

    def setUp(self):
        self.template = loader.get_template("organization/employee_detail.html")
        self.employee = _make_dummy_employee(
            pk=10,
            display_name="Bob Builder",
            employee_code="EMP010",
            reporting_manager=_DummyRecord(display_name="Sarah Supervisor"),
            user=_DummyRecord(is_active=True),
        )

    def _render(self, context):
        defaults = {
            "employee": self.employee,
            "user": _make_dummy_user(pk=99, username="current_user"),
            "perms": {"organization": {"change_employee": False}},
            "shell_role": None,
            "shell_can_view_certificates": False,
        }
        defaults.update(context)
        return self.template.render(defaults)

    def test_employee_detail_breadcrumbs_render_hierarchy(self):
        html = self._render({"shell_role": "manager"})
        self.assertIn('<nav aria-label="Breadcrumb">', html)
        self.assertIn(f'<a href="{reverse("reports:dashboard")}">Dashboard</a>', html)
        self.assertIn(f'<a href="{reverse("organization:employee-list")}">Employees</a>', html)
        self.assertIn('<li aria-current="page">Bob Builder</li>', html)

    def test_employee_detail_header_actions_for_manager(self):
        html = self._render({"shell_role": "manager"})
        self.assertIn(f'href="{reverse("organization:employee-list")}"', html)
        self.assertIn("Back to employees", html)
        self.assertIn(f'href="{reverse("training:assignment-list")}"', html)
        self.assertIn("Team assignments", html)
        # Without change_employee permission, Edit employee button must not render
        edit_url = reverse("organization:employee-update", kwargs={"pk": 10})
        self.assertNotIn(f'href="{edit_url}"', html)

    def test_employee_detail_training_oversight_section_for_manager(self):
        html = self._render({
            "shell_role": "manager",
            "shell_can_view_certificates": True,
        })
        self.assertIn('id="employee-training-nav-heading"', html)
        self.assertIn("Training &amp; assignments", html)
        self.assertIn(f'href="{reverse("training:assignment-list")}"', html)
        self.assertIn("View team assignments", html)
        self.assertIn(f'href="{reverse("reports:assignment-report")}"', html)
        self.assertIn("View assignment report", html)
        self.assertIn(f'href="{reverse("certifications:certificate-list")}"', html)
        self.assertIn("View certificates", html)

    def test_employee_detail_training_oversight_suppresses_certificates_without_perm(self):
        html = self._render({
            "shell_role": "manager",
            "shell_can_view_certificates": False,
        })
        self.assertIn("View team assignments", html)
        self.assertIn("View assignment report", html)
        self.assertNotIn(reverse("certifications:certificate-list"), html)

    def test_employee_detail_ordinary_employee_suppresses_training_oversight(self):
        html = self._render({"shell_role": "employee"})
        self.assertNotIn('id="employee-training-nav-heading"', html)
        self.assertNotIn("View team assignments", html)
        self.assertNotIn("View assignment report", html)
        # Header actions must not include Team assignments for learner role
        self.assertNotIn(f'href="{reverse("training:assignment-list")}"', html)

    def test_employee_detail_manager_cannot_see_deactivation_controls(self):
        html = self._render({
            "shell_role": "manager",
            "perms": {"organization": {"change_employee": False}},
        })
        self.assertNotIn('id="employee-deactivation-heading"', html)
        self.assertNotIn(reverse("organization:employee-deactivate", kwargs={"pk": 10}), html)

    def test_employee_detail_admin_sees_edit_and_deactivation_controls(self):
        html = self._render({
            "shell_role": "company",
            "perms": {"organization": {"change_employee": True}},
        })
        edit_url = reverse("organization:employee-update", kwargs={"pk": 10})
        deact_url = reverse("organization:employee-deactivate", kwargs={"pk": 10})
        self.assertIn(f'href="{edit_url}"', html)
        self.assertIn("Edit employee", html)
        self.assertIn('id="employee-deactivation-heading"', html)
        self.assertIn(f'action="{deact_url}"', html)

    def test_employee_detail_missing_optional_context_handling(self):
        sparse_employee = _make_dummy_employee(
            pk=11,
            display_name="No Manager",
            reporting_manager=None,
            user=None,
        )
        html = self._render({
            "employee": sparse_employee,
            "shell_role": None,
        })
        self.assertIn("Not assigned", html)
        self.assertIn("Not linked", html)
        self.assertNotIn("View team assignments", html)
