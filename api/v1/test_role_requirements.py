"""JWT role requirement and batch APIs against isolated, rolled-back fixtures."""

from types import SimpleNamespace
from unittest.mock import Mock, patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import PermissionDenied
from django.db import IntegrityError, models, transaction
from django.test import SimpleTestCase
from django.urls import resolve
from django.utils import timezone
from rest_framework.request import Request
from rest_framework.test import APIClient, APIRequestFactory, force_authenticate
from rest_framework_simplejwt.tokens import RefreshToken

from api.capabilities import mobile_capabilities
from assessments.models import Assessment, AssessmentQuestion
from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from notifications.models import Notification
from organization.models import Employee, JobRole
from training.models import Module, Lesson, RoleTrainingRequirement, Training, TrainingAssignment, TrainingVersion

from .role_requirement_serializers import RequirementCreateSerializer, RequirementCreationOptionsQuerySerializer
from .role_requirement_services import save_requirement
from .role_requirement_views import RequirementCreationOptionsView


class RoleRequirementAPITests(CurriculumTestCase):
    url = "/api/v1/management/role-requirements/"
    options_url = url + "creation-options/"

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

    def published_option_version(self, number):
        version = TrainingVersion.objects.create(
            training=self.training, version_number=number, title=f"Safety v{number}", created_by=self.user,
        )
        module = Module.objects.create(training_version=version, title="Read", position=1)
        Lesson.objects.create(module=module, title="Read", position=1, content_type="TEXT", body="Instructions")
        final = Assessment.objects.create(training_version=version, kind="FINAL", title="Final")
        AssessmentQuestion.objects.create(assessment=final, question_revision=self.revision, position=1)
        version.status, version.published_at, version.published_by = "PUBLISHED", timezone.now(), self.user
        version.save()
        return version

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

    def test_add_only_options_are_minimal_read_only_and_do_not_grant_generic_access(self):
        self.grant("add_roletrainingrequirement")
        for kind in ("job_roles", "training_versions"):
            response = self.client.get(self.options_url, {"kind": kind})
            self.assertEqual(response.status_code, 200, response.data)
            self.assertEqual(set(response.data), {"count", "next", "previous", "results"})
            self.assertGreater(response.data["count"], 0)
            for option in response.data["results"]:
                self.assertEqual(set(option), {"id", "label"})
                self.assertIsInstance(option["id"], int)
                self.assertIsInstance(option["label"], str)
        for url in ("/api/v1/management/job-roles/", "/api/v1/management/versions/",
                    "/api/v1/management/training-versions/", self.url):
            self.assertEqual(self.client.get(url).status_code, 403)
        self.assertEqual(self.client.head(self.options_url, {"kind": "job_roles"}).status_code, 200)
        self.assertEqual(self.client.post(self.options_url, {}, format="json").status_code, 405)
        self.assertEqual(RoleTrainingRequirement.objects.count(), 1)
        self.assertEqual(TrainingAssignment.objects.count(), 1)
        self.assertFalse(AuditLog.objects.exists())
        self.assertFalse(Notification.objects.exists())

    def test_reference_view_permissions_do_not_change_creation_options(self):
        self.grant("add_roletrainingrequirement", "view_trainingversion")
        expected = self.client.get(self.options_url, {"kind": "job_roles"}).data
        self.actor.user_permissions.add(Permission.objects.get(
            content_type__app_label="organization", codename="view_jobrole",
        ))
        self.assertEqual(self.client.get(self.options_url, {"kind": "job_roles"}).data, expected)
        self.assertEqual(self.client.get("/api/v1/management/job-roles/").status_code, 200)
        self.assertEqual(self.client.get("/api/v1/management/versions/").status_code, 200)

    def test_options_deny_manager_employee_and_read_only_then_honor_mixed_role_grant(self):
        manager = get_user_model().objects.create_user(username="options-manager")
        manager.groups.add(Group.objects.get(name="Manager"))
        self.recipient("OPTIONS-MANAGER", user=manager)
        for user in (manager, self.employee_user):
            self.grant(user=user)
            self.assertEqual(self.client.get(self.options_url, {"kind": "job_roles"}).status_code, 403)
        self.grant("view_roletrainingrequirement", "view_trainingversion")
        self.assertEqual(self.client.get(self.options_url, {"kind": "job_roles"}).status_code, 403)
        manager.groups.add(Group.objects.get(name="Employee"))
        self.grant("add_roletrainingrequirement", user=manager)
        self.assertEqual(self.client.get(self.options_url, {"kind": "job_roles"}).status_code, 200)
        self.assertEqual(self.client.post(self.batch, {}, format="json").status_code, 403)

    def test_options_deny_anonymous_inactive_user_and_inactive_linked_employee(self):
        self.assertEqual(self.client.get(self.options_url, {"kind": "job_roles"}).status_code, 401)
        self.grant("add_roletrainingrequirement")
        self.actor.is_active = False
        self.actor.save()
        self.assertEqual(self.client.get(self.options_url, {"kind": "job_roles"}).status_code, 401)
        self.actor.is_active = True
        self.actor.save()
        self.recipient("OPTIONS-DISABLED", user=self.actor, is_active=False, deactivation_reason="Fixture")
        # Exercise linked-Employee eligibility independently of the User flag.
        get_user_model().objects.filter(pk=self.actor.pk).update(is_active=True)
        self.assertEqual(self.client.get(self.options_url, {"kind": "job_roles"}).status_code, 403)

    def test_options_filter_lifecycle_but_include_inactive_catalog(self):
        self.grant("add_roletrainingrequirement")
        inactive = JobRole.objects.create(code="INACTIVE-OPTION", name="Hidden role", is_active=False)
        draft = self.new_version()
        retired = self.published_option_version(3)
        retired.status = "RETIRED"
        retired.save()
        self.training.is_active = False
        self.training.save()
        roles = self.client.get(self.options_url, {"kind": "job_roles"}).data["results"]
        self.assertEqual({row["id"] for row in roles}, {self.role.pk, self.other_role.pk})
        self.assertNotIn(inactive.pk, {row["id"] for row in roles})
        versions = self.client.get(self.options_url, {"kind": "training_versions"}).data["results"]
        self.assertEqual(versions, [{
            "id": self.version.pk,
            "label": f"{self.training.catalog_title} — {self.version.title} (v1)",
        }])
        self.assertNotIn(draft.pk, {row["id"] for row in versions})
        self.assertNotIn(retired.pk, {row["id"] for row in versions})
        self.assertEqual(self.client.post(self.url, self.payload(), format="json").status_code, 201)

    def test_options_validate_kind_and_pagination_with_structured_errors(self):
        self.grant("add_roletrainingrequirement")
        for query, field in (({}, "kind"), ({"kind": "employees"}, "kind"),
                             ({"kind": ""}, "kind"), ({"kind": "job_roles", "page": 0}, "page"),
                             ({"kind": "job_roles", "page": "no"}, "page"),
                             ({"kind": "job_roles", "page_size": 0}, "page_size"),
                             ({"kind": "job_roles", "page_size": 101}, "page_size"),
                             ({"kind": "job_roles", "page_size": "no"}, "page_size")):
            with self.subTest(query=query):
                response = self.client.get(self.options_url, query)
                self.assertEqual(response.status_code, 400, response.data)
                self.assertIn(field, response.data["error"]["fields"])
        self.assertEqual(self.client.get(self.options_url, {"kind": "job_roles", "page": 999}).status_code, 404)

    def test_job_role_options_are_completely_paginated_with_name_ties(self):
        self.grant("add_roletrainingrequirement")
        for number in range(21):
            JobRole.objects.create(code=f"OPTION-{number:02}", name="Same name")
        expected = list(JobRole.objects.filter(is_active=True).order_by("name", "pk").values_list("pk", flat=True))
        first = self.client.get(self.options_url, {"kind": "job_roles"})
        self.assertEqual(first.data["count"], len(expected))
        self.assertEqual(len(first.data["results"]), 20)
        self.assertIsNone(first.data["previous"])
        second = self.client.get(first.data["next"])
        self.assertEqual(second.status_code, 200)
        self.assertIsNone(second.data["next"])
        self.assertIsNotNone(second.data["previous"])
        options = first.data["results"] + second.data["results"]
        self.assertEqual([row["id"] for row in options], expected)
        expected_labels = {
            role.pk: f"{role.code} — {role.name}"
            for role in JobRole.objects.filter(is_active=True)
        }
        self.assertEqual({row["id"]: row["label"] for row in options}, expected_labels)
        self.assertEqual(len({row["label"] for row in options}), len(options))
        for option in options:
            self.assertEqual(set(option), {"id", "label"})
        maximum = self.client.get(self.options_url, {"kind": "job_roles", "page_size": 100})
        self.assertEqual(len(maximum.data["results"]), len(expected))

    def test_version_options_paginate_in_version_order(self):
        self.grant("add_roletrainingrequirement")
        later = self.published_option_version(3)
        earlier = self.published_option_version(2)
        response = self.client.get(self.options_url, {"kind": "training_versions", "page_size": 1})
        found = []
        while True:
            self.assertEqual(response.status_code, 200)
            found.extend(row["id"] for row in response.data["results"])
            if response.data["next"] is None:
                break
            response = self.client.get(response.data["next"])
        self.assertEqual(found, [self.version.pk, earlier.pk, later.pk])

    def test_options_allow_empty_eligible_result_sets(self):
        self.grant("add_roletrainingrequirement")
        self.version.status = "RETIRED"
        self.version.save()
        response = self.client.get(self.options_url, {"kind": "training_versions"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data, {"count": 0, "next": None, "previous": None, "results": []})

    def test_post_rechecks_permission_revoked_after_request_entry(self):
        self.grant("add_roletrainingrequirement")
        original = RequirementCreateSerializer.is_valid

        def revoke_after_entry(serializer, *args, **kwargs):
            valid = original(serializer, *args, **kwargs)
            self.actor.user_permissions.remove(Permission.objects.get(
                content_type__app_label="training", codename="add_roletrainingrequirement",
            ))
            return valid

        with patch.object(RequirementCreateSerializer, "is_valid", revoke_after_entry):
            response = self.client.post(self.url, self.payload(), format="json")
        self.assertEqual(response.status_code, 403, response.data)
        self.assertEqual(RoleTrainingRequirement.objects.count(), 1)
        self.assertFalse(AuditLog.objects.exists())

    def test_post_rechecks_actor_and_linked_employee_after_request_entry(self):
        self.grant("add_roletrainingrequirement")
        employee = self.recipient("OPTIONS-CREATOR", user=self.actor)
        original = RequirementCreateSerializer.is_valid
        for disable_employee in (False, True):
            with self.subTest(disable_employee=disable_employee):
                actor = get_user_model().objects.get(pk=self.actor.pk)
                actor.is_active = True
                actor.save(update_fields=["is_active"])
                employee.is_active = True
                employee.deactivated_at = None
                employee.deactivation_reason = ""
                employee.save()

                def disable_after_entry(serializer, *args, **kwargs):
                    valid = original(serializer, *args, **kwargs)
                    if disable_employee:
                        employee.is_active = False
                        employee.deactivation_reason = "Fixture"
                        employee.save()
                        actor.refresh_from_db()
                        actor.is_active = True
                        actor.save(update_fields=["is_active"])
                        self.assertTrue(actor.is_active)
                    else:
                        actor.is_active = False
                        actor.save(update_fields=["is_active"])
                    return valid

                with patch.object(RequirementCreateSerializer, "is_valid", disable_after_entry):
                    response = self.client.post(self.url, self.payload(), format="json")
                self.assertEqual(response.status_code, 403, response.data)
                if disable_employee:
                    employee.refresh_from_db()
                    self.assertFalse(employee.is_active)
                    self.assertIsNotNone(employee.deactivated_at)
                    actor.refresh_from_db()
                    self.assertTrue(actor.is_active)
        self.assertEqual(RoleTrainingRequirement.objects.count(), 1)
        self.assertFalse(AuditLog.objects.exists())

    def test_post_revalidates_references_after_successful_options_lookup(self):
        self.grant("add_roletrainingrequirement")
        self.assertEqual(self.client.get(self.options_url, {"kind": "job_roles"}).status_code, 200)
        self.assertEqual(self.client.get(self.options_url, {"kind": "training_versions"}).status_code, 200)
        self.other_role.is_active = False
        self.other_role.save()
        self.assertEqual(self.client.post(self.url, self.payload(), format="json").status_code, 400)
        self.other_role.is_active = True
        self.other_role.save()
        self.version.status = "RETIRED"
        self.version.save()
        self.assertEqual(self.client.post(self.url, self.payload(), format="json").status_code, 400)
        self.assertEqual(RoleTrainingRequirement.objects.count(), 1)
        self.assertFalse(AuditLog.objects.exists())

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


class RequirementCreationOptionsContractTests(SimpleTestCase):
    """No database: real DRF permission/serialization paths and lazy query contracts."""

    url = "/api/v1/management/role-requirements/creation-options/"

    def setUp(self):
        self.factory = APIRequestFactory()
        self.user = self.actor({"training.add_roletrainingrequirement"})

    def actor(self, permissions, *, active=True, employee=None):
        groups = Mock()
        groups.filter.return_value.exists.return_value = False
        return SimpleNamespace(
            pk=123, is_authenticated=True, is_active=active, employee=employee,
            groups=groups, has_perm=lambda permission: permission in permissions,
        )

    def request(self, query, *, user=None):
        request = self.factory.get(self.url, query)
        force_authenticate(request, user=user or self.user)
        return request

    def test_query_requires_kind_and_validates_pagination(self):
        for values in ({}, {"kind": "employees"}, {"kind": ""},
                       {"kind": "job_roles", "page": 0}, {"kind": "job_roles", "page": "bad"},
                       {"kind": "job_roles", "page_size": 0}, {"kind": "job_roles", "page_size": 101},
                       {"kind": "job_roles", "page_size": "bad"}):
            with self.subTest(values=values):
                self.assertFalse(RequirementCreationOptionsQuerySerializer(data=values).is_valid())
        for kind in ("job_roles", "training_versions"):
            serializer = RequirementCreationOptionsQuerySerializer(data={"kind": kind, "page": "1", "page_size": "100"})
            self.assertTrue(serializer.is_valid(), serializer.errors)
            self.assertEqual(serializer.validated_data, {"kind": kind, "page": 1, "page_size": 100})

    def test_invalid_query_uses_real_structured_api_error_without_database(self):
        response = RequirementCreationOptionsView.as_view()(self.request({"kind": "employees"}))
        self.assertEqual(response.status_code, 400)
        self.assertIn("kind", response.data["error"]["fields"])

    def test_add_only_can_read_paginated_minimal_job_role_labels(self):
        roles = [JobRole(id=number, code=f"ROLE-{number}", name="Same name", description="PRIVATE") for number in range(1, 24)]
        with patch.object(RequirementCreationOptionsView, "get_queryset", return_value=roles):
            first = RequirementCreationOptionsView.as_view()(self.request({"kind": "job_roles"}))
            second = RequirementCreationOptionsView.as_view()(self.request({"kind": "job_roles", "page": 2}))
        self.assertEqual(first.status_code, 200)
        self.assertEqual(set(first.data), {"count", "next", "previous", "results"})
        self.assertEqual(first.data["count"], 23)
        self.assertEqual(len(first.data["results"]), 20)
        self.assertIsNotNone(first.data["next"])
        self.assertIsNone(second.data["next"])
        self.assertEqual([row["id"] for row in first.data["results"] + second.data["results"]], list(range(1, 24)))
        options = first.data["results"] + second.data["results"]
        self.assertEqual(options, [{"id": number, "label": f"ROLE-{number} — Same name"} for number in range(1, 24)])
        self.assertEqual(len({row["label"] for row in options}), 23)
        self.assertNotIn("PRIVATE", str(first.data))

    def test_version_label_has_only_identifying_fields(self):
        version = TrainingVersion(
            id=8, training=Training(id=2, catalog_title="Safety", description="PRIVATE COURSE"),
            title="Safety v2", version_number=2, description="PRIVATE VERSION", status="PUBLISHED",
        )
        with patch.object(RequirementCreationOptionsView, "get_queryset", return_value=[version]):
            response = RequirementCreationOptionsView.as_view()(self.request({"kind": "training_versions"}))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["results"], [{"id": 8, "label": "Safety — Safety v2 (v2)"}])
        self.assertNotIn("PRIVATE", str(response.data))

    def test_denial_precedes_query_for_missing_permission_or_ineligible_account(self):
        actors = [self.actor(set()), self.actor({"training.view_roletrainingrequirement"}),
                  self.actor({"training.add_trainingassignment"}),
                  self.actor({"training.add_roletrainingrequirement"}, active=False),
                  self.actor({"training.add_roletrainingrequirement"}, employee=SimpleNamespace(is_active=False))]
        for actor in actors:
            with self.subTest(actor=actor):
                with patch.object(RequirementCreationOptionsView, "get_queryset") as query:
                    response = RequirementCreationOptionsView.as_view()(self.request({"kind": "job_roles"}, user=actor))
                self.assertEqual(response.status_code, 403)
                query.assert_not_called()

    def test_anonymous_denied_before_query(self):
        with patch.object(RequirementCreationOptionsView, "get_queryset") as query:
            response = RequirementCreationOptionsView.as_view()(self.factory.get(self.url, {"kind": "job_roles"}))
        self.assertEqual(response.status_code, 401)
        query.assert_not_called()

    def test_generic_reference_permissions_are_not_expanded(self):
        from .assignment_management_views import AssignableTrainingVersionListView
        from .management_views import JobRoleReferenceView
        from .training_management_views import TrainingVersionDiscoveryView

        for view in (JobRoleReferenceView, TrainingVersionDiscoveryView, AssignableTrainingVersionListView):
            with self.subTest(view=view.__name__):
                with patch.object(view, "get_queryset") as query:
                    response = view.as_view()(self.request({}))
                self.assertEqual(response.status_code, 403)
                query.assert_not_called()

    def test_querysets_match_post_eligibility_without_evaluating_database(self):
        for kind, expected_filters, expected_order in (
            ("job_roles", {"is_active": True}, ("name", "pk")),
            ("training_versions", {"status": "PUBLISHED"},
             ("training__catalog_title", "training_id", "version_number", "pk")),
        ):
            with self.subTest(kind=kind):
                view = RequirementCreationOptionsView()
                view.request = Request(self.factory.get(self.url, {"kind": kind}))
                queryset = view.get_queryset()
                self.assertEqual({item.lhs.target.name: item.rhs for item in queryset.query.where.children}, expected_filters)
                self.assertEqual(queryset.query.order_by, expected_order)
                if kind == "job_roles":
                    fields, deferred = queryset.query.deferred_loading
                    self.assertFalse(deferred)
                    self.assertIn("code", fields)

    def test_route_resolves_to_dedicated_view(self):
        self.assertIs(resolve(self.url).func.view_class, RequirementCreationOptionsView)

    def test_post_rechecks_fresh_actor_after_reference_locks_before_form_or_audit(self):
        for fresh_actor in (None, self.actor(set()),
                            self.actor({"training.add_roletrainingrequirement"}, active=False),
                            self.actor({"training.add_roletrainingrequirement"}, employee=SimpleNamespace(is_active=False))):
            with self.subTest(fresh_actor=fresh_actor):
                with patch("api.v1.role_requirement_services.get_object_or_404") as roots, \
                     patch("api.v1.role_requirement_services.get_user_model") as user_model, \
                     patch("api.v1.role_requirement_services.RoleTrainingRequirementCreateForm") as form, \
                     patch("api.v1.role_requirement_services.record_event") as audit:
                    def fresh_after_locks():
                        self.assertEqual(roots.call_count, 2)
                        return fresh_actor

                    user_model.return_value.objects.select_for_update.return_value.filter.return_value.first.side_effect = fresh_after_locks
                    # Exercise the service body only; atomic locking itself needs MySQL.
                    with self.assertRaises(PermissionDenied):
                        save_requirement.__wrapped__(self.user, {"job_role_id": 3, "training_version_id": 8})
                    form.assert_not_called()
                    audit.assert_not_called()
