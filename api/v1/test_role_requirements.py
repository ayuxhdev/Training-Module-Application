"""JWT role requirement and batch APIs against isolated, rolled-back fixtures."""

from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.db import IntegrityError, models, transaction
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from api.capabilities import mobile_capabilities
from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from notifications.models import Notification
from organization.models import Employee, JobRole
from training.models import RoleTrainingRequirement, TrainingAssignment


class RoleRequirementAPITests(CurriculumTestCase):
    url = "/api/v1/management/role-requirements/"

    def setUp(self):
        self.client = APIClient()
        self.actor = get_user_model().objects.create_user(username="requirement-api")
        self.requirement = RoleTrainingRequirement.objects.create(
            job_role=self.role, training_version=self.version, created_by=self.user,
        )
        self.detail = f"{self.url}{self.requirement.pk}/"
        self.batch = self.detail + "assignments/"
        self.other_role = JobRole.objects.create(code="OTHER", name="Other role")

    def grant(self, *names, user=None):
        user = user or self.actor
        user.user_permissions.add(*Permission.objects.filter(
            content_type__app_label="training", codename__in=names,
        ))
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + str(RefreshToken.for_user(user).access_token))
        return user

    def payload(self, **values):
        return {"job_role_id": self.other_role.pk, "training_version_id": self.version.pk, **values}

    def recipient(self, code, **values):
        return Employee.objects.create(employee_code=code, display_name=code, department=self.department,
                                       job_role=self.role, date_joined=timezone.localdate(), **values)

    def test_jwt_required_for_all_operations(self):
        for method, url, data in (("get", self.url, None), ("get", self.detail, None),
                                  ("post", self.url, self.payload()), ("patch", self.detail, {}),
                                  ("post", self.batch, {})):
            response = getattr(self.client, method)(url, data, format="json")
            self.assertEqual(response.status_code, 401)

    def test_view_only_can_list_detail_but_not_write_or_execute(self):
        self.grant("view_roletrainingrequirement")
        self.assertEqual(self.client.get(self.url).status_code, 200)
        self.assertEqual(self.client.get(self.detail).status_code, 200)
        self.assertEqual(self.client.post(self.url, self.payload(), format="json").status_code, 403)
        self.assertEqual(self.client.patch(self.detail, {}, format="json").status_code, 403)
        self.assertEqual(self.client.post(self.batch, {}, format="json").status_code, 403)

    def test_add_only_has_workspace_and_create_without_view_or_batch(self):
        self.grant("add_roletrainingrequirement")
        actor = get_user_model().objects.get(pk=self.actor.pk)
        caps = mobile_capabilities(actor)
        self.assertIn("management_workspace", caps)
        self.assertIn("training.add_roletrainingrequirement", caps)
        self.assertNotIn("company_dashboard", caps)
        self.assertEqual(self.client.get(self.url).status_code, 403)
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(self.url, self.payload(due_in_days=0), format="json")
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data["due_in_days"], 0)
        self.assertEqual(RoleTrainingRequirement.objects.get(pk=response.data["id"]).created_by_id, self.actor.pk)
        event = AuditLog.objects.get(action="training.roletrainingrequirement.created")
        self.assertEqual(event.actor_id, self.actor.pk)
        self.assertEqual(event.after_data["job_role_id"], self.other_role.pk)
        self.assertEqual(self.client.post(self.batch, {}, format="json").status_code, 403)

    def test_change_only_preserves_references_and_records_exact_changes(self):
        self.grant("change_roletrainingrequirement")
        self.assertEqual(self.client.get(self.detail).status_code, 403)
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.patch(self.detail, {"due_in_days": 12, "is_active": False}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.requirement.refresh_from_db()
        self.assertEqual(self.requirement.job_role_id, self.role.pk)
        self.assertEqual(self.requirement.training_version_id, self.version.pk)
        self.assertEqual(self.requirement.due_in_days, 12)
        self.assertFalse(self.requirement.is_active)
        event = AuditLog.objects.get(action="training.roletrainingrequirement.updated")
        self.assertEqual(event.before_data["due_in_days"], 30)
        self.assertEqual(event.after_data["due_in_days"], 12)

    def test_noop_does_not_change_timestamps_or_audit(self):
        self.grant("change_roletrainingrequirement")
        before = self.requirement.updated_at
        for payload in ({}, {"due_in_days": 30, "is_active": True}):
            with self.captureOnCommitCallbacks(execute=True):
                self.assertEqual(self.client.patch(self.detail, payload, format="json").status_code, 200)
        self.requirement.refresh_from_db()
        self.assertEqual(self.requirement.updated_at, before)
        self.assertFalse(AuditLog.objects.exists())

    def test_references_and_authoritative_fields_cannot_be_patched(self):
        self.grant("change_roletrainingrequirement")
        for field in ("job_role_id", "training_version_id", "created_by", "created_by_id", "id", "created_at"):
            with self.subTest(field=field):
                response = self.client.patch(self.detail, {field: 123}, format="json")
                self.assertEqual(response.status_code, 400, response.data)
        self.assertFalse(AuditLog.objects.exists())

    def test_create_defaults_and_duplicate_rejection(self):
        self.grant("add_roletrainingrequirement")
        first = self.client.post(self.url, self.payload(), format="json")
        self.assertEqual(first.status_code, 201, first.data)
        self.assertEqual((first.data["due_in_days"], first.data["is_active"]), (30, True))
        duplicate = self.client.post(self.url, self.payload(), format="json")
        self.assertEqual(duplicate.status_code, 400, duplicate.data)
        self.assertEqual(RoleTrainingRequirement.objects.count(), 2)

    def test_invalid_create_values_and_inactive_role(self):
        self.grant("add_roletrainingrequirement")
        for payload in ({}, self.payload(due_in_days=-1), self.payload(due_in_days=4294967296),
                        self.payload(job_role_id=0), self.payload(training_version_id=None),
                        self.payload(created_by_id=self.user.pk), []):
            with self.subTest(payload=payload):
                self.assertEqual(self.client.post(self.url, payload, format="json").status_code, 400)
        self.other_role.is_active = False
        self.other_role.save()
        self.assertEqual(self.client.post(self.url, self.payload(), format="json").status_code, 400)
        self.assertEqual(RoleTrainingRequirement.objects.count(), 1)

    def test_missing_reference_is_not_created(self):
        self.grant("add_roletrainingrequirement")
        for payload in (self.payload(job_role_id=99999999), self.payload(training_version_id=99999999)):
            self.assertEqual(self.client.post(self.url, payload, format="json").status_code, 404)

    def test_draft_and_retired_versions_are_rejected_on_creation(self):
        self.grant("add_roletrainingrequirement")
        draft = self.new_version()
        self.assertEqual(self.client.post(self.url, self.payload(training_version_id=draft.pk), format="json").status_code, 400)
        self.version.status, self.version.retired_at = "RETIRED", timezone.now()
        self.version.save()
        self.assertEqual(self.client.post(self.url, self.payload(), format="json").status_code, 400)

    def test_historical_requirement_can_be_deactivated_but_not_reactivated(self):
        self.grant("change_roletrainingrequirement")
        self.version.status, self.version.retired_at = "RETIRED", timezone.now()
        self.version.save()
        response = self.client.patch(self.detail, {"is_active": False, "due_in_days": 4}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(self.client.patch(self.detail, {"due_in_days": 5}, format="json").status_code, 200)
        self.assertEqual(self.client.patch(self.detail, {"is_active": True}, format="json").status_code, 400)

    def test_list_filters_pagination_and_safe_contract_without_mutation(self):
        self.grant("view_roletrainingrequirement")
        second = RoleTrainingRequirement.objects.create(job_role=self.other_role, training_version=self.version,
                                                       is_active=False, created_by=self.user)
        before = list(RoleTrainingRequirement.objects.order_by("pk").values())
        response = self.client.get(self.url, {"page_size": 1})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(set(response.data), {"count", "next", "previous", "results"})
        self.assertEqual(response.data["count"], 2)
        self.assertIsNotNone(response.data["next"])
        for query in ({"search": "OTHER"}, {"job_role_id": self.other_role.pk},
                      {"is_active": "false", "training_version_id": self.version.pk}):
            result = self.client.get(self.url, query)
            self.assertEqual([row["id"] for row in result.data["results"]], [second.pk])
        record = self.client.get(self.detail).data
        self.assertEqual(set(record), {"id", "job_role_id", "job_role_code", "job_role_name", "training_version_id",
                                      "training_id", "training_title", "version_title", "version_number", "version_status",
                                      "due_in_days", "is_active", "created_at", "updated_at"})
        self.assertEqual(record["training_title"], self.training.catalog_title)
        self.assertEqual(list(RoleTrainingRequirement.objects.order_by("pk").values()), before)
        self.assertFalse(Notification.objects.exists())
        self.assertFalse(AuditLog.objects.exists())
        for query in ({"page_size": 101}, {"page": 0}, {"search": "a" * 151}, {"job_role_id": -1}):
            self.assertEqual(self.client.get(self.url, query).status_code, 400)

    def test_denial_precedes_lookup_and_no_deletion_is_exposed(self):
        self.grant("view_training")
        for pk in (self.requirement.pk, 99999999):
            self.assertEqual(self.client.get(f"{self.url}{pk}/").status_code, 403)
            self.assertEqual(self.client.post(f"{self.url}{pk}/assignments/", {}, format="json").status_code, 403)
        self.grant("view_roletrainingrequirement")
        self.assertEqual(self.client.get(f"{self.url}99999999/").status_code, 404)
        self.assertEqual(self.client.delete(self.detail).status_code, 405)

    def test_team_only_manager_and_regular_employee_cannot_execute_batches(self):
        manager = get_user_model().objects.create_user(username="requirement-manager")
        manager.groups.add(Group.objects.get(name="Manager"))
        self.recipient("MANAGER", user=manager)
        self.grant("assign_team_trainingassignment", user=manager)
        self.assertEqual(self.client.post(self.batch, {}, format="json").status_code, 403)
        self.grant(user=self.employee_user)
        self.assertEqual(self.client.get(self.url).status_code, 403)
        self.assertEqual(self.client.post(self.batch, {}, format="json").status_code, 403)

    def test_inactive_user_or_linked_employee_denied(self):
        self.grant("add_trainingassignment")
        self.actor.is_active = False
        self.actor.save()
        self.assertEqual(self.client.post(self.batch, {}, format="json").status_code, 401)
        self.actor.is_active = True
        self.actor.save()
        linked = self.recipient("DISABLED", user=self.actor)
        linked.is_active, linked.deactivation_reason = False, "Fixture"
        linked.save()
        # Even a forged still-active User cannot bypass an inactive employee link.
        get_user_model().objects.filter(pk=self.actor.pk).update(is_active=True)
        self.assertEqual(self.client.post(self.batch, {}, format="json").status_code, 403)

    def test_global_assignment_permission_does_not_grant_requirement_mutation(self):
        self.grant("add_trainingassignment")
        self.assertEqual(self.client.get(self.url).status_code, 403)
        self.assertEqual(self.client.post(self.url, self.payload(), format="json").status_code, 403)
        self.assertEqual(self.client.patch(self.detail, {}, format="json").status_code, 403)
        self.assertEqual(self.client.post(self.batch, {}, format="json").status_code, 200)

    def test_global_role_batches_preserve_existing_and_skip_inactive_or_other_roles(self):
        self.grant("add_trainingassignment")
        active = self.recipient("NEW")
        inactive = self.recipient("INACTIVE", is_active=False, deactivation_reason="Fixture")
        foreign = self.recipient("FOREIGN")
        foreign.job_role = self.other_role
        foreign.save()
        before = dict(TrainingAssignment.objects.filter(pk=self.assignment.pk).values().get())
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(self.batch, {}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data, {"role_requirement_id": self.requirement.pk, "job_role_id": self.role.pk,
                                         "training_version_id": self.version.pk, "created_count": 1, "skipped_count": 2})
        created = TrainingAssignment.objects.get(employee=active)
        self.assertEqual((created.source, created.role_requirement_id, created.assigned_by_id), ("ROLE", self.requirement.pk, self.actor.pk))
        self.assertEqual((created.department_at_assignment_id, created.job_role_at_assignment_id), (self.department.pk, self.role.pk))
        self.assertEqual((created.due_at - created.assigned_at).days, 30)
        self.assertEqual(TrainingAssignment.objects.filter(pk=self.assignment.pk).values().get(), before)
        self.assertFalse(TrainingAssignment.objects.filter(employee__in=[inactive, foreign]).exists())
        self.assertEqual(Notification.objects.filter(assignment=created, event_type="ASSIGNED").count(), 1)
        self.assertEqual(AuditLog.objects.filter(action="training.role_assignment.batch_created").count(), 1)
        with self.captureOnCommitCallbacks(execute=True):
            repeat = self.client.post(self.batch, {}, format="json")
        self.assertEqual((repeat.data["created_count"], repeat.data["skipped_count"]), (0, 3))
        self.assertEqual(Notification.objects.count(), 1)
        self.assertEqual(AuditLog.objects.count(), 1)

    def test_completed_assignment_and_progress_are_not_replaced(self):
        self.grant("add_trainingassignment")
        self.complete_assignment()
        before = list(TrainingAssignment.objects.values())
        progress = list(self.assignment.lesson_progress.values())
        response = self.client.post(self.batch, {}, format="json")
        self.assertEqual(response.data["created_count"], 0)
        self.assertEqual(list(TrainingAssignment.objects.values()), before)
        self.assertEqual(list(self.assignment.lesson_progress.values()), progress)

    def test_due_zero_and_catalog_inactive_follow_existing_website_rules(self):
        self.grant("add_trainingassignment")
        self.recipient("ZERO")
        self.requirement.due_in_days = 0
        self.requirement.save()
        self.training.is_active = False
        self.training.save()
        response = self.client.post(self.batch, {}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        created = TrainingAssignment.objects.get(source="ROLE")
        self.assertEqual(created.due_at, created.assigned_at)

    def test_ineligible_requirement_or_overflow_does_not_write(self):
        self.grant("add_trainingassignment")
        self.recipient("ELIGIBLE")
        self.requirement.is_active = False
        self.requirement.save()
        self.assertEqual(self.client.post(self.batch, {}, format="json").status_code, 400)
        self.requirement.is_active, self.requirement.due_in_days = True, 4294967295
        self.requirement.save()
        self.assertEqual(self.client.post(self.batch, {}, format="json").status_code, 400)
        self.assertEqual(TrainingAssignment.objects.count(), 1)
        self.assertFalse(Notification.objects.exists())
        self.assertFalse(AuditLog.objects.exists())

    def test_retired_batch_and_unexpected_payload_rejected(self):
        self.grant("add_trainingassignment")
        for payload in ({"employee_id": self.employee.pk}, {"assigned_by_id": self.actor.pk}, []):
            self.assertEqual(self.client.post(self.batch, payload, format="json").status_code, 400)
        self.version.status, self.version.retired_at = "RETIRED", timezone.now()
        self.version.save()
        self.assertEqual(self.client.post(self.batch, {}, format="json").status_code, 400)
        self.assertEqual(TrainingAssignment.objects.count(), 1)

    def test_notification_failure_rolls_back_entire_batch_and_success_audit(self):
        self.grant("add_trainingassignment")
        self.recipient("ROLLBACK-1")
        self.recipient("ROLLBACK-2")
        from api.v1 import role_requirement_services as services
        original = services.create_assignment_notification
        calls = []

        def fail_second(*args, **kwargs):
            calls.append(args)
            if len(calls) == 2:
                raise RuntimeError("Controlled notification failure")
            return original(*args, **kwargs)

        with self.captureOnCommitCallbacks(execute=True), patch.object(services, "create_assignment_notification", fail_second):
            with self.assertRaisesRegex(RuntimeError, "Controlled notification failure"):
                self.client.post(self.batch, {}, format="json")
        self.assertEqual(TrainingAssignment.objects.count(), 1)
        self.assertFalse(Notification.objects.exists())
        self.assertFalse(AuditLog.objects.exists())

    def test_unrelated_integrity_errors_are_not_misreported_as_conflicts(self):
        self.grant("add_roletrainingrequirement")
        with patch("api.v1.role_requirement_services.save_requirement", side_effect=IntegrityError(1062, "other key")):
            with self.assertRaises(IntegrityError):
                self.client.post(self.url, self.payload(), format="json")


    def test_empty_batch_and_existing_global_role_authority(self):
        empty = RoleTrainingRequirement.objects.create(
            job_role=self.other_role, training_version=self.version, created_by=self.user,
        )
        for name in ("Administrator", "Training Coordinator"):
            actor = get_user_model().objects.create_user(username="empty-" + name.replace(" ", "-"))
            actor.groups.add(Group.objects.get(name=name))
            self.grant(user=actor)
            with self.captureOnCommitCallbacks(execute=True):
                response = self.client.post(f"{self.url}{empty.pk}/assignments/", {}, format="json")
            self.assertEqual(response.status_code, 200, response.data)
            self.assertEqual((response.data["created_count"], response.data["skipped_count"]), (0, 0))
        self.assertEqual(TrainingAssignment.objects.count(), 1)
        self.assertFalse(AuditLog.objects.exists())

    def test_real_requirement_unique_index_maps_only_expected_conflict(self):
        self.grant("add_roletrainingrequirement")
        duplicate = RoleTrainingRequirement(job_role=self.role, training_version=self.version, created_by=self.actor)
        # Exercise the real schema index inside a rollback savepoint. Production
        # saves keep full validation; only this fixture deliberately bypasses it.
        with self.assertRaises(IntegrityError) as caught:
            with transaction.atomic():
                models.Model.save(duplicate, force_insert=True)
        self.assertEqual(caught.exception.args[0], 1062)
        with patch("api.v1.role_requirement_services.save_requirement", side_effect=caught.exception):
            response = self.client.post(self.url, self.payload(), format="json")
        self.assertEqual(response.status_code, 409, response.data)
        self.assertEqual(RoleTrainingRequirement.objects.count(), 1)
