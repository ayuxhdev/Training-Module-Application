"""Website personal training stays independent of management scope."""

from html.parser import HTMLParser
from types import SimpleNamespace
from unittest.mock import Mock, patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import PermissionDenied
from django.test import Client, SimpleTestCase
from django.urls import reverse
from django.utils import timezone

from config.model_test_utils import CurriculumTestCase
from organization.models import Employee
from training.models import TrainingAssignment
from training.views import TrainingAssignmentListView

from .queries import dashboard_role


class NavigationLinks(HTMLParser):
    def __init__(self, response):
        super().__init__()
        self.links = {}
        self.current = None
        self.feed(response.content.decode())

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "a" and "nav-link" in attrs.get("class", "").split():
            self.current = (attrs, [])

    def handle_data(self, data):
        if self.current is not None:
            self.current[1].append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self.current is not None:
            attrs, text = self.current
            self.links["".join(text).strip()] = attrs
            self.current = None


class AssignmentListIdentityGateTests(SimpleTestCase):
    """Exercise the real list queryset gate without opening any database."""

    def view_for(self, roles, *, company=False, personal=False):
        user = Mock(is_superuser=False)
        user.has_perm.return_value = company
        user.groups.filter.side_effect = lambda **filters: Mock(
            exists=Mock(return_value=filters.get("name") in roles),
        )
        view = TrainingAssignmentListView()
        view.request = SimpleNamespace(user=user, GET={"scope": "mine"} if personal else {})
        return view

    def test_default_and_explicit_personal_lists_reject_missing_active_identity(self):
        for role in ("Employee", "Trainer", "Supervisor"):
            for personal in (False, True):
                with self.subTest(role=role, personal=personal):
                    view = self.view_for({role}, personal=personal)
                    with patch("training.views.has_active_learner_identity", return_value=False), \
                            patch("training.views.assignment_scope") as scope, \
                            patch("training.views.TrainingAssignment.objects.select_related") as assignments:
                        with self.assertRaises(PermissionDenied):
                            view.get_queryset()
                        scope.assert_not_called()
                        assignments.assert_not_called()

    def test_default_management_scope_does_not_require_personal_identity(self):
        for roles, company in (({"Manager"}, False), ({"Administrator"}, True),
                               ({"Manager", "Employee"}, True)):
            with self.subTest(roles=roles, company=company):
                view = self.view_for(roles, company=company)
                with patch("training.views.has_active_learner_identity", return_value=False) as identity, \
                        patch("training.views.assignment_scope") as scope, \
                        patch("training.views.TrainingAssignment.objects.select_related") as assignments, \
                        patch("training.views._with_assignment_overdue", side_effect=lambda queryset: queryset):
                    result = view.get_queryset()
                    scope.assert_called_once_with(view.request.user)
                    identity.assert_not_called()
                    queryset = assignments.return_value
                    queryset.filter.assert_called_once_with(employee__in=scope.return_value)
                    self.assertIs(result, queryset.filter.return_value.order_by.return_value)
                view.request.GET = {"scope": "mine"}
                with patch("training.views.has_active_learner_identity", return_value=False):
                    with self.assertRaises(PermissionDenied):
                        view.get_queryset()

    def test_personal_lists_use_only_the_active_authenticated_employee(self):
        for roles, company, personal in (({"Employee"}, False, False),
                                          ({"Trainer"}, False, False),
                                          ({"Supervisor"}, False, False),
                                          ({"Manager", "Employee"}, False, True),
                                          ({"Administrator"}, True, True)):
            with self.subTest(roles=roles, personal=personal):
                view = self.view_for(roles, company=company, personal=personal)
                with patch("training.views.has_active_learner_identity", return_value=True) as identity, \
                        patch("training.views.Employee.objects.filter") as employees, \
                        patch("training.views.assignment_scope") as scope, \
                        patch("training.views.TrainingAssignment.objects.select_related") as assignments, \
                        patch("training.views._with_assignment_overdue", side_effect=lambda queryset: queryset):
                    view.get_queryset()
                    identity.assert_called_once_with(view.request.user)
                    employees.assert_called_once_with(user=view.request.user, is_active=True)
                    assignments.return_value.filter.assert_called_once_with(employee__in=employees.return_value)
                    scope.assert_not_called()


