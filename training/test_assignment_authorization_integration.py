"""Standalone integration and authorization tests for training assignments and employee access.

Covers M19 release-readiness verification for:
1. Authorized Manager assigns published training to an eligible direct report.
2. Manager cannot assign training to an employee outside the authorized reporting hierarchy.
3. An Employee cannot assign training to themselves.
4. Another employee cannot retrieve a private assignment by guessing its ID.
5. Assignments remain pinned to the published version originally selected.
6. Duplicate assignments are rejected correctly.
7. Draft or otherwise ineligible training versions cannot be assigned.
8. Inactive employees cannot receive assignments where current business rules prohibit them.
9. Correct authorization failures do not create partial assignments or unauthorized records.
"""

from datetime import timedelta
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import IntegrityError
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from notifications.models import Notification
from organization.models import Department, Employee, JobRole
from training.models import LessonProgress, TrainingAssignment, TrainingVersion


class AssignmentAuthorizationIntegrationTests(CurriculumTestCase):
    """Authoritative integration tests verifying assignment lifecycle and authorization."""

    web_create_url = "/assignments/new/"
    api_create_url = "/api/v1/management/assignments/"
    api_versions_url = "/api/v1/management/training-versions/"

    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()

        # Groups setup
        cls.manager_group = Group.objects.get(name="Manager")
        cls.employee_group = Group.objects.get(name="Employee")
        cls.coordinator_group = Group.objects.get(name="Training Coordinator")

        cls.user.groups.add(cls.coordinator_group)
        cls.employee_user.groups.add(cls.employee_group)

        # Manager user and employee record (reports to cls.employee)
        cls.manager_user = get_user_model().objects.create_user(username="m19-manager")
        cls.manager_user.groups.add(cls.manager_group)
        cls.manager_employee = Employee.objects.create(
            employee_code="M19-MGR",
            display_name="M19 Manager",
            user=cls.manager_user,
            department=cls.department,
            job_role=cls.role,
            reporting_manager=cls.employee,
            date_joined=cls.now.date(),
        )

        # Direct report of manager
        cls.direct_user = get_user_model().objects.create_user(username="m19-direct")
        cls.direct_user.groups.add(cls.employee_group)
        cls.direct_employee = Employee.objects.create(
            employee_code="M19-DIR",
            display_name="M19 Direct Report",
            user=cls.direct_user,
            department=cls.department,
            job_role=cls.role,
            reporting_manager=cls.manager_employee,
            date_joined=cls.now.date(),
        )

        # Indirect report (reports to direct_employee)
        cls.indirect_user = get_user_model().objects.create_user(username="m19-indirect")
        cls.indirect_user.groups.add(cls.employee_group)
        cls.indirect_employee = Employee.objects.create(
            employee_code="M19-INDIR",
            display_name="M19 Indirect Report",
            user=cls.indirect_user,
            department=cls.department,
            job_role=cls.role,
            reporting_manager=cls.direct_employee,
            date_joined=cls.now.date(),
        )

        # Peer employee (reports to cls.employee, NOT manager_employee)
        cls.peer_user = get_user_model().objects.create_user(username="m19-peer")
        cls.peer_user.groups.add(cls.employee_group)
        cls.peer_employee = Employee.objects.create(
            employee_code="M19-PEER",
            display_name="M19 Peer Employee",
            user=cls.peer_user,
            department=cls.department,
            job_role=cls.role,
            reporting_manager=cls.employee,
            date_joined=cls.now.date(),
        )

        # Foreign employee (separate department, no reporting manager)
        cls.foreign_dept = Department.objects.create(code="FOR-DEP", name="Foreign Department")
        cls.foreign_role = JobRole.objects.create(code="FOR-ROL", name="Foreign Role")
        cls.foreign_user = get_user_model().objects.create_user(username="m19-foreign")
        cls.foreign_user.groups.add(cls.employee_group)
        cls.foreign_employee = Employee.objects.create(
            employee_code="M19-FOR",
            display_name="M19 Foreign Employee",
            user=cls.foreign_user,
            department=cls.foreign_dept,
            job_role=cls.foreign_role,
            reporting_manager=None,
            date_joined=cls.now.date(),
        )

        # Inactive direct report of manager
        cls.inactive_user = get_user_model().objects.create_user(username="m19-inactive")
        cls.inactive_user.groups.add(cls.employee_group)
        cls.inactive_employee = Employee.objects.create(
            employee_code="M19-INACT",
            display_name="M19 Inactive Report",
            user=cls.inactive_user,
            department=cls.department,
            job_role=cls.role,
            reporting_manager=cls.manager_employee,
            date_joined=cls.now.date(),
            is_active=False,
            deactivation_reason="M19 test fixture deactivation",
        )

    def api_client_for(self, user):
        """Build an authenticated API client with a JWT token for the user."""
        client = APIClient()
        token = RefreshToken.for_user(user).access_token
        client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
        return client

    # -------------------------------------------------------------------------
    # Scenario 1: Authorized Manager assigns published training to an eligible direct report
    # -------------------------------------------------------------------------
    def test_01_authorized_manager_assigns_published_training_to_direct_report(self):
        """A Manager can assign published training to direct reports via web and API with full audit & notifications."""
        # 1A. Web assignment to direct report
        self.client.force_login(self.manager_user)
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(self.web_create_url, {
                "employee": self.direct_employee.pk,
                "training_version": self.version.pk,
                "due_date": "",
            })
        assignment = TrainingAssignment.objects.get(employee=self.direct_employee)
        self.assertRedirects(response, f"/assignments/{assignment.pk}/", fetch_redirect_response=False)
        self.assertEqual(assignment.training_version_id, self.version.pk)
        self.assertEqual(assignment.assigned_by_id, self.manager_user.pk)
        self.assertEqual(assignment.status, TrainingAssignment.Status.ASSIGNED)
        self.assertEqual(assignment.source, TrainingAssignment.Source.MANUAL)
        self.assertEqual(assignment.department_at_assignment_id, self.direct_employee.department_id)
        self.assertEqual(assignment.job_role_at_assignment_id, self.direct_employee.job_role_id)

        # Verify notification and audit log for web creation
        notification = Notification.objects.get(assignment=assignment)
        self.assertEqual(notification.employee_id, self.direct_employee.pk)
        self.assertEqual(notification.event_type, Notification.EventType.ASSIGNED)

        audit_entry = AuditLog.objects.get(
            action="training.trainingassignment.created",
            entity_id=str(assignment.pk),
        )
        self.assertEqual(audit_entry.actor_id, self.manager_user.pk)
        self.assertEqual(audit_entry.after_data["employee_id"], self.direct_employee.pk)

        # 1B. API assignment to indirect report
        api_client = self.api_client_for(self.manager_user)
        with self.captureOnCommitCallbacks(execute=True):
            api_resp = api_client.post(self.api_create_url, {
                "employee_id": self.indirect_employee.pk,
                "training_version_id": self.version.pk,
            }, format="json")
        self.assertEqual(api_resp.status_code, 201)
        indirect_assignment = TrainingAssignment.objects.get(employee=self.indirect_employee)
        self.assertEqual(api_resp.data["id"], indirect_assignment.pk)
        self.assertEqual(indirect_assignment.assigned_by_id, self.manager_user.pk)
        self.assertEqual(indirect_assignment.status, TrainingAssignment.Status.ASSIGNED)

        # 1C. Verify direct report can see the assignment in both personal API and web views
        direct_api = self.api_client_for(self.direct_user)
        list_resp = direct_api.get("/api/v1/assignments/")
        self.assertEqual(list_resp.status_code, 200)
        assignment_ids = [row["id"] for row in list_resp.data.get("results", list_resp.data)]
        self.assertIn(assignment.pk, assignment_ids)

        self.client.force_login(self.direct_user)
        web_resp = self.client.get(f"/assignments/{assignment.pk}/")
        self.assertEqual(web_resp.status_code, 200)
        self.assertTrue(web_resp.context.get("can_learn"))

    # -------------------------------------------------------------------------
    # Scenario 2: Manager cannot assign training to employee outside reporting hierarchy
    # -------------------------------------------------------------------------
    def test_02_manager_cannot_assign_to_employee_outside_authorized_hierarchy(self):
        """Managers are strictly scoped to direct and indirect reports; peers, superiors, and foreign employees are rejected."""
        self.client.force_login(self.manager_user)
        api_client = self.api_client_for(self.manager_user)

        out_of_scope = [
            ("peer", self.peer_employee.pk),
            ("superior", self.employee.pk),
            ("foreign", self.foreign_employee.pk),
            ("nonexistent", 999999),
        ]

        before_assignment_count = TrainingAssignment.objects.count()

        for label, emp_id in out_of_scope:
            with self.subTest(scope=label, employee_id=emp_id):
                # Web attempt
                web_resp = self.client.post(self.web_create_url, {
                    "employee": emp_id,
                    "training_version": self.version.pk,
                    "due_date": "",
                })
                self.assertEqual(web_resp.status_code, 200)
                self.assertIn("employee", web_resp.context["form"].errors)

                # API attempt
                api_resp = api_client.post(self.api_create_url, {
                    "employee_id": emp_id,
                    "training_version_id": self.version.pk,
                }, format="json")
                self.assertEqual(api_resp.status_code, 400)
                self.assertIn("employee_id", api_resp.data["error"]["fields"])

        # No records created
        self.assertEqual(TrainingAssignment.objects.count(), before_assignment_count)

    # -------------------------------------------------------------------------
    # Scenario 3: An Employee cannot assign training to themselves or others; Manager cannot self-assign
    # -------------------------------------------------------------------------
    def test_03_employee_cannot_assign_training_and_manager_cannot_self_assign(self):
        """Regular employees cannot access assignment creation, and managers cannot self-assign."""
        # 3A. Regular employee access blocked
        self.client.force_login(self.direct_user)
        self.assertEqual(self.client.get(self.web_create_url).status_code, 403)
        self.assertEqual(self.client.post(self.web_create_url, {
            "employee": self.direct_employee.pk,
            "training_version": self.version.pk,
        }).status_code, 403)

        employee_api = self.api_client_for(self.direct_user)
        self.assertEqual(employee_api.post(self.api_create_url, {
            "employee_id": self.direct_employee.pk,
            "training_version_id": self.version.pk,
        }, format="json").status_code, 403)

        # 3B. Manager cannot assign training to themselves
        self.client.force_login(self.manager_user)
        web_resp = self.client.post(self.web_create_url, {
            "employee": self.manager_employee.pk,
            "training_version": self.version.pk,
            "due_date": "",
        })
        self.assertEqual(web_resp.status_code, 200)
        self.assertIn("employee", web_resp.context["form"].errors)

        manager_api = self.api_client_for(self.manager_user)
        api_resp = manager_api.post(self.api_create_url, {
            "employee_id": self.manager_employee.pk,
            "training_version_id": self.version.pk,
        }, format="json")
        self.assertEqual(api_resp.status_code, 400)
        self.assertIn("employee_id", api_resp.data["error"]["fields"])

    # -------------------------------------------------------------------------
    # Scenario 4: Another employee cannot retrieve private assignment by guessing ID
    # -------------------------------------------------------------------------
    def test_04_cross_employee_private_assignment_retrieval_prevented(self):
        """Learners can only retrieve their own assignments. Guessing other IDs returns fail-closed 404."""
        # Create an assignment for direct_employee
        assignment = TrainingAssignment.objects.create(
            employee=self.direct_employee,
            training_version=self.version,
            department_at_assignment=self.department,
            job_role_at_assignment=self.role,
            assigned_by=self.manager_user,
            status=TrainingAssignment.Status.ASSIGNED,
        )

        # Peer employee attempts to inspect or mutate direct employee's assignment
        peer_api = self.api_client_for(self.peer_user)

        # 4A. API detail view returns fail-closed 404
        self.assertEqual(peer_api.get(f"/api/v1/assignments/{assignment.pk}/").status_code, 404)

        # 4B. API lesson progress, completion, session endpoints return fail-closed 404
        self.assertEqual(
            peer_api.get(f"/api/v1/assignments/{assignment.pk}/lessons/{self.text_lesson.pk}/progress/").status_code,
            404,
        )
        self.assertEqual(
            peer_api.post(f"/api/v1/assignments/{assignment.pk}/lessons/{self.text_lesson.pk}/complete/").status_code,
            404,
        )
        self.assertEqual(
            peer_api.post(f"/api/v1/assignments/{assignment.pk}/lessons/{self.video_lesson.pk}/sessions/").status_code,
            404,
        )

        # 4C. Web detail view returns fail-closed 404
        self.client.force_login(self.peer_user)
        self.assertEqual(self.client.get(f"/assignments/{assignment.pk}/").status_code, 404)

        # 4D. Anonymous access rejected (401 on API, 403 on protected web view)
        self.client.logout()
        unauth_api = APIClient()
        self.assertEqual(unauth_api.get(f"/api/v1/assignments/{assignment.pk}/").status_code, 401)
        self.assertEqual(self.client.get(f"/assignments/{assignment.pk}/").status_code, 403)

    # -------------------------------------------------------------------------
    # Scenario 5: Assignments remain pinned to the published version originally selected
    # -------------------------------------------------------------------------
    def test_05_assignment_remains_pinned_to_originally_selected_version(self):
        """Assignments stay strictly pinned to their original version, even when newer versions are published or old ones retired."""
        # Create assignment on version 1
        assignment = TrainingAssignment.objects.create(
            employee=self.direct_employee,
            training_version=self.version,
            department_at_assignment=self.department,
            job_role_at_assignment=self.role,
            assigned_by=self.manager_user,
            assigned_at=self.now,
            started_at=self.now,
            status=TrainingAssignment.Status.IN_PROGRESS,
        )

        # Later, Version 2 is published and Version 1 is retired
        from assessments.models import Assessment, AssessmentQuestion
        from training.models import Lesson, Module
        v2 = self.new_version()
        v2.title = "Safety v2 Enhanced"
        v2_module = Module.objects.create(training_version=v2, title="V2 Module", position=1)
        Lesson.objects.create(module=v2_module, title="V2 Lesson", position=1, content_type="TEXT", body="V2 content")
        v2_final = Assessment.objects.create(training_version=v2, kind="FINAL", title="V2 Final")
        AssessmentQuestion.objects.create(assessment=v2_final, question_revision=self.revision, position=1)
        v2.status = TrainingVersion.Status.PUBLISHED
        v2.published_at = timezone.now()
        v2.published_by = self.user
        v2.save()

        self.version.status = TrainingVersion.Status.RETIRED
        self.version.save()

        # Database verification: assignment is still pinned to version 1
        assignment.refresh_from_db()
        self.assertEqual(assignment.training_version_id, self.version.pk)
        self.assertNotEqual(assignment.training_version_id, v2.pk)

        # Web detail renders Version 1 content, even if ?training_version_id=v2 is injected
        self.client.force_login(self.direct_user)
        resp = self.client.get(f"/assignments/{assignment.pk}/?training_version_id={v2.pk}")
        self.assertEqual(resp.status_code, 200)
        self.assertContains(resp, "Safety v1")
        self.assertNotContains(resp, "Safety v2 Enhanced")

        # API detail serves Version 1 metadata
        direct_api = self.api_client_for(self.direct_user)
        api_resp = direct_api.get(f"/api/v1/assignments/{assignment.pk}/")
        self.assertEqual(api_resp.status_code, 200)
        self.assertEqual(api_resp.data["training_title"], "Safety v1")
        self.assertEqual(api_resp.data["version_number"], 1)
        module_titles = [m["title"] for m in api_resp.data["modules"]]
        self.assertIn("Introduction", module_titles)
        self.assertNotIn("V2 Module", module_titles)

        # Manager progress summary respects pinned version 1
        self.client.force_login(self.manager_user)
        mgr_resp = self.client.get(f"/assignments/{assignment.pk}/")
        self.assertEqual(mgr_resp.status_code, 200)
        self.assertIn("management_progress", mgr_resp.context)
        self.assertContains(mgr_resp, "Safety v1")
        self.assertNotContains(mgr_resp, "Safety v2 Enhanced")

    # -------------------------------------------------------------------------
    # Scenario 6: Duplicate assignments are rejected correctly
    # -------------------------------------------------------------------------
    def test_06_duplicate_assignment_rejected_web_and_api(self):
        """Duplicate assignments for the same employee and version fail validation without duplicate side effects."""
        # Initial assignment
        TrainingAssignment.objects.create(
            employee=self.direct_employee,
            training_version=self.version,
            department_at_assignment=self.department,
            job_role_at_assignment=self.role,
            assigned_by=self.manager_user,
            status=TrainingAssignment.Status.ASSIGNED,
        )

        before_notifications = Notification.objects.count()
        before_audits = AuditLog.objects.count()

        # 6A. Web duplicate attempt
        self.client.force_login(self.manager_user)
        web_resp = self.client.post(self.web_create_url, {
            "employee": self.direct_employee.pk,
            "training_version": self.version.pk,
            "due_date": "",
        })
        self.assertEqual(web_resp.status_code, 200)
        self.assertContains(web_resp, "already has an assignment for that training version")

        # 6B. API duplicate attempt
        manager_api = self.api_client_for(self.manager_user)
        api_resp = manager_api.post(self.api_create_url, {
            "employee_id": self.direct_employee.pk,
            "training_version_id": self.version.pk,
        }, format="json")
        self.assertEqual(api_resp.status_code, 400)
        self.assertIn("non_field_errors", api_resp.data["error"]["fields"])
        self.assertIn(
            "already has an assignment",
            api_resp.data["error"]["fields"]["non_field_errors"][0],
        )

        # Count remains 1, no duplicate notifications or audit records
        self.assertEqual(
            TrainingAssignment.objects.filter(employee=self.direct_employee, training_version=self.version).count(),
            1,
        )
        self.assertEqual(Notification.objects.count(), before_notifications)
        self.assertEqual(AuditLog.objects.count(), before_audits)

    # -------------------------------------------------------------------------
    # Scenario 7: Draft or otherwise ineligible training versions cannot be assigned
    # -------------------------------------------------------------------------
    def test_07_draft_and_retired_versions_ineligible_for_assignment(self):
        """Draft, retired, and deactivated catalog training versions cannot be assigned via web or API."""
        draft_version = self.new_version()
        self.assertEqual(draft_version.status, TrainingVersion.Status.DRAFT)

        self.client.force_login(self.manager_user)
        manager_api = self.api_client_for(self.manager_user)

        # 7A. Draft version rejected
        web_resp = self.client.post(self.web_create_url, {
            "employee": self.direct_employee.pk,
            "training_version": draft_version.pk,
            "due_date": "",
        })
        self.assertEqual(web_resp.status_code, 200)
        self.assertIn("training_version", web_resp.context["form"].errors)

        api_resp = manager_api.post(self.api_create_url, {
            "employee_id": self.direct_employee.pk,
            "training_version_id": draft_version.pk,
        }, format="json")
        self.assertEqual(api_resp.status_code, 400)
        self.assertIn("training_version_id", api_resp.data["error"]["fields"])

        # 7B. Retired version rejected
        self.version.status = TrainingVersion.Status.RETIRED
        self.version.save()

        web_retired = self.client.post(self.web_create_url, {
            "employee": self.direct_employee.pk,
            "training_version": self.version.pk,
            "due_date": "",
        })
        self.assertEqual(web_retired.status_code, 200)
        self.assertIn("training_version", web_retired.context["form"].errors)

        api_retired = manager_api.post(self.api_create_url, {
            "employee_id": self.direct_employee.pk,
            "training_version_id": self.version.pk,
        }, format="json")
        self.assertEqual(api_retired.status_code, 400)
        self.assertIn("training_version_id", api_retired.data["error"]["fields"])

        # 7C. Deactivated training catalog entry rejected
        self.training.is_active = False
        self.training.save()

        api_inactive_cat = manager_api.post(self.api_create_url, {
            "employee_id": self.direct_employee.pk,
            "training_version_id": self.version.pk,
        }, format="json")
        self.assertEqual(api_inactive_cat.status_code, 400)

        self.assertFalse(TrainingAssignment.objects.filter(employee=self.direct_employee).exists())

    # -------------------------------------------------------------------------
    # Scenario 8: Inactive employees cannot receive assignments
    # -------------------------------------------------------------------------
    def test_08_inactive_employee_cannot_receive_assignments(self):
        """Inactive employees are excluded from assignable scopes, fail assignment validation, and cannot authenticate."""
        self.client.force_login(self.manager_user)
        manager_api = self.api_client_for(self.manager_user)

        # Web check: inactive employee choice is rejected
        web_resp = self.client.post(self.web_create_url, {
            "employee": self.inactive_employee.pk,
            "training_version": self.version.pk,
            "due_date": "",
        })
        self.assertEqual(web_resp.status_code, 200)
        self.assertIn("employee", web_resp.context["form"].errors)

        # API check: inactive employee ID rejected
        api_resp = manager_api.post(self.api_create_url, {
            "employee_id": self.inactive_employee.pk,
            "training_version_id": self.version.pk,
        }, format="json")
        self.assertEqual(api_resp.status_code, 400)
        self.assertIn("employee_id", api_resp.data["error"]["fields"])

        # Inactive employee cannot access learning API endpoints (authentication/eligibility denied)
        inactive_api = self.api_client_for(self.inactive_user)
        self.assertIn(inactive_api.get("/api/v1/assignments/").status_code, (401, 403))

        self.assertFalse(TrainingAssignment.objects.filter(employee=self.inactive_employee).exists())

    # -------------------------------------------------------------------------
    # Scenario 9: Authorization and validation failures create no partial records
    # -------------------------------------------------------------------------
    def test_09_correct_authorization_failures_create_no_partial_records(self):
        """When an assignment operation fails authorization or validation, database state rolls back cleanly."""
        baseline_assignments = TrainingAssignment.objects.count()
        baseline_notifications = Notification.objects.count()
        baseline_audits = AuditLog.objects.count()
        baseline_progress = LessonProgress.objects.count()

        # 9A. Web notification failure triggers full atomic rollback
        self.client.force_login(self.manager_user)
        with patch("training.forms.create_assignment_notification", side_effect=IntegrityError("Simulated failure")):
            with self.captureOnCommitCallbacks(execute=True):
                web_resp = self.client.post(self.web_create_url, {
                    "employee": self.direct_employee.pk,
                    "training_version": self.version.pk,
                    "due_date": "",
                })
                self.assertEqual(web_resp.status_code, 200)
                self.assertTrue(web_resp.context["form"].non_field_errors())

        # 9B. API notification validation failure triggers full atomic rollback
        manager_api = self.api_client_for(self.manager_user)
        with patch("training.forms.create_assignment_notification", side_effect=DjangoValidationError("Simulated validation failure")):
            with self.captureOnCommitCallbacks(execute=True):
                api_resp = manager_api.post(self.api_create_url, {
                    "employee_id": self.direct_employee.pk,
                    "training_version_id": self.version.pk,
                }, format="json")
                self.assertEqual(api_resp.status_code, 400)

        # Verify full transaction rollback: zero orphaned records created
        self.assertEqual(TrainingAssignment.objects.count(), baseline_assignments)
        self.assertEqual(Notification.objects.count(), baseline_notifications)
        self.assertEqual(AuditLog.objects.count(), baseline_audits)
        self.assertEqual(LessonProgress.objects.count(), baseline_progress)
