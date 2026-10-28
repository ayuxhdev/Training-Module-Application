"""Isolated, rollback-only regressions for company/team assignment monitoring."""

import hashlib
import json
from datetime import timedelta

from django.apps import apps
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.serializers.json import DjangoJSONEncoder
from django.db import connection
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from assessments.models import Assessment, AssessmentQuestion
from config.model_test_utils import CurriculumTestCase
from organization.models import Employee
from training.models import Lesson, LessonProgress, Module, Training, TrainingAssignment, TrainingVersion


class AssignmentMonitoringAPITests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.user.groups.add(Group.objects.get(name="Training Coordinator"))
        cls.employee_user.groups.add(Group.objects.get(name="Employee"))
        cls.admin = get_user_model().objects.create_user(username="monitor-admin")
        cls.admin.groups.add(Group.objects.get(name="Administrator"))
        cls.manager = get_user_model().objects.create_user(username="monitor-manager")
        cls.manager.groups.add(Group.objects.get(name="Manager"))
        cls.superior = cls.recipient("superior")
        cls.manager_employee = cls.recipient("manager", user=cls.manager, manager=cls.superior)
        cls.employee.reporting_manager = cls.manager_employee
        cls.employee.save()
        cls.indirect = cls.recipient("indirect", manager=cls.employee)
        cls.peer = cls.recipient("peer", manager=cls.superior)
        cls.foreign = cls.recipient("foreign")
        cls.inactive = cls.recipient("inactive", manager=cls.manager_employee)
        cls.inactive_assignment = cls.assignment_for(cls.inactive)
        cls.inactive.is_active = False
        cls.inactive.deactivation_reason = "Isolated fixture"
        cls.inactive.save()
        cls.indirect_assignment = cls.assignment_for(cls.indirect)
        cls.foreign_assignment = cls.assignment_for(cls.foreign)

    @classmethod
    def recipient(cls, label, *, user=None, manager=None):
        return Employee.objects.create(
            employee_code="MONITOR-" + label.upper(), display_name=label,
            user=user, reporting_manager=manager, department=cls.department,
            job_role=cls.role, date_joined=cls.now.date(),
        )

    @classmethod
    def assignment_for(cls, employee, version=None, **kwargs):
        return TrainingAssignment.objects.create(
            employee=employee, training_version=version or cls.version,
            department_at_assignment=employee.department, job_role_at_assignment=employee.job_role,
            assigned_by=cls.user, assigned_at=kwargs.pop("assigned_at", cls.now), **kwargs,
        )

    def extra_assignment(self, number, **kwargs):
        training = Training.objects.create(code=f"MON-{number}", catalog_title=f"Catalog {number}", created_by=self.user)
        version = TrainingVersion.objects.create(training=training, version_number=1, title=f"Pinned title {number}", created_by=self.user)
        module = Module.objects.create(training_version=version, title="Module", position=1)
        Lesson.objects.create(module=module, title="Required text", position=1, content_type="TEXT", body="Content")
        final = Assessment.objects.create(training_version=version, kind="FINAL", title="Final")
        AssessmentQuestion.objects.create(assessment=final, question_revision=self.revision, position=1, points=2)
        version.status = "PUBLISHED"
        version.published_at = self.now
        version.published_by = self.user
        version.save()
        return self.assignment_for(self.employee, version, **kwargs)

    def setUp(self):
        self.client = APIClient()

    def authenticate(self, user=None):
        user = user or self.manager
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + str(RefreshToken.for_user(user).access_token))

    def url(self, employee=None):
        employee_id = (employee or self.employee).pk
        return f"/api/v1/management/employees/{employee_id}/assignments/"

    def get(self, employee=None, *, user=None, query=""):
        self.authenticate(user)
        return self.client.get(self.url(employee) + query)

    def test_manager_direct_report(self):
        response = self.get()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["count"], 1)
        self.assertEqual([row["id"] for row in response.data["results"]], [self.assignment.pk])

    def test_manager_indirect_report(self):
        response = self.get(self.indirect)
        self.assertEqual(response.status_code, 200)
        self.assertEqual([row["id"] for row in response.data["results"]], [self.indirect_assignment.pk])

    def test_self_peer_superior_foreign_inactive_and_unknown_share_generic_404(self):
        payloads = []
        self.authenticate()
        for employee in (self.manager_employee, self.peer, self.superior, self.foreign, self.inactive):
            with self.subTest(employee=employee.pk):
                response = self.client.get(self.url(employee))
                self.assertEqual(response.status_code, 404)
                payloads.append(response.data)
        response = self.client.get("/api/v1/management/employees/999999999/assignments/")
        self.assertEqual(response.status_code, 404)
        self.assertTrue(all(data == response.data for data in payloads))
        self.assertEqual(set(response.data), {"error"})
        self.assertEqual(response.data["error"]["fields"], {})

    def test_unauthorized_target_is_checked_before_pagination(self):
        response = self.get(self.foreign, query="?page=999999")
        self.assertEqual(response.status_code, 404)
        self.assertEqual(response.data, self.get(self.foreign).data)

    def test_query_parameters_cannot_change_employee_scope(self):
        response = self.get(query=f"?employee_id={self.foreign.pk}&scope=company")
        self.assertEqual(response.status_code, 200)
        self.assertEqual([row["id"] for row in response.data["results"]], [self.assignment.pk])

    def test_team_read_does_not_require_assignment_write_permission(self):
        permission = Permission.objects.get(content_type__app_label="training", codename="assign_team_trainingassignment")
        Group.objects.get(name="Manager").permissions.remove(permission)
        self.assertEqual(self.get().status_code, 200)

    def test_directory_permission_alone_grants_no_monitoring(self):
        self.authenticate(self.employee_user)
        self.assertEqual(self.client.get(f"/api/v1/management/employees/{self.employee.pk}/").status_code, 200)
        own = self.client.get(self.url())
        foreign = self.client.get(self.url(self.foreign))
        self.assertEqual(own.status_code, 403)
        self.assertEqual(own.data, foreign.data)
        self.assertEqual(self.client.get("/api/v1/assignments/").status_code, 200)

    def test_company_wide_directory_grant_does_not_broaden_manager_monitoring(self):
        self.manager.user_permissions.add(Permission.objects.get(content_type__app_label="organization", codename="change_employee"))
        self.authenticate()
        self.assertEqual(self.client.get(f"/api/v1/management/employees/{self.foreign.pk}/").status_code, 200)
        self.assertEqual(self.client.get(self.url(self.foreign)).status_code, 404)
        self.assertEqual(self.client.get(self.url()).status_code, 200)

    def test_trainer_supervisor_and_unlinked_manager_are_denied(self):
        for name in ("Trainer", "Supervisor", "Manager"):
            with self.subTest(group=name):
                user = get_user_model().objects.create_user(username="monitor-denied-" + name.lower())
                user.groups.add(Group.objects.get(name=name))
                if name != "Manager":
                    self.recipient(name.lower(), user=user)
                self.assertEqual(self.get(user=user).status_code, 403)

    def test_disabled_actor_user_is_401(self):
        self.authenticate()
        self.manager.is_active = False
        self.manager.save(update_fields=["is_active"])
        self.assertEqual(self.client.get(self.url()).status_code, 401)

    def test_inactive_actor_employee_cannot_bypass_with_enabled_user(self):
        self.authenticate()
        self.manager_employee.is_active = False
        self.manager_employee.deactivation_reason = "Isolated fixture"
        self.manager_employee.save()
        self.manager.is_active = True
        self.manager.save(update_fields=["is_active"])
        self.assertEqual(self.client.get(self.url()).status_code, 403)

    def test_company_account_with_inactive_employee_is_also_denied(self):
        self.manager.groups.add(Group.objects.get(name="Administrator"))
        self.test_inactive_actor_employee_cannot_bypass_with_enabled_user()

    def test_missing_and_invalid_jwt_and_web_session_only_are_401(self):
        self.assertEqual(self.client.get(self.url()).status_code, 401)
        self.client.credentials(HTTP_AUTHORIZATION="Bearer invalid")
        self.assertEqual(self.client.get(self.url()).status_code, 401)
        self.client.credentials()
        self.client.force_login(self.manager)
        self.assertEqual(self.client.get(self.url()).status_code, 401)

    def test_administrator_and_coordinator_keep_company_oversight_without_employee_link(self):
        for user in (self.admin, self.user):
            with self.subTest(user=user.pk):
                response = self.get(self.foreign, user=user)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.data["results"][0]["id"], self.foreign_assignment.pk)
                inactive = self.get(self.inactive, user=user)
                self.assertEqual(inactive.status_code, 200)
                self.assertEqual(inactive.data["results"][0]["id"], self.inactive_assignment.pk)

    def test_mixed_administrator_manager_preserves_global_precedence_and_self_access(self):
        self.manager.groups.add(Group.objects.get(name="Administrator"))
        self.assertEqual(self.get(self.foreign).status_code, 200)
        self.assertEqual(self.get(self.manager_employee).status_code, 200)
        self.assertEqual(self.get(self.inactive).status_code, 200)

    def test_mixed_manager_employee_keeps_team_scope(self):
        self.manager.groups.add(Group.objects.get(name="Employee"))
        self.assertEqual(self.get().status_code, 200)
        self.assertEqual(self.get(self.foreign).status_code, 404)
        self.assertEqual(self.get(self.manager_employee).status_code, 404)

    def test_explicit_global_assignment_permission_preserves_existing_authority(self):
        self.employee_user.user_permissions.add(Permission.objects.get(content_type__app_label="training", codename="add_trainingassignment"))
        self.assertEqual(self.get(self.foreign, user=self.employee_user).status_code, 200)

    def test_active_target_without_login_or_with_disabled_login_remains_monitorable(self):
        self.assertIsNone(self.indirect.user_id)
        self.assertEqual(self.get(self.indirect).status_code, 200)
        self.employee_user.is_active = False
        self.employee_user.save(update_fields=["is_active"])
        self.assertTrue(self.employee.is_active)
        self.assertEqual(self.get().status_code, 200)

    def test_empty_team_employee_has_normal_paginated_envelope(self):
        empty = self.recipient("empty", manager=self.manager_employee)
        response = self.get(empty)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(dict(response.data), {"count": 0, "next": None, "previous": None, "results": []})

    def test_summary_contract_dates_due_and_server_lesson_counts(self):
        self.assignment.due_at = timezone.now() - timedelta(seconds=1)
        self.assignment.save()
        LessonProgress.objects.create(assignment=self.assignment, lesson=self.text_lesson, started_at=self.now, last_accessed_at=timezone.now(), completed_at=timezone.now())
        response = self.get()
        row = response.data["results"][0]
        self.assertEqual(set(row), {"id", "training_id", "training_version_id", "training_title", "version_number", "status", "assigned_at", "due_at", "started_at", "completed_at", "is_overdue", "progress_summary"})
        self.assertEqual(row["training_version_id"], self.version.pk)
        self.assertEqual(row["training_id"], self.training.pk)
        self.assertEqual(row["training_title"], self.version.title)
        self.assertEqual(row["version_number"], self.version.version_number)
        self.assertEqual(row["status"], "IN_PROGRESS")
        self.assertTrue(row["is_overdue"])
        self.assertIsNotNone(row["assigned_at"])
        self.assertIsNotNone(row["due_at"])
        self.assertIsNotNone(row["started_at"])
        self.assertIsNone(row["completed_at"])
        self.assertEqual(row["progress_summary"], {"required_lessons_completed": 1, "required_lessons_total": 2})
        self.authenticate(self.employee_user)
        learner = self.client.get("/api/v1/assignments/").data["results"][0]
        self.assertEqual({key: value for key, value in row.items() if key != "training_version_id"}, learner)

    def test_null_deadline_and_assigned_status(self):
        row = self.get(self.indirect).data["results"][0]
        self.assertEqual(row["status"], "ASSIGNED")
        self.assertIsNone(row["due_at"])
        self.assertIsNone(row["started_at"])
        self.assertFalse(row["is_overdue"])

    def test_completed_history_keeps_retired_pinned_version_without_mutation(self):
        self.complete_assignment()
        self.version.status = "RETIRED"
        self.version.retired_at = timezone.now()
        self.version.save()
        row = self.get().data["results"][0]
        self.assertEqual(row["status"], "COMPLETED")
        self.assertEqual(row["training_version_id"], self.version.pk)
        self.assertEqual(row["progress_summary"], {"required_lessons_completed": 2, "required_lessons_total": 2})
        self.assertIsNotNone(row["completed_at"])
        self.assertFalse(row["is_overdue"])

    def test_cancelled_assignment_is_not_overdue(self):
        self.assignment.status = "CANCELLED"
        self.assignment.cancelled_at = timezone.now()
        self.assignment.cancellation_reason = "Isolated fixture"
        self.assignment.due_at = timezone.now() - timedelta(seconds=1)
        self.assignment.save()
        row = self.get().data["results"][0]
        self.assertEqual(row["status"], "CANCELLED")
        self.assertFalse(row["is_overdue"])

    def test_pagination_order_is_newest_then_descending_primary_key_and_stable(self):
        newer = self.extra_assignment(2, assigned_at=self.now + timedelta(seconds=2))
        newest = self.extra_assignment(3, assigned_at=self.now + timedelta(seconds=2))
        oldest = self.extra_assignment(4, assigned_at=self.now - timedelta(seconds=1))
        expected = [newest.pk, newer.pk, self.assignment.pk, oldest.pk]
        for _ in range(2):
            ids = []
            for page in range(1, 5):
                response = self.get(query=f"?page_size=1&page={page}")
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.data["count"], 4)
                self.assertEqual(response.data["previous"] is None, page == 1)
                self.assertEqual(response.data["next"] is None, page == 4)
                ids.append(response.data["results"][0]["id"])
            self.assertEqual(ids, expected)
        self.assertEqual(self.get(query="?page_size=1&page=5").status_code, 404)

    def test_pagination_is_bounded_by_existing_convention(self):
        from api.pagination import StandardResultsSetPagination
        from rest_framework.request import Request
        from rest_framework.test import APIRequestFactory

        paginator = StandardResultsSetPagination()
        self.assertEqual(paginator.get_page_size(Request(APIRequestFactory().get("/"))), 20)
        self.assertEqual(paginator.get_page_size(Request(APIRequestFactory().get("/", {"page_size": 999}))), 100)

    def test_scope_changes_and_group_revocation_take_effect_with_existing_jwt(self):
        self.authenticate()
        self.employee.reporting_manager = self.foreign
        self.employee.save()
        self.assertEqual(self.client.get(self.url()).status_code, 404)
        self.assertEqual(self.client.get(self.url(self.indirect)).status_code, 404)
        self.manager.groups.clear()
        self.assertEqual(self.client.get(self.url()).status_code, 403)

    def test_monitoring_never_grants_personal_lesson_or_assignment_access(self):
        self.authenticate()
        self.assertEqual(self.client.get(self.url()).status_code, 200)
        self.assertEqual(self.client.get(f"/api/v1/assignments/{self.assignment.pk}/").status_code, 404)
        self.assertEqual(self.client.post(f"/api/v1/assignments/{self.assignment.pk}/lessons/{self.text_lesson.pk}/complete/", {}, format="json").status_code, 404)

    def test_unsupported_mutation_methods_are_405(self):
        self.authenticate()
        for method in ("post", "patch", "put", "delete"):
            with self.subTest(method=method):
                response = getattr(self.client, method)(self.url(), {}, format="json")
                self.assertEqual(response.status_code, 405)
                self.assertEqual(set(response.data), {"error"})

    def test_get_head_options_do_not_modify_any_database_record(self):
        self.authenticate()
        def signature():
            state = {model._meta.label: list(model.objects.order_by("pk").values()) for model in apps.get_models()}
            return hashlib.sha256(json.dumps(state, cls=DjangoJSONEncoder, sort_keys=True).encode()).hexdigest()
        before = signature()
        with CaptureQueriesContext(connection) as captured:
            for method in ("get", "head", "options"):
                self.assertEqual(getattr(self.client, method)(self.url()).status_code, 200)
        self.assertEqual(signature(), before)
        self.assertFalse(any(query["sql"].lstrip().split()[0].upper() in {"INSERT", "UPDATE", "DELETE", "REPLACE", "CREATE", "ALTER", "DROP", "TRUNCATE"} for query in captured))

    def test_assignment_query_count_does_not_grow_with_page_rows(self):
        self.authenticate()
        with CaptureQueriesContext(connection) as one:
            self.assertEqual(self.client.get(self.url()).status_code, 200)
        self.extra_assignment(2)
        self.extra_assignment(3)
        with CaptureQueriesContext(connection) as many:
            self.assertEqual(self.client.get(self.url()).status_code, 200)
        self.assertEqual(len(one), len(many))
