"""Team assignment permission isolation; fixtures live only in Django's test DB."""

from importlib import import_module
from types import SimpleNamespace

from django.apps import apps
from django.contrib.auth import get_user_model
from django.contrib.auth.models import AnonymousUser, Group, Permission
from django.db import connection
from django.test import TestCase
from django.utils import timezone

from api.capabilities import mobile_capabilities
from organization.models import Department, Employee, JobRole
from organization.scopes import employee_scope
from organization.views import employee_scope as legacy_employee_scope
from reports.queries import dashboard_role
from training.models import TrainingAssignment
from training.permissions import (
    COMPANY_ASSIGNMENT_PERMISSION,
    TEAM_ASSIGNMENT_PERMISSION,
    assignable_employees,
    can_assign_company_training,
    can_assign_team_training,
)
from training.views import assignment_scope, can_manage_assignments


class TeamAssignmentPermissionTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.department = Department.objects.create(code="TEAM", name="Team permission QA")
        cls.job_role = JobRole.objects.create(code="TEAM", name="Training participant")
        cls.superior = cls.employee("superior")
        cls.manager = cls.employee("manager", manager=cls.superior, groups=("Manager",))
        cls.direct = cls.employee("direct", manager=cls.manager, groups=("Employee",))
        cls.indirect = cls.employee("indirect", manager=cls.direct, groups=("Employee",))
        cls.peer = cls.employee("peer", manager=cls.superior, groups=("Manager",))
        cls.peer_report = cls.employee("peer-report", manager=cls.peer)
        cls.unrelated = cls.employee("unrelated", groups=("Manager",))
        cls.foreign = cls.employee("foreign", manager=cls.unrelated)
        cls.inactive = cls.employee("inactive-report", manager=cls.manager, active=False)
        cls.active_under_inactive = cls.employee("active-under-inactive", manager=cls.inactive)

    @classmethod
    def employee(cls, name, *, manager=None, groups=(), active=True):
        user = get_user_model().objects.create_user(username=name)
        user.groups.add(*Group.objects.filter(name__in=groups))
        return Employee.objects.create(
            employee_code=name.upper(), display_name=name, user=user,
            department=cls.department, job_role=cls.job_role,
            reporting_manager=manager, date_joined=timezone.now().date(),
            is_active=active, deactivation_reason="Isolated fixture" if not active else "",
        )

    def user(self, employee):
        # Reload per test so Django's permission cache cannot conceal grant changes.
        return get_user_model().objects.get(pk=employee.user_id)

    def ids(self, user):
        return set(assignable_employees(user).values_list("pk", flat=True))

    def test_migration_registers_exact_custom_permission_and_grants_only_manager(self):
        permission = Permission.objects.get(
            content_type__app_label="training", content_type__model="trainingassignment",
            codename="assign_team_trainingassignment",
        )
        self.assertEqual(permission.name, "Can assign training to reporting hierarchy")
        self.assertIn((permission.codename, permission.name), TrainingAssignment._meta.permissions)
        self.assertEqual(set(permission.group_set.values_list("name", flat=True)), {"Manager"})
        manager = self.user(self.manager)
        self.assertTrue(manager.has_perm(TEAM_ASSIGNMENT_PERMISSION))
        self.assertFalse(manager.has_perm(COMPANY_ASSIGNMENT_PERMISSION))

    def test_administrator_and_coordinator_keep_existing_global_grants(self):
        for name in ("Administrator", "Training Coordinator"):
            with self.subTest(group=name):
                user = get_user_model().objects.create_user(username=name)
                user.groups.add(Group.objects.get(name=name))
                self.assertTrue(can_assign_company_training(user))
                self.assertTrue(can_manage_assignments(user))
                self.assertEqual(dashboard_role(user), "company")
                self.assertIn(self.foreign.pk, self.ids(user))
                self.assertNotIn(self.inactive.pk, self.ids(user))
                caps = mobile_capabilities(user)
                self.assertIn("company_dashboard", caps)
                self.assertIn("management_workspace", caps)
                self.assertIn(COMPANY_ASSIGNMENT_PERMISSION, caps)

    def test_active_direct_and_indirect_subordinates_are_assignable(self):
        self.assertEqual(self.ids(self.user(self.manager)), {
            self.direct.pk, self.indirect.pk, self.active_under_inactive.pk,
        })

    def test_manager_self_peers_superior_and_foreign_hierarchies_are_excluded(self):
        recipients = self.ids(self.user(self.manager))
        self.assertTrue(recipients.isdisjoint({
            self.manager.pk, self.superior.pk, self.peer.pk,
            self.peer_report.pk, self.unrelated.pk, self.foreign.pk, self.inactive.pk,
        }))

    def test_traversal_keeps_active_indirect_reports_below_inactive_intermediates(self):
        recipients = self.ids(self.user(self.manager))
        self.assertNotIn(self.inactive.pk, recipients)
        self.assertIn(self.active_under_inactive.pk, recipients)

    def test_inactive_user_cannot_exercise_team_authority_or_capability(self):
        user = self.user(self.manager)
        user.is_active = False
        user.save(update_fields=["is_active"])
        self.assertFalse(can_assign_team_training(user))
        self.assertEqual(self.ids(user), set())
        self.assertNotIn("team_assignment", mobile_capabilities(user))

    def test_inactive_employee_cannot_use_team_rights_even_if_login_was_reenabled(self):
        user = self.user(self.manager)
        # Populate the relation cache before deactivation to verify a fresh gate.
        self.assertTrue(user.employee.is_active)
        self.manager.is_active = False
        self.manager.deactivation_reason = "Isolated deactivation"
        self.manager.save()
        user.is_active = True
        user.save(update_fields=["is_active"])
        self.assertTrue(user.employee.is_active)
        self.assertFalse(can_assign_team_training(user))
        self.assertEqual(self.ids(user), set())
        self.assertNotIn("team_assignment", mobile_capabilities(user))

    def test_manager_without_linked_employee_has_no_team_authority(self):
        user = get_user_model().objects.create_user(username="manager-no-profile")
        user.groups.add(Group.objects.get(name="Manager"))
        self.assertFalse(can_assign_team_training(user))
        self.assertEqual(self.ids(user), set())
        self.assertNotIn("team_assignment", mobile_capabilities(user))
        self.assertNotIn("company_dashboard", mobile_capabilities(user))

    def test_regular_employee_trainer_and_supervisor_gain_no_assignment_rights(self):
        for name in ("Employee", "Trainer", "Supervisor"):
            with self.subTest(group=name):
                employee = self.employee("role-" + name.lower(), groups=(name,))
                user = self.user(employee)
                self.assertFalse(can_assign_team_training(user))
                self.assertFalse(can_assign_company_training(user))
                self.assertEqual(self.ids(user), set())
                self.assertNotIn("team_assignment", mobile_capabilities(user))

    def test_manager_group_without_effective_permission_is_not_authority(self):
        permission = Permission.objects.get(
            content_type__app_label="training", codename="assign_team_trainingassignment",
        )
        Group.objects.get(name="Manager").permissions.remove(permission)
        user = self.user(self.manager)
        self.assertFalse(can_assign_team_training(user))
        self.assertEqual(self.ids(user), set())
        self.assertNotIn("team_assignment", mobile_capabilities(user))

    def test_permission_alone_does_not_invent_a_non_manager_hierarchy(self):
        user = self.user(self.direct)
        user.user_permissions.add(Permission.objects.get(
            content_type__app_label="training", codename="assign_team_trainingassignment",
        ))
        self.assertTrue(user.has_perm(TEAM_ASSIGNMENT_PERMISSION))
        self.assertFalse(can_assign_team_training(user))
        self.assertEqual(self.ids(user), set())
        self.assertNotIn("team_assignment", mobile_capabilities(user))

    def test_manager_team_capability_does_not_grant_company_or_curriculum_access(self):
        user = self.user(self.manager)
        caps = mobile_capabilities(user)
        self.assertIn("team_assignment", caps)
        self.assertIn("team_workspace", caps)
        self.assertIn("personal_learning", caps)
        self.assertEqual(caps, sorted(set(caps)))
        for denied in ("company_dashboard", "management_workspace", COMPANY_ASSIGNMENT_PERMISSION,
                       "training.change_trainingversion", "training.add_lesson"):
            self.assertNotIn(denied, caps)
        self.assertFalse(can_manage_assignments(user))
        self.assertEqual(dashboard_role(user), "manager")

    def test_existing_explicit_global_grant_still_takes_precedence(self):
        user = self.user(self.manager)
        user.user_permissions.add(Permission.objects.get(
            content_type__app_label="training", codename="add_trainingassignment",
        ))
        self.assertTrue(can_assign_company_training(user))
        self.assertTrue(can_assign_team_training(user))
        self.assertIn(self.manager.pk, self.ids(user))
        self.assertIn(self.foreign.pk, self.ids(user))
        self.assertEqual(dashboard_role(user), "company")
        self.assertIn("company_dashboard", mobile_capabilities(user))

    def test_old_read_scope_preserves_self_and_inactive_members(self):
        user = self.user(self.manager)
        self.assertIs(legacy_employee_scope, employee_scope)
        self.assertIn(self.manager.pk, employee_scope(user).values_list("pk", flat=True))
        self.assertIn(self.inactive.pk, assignment_scope(user).values_list("pk", flat=True))
        self.assertNotIn(self.foreign.pk, assignment_scope(user).values_list("pk", flat=True))

    def test_team_permission_does_not_enable_company_wide_assignment_configuration(self):
        self.client.force_login(self.user(self.manager))
        for path in ("/assignments/role/new/", "/assignments/requirements/"):
            with self.subTest(path=path):
                self.assertEqual(self.client.get(path).status_code, 403)
        self.assertEqual(TrainingAssignment.objects.count(), 0)

    def test_unauthenticated_users_have_no_assignment_authority(self):
        for user in (None, AnonymousUser()):
            with self.subTest(user=user):
                self.assertFalse(can_assign_team_training(user))
                self.assertFalse(can_assign_company_training(user))
                self.assertEqual(self.ids(user), set())

    def test_inactive_global_account_cannot_exercise_new_helpers(self):
        user = get_user_model().objects.create_user(username="inactive-global", is_active=False)
        user.groups.add(Group.objects.get(name="Administrator"))
        self.assertFalse(can_assign_company_training(user))
        self.assertEqual(self.ids(user), set())

    def test_group_grant_migration_is_idempotent_additive_and_reverse_is_non_destructive(self):
        migration = import_module("accounts.migrations.0005_team_assignment_permission")
        manager = Group.objects.get(name="Manager")
        member = self.user(self.manager)
        unrelated = Permission.objects.get(content_type__app_label="auth", codename="view_group")
        manager.permissions.add(unrelated)
        original = {
            group.pk: set(group.permissions.values_list("pk", flat=True))
            for group in Group.objects.all()
        }
        permission_count = Permission.objects.count()
        schema_editor = SimpleNamespace(connection=connection)
        migration.grant_team_assignment_permission(apps, schema_editor)
        migration.grant_team_assignment_permission(apps, schema_editor)
        migration.Migration.operations[0].reverse_code(apps, schema_editor)
        self.assertEqual(Permission.objects.count(), permission_count)
        self.assertEqual(Group.objects.count(), len(original))
        for group in Group.objects.all():
            self.assertEqual(set(group.permissions.values_list("pk", flat=True)), original[group.pk])
        self.assertTrue(manager.user_set.filter(pk=member.pk).exists())
        self.assertFalse(manager.permissions.filter(codename="add_trainingassignment").exists())
