from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.test import TestCase

from .models import Department, Employee, JobRole


class EmployeeDirectoryFilterTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        user_model = get_user_model()
        cls.department = Department.objects.create(code="DIR-A", name="Assembly")
        cls.other_department = Department.objects.create(code="DIR-B", name="Packing")
        cls.outside_department = Department.objects.create(code="DIR-X", name="Outside")
        cls.role = JobRole.objects.create(code="DIR-OP", name="Operator")
        cls.other_role = JobRole.objects.create(code="DIR-PK", name="Packer")
        cls.outside_role = JobRole.objects.create(code="DIR-OT", name="Outside role")
        cls.manager_user = user_model.objects.create_user(
            username="directory-manager",
            password="password",
        )
        cls.manager_user.user_permissions.add(
            Permission.objects.get(
                content_type__app_label="organization",
                codename="view_employee",
            )
        )
        manager_group, _ = Group.objects.get_or_create(name="Manager")
        cls.manager_user.groups.add(manager_group)
        cls.manager = Employee.objects.create(
            employee_code="DIR-MANAGER",
            display_name="Zoe Manager",
            user=cls.manager_user,
            department=cls.department,
            job_role=cls.role,
            date_joined="2026-01-01",
        )
        cls.ada = cls.employee(
            "DIR-001", "Ada Assembly", cls.department, cls.role, cls.manager
        )
        cls.inactive = Employee.objects.create(
            employee_code="DIR-002",
            display_name="Ben Packing",
            department=cls.other_department,
            job_role=cls.other_role,
            reporting_manager=cls.manager,
            date_joined="2026-01-01",
            is_active=False,
            deactivation_reason="Left employment",
        )
        cls.outside = cls.employee(
            "DIR-OUTSIDE",
            "Outside Person",
            cls.outside_department,
            cls.outside_role,
            None,
        )
        cls.unauthorized_user = user_model.objects.create_user(
            username="directory-no-permission",
            password="password",
        )
        cls.editor_user = user_model.objects.create_user(
            username="directory-editor",
            password="password",
        )
        cls.editor_user.user_permissions.add(*Permission.objects.filter(
            content_type__app_label="organization",
            codename__in=("view_employee", "change_employee", "add_employee"),
        ))

    @classmethod
    def employee(cls, code, name, department, role, manager):
        return Employee.objects.create(
            employee_code=code,
            display_name=name,
            department=department,
            job_role=role,
            reporting_manager=manager,
            date_joined="2026-01-01",
        )

    def get_as(self, user, query=""):
        self.client.force_login(user)
        return self.client.get(f"/employees/{query}")

    def ids(self, response):
        return {
            employee.pk
            for employee in response.context["employees"]
        }

    def test_search_matches_name_or_employee_code_and_empty_search_results(self):
        by_name = self.get_as(self.manager_user, "?q=Ada")
        self.assertEqual(by_name.status_code, 200)
        self.assertEqual(self.ids(by_name), {self.ada.pk})

        by_code = self.get_as(self.manager_user, "?q=DIR-001")
        self.assertEqual(self.ids(by_code), {self.ada.pk})

        no_match = self.get_as(self.manager_user, "?q=not-a-real-employee")
        self.assertEqual(no_match.status_code, 200)
        self.assertEqual(self.ids(no_match), set())
        self.assertContains(no_match, "No employees match the current filters.")
        self.assertContains(no_match, "Showing 0 employees.")

    def test_department_job_role_and_active_status_filters(self):
        department = self.get_as(
            self.manager_user,
            f"?department={self.other_department.pk}",
        )
        self.assertEqual(self.ids(department), {self.inactive.pk})

        role = self.get_as(self.manager_user, f"?job_role={self.other_role.pk}")
        self.assertEqual(self.ids(role), {self.inactive.pk})

        active = self.get_as(self.manager_user, "?status=active")
        self.assertIn(self.ada.pk, self.ids(active))
        self.assertNotIn(self.inactive.pk, self.ids(active))

        inactive = self.get_as(self.manager_user, "?status=inactive")
        self.assertEqual(self.ids(inactive), {self.inactive.pk})

    def test_combined_filters_and_invalid_values_fail_closed(self):
        combined = self.get_as(
            self.manager_user,
            f"?q=Ben&department={self.other_department.pk}"
            f"&job_role={self.other_role.pk}&status=inactive",
        )
        self.assertEqual(self.ids(combined), {self.inactive.pk})

        for query in (
            "?department=invalid",
            "?status=unknown",
            f"?department={self.outside_department.pk}",
            f"?q={'x' * 151}",
        ):
            with self.subTest(query=query):
                response = self.get_as(self.manager_user, query)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(self.ids(response), set())
                self.assertContains(response, "Please correct the highlighted filters.")
                self.assertNotIn(self.outside.pk, self.ids(response))

    def test_equal_names_use_employee_id_as_stable_tiebreaker(self):
        matching = [
            self.employee(
                f"DIR-SAME-{number}",
                "Same display name",
                self.department,
                self.role,
                self.manager,
            )
            for number in range(2)
        ]
        response = self.get_as(self.manager_user, "?q=Same+display+name")
        self.assertEqual(
            [employee.pk for employee in response.context["employees"]],
            sorted(employee.pk for employee in matching),
        )

    def test_pagination_is_bounded_stable_and_preserves_filters(self):
        paged = [
            self.employee(
                f"DIR-PAGE-{number:03}",
                f"Paged employee {number:03}",
                self.department,
                self.role,
                self.manager,
            )
            for number in range(51)
        ]
        expected = list(
            Employee.objects.filter(
                pk__in=[employee.pk for employee in paged] + [self.manager.pk, self.ada.pk],
            ).order_by("display_name", "pk").values_list("pk", flat=True)
        )
        query = f"?department={self.department.pk}&status=active"
        first_page = self.get_as(self.manager_user, query)
        self.assertEqual(first_page.context["paginator"].count, len(expected))
        self.assertEqual(len(first_page.context["employees"]), 50)
        self.assertEqual(
            [employee.pk for employee in first_page.context["employees"]],
            expected[:50],
        )
        self.assertContains(first_page, "Page 1 of 2")
        self.assertContains(
            first_page,
            f"?department={self.department.pk}&amp;status=active&amp;page=2",
        )

        second_page = self.get_as(self.manager_user, f"{query}&page=2")
        self.assertEqual(second_page.context["page_obj"].number, 2)
        self.assertEqual(
            [employee.pk for employee in second_page.context["employees"]],
            expected[50:],
        )
        self.assertContains(second_page, "Showing 51-53 of 53 employees.")

    def test_filter_submission_resets_page_and_clear_filters_removes_query(self):
        for number in range(51):
            self.employee(
                f"DIR-RESET-{number:03}",
                f"Reset employee {number:03}",
                self.department,
                self.role,
                self.manager,
            )
        response = self.get_as(
            self.manager_user,
            f"?page=2&status=active&department={self.department.pk}",
        )
        self.assertEqual(response.context["page_obj"].number, 2)
        changed_filters = self.get_as(self.manager_user, "?status=inactive")
        self.assertEqual(changed_filters.context["page_obj"].number, 1)
        self.assertNotContains(changed_filters, 'name="page"')
        self.assertContains(
            changed_filters,
            '<form method="get" action="/employees/"',
        )
        self.assertContains(
            changed_filters,
            '<a class="btn btn-secondary" href="/employees/">Clear filters</a>',
            html=True,
        )

    def test_invalid_page_values_are_handled_without_exposing_other_rows(self):
        for query in ("?page=invalid", "?page=-1", "?page=999999"):
            with self.subTest(query=query):
                response = self.get_as(self.manager_user, query)
                self.assertEqual(response.status_code, 404)

    def test_manager_scope_and_unauthorized_access_are_preserved(self):
        response = self.get_as(self.manager_user, "?q=Outside")
        self.assertEqual(self.ids(response), set())
        self.assertNotContains(response, self.outside.employee_code)
        self.assertNotIn(
            self.outside_department.pk,
            {
                choice.pk
                for choice in response.context["filter_form"].fields["department"].queryset
            },
        )

        no_permission = self.get_as(self.unauthorized_user)
        self.assertEqual(no_permission.status_code, 200)
        self.assertEqual(self.ids(no_permission), set())
        self.assertNotContains(no_permission, self.ada.employee_code)

        self.client.logout()
        unauthenticated = self.client.get("/employees/")
        self.assertEqual(unauthenticated.status_code, 302)

    def test_employee_detail_and_permission_gated_edit_operations_remain_available(self):
        listing = self.get_as(self.editor_user)
        self.assertContains(listing, "Add employee")
        self.assertContains(listing, f"/employees/{self.ada.pk}/edit/")
        self.assertEqual(self.client.get(f"/employees/{self.ada.pk}/").status_code, 200)
        self.assertEqual(self.client.get(f"/employees/{self.ada.pk}/edit/").status_code, 200)

        manager_listing = self.get_as(self.manager_user)
        self.assertNotContains(manager_listing, "Add employee")
        self.assertNotContains(manager_listing, f"/employees/{self.ada.pk}/edit/")

