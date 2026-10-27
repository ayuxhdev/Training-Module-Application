"""Website-only team assignment authorization and transactional revalidation."""

from datetime import time, timedelta
from unittest import skipUnless
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import ValidationError
from django.db import IntegrityError, connection
from django.test import Client
from django.utils import timezone

from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from notifications.models import Notification
from organization.models import Department, Employee, JobRole
from training.forms import TrainingAssignmentForm
from training.models import TrainingAssignment


class ManagerWebsiteAssignmentTests(CurriculumTestCase):
    url = "/assignments/new/"

    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.user.groups.add(Group.objects.get(name="Training Coordinator"))
        cls.employee_user.groups.add(Group.objects.get(name="Employee"))
        cls.manager_user = get_user_model().objects.create_user(username="team-assign-manager")
        cls.manager_user.groups.add(Group.objects.get(name="Manager"))
        cls.manager = cls.recipient("manager", manager=cls.employee, user=cls.manager_user)
        cls.direct = cls.recipient("direct", manager=cls.manager)
        cls.indirect = cls.recipient("indirect", manager=cls.direct)
        cls.peer = cls.recipient("peer", manager=cls.employee)
        cls.foreign = cls.recipient("foreign")
        cls.inactive = cls.recipient("inactive", manager=cls.manager)
        cls.inactive.is_active = False
        cls.inactive.deactivation_reason = "Isolated test fixture"
        cls.inactive.save()

    @classmethod
    def recipient(cls, name, *, manager=None, user=None):
        return Employee.objects.create(
            employee_code="ASSIGN-" + name.upper(), display_name="Assignment " + name,
            department=cls.department, job_role=cls.role, date_joined=timezone.localdate(),
            reporting_manager=manager, user=user,
        )

    def payload(self, employee=None, **overrides):
        return {
            "employee": (employee or self.direct).pk,
            "training_version": self.version.pk, "due_date": "", **overrides,
        }

    def form(self, employee=None, user=None):
        form = TrainingAssignmentForm(user=user or self.manager_user, data=self.payload(employee))
        self.assertTrue(form.is_valid(), form.errors)
        return form

    def login(self, user=None):
        self.client.force_login(user or self.manager_user)

    def assert_no_writes(self):
        self.assertEqual(list(TrainingAssignment.objects.values_list("pk", flat=True)), [self.assignment.pk])
        self.assertFalse(Notification.objects.exists())
        self.assertFalse(AuditLog.objects.exists())

    def test_get_choices_are_active_team_only_and_published_only(self):
        draft = self.new_version()
        self.login()
        response = self.client.get(self.url)
        self.assertEqual(response.status_code, 200)
        form = response.context["form"]
        self.assertEqual(form.user.pk, self.manager_user.pk)
        self.assertEqual(set(form.fields["employee"].queryset), {self.direct, self.indirect})
        self.assertEqual(list(form.fields["training_version"].queryset), [self.version])
        self.assertNotContains(response, draft.title)
        self.assertContains(response, "reporting hierarchy")
        self.assertContains(self.client.get("/assignments/"), 'href="/assignments/new/"')
        self.assert_no_writes()

    def test_direct_and_indirect_posts_create_snapshots_audit_and_one_notification(self):
        self.login()
        for employee in (self.direct, self.indirect):
            with self.subTest(employee=employee.pk), self.captureOnCommitCallbacks(execute=True):
                response = self.client.post(self.url, self.payload(
                    employee, assigned_by=self.user.pk, source="ROLE", status="COMPLETED",
                ))
                assignment = TrainingAssignment.objects.get(employee=employee)
                self.assertRedirects(response, f"/assignments/{assignment.pk}/", fetch_redirect_response=False)
                self.assertEqual(assignment.training_version_id, self.version.pk)
                self.assertEqual(assignment.assigned_by_id, self.manager_user.pk)
                self.assertEqual(assignment.department_at_assignment_id, self.department.pk)
                self.assertEqual(assignment.job_role_at_assignment_id, self.role.pk)
                self.assertEqual(assignment.status, "ASSIGNED")
                self.assertEqual(assignment.source, "MANUAL")
                self.assertIsNone(assignment.role_requirement_id)
                notification = Notification.objects.get(assignment=assignment)
                self.assertEqual(notification.employee_id, employee.pk)
                self.assertEqual(notification.event_type, "ASSIGNED")
            event = AuditLog.objects.get(action="training.trainingassignment.created", entity_id=str(assignment.pk))
            self.assertEqual(event.actor_id, self.manager_user.pk)
            self.assertEqual(event.after_data["employee_id"], employee.pk)
        self.assertEqual(Notification.objects.count(), 2)
        self.assertEqual(AuditLog.objects.count(), 2)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, "IN_PROGRESS")
        self.assertEqual(self.assignment.training_version_id, self.version.pk)

    def test_forged_self_peer_superior_foreign_inactive_and_unknown_ids_are_rejected(self):
        self.login()
        for employee_id in (self.manager.pk, self.peer.pk, self.employee.pk, self.foreign.pk,
                            self.inactive.pk, 999999):
            with self.subTest(employee=employee_id), self.captureOnCommitCallbacks(execute=True):
                response = self.client.post(self.url, {**self.payload(), "employee": employee_id})
                self.assertEqual(response.status_code, 200)
                self.assertIn("employee", response.context["form"].errors)
        self.assert_no_writes()

    def test_inactive_user_cannot_get_or_post(self):
        self.manager_user.is_active = False
        self.manager_user.save()
        self.login()
        self.assertEqual(self.client.get(self.url).status_code, 403)
        self.assertEqual(self.client.post(self.url, self.payload()).status_code, 403)
        self.assert_no_writes()

    def test_inactive_manager_employee_cannot_get_or_post_with_reenabled_user(self):
        self.manager.is_active = False
        self.manager.deactivation_reason = "Isolated test deactivation"
        self.manager.save()
        self.manager_user.is_active = True
        self.manager_user.save()
        self.login()
        self.assertEqual(self.client.get(self.url).status_code, 403)
        self.assertEqual(self.client.post(self.url, self.payload()).status_code, 403)
        self.assertNotContains(self.client.get("/assignments/"), 'href="/assignments/new/"')
        self.assert_no_writes()

    def test_employee_unlinked_manager_and_anonymous_cannot_get_or_post(self):
        unlinked = get_user_model().objects.create_user(username="unlinked-team-manager")
        unlinked.groups.add(Group.objects.get(name="Manager"))
        for user in (self.employee_user, unlinked, None):
            with self.subTest(user=user):
                self.client.logout()
                if user:
                    self.login(user)
                self.assertEqual(self.client.get(self.url).status_code, 403)
                self.assertEqual(self.client.post(self.url, self.payload()).status_code, 403)
        self.assert_no_writes()

    def test_manager_without_permission_has_no_action_get_or_post_access(self):
        permission = Permission.objects.get(codename="assign_team_trainingassignment")
        Group.objects.get(name="Manager").permissions.remove(permission)
        self.login()
        self.assertNotContains(self.client.get("/assignments/"), 'href="/assignments/new/"')
        self.assertEqual(self.client.get(self.url).status_code, 403)
        self.assertEqual(self.client.post(self.url, self.payload()).status_code, 403)
        self.assert_no_writes()

    def test_company_wide_role_configuration_remains_forbidden_on_get_and_post(self):
        self.login()
        listing = self.client.get("/assignments/")
        for path in ("/assignments/role/new/", "/assignments/requirements/", "/assignments/requirements/new/"):
            with self.subTest(path=path):
                self.assertNotContains(listing, f'href="{path}"')
                self.assertEqual(self.client.get(path).status_code, 403)
                self.assertEqual(self.client.post(path, self.payload()).status_code, 403)
        self.assert_no_writes()

    def test_draft_and_retired_versions_are_rejected_by_get_choices_and_post(self):
        draft = self.new_version()
        self.version.status = "RETIRED"
        self.version.save()
        self.login()
        self.assertFalse(self.client.get(self.url).context["form"].fields["training_version"].queryset.exists())
        for version in (draft, self.version):
            with self.subTest(version=version.pk):
                response = self.client.post(self.url, self.payload(training_version=version.pk))
                self.assertEqual(response.status_code, 200)
                self.assertIn("training_version", response.context["form"].errors)
        self.assert_no_writes()

    def test_duplicate_post_creates_no_duplicate_assignment_event_or_audit(self):
        self.login()
        with self.captureOnCommitCallbacks(execute=True):
            self.assertEqual(self.client.post(self.url, self.payload()).status_code, 302)
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(self.url, self.payload())
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "already has an assignment")
        self.assertEqual(TrainingAssignment.objects.filter(employee=self.direct).count(), 1)
        self.assertEqual(Notification.objects.count(), 1)
        self.assertEqual(AuditLog.objects.count(), 1)

    def test_invalid_and_past_due_dates_are_field_errors(self):
        self.login()
        for value in ("not-a-date", (timezone.localdate() - timedelta(days=1)).isoformat()):
            with self.subTest(due_date=value):
                response = self.client.post(self.url, self.payload(due_date=value))
                self.assertEqual(response.status_code, 200)
                self.assertIn("due_date", response.context["form"].errors)
                self.assertEqual(response.context["form"].data["employee"], str(self.direct.pk))
        self.assert_no_writes()

    def test_due_today_keeps_existing_end_of_day_behavior(self):
        self.login()
        self.assertEqual(self.client.post(self.url, self.payload(due_date=timezone.localdate().isoformat())).status_code, 302)
        assignment = TrainingAssignment.objects.get(employee=self.direct)
        self.assertEqual(timezone.localtime(assignment.due_at).time(), time.max)

    def test_global_administrator_and_coordinator_keep_company_choices_and_actions(self):
        admin = get_user_model().objects.create_user(username="team-assignment-admin")
        admin.groups.add(Group.objects.get(name="Administrator"))
        for user, recipient in ((admin, self.foreign), (self.user, self.peer)):
            with self.subTest(user=user.pk):
                self.login(user)
                response = self.client.get(self.url)
                choices = response.context["form"].fields["employee"].queryset
                self.assertIn(self.manager, choices)
                self.assertIn(self.foreign, choices)
                self.assertNotIn(self.inactive, choices)
                listing = self.client.get("/assignments/")
                self.assertContains(listing, 'href="/assignments/role/new/"')
                self.assertContains(listing, 'href="/assignments/requirements/"')
                self.assertEqual(self.client.post(self.url, self.payload(recipient)).status_code, 302)
                self.assertEqual(TrainingAssignment.objects.get(employee=recipient).assigned_by_id, user.pk)

    def test_manager_post_still_requires_csrf(self):
        client = Client(enforce_csrf_checks=True)
        client.force_login(self.manager_user)
        self.assertContains(client.get(self.url), 'name="csrfmiddlewaretoken"')
        self.assertEqual(client.post(self.url, self.payload()).status_code, 403)
        self.assert_no_writes()

    def test_scope_is_rechecked_after_direct_or_ancestor_reporting_line_changes(self):
        forms = [self.form(self.direct), self.form(self.indirect)]
        self.direct.reporting_manager = self.foreign
        self.direct.save()
        for form in forms:
            with self.subTest(employee=form.instance.employee_id):
                with self.assertRaisesMessage(ValidationError, "no longer assign"):
                    form.save(assigned_by=self.manager_user)
        self.assert_no_writes()

    def test_recipient_deactivation_after_validation_is_rejected(self):
        form = self.form()
        self.direct.is_active = False
        self.direct.deactivation_reason = "Isolated fixture"
        self.direct.save()
        with self.assertRaisesMessage(ValidationError, "no longer assign"):
            form.save(assigned_by=self.manager_user)
        self.assert_no_writes()

    def test_manager_deactivation_after_validation_is_rejected(self):
        form = self.form()
        self.manager.is_active = False
        self.manager.deactivation_reason = "Isolated fixture"
        self.manager.save()
        with self.assertRaisesMessage(ValidationError, "no longer assign"):
            form.save(assigned_by=self.manager_user)
        self.assert_no_writes()

    def test_user_deactivation_after_validation_uses_fresh_user_not_request_cache(self):
        form = self.form()
        get_user_model().objects.filter(pk=self.manager_user.pk).update(is_active=False)
        with self.assertRaisesMessage(ValidationError, "no longer assign"):
            form.save(assigned_by=self.manager_user)
        self.assert_no_writes()

    def test_permission_revocation_after_validation_uses_fresh_effective_permissions(self):
        form = self.form()
        Group.objects.get(name="Manager").permissions.remove(Permission.objects.get(codename="assign_team_trainingassignment"))
        with self.assertRaisesMessage(ValidationError, "no longer assign"):
            form.save(assigned_by=self.manager_user)
        self.assert_no_writes()

    def test_global_authority_loss_does_not_fall_back_without_hierarchy_locks(self):
        self.manager_user.groups.add(Group.objects.get(name="Administrator"))
        form = self.form(self.foreign)
        self.manager_user.groups.remove(Group.objects.get(name="Administrator"))
        with self.assertRaisesMessage(ValidationError, "permissions changed"):
            form.save(assigned_by=self.manager_user)
        self.assert_no_writes()

    def test_snapshots_use_fresh_locked_employee_for_team_and_global_assignments(self):
        department = Department.objects.create(code="FRESH", name="Current department")
        role = JobRole.objects.create(code="FRESH", name="Current role")
        for actor, employee in ((self.manager_user, self.direct), (self.user, self.indirect)):
            with self.subTest(actor=actor.pk):
                form = self.form(employee, user=actor)
                employee.department = department
                employee.job_role = role
                employee.save()
                assignment = form.save(assigned_by=actor)
                self.assertEqual(assignment.department_at_assignment_id, department.pk)
                self.assertEqual(assignment.job_role_at_assignment_id, role.pk)

    def test_retirement_after_validation_is_rejected_without_notification(self):
        form = self.form()
        self.version.status = "RETIRED"
        self.version.save()
        with self.assertRaises(ValidationError):
            form.save(assigned_by=self.manager_user)
        self.assert_no_writes()

    def test_missing_actor_fails_closed_and_commit_false_or_forged_actor_cannot_write(self):
        missing_actor = TrainingAssignmentForm(data=self.payload())
        self.assertFalse(missing_actor.is_valid())
        self.assertIn("employee", missing_actor.errors)
        form = self.form()
        self.assertIsNone(form.save(commit=False, assigned_by=self.manager_user).pk)
        with self.assertRaisesMessage(ValidationError, "authenticated user"):
            self.form().save(assigned_by=self.user)
        self.assert_no_writes()

    def test_two_prevalidated_forms_still_create_only_one_assignment_and_notification(self):
        first, second = self.form(), self.form()
        first.save(assigned_by=self.manager_user)
        with self.assertRaises(ValidationError):
            second.save(assigned_by=self.manager_user)
        self.assertEqual(TrainingAssignment.objects.filter(employee=self.direct).count(), 1)
        self.assertEqual(Notification.objects.count(), 1)

    def test_notification_failure_rolls_back_assignment_and_emits_no_success_audit(self):
        self.login()
        with patch("training.forms.create_assignment_notification", side_effect=IntegrityError("Isolated failure")):
            with self.captureOnCommitCallbacks(execute=True):
                response = self.client.post(self.url, self.payload())
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.context["form"].non_field_errors())
        self.assert_no_writes()

    def test_save_validation_errors_are_attached_to_employee_field(self):
        self.login()
        with patch.object(TrainingAssignmentForm, "save", side_effect=ValidationError({"employee": "Scope changed; reload."})):
            response = self.client.post(self.url, self.payload())
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.context["form"].errors["employee"], ["Scope changed; reload."])
        self.assert_no_writes()

    @skipUnless(connection.vendor == "mysql", "MySQL row-lock SQL assertion")
    def test_team_hierarchy_and_version_locks_precede_actor_lock(self):
        form = self.form()
        queries = []

        def capture(execute, sql, params, many, context):
            if "FOR UPDATE" in sql.upper():
                queries.append(sql)
            return execute(sql, params, many, context)

        with connection.execute_wrapper(capture):
            form.save(assigned_by=self.manager_user)
        self.assertIn('FROM `organization_employee`', queries[0])
        self.assertIn('`organization_employee`.`id`', queries[0])
        self.assertRegex(queries[0], r'ORDER BY (?:1|`organization_employee`\.`id`) ASC')
        user_index = next(i for i, sql in enumerate(queries) if 'FROM `auth_user`' in sql)
        version_index = next(i for i, sql in enumerate(queries) if 'FROM `training_trainingversion`' in sql)
        self.assertGreater(version_index, 0)
        self.assertGreater(user_index, version_index)