class LearnerParityTests(CurriculumTestCase):
    def role_user(self, role, linked=True):
        user = get_user_model().objects.create_user(username=f"parity-{role}")
        user.groups.add(Group.objects.get(name=role))
        employee = None
        if linked:
            employee = Employee.objects.create(
                employee_code=f"P-{role}", display_name=f"QA {role}",
                user=user, department=self.department, job_role=self.role,
                date_joined=timezone.localdate(),
            )
        return user, employee

    def assignment_for(self, employee):
        return TrainingAssignment.objects.create(
            employee=employee, training_version=self.version,
            department_at_assignment=employee.department,
            job_role_at_assignment=employee.job_role,
            assigned_by=self.user, assigned_at=self.now,
        )

    def client_for(self, user):
        client = Client()
        client.force_login(user)
        return client

    def list_ids(self, response):
        self.assertEqual(response.status_code, 200)
        return {assignment.pk for assignment in response.context["assignments"]}

    def test_trainer_and_supervisor_get_self_scoped_dashboard_and_assignment_access(self):
        for role in ("Trainer", "Supervisor"):
            with self.subTest(role=role):
                user, employee = self.role_user(role)
                own = self.assignment_for(employee)
                client = self.client_for(user)
                dashboard = client.get(reverse("reports:dashboard"))
                self.assertEqual(dashboard.context["role"], "employee")
                self.assertEqual(dashboard.context["metrics"]["total"], 1)
                self.assertFalse(dashboard.context["can_view_report"])
                listing = client.get(reverse("training:assignment-list"))
                self.assertEqual(self.list_ids(listing), {own.pk})
                self.assertContains(listing, "My assignments")
                detail = client.get(reverse("training:assignment-detail", args=[own.pk]))
                self.assertEqual(detail.status_code, 200)
                self.assertTrue(detail.context["can_learn"])
                foreign = client.get(reverse("training:assignment-detail", args=[self.assignment.pk]))
                self.assertEqual(foreign.status_code, 404)
                self.assertEqual(client.get(reverse("training:assignment-create")).status_code, 403)
                self.assertEqual(client.get(reverse("reports:assignment-report")).status_code, 403)

    def test_trainer_and_supervisor_without_employee_have_no_learner_access(self):
        for role in ("Trainer", "Supervisor"):
            with self.subTest(role=role):
                user, _ = self.role_user(role, linked=False)
                client = self.client_for(user)
                dashboard = client.get(reverse("reports:dashboard"))
                self.assertEqual(dashboard.context["role"], "unavailable")
                self.assertNotIn("My training", NavigationLinks(dashboard).links)
                self.assertEqual(client.get(reverse("training:assignment-list")).status_code, 403)

    def test_inactive_employee_is_rejected_even_with_active_login(self):
        for role in ("Employee", "Trainer", "Supervisor", "Manager"):
            with self.subTest(role=role):
                user, employee = self.role_user(role)
                employee.is_active = False
                employee.deactivation_reason = "QA fixture"
                employee.save()
                # Exercise Employee eligibility independently of inactive User rejection.
                user.is_active = True
                user.save(update_fields=["is_active"])
                client = self.client_for(user)
                dashboard = client.get(reverse("reports:dashboard"))
                self.assertEqual(dashboard.context["role"], "unavailable")
                self.assertNotIn("My training", NavigationLinks(dashboard).links)
                response = client.get(reverse("training:assignment-list"), {"scope": "mine"})
                self.assertEqual(response.status_code, 403)
                if role != "Manager":
                    self.assertEqual(client.get(reverse("training:assignment-list")).status_code, 403)

    def test_unlinked_employee_is_denied_instead_of_receiving_an_empty_list(self):
        user, _ = self.role_user("Employee", linked=False)
        client = self.client_for(user)
        url = reverse("training:assignment-list")
        for params in ({}, {"scope": "mine"}, {"scope": "all", "employee": self.employee.pk}):
            with self.subTest(params=params):
                self.assertEqual(client.get(url, params).status_code, 403)
        self.assertEqual(client.get(reverse("training:assignment-detail", args=[self.assignment.pk])).status_code, 404)

    def test_inactive_manager_preserves_team_read_scope_but_cannot_learn(self):
        user, manager = self.role_user("Manager")
        user.groups.add(Group.objects.get(name="Employee"), Group.objects.get(name="Trainer"))
        own = self.assignment_for(manager)
        self.employee.reporting_manager = manager
        self.employee.save()
        _, outsider = self.role_user("Employee")
        foreign = self.assignment_for(outsider)
        manager.is_active = False
        manager.deactivation_reason = "QA fixture"
        manager.save()
        user.is_active = True
        user.save(update_fields=["is_active"])
        self.assertTrue(get_user_model().objects.get(pk=user.pk).is_active)
        self.assertFalse(Employee.objects.get(pk=manager.pk).is_active)
        client = self.client_for(user)
        url = reverse("training:assignment-list")
        team = client.get(url, {"employee": outsider.pk})
        self.assertEqual(self.list_ids(team), {own.pk, self.assignment.pk})
        self.assertFalse(team.context["personal_assignments"])
        self.assertEqual(client.get(url, {"scope": "mine"}).status_code, 403)
        own_detail = client.get(reverse("training:assignment-detail", args=[own.pk]))
        self.assertEqual(own_detail.status_code, 200)
        self.assertFalse(own_detail.context.get("can_learn", False))
        self.assertEqual(client.get(reverse("training:assignment-detail", args=[foreign.pk])).status_code, 404)

    def test_company_assignment_authority_is_independent_of_learner_activity(self):
        permission = Permission.objects.get(
            content_type__app_label="training", codename="add_trainingassignment",
        )
        for role in ("Administrator", "Training Coordinator", "Manager"):
            with self.subTest(role=role):
                user, employee = self.role_user(role)
                if role == "Manager":
                    user.user_permissions.add(permission)
                own = self.assignment_for(employee)
                employee.is_active = False
                employee.deactivation_reason = "QA fixture"
                employee.save()
                user.is_active = True
                user.save(update_fields=["is_active"])
                self.assertTrue(get_user_model().objects.get(pk=user.pk).is_active)
                self.assertFalse(Employee.objects.get(pk=employee.pk).is_active)
                client = self.client_for(user)
                url = reverse("training:assignment-list")
                listing = client.get(url)
                self.assertEqual(self.list_ids(listing), set(TrainingAssignment.objects.values_list("pk", flat=True)))
                self.assertFalse(listing.context["personal_assignments"])
                self.assertEqual(client.get(url, {"scope": "mine"}).status_code, 403)
                detail = client.get(reverse("training:assignment-detail", args=[own.pk]))
                self.assertEqual(detail.status_code, 200)
                self.assertFalse(detail.context.get("can_learn", False))

    def test_inactive_user_and_anonymous_have_no_learner_access(self):
        user, _ = self.role_user("Trainer")
        user.is_active = False
        user.save(update_fields=["is_active"])
        self.assertIsNone(dashboard_role(user))
        for client in (Client(), self.client_for(user)):
            self.assertEqual(client.get(reverse("training:assignment-list")).status_code, 403)

    def test_manager_personal_and_team_scopes_remain_separate(self):
        user, manager = self.role_user("Manager")
        user.groups.add(Group.objects.get(name="Employee"), Group.objects.get(name="Trainer"),
                        Group.objects.get(name="Supervisor"))
        own = self.assignment_for(manager)
        self.employee.reporting_manager = manager
        self.employee.save()
        _, outsider = self.role_user("Employee")
        outsider_assignment = self.assignment_for(outsider)
        client = self.client_for(user)
        url = reverse("training:assignment-list")
        personal = client.get(url, {"scope": "mine", "employee": self.employee.pk})
        self.assertEqual(self.list_ids(personal), {own.pk})
        self.assertTrue(personal.context["personal_assignments"])
        self.assertFalse(personal.context["can_assign_training"])
        self.assertContains(personal, "Your training assignments")
        team = client.get(url)
        self.assertEqual(self.list_ids(team), {own.pk, self.assignment.pk})
        self.assertFalse(team.context["personal_assignments"])
        self.assertContains(team, "Team assignments")
        foreign = client.get(reverse("training:assignment-detail", args=[outsider_assignment.pk]))
        self.assertEqual(foreign.status_code, 404)
        team_detail = client.get(reverse("training:assignment-detail", args=[self.assignment.pk]))
        self.assertEqual(team_detail.status_code, 200)
        self.assertFalse(team_detail.context.get("can_learn", False))

    def test_manager_navigation_distinguishes_personal_and_team_pages(self):
        user, manager = self.role_user("Manager")
        own = self.assignment_for(manager)
        client = self.client_for(user)
        url = reverse("training:assignment-list")
        personal = NavigationLinks(client.get(url, {"scope": "mine"})).links
        self.assertEqual(personal["My training"]["href"], f"{url}?scope=mine")
        self.assertEqual(personal["My training"].get("aria-current"), "page")
        self.assertNotIn("aria-current", personal["Assignments"])
        team = NavigationLinks(client.get(url)).links
        self.assertEqual(team["Assignments"]["href"], url)
        self.assertEqual(team["Assignments"].get("aria-current"), "page")
        self.assertNotIn("aria-current", team["My training"])
        own_detail = NavigationLinks(client.get(reverse("training:assignment-detail", args=[own.pk]))).links
        self.assertEqual(own_detail["My training"].get("aria-current"), "page")
        self.assertNotIn("aria-current", own_detail["Assignments"])

    def test_management_dashboard_priority_survives_mixed_roles(self):
        for role, expected in (("Administrator", "company"), ("Training Coordinator", "company"), ("Manager", "manager")):
            with self.subTest(role=role):
                user, _ = self.role_user(role)
                user.groups.add(Group.objects.get(name="Trainer"), Group.objects.get(name="Supervisor"))
                self.assertEqual(dashboard_role(user), expected)

    def test_company_personal_view_does_not_change_default_management_access(self):
        user, employee = self.role_user("Administrator")
        own = self.assignment_for(employee)
        client = self.client_for(user)
        url = reverse("training:assignment-list")
        self.assertEqual(self.list_ids(client.get(url, {"scope": "mine"})), {own.pk})
        self.assertEqual(self.list_ids(client.get(url)), {own.pk, self.assignment.pk})
        dashboard = client.get(reverse("reports:dashboard"))
        self.assertEqual(dashboard.context["role"], "company")
        links = NavigationLinks(dashboard).links
        self.assertIn("My training", links)
        self.assertIn("Assignments", links)

    def test_company_without_employee_keeps_management_not_personal_access(self):
        user, _ = self.role_user("Administrator", linked=False)
        client = self.client_for(user)
        dashboard = client.get(reverse("reports:dashboard"))
        self.assertEqual(dashboard.context["role"], "company")
        self.assertNotIn("My training", NavigationLinks(dashboard).links)
        url = reverse("training:assignment-list")
        self.assertEqual(self.list_ids(client.get(url)), {self.assignment.pk})
        self.assertEqual(client.get(url, {"scope": "mine"}).status_code, 403)

    def test_employee_existing_url_and_self_scope_remain_unchanged(self):
        self.employee_user.groups.add(Group.objects.get(name="Employee"))
        client = self.client_for(self.employee_user)
        response = client.get(reverse("training:assignment-list"))
        self.assertEqual(self.list_ids(response), {self.assignment.pk})
        links = NavigationLinks(response).links
        self.assertEqual(links["My training"]["href"], reverse("training:assignment-list"))
        self.assertEqual(links["My training"].get("aria-current"), "page")
        self.assertNotIn("Assignments", links)
        _, outsider = self.role_user("Employee")
        foreign = self.assignment_for(outsider)
        filtered = client.get(reverse("training:assignment-list"), {"employee": outsider.pk, "scope": "all"})
        self.assertEqual(self.list_ids(filtered), {self.assignment.pk})
        self.assertEqual(client.get(reverse("training:assignment-detail", args=[foreign.pk])).status_code, 404)

    def test_forged_filter_parameters_cannot_expand_learner_scope_or_mutate_assignment(self):
        user, employee = self.role_user("Trainer")
        own = self.assignment_for(employee)
        client = self.client_for(user)
        for scope in ("mine", "team", "all", str(self.employee.pk)):
            with self.subTest(scope=scope):
                response = client.get(reverse("training:assignment-list"), {
                    "scope": scope, "employee": self.employee.pk,
                })
                self.assertEqual(self.list_ids(response), {own.pk})
        own.refresh_from_db()
        self.assertEqual(own.training_version_id, self.version.pk)
        self.assertEqual(own.status, TrainingAssignment.Status.ASSIGNED)

    def test_unlinked_unprivileged_user_does_not_gain_learner_navigation(self):
        user = get_user_model().objects.create_user(username="parity-unlinked")
        client = self.client_for(user)
        dashboard = client.get(reverse("reports:dashboard"))
        self.assertEqual(dashboard.context["role"], "unavailable")
        self.assertNotIn("My training", NavigationLinks(dashboard).links)
        self.assertEqual(client.get(reverse("training:assignment-list")).status_code, 403)
