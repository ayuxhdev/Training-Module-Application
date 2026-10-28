"""Isolated account provisioning, authorization and integrity regressions."""

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import transaction
from django.test import Client, TestCase
from django.urls import reverse

from audit.models import AuditLog
from organization.models import Department, Employee, JobRole

from .system_admin_forms import CreateSystemUserForm, BUSINESS_GROUP_NAMES
from .system_admin_services import (
    create_system_user, link_system_user_employee, update_system_user_groups,
)


class SystemAccountManagementTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        User = get_user_model()
        cls.root = User.objects.create_user(username="stage2-root", is_superuser=True, is_staff=True)
        cls.other_root = User.objects.create_user(username="stage2-other-root", is_superuser=True)
        cls.admin = User.objects.create_user(username="stage2-admin")
        cls.admin.groups.add(Group.objects.get(name="Administrator"))
        cls.manager = User.objects.create_user(username="stage2-manager")
        cls.manager.groups.add(Group.objects.get(name="Manager"))
        cls.learner = User.objects.create_user(username="stage2-learner")
        cls.learner.groups.add(Group.objects.get(name="Employee"))
        cls.staff = User.objects.create_user(username="stage2-staff", is_staff=True)
        cls.inactive = User.objects.create_user(username="stage2-inactive-root", is_superuser=True, is_active=False)
        cls.target = User.objects.create_user(username="stage2-target", is_active=False)
        cls.department = Department.objects.create(code="ST2", name="Stage 2 fixtures")
        cls.role = JobRole.objects.create(code="ST2", name="Stage 2 fixtures")
        cls.employee = Employee.objects.create(
            employee_code="ST2-EMP", display_name="Existing unlinked Employee",
            department=cls.department, job_role=cls.role, date_joined="2026-01-01",
        )

    def setUp(self):
        self.client.force_login(self.root)

    def url(self, operation, target=None):
        name = {
            "create": "system-user-create",
            "groups": "system-user-groups",
            "link": "system-user-link-employee",
        }[operation]
        return reverse("accounts:" + name, args=[] if operation == "create" else [(target or self.target).pk])

    def create_data(self, **overrides):
        return {"username": "new-stage2-user", "first_name": "New", "last_name": "Learner",
                "email": "new@example.test", "confirm": "on", **overrides}

    def post(self, operation, data, target=None):
        with self.captureOnCommitCallbacks(execute=True):
            return self.client.post(self.url(operation, target), data)

    def test_create_inactive_user_with_unusable_password_and_no_technical_privileges(self):
        response = self.post("create", self.create_data())
        user = get_user_model().objects.get(username="new-stage2-user")
        self.assertRedirects(response, reverse("accounts:system-user-detail", args=[user.pk]))
        self.assertEqual((user.first_name, user.last_name, user.email), ("New", "Learner", "new@example.test"))
        self.assertFalse(user.is_active)
        self.assertFalse(user.has_usable_password())
        self.assertFalse(user.is_staff)
        self.assertFalse(user.is_superuser)
        self.assertFalse(user.user_permissions.exists())
        self.assertFalse(user.groups.exists())

    def test_create_with_approved_groups_and_existing_employee_is_atomic_and_audited_after_commit(self):
        groups = list(Group.objects.filter(name__in=["Employee", "Manager"]).values_list("pk", flat=True))
        before = self.employee.reporting_manager_id, self.employee.is_active
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            response = self.client.post(self.url("create"), self.create_data(groups=groups, employee=self.employee.pk))
            self.assertFalse(AuditLog.objects.filter(action__startswith="accounts.user.").exists())
        self.assertEqual(response.status_code, 302)
        self.assertEqual(len(callbacks), 2)
        user = get_user_model().objects.get(username="new-stage2-user")
        self.employee.refresh_from_db()
        self.assertEqual(self.employee.user_id, user.pk)
        self.assertEqual((self.employee.reporting_manager_id, self.employee.is_active), before)
        self.assertEqual(set(user.groups.values_list("name", flat=True)), {"Employee", "Manager"})
        self.assertFalse(user.is_active)
        self.assertEqual(set(AuditLog.objects.values_list("action", flat=True)), {
            "accounts.user.created", "accounts.user.employee_linked",
        })
        event = AuditLog.objects.get(action="accounts.user.created")
        self.assertEqual(event.actor_id, self.root.pk)
        self.assertEqual(event.entity_id, str(user.pk))
        self.assertEqual(event.after_data["employee_id"], self.employee.pk)
        self.assertNotIn("password", event.after_data)

    def test_optional_name_email_groups_and_employee_may_be_blank(self):
        response = self.post("create", {"username": "minimal-stage2", "confirm": "on"})
        self.assertEqual(response.status_code, 302)
        user = get_user_model().objects.get(username="minimal-stage2")
        self.assertFalse(user.groups.exists())
        self.assertFalse(Employee.objects.filter(user=user).exists())
        self.assertFalse(user.is_active)

    def test_invalid_and_duplicate_usernames_and_email_do_not_create_accounts(self):
        cases = [
            ({"username": ""}, "username"),
            ({"username": "bad name"}, "username"),
            ({"username": "x" * 151}, "username"),
            ({"username": self.target.username}, "username"),
            ({"username": self.target.username.upper()}, "username"),
            ({"email": "not-an-email"}, "email"),
        ]
        before = get_user_model().objects.count()
        for overrides, field in cases:
            with self.subTest(overrides=overrides):
                response = self.post("create", self.create_data(**overrides))
                self.assertEqual(response.status_code, 400)
                self.assertIn(field, response.context["form"].errors)
        self.assertEqual(get_user_model().objects.count(), before)
        self.assertFalse(AuditLog.objects.exists())

    def test_username_normalization_uses_django_username_field(self):
        response = self.post("create", self.create_data(username="\uff33\uff54\uff41\uff47\uff45\uff12"))
        self.assertEqual(response.status_code, 302)
        self.assertTrue(get_user_model().objects.filter(username="Stage2").exists())

    def test_all_six_business_groups_are_available_without_technical_groups(self):
        extra = Group.objects.create(name="Technical operators")
        response = self.client.get(self.url("create"))
        groups = response.context["form"].fields["groups"].queryset
        self.assertEqual(set(groups.values_list("name", flat=True)), set(BUSINESS_GROUP_NAMES))
        self.assertNotIn(extra.pk, set(groups.values_list("pk", flat=True)))

    def test_invalid_and_unapproved_group_ids_are_rejected_on_create_and_update(self):
        extra = Group.objects.create(name="Technical operators")
        for ids in ([extra.pk], [99999999], ["not-an-id"]):
            for operation in ("create", "groups"):
                with self.subTest(operation=operation, ids=ids):
                    data = self.create_data(groups=ids) if operation == "create" else {"groups": ids, "confirm": "on"}
                    response = self.post(operation, data)
                    self.assertEqual(response.status_code, 400)
                    self.assertIn("groups", response.context["form"].errors)
        self.assertFalse(get_user_model().objects.filter(username="new-stage2-user").exists())
        self.assertFalse(AuditLog.objects.exists())

    def test_all_forms_require_explicit_confirmation(self):
        for operation, data in (
            ("create", {"username": "unconfirmed"}),
            ("groups", {"groups": []}),
            ("link", {"employee": self.employee.pk}),
        ):
            response = self.post(operation, data)
            self.assertEqual(response.status_code, 400)
            self.assertIn("confirm", response.context["form"].errors)
        self.assertFalse(AuditLog.objects.exists())

    def test_forged_privileged_and_unknown_fields_are_rejected_not_ignored(self):
        for operation in ("create", "groups", "link"):
            for field in ("is_active", "is_staff", "is_superuser", "password", "user_permissions", "user", "actor"):
                with self.subTest(operation=operation, field=field):
                    data = {
                        "create": self.create_data(),
                        "groups": {"groups": [], "confirm": "on"},
                        "link": {"employee": self.employee.pk, "confirm": "on"},
                    }[operation]
                    response = self.post(operation, {**data, field: "1"})
                    self.assertEqual(response.status_code, 400)
                    self.assertTrue(response.context["form"].non_field_errors())
        self.assertFalse(AuditLog.objects.exists())
        self.target.refresh_from_db()
        self.assertFalse(self.target.is_active)

    def test_duplicate_single_value_fields_are_rejected(self):
        response = self.client.post(
            self.url("create"),
            "username=first&username=second&confirm=on",
            content_type="application/x-www-form-urlencoded",
        )
        self.assertEqual(response.status_code, 400)
        self.assertFalse(get_user_model().objects.filter(username__in=["first", "second"]).exists())

    def test_business_admin_manager_employee_and_ordinary_staff_are_denied_get_and_post(self):
        before = get_user_model().objects.count()
        for user in (self.admin, self.manager, self.learner, self.staff):
            self.client.force_login(user)
            for operation in ("create", "groups", "link"):
                with self.subTest(actor=user.username, operation=operation):
                    self.assertEqual(self.client.get(self.url(operation)).status_code, 403)
                    self.assertEqual(self.client.post(self.url(operation), self.create_data()).status_code, 403)
        self.assertEqual(get_user_model().objects.count(), before)
        self.assertFalse(AuditLog.objects.exists())

    def test_anonymous_and_inactive_superuser_cannot_get_or_post(self):
        for user in (None, self.inactive):
            client = Client()
            if user:
                client.force_login(user)
            for operation in ("create", "groups", "link"):
                for method in ("get", "post"):
                    response = getattr(client, method)(self.url(operation), {})
                    self.assertEqual(response.status_code, 302)
                    self.assertTrue(response.url.startswith(reverse("accounts:login")))
        self.assertFalse(AuditLog.objects.exists())

    def test_get_displays_forms_and_never_changes_accounts_or_links(self):
        counts = (get_user_model().objects.count(), self.target.groups.count(), AuditLog.objects.count())
        for operation in ("create", "groups", "link"):
            response = self.client.get(self.url(operation), self.create_data(employee=self.employee.pk))
            self.assertEqual(response.status_code, 200)
            self.assertContains(response, 'name="csrfmiddlewaretoken"')
            self.assertContains(response, 'class="appearance-control"')
            self.assertNotContains(response, 'type="password"')
        self.employee.refresh_from_db()
        self.assertIsNone(self.employee.user_id)
        self.assertEqual((get_user_model().objects.count(), self.target.groups.count(), AuditLog.objects.count()), counts)

    def test_only_post_can_mutate_and_other_mutation_methods_are_405(self):
        for operation in ("create", "groups", "link"):
            self.assertEqual(self.client.head(self.url(operation)).status_code, 200)
            for method in ("put", "patch", "delete"):
                self.assertEqual(getattr(self.client, method)(self.url(operation), {}).status_code, 405)
        self.assertFalse(AuditLog.objects.exists())

    def test_csrf_required_for_all_saves_and_valid_csrf_allows_creation(self):
        client = Client(enforce_csrf_checks=True)
        client.force_login(self.root)
        for operation in ("create", "groups", "link"):
            self.assertEqual(client.post(self.url(operation), self.create_data()).status_code, 403)
        client.get(self.url("create"))
        data = self.create_data(csrfmiddlewaretoken=client.cookies["csrftoken"].value)
        with self.captureOnCommitCallbacks(execute=True):
            self.assertEqual(client.post(self.url("create"), data).status_code, 302)
        self.assertTrue(get_user_model().objects.filter(username="new-stage2-user", is_active=False).exists())

    def test_groups_replace_only_approved_memberships_preserving_other_memberships_and_direct_permissions(self):
        employee = Group.objects.get(name="Employee")
        trainer = Group.objects.get(name="Trainer")
        extra = Group.objects.create(name="Unrelated membership")
        permission = Permission.objects.get(codename="view_group", content_type__app_label="auth")
        self.target.groups.add(employee, extra)
        self.target.user_permissions.add(permission)
        response = self.post("groups", {"groups": [trainer.pk], "confirm": "on"})
        self.assertEqual(response.status_code, 302)
        self.assertEqual(set(self.target.groups.values_list("pk", flat=True)), {trainer.pk, extra.pk})
        self.assertEqual(list(self.target.user_permissions.values_list("pk", flat=True)), [permission.pk])
        event = AuditLog.objects.get(action="accounts.user.groups_changed")
        self.assertEqual(event.actor_id, self.root.pk)
        self.assertEqual({g["id"] for g in event.before_data["groups"]}, {employee.pk})
        self.assertEqual({g["id"] for g in event.after_data["groups"]}, {trainer.pk})
        self.assertNotIn(extra.name, str(event.before_data))
        self.assertNotIn(extra.name, str(event.after_data))
        self.target.refresh_from_db()
        self.assertFalse(self.target.is_active)
        self.assertFalse(self.target.is_staff)
        self.assertFalse(self.target.is_superuser)

    def test_empty_group_selection_removes_business_groups_only(self):
        self.target.groups.add(Group.objects.get(name="Employee"))
        extra = Group.objects.create(name="Retained membership")
        self.target.groups.add(extra)
        self.assertEqual(self.post("groups", {"confirm": "on"}).status_code, 302)
        self.assertEqual(list(self.target.groups.values_list("pk", flat=True)), [extra.pk])

    def test_group_noop_emits_no_misleading_change_event(self):
        self.assertEqual(self.post("groups", {"confirm": "on"}).status_code, 302)
        self.assertFalse(AuditLog.objects.exists())

    def test_superuser_and_self_cannot_have_groups_or_employee_links_changed(self):
        for target in (self.root, self.other_root):
            for operation in ("groups", "link"):
                with self.subTest(target=target.username, operation=operation):
                    self.assertEqual(self.client.get(self.url(operation, target)).status_code, 403)
                    self.assertEqual(self.post(operation, {"confirm": "on", "employee": self.employee.pk}, target).status_code, 403)
        self.assertFalse(AuditLog.objects.exists())

    def test_service_rechecks_actor_and_target_privileges_inside_transaction(self):
        stale_actor = get_user_model().objects.get(pk=self.root.pk)
        get_user_model().objects.filter(pk=self.root.pk).update(is_superuser=False)
        with self.assertRaises(PermissionDenied):
            update_system_user_groups(stale_actor, self.target.pk, [])
        get_user_model().objects.filter(pk=self.root.pk).update(is_superuser=True)
        get_user_model().objects.filter(pk=self.target.pk).update(is_superuser=True)
        with self.assertRaises(PermissionDenied):
            link_system_user_employee(self.root, self.target.pk, self.employee.pk)
        self.employee.refresh_from_db()
        self.assertIsNone(self.employee.user_id)
        self.assertFalse(AuditLog.objects.exists())

    def test_services_recheck_inactive_actor_before_any_mutation(self):
        form = CreateSystemUserForm(self.create_data())
        self.assertTrue(form.is_valid(), form.errors)
        get_user_model().objects.filter(pk=self.root.pk).update(is_active=False)
        for operation in (
            lambda: create_system_user(self.root, form.cleaned_data),
            lambda: update_system_user_groups(self.root, self.target.pk, []),
            lambda: link_system_user_employee(self.root, self.target.pk, self.employee.pk),
        ):
            with self.assertRaises(PermissionDenied):
                operation()
        self.assertFalse(get_user_model().objects.filter(username="new-stage2-user").exists())
        self.assertFalse(AuditLog.objects.exists())

    def test_link_existing_employee_without_changing_hierarchy_or_account_status(self):
        self.target.groups.add(Group.objects.get(name="Trainer"))
        before = Employee.objects.filter(pk=self.employee.pk).values(
            "employee_code", "display_name", "is_active", "department_id", "job_role_id",
            "reporting_manager_id", "date_joined", "created_at", "deactivated_at", "deactivation_reason",
        ).get()
        self.assertEqual(self.post("link", {"employee": self.employee.pk, "confirm": "on"}).status_code, 302)
        self.employee.refresh_from_db()
        self.target.refresh_from_db()
        self.assertEqual(self.employee.user_id, self.target.pk)
        self.assertEqual(Employee.objects.filter(pk=self.employee.pk).values(*before).get(), before)
        self.assertFalse(self.target.is_active)
        self.assertEqual(list(self.target.groups.values_list("name", flat=True)), ["Trainer"])
        event = AuditLog.objects.get(action="accounts.user.employee_linked")
        self.assertEqual(event.before_data, {"employee_id": None})
        self.assertEqual(event.after_data, {"employee_id": self.employee.pk})

    def test_existing_employee_link_cannot_be_replaced_or_removed(self):
        self.employee.user = self.learner
        self.employee.save()
        before = AuditLog.objects.count()
        response = self.post("link", {"employee": self.employee.pk, "confirm": "on"})
        self.assertEqual(response.status_code, 400)
        self.employee.refresh_from_db()
        self.assertEqual(self.employee.user_id, self.learner.pk)
        with self.assertRaises(ValidationError):
            link_system_user_employee(self.root, self.target.pk, self.employee.pk)
        self.assertEqual(AuditLog.objects.count(), before)

    def test_already_linked_account_cannot_link_another_employee(self):
        other = Employee.objects.create(
            employee_code="ST2-OTHER", display_name="Other", user=self.target,
            department=self.department, job_role=self.role, date_joined="2026-01-01",
        )
        response = self.post("link", {"employee": self.employee.pk, "confirm": "on"})
        self.assertEqual(response.status_code, 400)
        self.employee.refresh_from_db()
        other.refresh_from_db()
        self.assertIsNone(self.employee.user_id)
        self.assertEqual(other.user_id, self.target.pk)
        self.assertFalse(AuditLog.objects.exists())

    def test_missing_and_invalid_employee_references_are_controlled(self):
        for value in ("", "invalid", 99999999):
            response = self.post("link", {"employee": value, "confirm": "on"})
            self.assertEqual(response.status_code, 400)
            self.assertIn("employee", response.context["form"].errors)
        self.assertFalse(AuditLog.objects.exists())

    def test_inactive_employee_link_does_not_implicitly_deactivate_active_account(self):
        self.employee.is_active = False
        self.employee.deactivation_reason = "Isolated fixture"
        self.employee.save()
        response = self.post("link", {"employee": self.employee.pk, "confirm": "on"}, self.staff)
        self.assertEqual(response.status_code, 400)
        with self.assertRaises(ValidationError):
            link_system_user_employee(self.root, self.staff.pk, self.employee.pk)
        self.staff.refresh_from_db()
        self.assertTrue(self.staff.is_active)
        self.employee.refresh_from_db()
        self.assertIsNone(self.employee.user_id)
        self.assertFalse(AuditLog.objects.exists())

    def test_inactive_employee_can_link_to_an_already_inactive_user_without_lifecycle_changes(self):
        self.employee.is_active = False
        self.employee.deactivation_reason = "Isolated fixture"
        self.employee.save()
        before = self.employee.deactivated_at, self.employee.deactivation_reason
        self.assertEqual(self.post("link", {"employee": self.employee.pk, "confirm": "on"}).status_code, 302)
        self.employee.refresh_from_db()
        self.target.refresh_from_db()
        self.assertFalse(self.target.is_active)
        self.assertEqual((self.employee.deactivated_at, self.employee.deactivation_reason), before)

    def test_create_with_failed_link_rolls_back_user_groups_and_all_audit_callbacks(self):
        form = CreateSystemUserForm(self.create_data(employee=self.employee.pk))
        self.assertTrue(form.is_valid(), form.errors)
        self.employee.user = self.learner
        self.employee.save()
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            with self.assertRaises(ValidationError):
                create_system_user(self.root, form.cleaned_data)
        self.assertFalse(get_user_model().objects.filter(username="new-stage2-user").exists())
        self.assertFalse(AuditLog.objects.exists())
        self.assertEqual(callbacks, [])

    def test_service_revalidates_group_allowlist_after_form_validation(self):
        group = Group.objects.get(name="Trainer")
        form = CreateSystemUserForm(self.create_data(groups=[group.pk]))
        self.assertTrue(form.is_valid(), form.errors)
        group.name = "No longer a business Group"
        group.save(update_fields=["name"])
        with self.assertRaises(ValidationError):
            create_system_user(self.root, form.cleaned_data)
        self.assertFalse(get_user_model().objects.filter(username="new-stage2-user").exists())

    def test_stale_creation_validation_cannot_create_duplicate_user(self):
        form = CreateSystemUserForm(self.create_data())
        self.assertTrue(form.is_valid(), form.errors)
        create_system_user(self.root, form.cleaned_data)
        with self.assertRaises(ValidationError):
            create_system_user(self.root, form.cleaned_data)
        self.assertEqual(get_user_model().objects.filter(username="new-stage2-user").count(), 1)

    def test_outer_rollback_discards_changes_and_success_audits(self):
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            with self.assertRaisesMessage(ValidationError, "Rollback fixture"):
                with transaction.atomic():
                    link_system_user_employee(self.root, self.target.pk, self.employee.pk)
                    raise ValidationError("Rollback fixture")
        self.employee.refresh_from_db()
        self.assertIsNone(self.employee.user_id)
        self.assertFalse(AuditLog.objects.exists())
        self.assertEqual(callbacks, [])

    def test_group_permission_definitions_and_grants_are_unchanged(self):
        definitions = list(Permission.objects.order_by("pk").values())
        grants = list(Group.permissions.through.objects.order_by("pk").values())
        group = Group.objects.get(name="Administrator")
        self.assertEqual(self.post("create", self.create_data(groups=[group.pk])).status_code, 302)
        self.assertEqual(self.post("groups", {"groups": [group.pk], "confirm": "on"}).status_code, 302)
        self.assertEqual(list(Permission.objects.order_by("pk").values()), definitions)
        self.assertEqual(list(Group.permissions.through.objects.order_by("pk").values()), grants)

    def test_account_provisioning_ui_and_protected_account_actions_are_accurate(self):
        detail = reverse("accounts:system-user-detail", args=[self.target.pk])
        response = self.client.get(detail)
        for text in ("Account provisioning", "Inactive account: sign-in is disabled", "Edit business Groups", "Link Employee", "Create user"):
            self.assertContains(response, text)
        response = self.client.get(reverse("accounts:system-user-detail", args=[self.root.pk]))
        self.assertContains(response, "Protected account")
        self.assertNotContains(response, 'href="' + self.url("groups", self.root) + '"')
        self.assertNotContains(response, 'href="' + self.url("link", self.root) + '"')
        self.assertContains(response, 'href="/admin/"')
        for operation in ("create", "groups", "link"):
            response = self.client.get(self.url(operation))
            self.assertContains(response, 'href="/accounts/system/" aria-current="page"')
            self.assertContains(response, 'name="confirm"')
            self.assertContains(response, 'label for="id_confirm"')

    def test_form_errors_preserve_values_and_escape_untrusted_text(self):
        data = self.create_data(first_name='<script>alert("name")</script>', email="invalid")
        response = self.post("create", data)
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.context["form"]["first_name"].value(), data["first_name"])
        self.assertContains(response, "&lt;script&gt;", status_code=400)
        self.assertNotContains(response, "<script>alert", status_code=400)
        self.assertContains(response, 'role="alert"', status_code=400)
