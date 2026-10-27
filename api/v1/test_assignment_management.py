from datetime import timedelta
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import ValidationError
from django.db import IntegrityError
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from notifications.models import Notification
from organization.models import Department, Employee, JobRole
from training.forms import TrainingAssignmentForm
from training.models import Training, TrainingAssignment, TrainingVersion


class AssignmentManagementAPITests(CurriculumTestCase):
    versions_url = "/api/v1/management/training-versions/"
    create_url = "/api/v1/management/assignments/"

    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.user.groups.add(Group.objects.get(name="Training Coordinator"))
        cls.employee_user.groups.add(Group.objects.get(name="Employee"))
        cls.manager = get_user_model().objects.create_user(username="assignment-api-manager")
        cls.manager.groups.add(Group.objects.get(name="Manager"))
        cls.manager_employee = cls.recipient("manager", manager=cls.employee, user=cls.manager)
        cls.direct = cls.recipient("direct", manager=cls.manager_employee)
        cls.indirect = cls.recipient("indirect", manager=cls.direct)
        cls.peer = cls.recipient("peer", manager=cls.employee)
        cls.foreign = cls.recipient("foreign")
        cls.inactive = cls.recipient("inactive", manager=cls.manager_employee)
        cls.inactive.is_active = False
        cls.inactive.deactivation_reason = "Isolated API fixture"
        cls.inactive.save()
        cls.admin = get_user_model().objects.create_user(username="assignment-api-admin")
        cls.admin.groups.add(Group.objects.get(name="Administrator"))

    @classmethod
    def recipient(cls, name, *, manager=None, user=None):
        return Employee.objects.create(
            employee_code="API-ASSIGN-" + name.upper(), display_name=name,
            department=cls.department, job_role=cls.role, date_joined=timezone.localdate(),
            reporting_manager=manager, user=user,
        )

    def setUp(self):
        self.client = APIClient()

    def authenticate(self, user=None):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + str(RefreshToken.for_user(user or self.manager).access_token))

    def payload(self, employee=None, **overrides):
        return {"employee_id": (employee or self.direct).pk, "training_version_id": self.version.pk, **overrides}

    def post(self, payload=None, user=None):
        self.authenticate(user)
        return self.client.post(self.create_url, self.payload() if payload is None else payload, format="json")

    def assert_no_assignment_writes(self):
        self.assertEqual(list(TrainingAssignment.objects.values_list("pk", flat=True)), [self.assignment.pk])
        self.assertFalse(Notification.objects.exists())
        self.assertFalse(AuditLog.objects.exists())

    def test_both_endpoints_require_jwt(self):
        for token in (None, "invalid"):
            self.client.credentials(**({"HTTP_AUTHORIZATION": "Bearer " + token} if token else {}))
            self.assertEqual(self.client.get(self.versions_url).status_code, 401)
            self.assertEqual(self.client.post(self.create_url, self.payload(), format="json").status_code, 401)
        self.assert_no_assignment_writes()

    def test_direct_and_indirect_creations_use_server_metadata_and_emit_one_event(self):
        for employee in (self.direct, self.indirect):
            with self.subTest(employee=employee.pk), self.captureOnCommitCallbacks(execute=True):
                response = self.post(self.payload(employee))
                self.assertEqual(response.status_code, 201, response.data)
                self.assertEqual(set(response.data), {
                    "id", "employee_id", "training_version_id", "status", "source", "assigned_by_id",
                    "department_at_assignment_id", "job_role_at_assignment_id", "assigned_at", "due_at",
                })
                self.assertEqual(response.data["assigned_by_id"], self.manager.pk)
                self.assertEqual(response.data["employee_id"], employee.pk)
                self.assertEqual(response.data["training_version_id"], self.version.pk)
                self.assertEqual(response.data["status"], "ASSIGNED")
                self.assertEqual(response.data["source"], "MANUAL")
                self.assertEqual(response.data["department_at_assignment_id"], self.department.pk)
                self.assertEqual(response.data["job_role_at_assignment_id"], self.role.pk)
                self.assertIsNone(response.data["due_at"])
            event = AuditLog.objects.get(entity_id=str(response.data["id"]), action="training.trainingassignment.created")
            self.assertEqual(event.actor_id, self.manager.pk)
            notification = Notification.objects.get(assignment_id=response.data["id"])
            self.assertEqual(notification.employee_id, employee.pk)
            self.assertEqual(notification.event_type, "ASSIGNED")
        self.assertEqual(AuditLog.objects.count(), 2)
        self.assertEqual(Notification.objects.count(), 2)

    def test_foreign_and_nonexistent_ids_have_identical_generic_field_errors(self):
        errors = []
        for pk in (self.manager_employee.pk, self.peer.pk, self.employee.pk, self.foreign.pk, self.inactive.pk, 999999):
            with self.subTest(employee=pk):
                response = self.post({**self.payload(), "employee_id": pk})
                self.assertEqual(response.status_code, 400)
                self.assertEqual(set(response.data), {"error"})
                self.assertEqual(response.data["error"]["code"], "validation_error")
                self.assertEqual(set(response.data["error"]["fields"]), {"employee_id"})
                errors.append(response.data)
        self.assertTrue(all(error == errors[0] for error in errors))
        self.assert_no_assignment_writes()

    def test_inactive_user_is_denied_by_jwt(self):
        self.authenticate()
        self.manager.is_active = False
        self.manager.save()
        self.assertEqual(self.client.get(self.versions_url).status_code, 401)
        self.assertEqual(self.client.post(self.create_url, self.payload(), format="json").status_code, 401)
        self.assert_no_assignment_writes()

    def test_inactive_employee_with_reenabled_user_is_denied(self):
        self.manager_employee.is_active = False
        self.manager_employee.deactivation_reason = "Isolated fixture"
        self.manager_employee.save()
        self.manager.is_active = True
        self.manager.save()
        self.authenticate()
        self.assertEqual(self.client.get(self.versions_url).status_code, 403)
        self.assertEqual(self.client.post(self.create_url, self.payload(), format="json").status_code, 403)
        self.assert_no_assignment_writes()

    def test_manager_requires_dedicated_permission_and_linked_employee(self):
        Group.objects.get(name="Manager").permissions.remove(Permission.objects.get(codename="assign_team_trainingassignment"))
        self.authenticate()
        self.assertEqual(self.client.get(self.versions_url).status_code, 403)
        self.assertEqual(self.client.post(self.create_url, self.payload(), format="json").status_code, 403)
        unlinked = get_user_model().objects.create_user(username="assignment-manager-no-employee")
        unlinked.groups.add(Group.objects.get(name="Manager"))
        self.authenticate(unlinked)
        self.assertEqual(self.client.get(self.versions_url).status_code, 403)
        self.assertEqual(self.client.post(self.create_url, self.payload(), format="json").status_code, 403)
        self.assert_no_assignment_writes()

    def test_employee_trainer_supervisor_and_permission_only_non_manager_are_denied(self):
        for group in ("Employee", "Trainer", "Supervisor"):
            with self.subTest(group=group):
                user = get_user_model().objects.create_user(username="assignment-denied-" + group)
                user.groups.add(Group.objects.get(name=group))
                self.recipient("denied-" + group, user=user)
                self.authenticate(user)
                self.assertEqual(self.client.get(self.versions_url).status_code, 403)
                self.assertEqual(self.client.post(self.create_url, self.payload(), format="json").status_code, 403)
        self.employee_user.user_permissions.add(Permission.objects.get(codename="assign_team_trainingassignment"))
        self.assertEqual(self.post(user=self.employee_user).status_code, 403)
        self.assert_no_assignment_writes()

    def test_admin_and_coordinator_keep_company_wide_management_only_access(self):
        for user, employee in ((self.admin, self.foreign), (self.user, self.peer)):
            with self.subTest(user=user.pk):
                self.authenticate(user)
                self.assertEqual(self.client.get(self.versions_url).status_code, 200)
                response = self.client.post(self.create_url, self.payload(employee), format="json")
                self.assertEqual(response.status_code, 201, response.data)
                self.assertEqual(response.data["assigned_by_id"], user.pk)

    def test_list_is_read_only_metadata_with_stable_bounded_pagination(self):
        # A second published version with the same title proves version tie ordering.
        second = self.new_version()
        second.title = self.version.title
        from assessments.models import Assessment, AssessmentQuestion
        from training.models import Lesson, Module
        module = Module.objects.create(training_version=second, title="Metadata fixture", position=1)
        Lesson.objects.create(module=module, title="Read", position=1, content_type="TEXT", body="Private lesson content")
        final = Assessment.objects.create(training_version=second, kind="FINAL", title="Private assessment")
        AssessmentQuestion.objects.create(assessment=final, question_revision=self.revision, position=1)
        second.status = "PUBLISHED"
        second.published_at = timezone.now()
        second.published_by = self.user
        second.save()
        self.authenticate()
        first = self.client.get(self.versions_url + "?page_size=1")
        self.assertEqual(first.data, self.client.get(self.versions_url + "?page_size=1").data)
        self.assertEqual(set(first.data), {"count", "next", "previous", "results"})
        self.assertEqual(first.data["count"], 2)
        self.assertEqual(first.data["results"][0]["id"], self.version.pk)
        self.assertEqual(self.client.get(self.versions_url + "?page_size=1&page=2").data["results"][0]["id"], second.pk)
        self.assertEqual(set(first.data["results"][0]), {
            "id", "training_id", "training_code", "training_title", "title", "version_number", "published_at",
        })
        self.assertEqual(self.client.get(self.versions_url + "?page_size=9999").data["count"], 2)
        self.assertEqual(self.client.get(self.versions_url + "?page=9999").status_code, 404)
        self.assert_no_assignment_writes()

    def test_pagination_class_enforces_existing_100_record_bound(self):
        from rest_framework.request import Request
        from rest_framework.test import APIRequestFactory
        from api.pagination import StandardResultsSetPagination
        request = Request(APIRequestFactory().get(self.versions_url, {"page_size": 9999}))
        self.assertEqual(StandardResultsSetPagination().get_page_size(request), 100)

    def test_search_matches_catalog_code_title_and_version_title(self):
        self.authenticate()
        for query in ("sAfEtY", self.training.code, self.version.title):
            with self.subTest(search=query):
                response = self.client.get(self.versions_url, {"search": " " + query + " "})
                self.assertEqual([row["id"] for row in response.data["results"]], [self.version.pk])
        self.assertEqual(self.client.get(self.versions_url, {"search": "missing"}).data["count"], 0)
        self.assertEqual(self.client.get(self.versions_url, {"search": "x" * 151}).status_code, 400)
        self.assert_no_assignment_writes()

    def test_draft_retired_and_inactive_catalog_versions_are_not_assignable(self):
        draft = self.new_version()
        self.authenticate()
        self.assertEqual(self.client.post(self.create_url, self.payload(training_version_id=draft.pk), format="json").status_code, 400)
        self.version.status = "RETIRED"
        self.version.save()
        self.assertEqual(self.client.get(self.versions_url).data["count"], 0)
        self.assertEqual(self.client.post(self.create_url, self.payload(), format="json").status_code, 400)
        self.assert_no_assignment_writes()

    def test_inactive_catalog_is_hidden_and_rejected_for_all_authorized_roles(self):
        self.training.is_active = False
        self.training.save()
        for user in (self.manager, self.admin, self.user):
            with self.subTest(user=user.pk):
                self.authenticate(user)
                self.assertEqual(self.client.get(self.versions_url).data["count"], 0)
                response = self.client.post(self.create_url, self.payload(), format="json")
                self.assertEqual(response.status_code, 400)
                self.assertIn("training_version_id", response.data["error"]["fields"])
        self.assert_no_assignment_writes()

    def test_active_catalog_is_rechecked_after_validation_and_website_default_is_unchanged(self):
        form = TrainingAssignmentForm(user=self.manager, require_active_training=True, data={
            "employee": self.direct.pk, "training_version": self.version.pk,
        })
        self.assertTrue(form.is_valid(), form.errors)
        self.training.is_active = False
        self.training.save()
        with self.assertRaises(ValidationError):
            form.save(assigned_by=self.manager)
        website_form = TrainingAssignmentForm(user=self.manager, data={"employee": self.direct.pk, "training_version": self.version.pk})
        self.assertFalse(website_form.require_active_training)
        self.assertTrue(website_form.is_valid(), website_form.errors)
        self.assert_no_assignment_writes()

    def test_duplicate_requests_create_one_assignment_notification_and_audit(self):
        with self.captureOnCommitCallbacks(execute=True):
            self.assertEqual(self.post().status_code, 201)
        with self.captureOnCommitCallbacks(execute=True):
            response = self.post()
        self.assertEqual(response.status_code, 400)
        self.assertIn("non_field_errors", response.data["error"]["fields"])
        self.assertEqual(TrainingAssignment.objects.filter(employee=self.direct).count(), 1)
        self.assertEqual(Notification.objects.count(), 1)
        self.assertEqual(AuditLog.objects.count(), 1)

    def test_due_today_and_null_deadlines_keep_local_end_of_day_semantics(self):
        with timezone.override("Asia/Kolkata"):
            today = timezone.localdate()
            response = self.post(self.payload(due_date=today.isoformat()))
            self.assertEqual(response.status_code, 201, response.data)
            assignment = TrainingAssignment.objects.get(pk=response.data["id"])
            local = timezone.localtime(assignment.due_at)
            self.assertEqual(local.date(), today)
            self.assertEqual((local.hour, local.minute, local.second, local.microsecond), (23, 59, 59, 999999))
            self.assertEqual(local.utcoffset(), timedelta(hours=5, minutes=30))
        response = self.post(self.payload(self.indirect, due_date=None))
        self.assertEqual(response.status_code, 201)
        self.assertIsNone(response.data["due_at"])

    def test_past_deadline_and_invalid_dates_return_due_date_errors(self):
        with timezone.override("Pacific/Kiritimati"):
            for value in ((timezone.localdate() - timedelta(days=1)).isoformat(), "2026-02-30", "bad", "2026-11-30T12:00:00Z"):
                with self.subTest(due_date=value):
                    response = self.post(self.payload(due_date=value))
                    self.assertEqual(response.status_code, 400)
                    self.assertIn("due_date", response.data["error"]["fields"])
        self.assert_no_assignment_writes()

    def test_unexpected_and_privileged_fields_are_rejected(self):
        for field in ("assigned_by", "source", "status", "department_at_assignment_id", "job_role_at_assignment_id", "is_superuser"):
            with self.subTest(field=field):
                response = self.post(self.payload(**{field: 1}))
                self.assertEqual(response.status_code, 400)
                self.assertIn(field, response.data["error"]["fields"])
        self.assert_no_assignment_writes()

    def test_malformed_and_missing_ids_return_controlled_errors(self):
        for field in ("employee_id", "training_version_id"):
            for value in (None, False, 0, -1, "bad", {}, [], 1.5):
                with self.subTest(field=field, value=value):
                    response = self.post(self.payload(**{field: value}))
                    self.assertEqual(response.status_code, 400)
                    self.assertIn(field, response.data["error"]["fields"])
            payload = self.payload()
            del payload[field]
            self.assertEqual(self.post(payload).status_code, 400)
        self.assert_no_assignment_writes()

    def test_non_object_and_malformed_json_bodies_are_controlled(self):
        self.authenticate()
        for body in ("[]", "null", "1", '"text"', "{broken"):
            with self.subTest(body=body):
                response = self.client.generic("POST", self.create_url, body, content_type="application/json")
                self.assertEqual(response.status_code, 400)
                self.assertIn("error", response.data)
        self.assert_no_assignment_writes()

    def test_unknown_training_id_and_unsupported_methods_do_not_write(self):
        response = self.post(self.payload(training_version_id=999999))
        self.assertEqual(response.status_code, 400)
        self.assertIn("training_version_id", response.data["error"]["fields"])
        self.assertEqual(self.client.get(self.create_url).status_code, 405)
        self.assertEqual(self.client.post(self.versions_url, {}, format="json").status_code, 405)
        self.assertEqual(self.client.patch(self.create_url, {}, format="json").status_code, 405)
        self.assert_no_assignment_writes()

    def test_failure_creates_no_assignment_notification_or_success_audit(self):
        with patch("training.forms.create_assignment_notification", side_effect=ValidationError("Notification validation failed")):
            with self.captureOnCommitCallbacks(execute=True):
                response = self.post()
        self.assertEqual(response.status_code, 400)
        self.assert_no_assignment_writes()

    def test_save_time_field_errors_are_mapped_to_mobile_field_names(self):
        for field, mapped in (("employee", "employee_id"), ("training_version", "training_version_id")):
            with patch.object(TrainingAssignmentForm, "save", side_effect=ValidationError({field: ["Changed; reload."]})):
                response = self.post()
            self.assertEqual(response.status_code, 400)
            self.assertEqual(response.data["error"]["fields"][mapped], ["Changed; reload."])
        self.assert_no_assignment_writes()

    def test_exact_mysql_uniqueness_collision_maps_to_duplicate_but_unrelated_integrity_does_not(self):
        from api.v1.assignment_management_views import ManualAssignmentCreateView
        from rest_framework.test import APIRequestFactory, force_authenticate

        # Simulate a separate writer committing after form validation but before save.
        original_is_valid = TrainingAssignmentForm.is_valid

        def validate_then_insert(form):
            valid = original_is_valid(form)
            if valid:
                TrainingAssignment.objects.create(
                    employee=self.direct, training_version=self.version, assigned_by=self.manager,
                    department_at_assignment=self.department, job_role_at_assignment=self.role,
                )
            return valid

        with patch.object(TrainingAssignmentForm, "is_valid", validate_then_insert):
            with patch.object(TrainingAssignmentForm, "save", side_effect=IntegrityError(1062, "unique_employee_version")):
                response = self.post()
        self.assertEqual(response.status_code, 400)
        self.assertIn("non_field_errors", response.data["error"]["fields"])
        self.assertEqual(TrainingAssignment.objects.filter(employee=self.direct).count(), 1)
        self.assertFalse(Notification.objects.exists())
        self.assertFalse(AuditLog.objects.exists())
        request = APIRequestFactory().post(self.create_url, self.payload(self.indirect), format="json")
        force_authenticate(request, user=self.manager)
        with patch.object(TrainingAssignmentForm, "save", side_effect=IntegrityError(1062, "unrelated_constraint")):
            with self.assertRaises(IntegrityError):
                ManualAssignmentCreateView.as_view()(request)

    def test_manager_capabilities_and_learning_ownership_do_not_expand(self):
        response = self.post()
        self.assertEqual(response.status_code, 201)
        identity = self.client.get("/api/v1/auth/me/").data
        self.assertIn("team_assignment", identity["capabilities"])
        for denied in ("company_dashboard", "training.add_trainingassignment", "management_workspace", "training.add_lesson"):
            self.assertNotIn(denied, identity["capabilities"])
        self.assertEqual(self.client.get(f'/api/v1/assignments/{response.data["id"]}/').status_code, 404)
