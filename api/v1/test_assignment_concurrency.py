"""Actual MySQL requests racing on committed, disposable fixtures; no flush."""

from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from unittest.mock import patch

from django.contrib.auth.models import Group, Permission
from django.db import connection, models
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from assessments.models import Assessment, AssessmentQuestion, Question, QuestionOption, QuestionRevision
from audit.models import AuditLog
from notifications.models import Notification
from organization.models import Employee
from training.forms import TrainingAssignmentForm
from training.models import Lesson, Module, Training, TrainingAssignment, TrainingVersion

from .test_m21_concurrency import MySQLConcurrencyFixtures


class AssignmentCreationConcurrencyTests(MySQLConcurrencyFixtures):
    def setUp(self):
        super().setUp()
        self.test_database = connection.settings_dict["NAME"]
        self.fixture_ids = {}
        self.manager_group = None
        self.created_manager_group = False
        self.addCleanup(self.cleanup_curriculum)
        # Full CI may have flushed migration-created groups earlier. Use only
        # a fixture membership/direct grant, leaving existing group grants alone.
        self.manager_group, self.created_manager_group = Group.objects.get_or_create(name="Manager")
        self.user.groups.add(self.manager_group)
        self.user.user_permissions.add(Permission.objects.get(
            content_type__app_label="training", codename="assign_team_trainingassignment",
        ))
        self.recipient = self.remember(Employee.objects.create(
            employee_code=self.marker + "-R", display_name="Race recipient", reporting_manager=self.employee,
            department_id=self.department_id, job_role_id=self.role_id, date_joined=timezone.localdate(),
        ))
        self.training = self.remember(Training.objects.create(code=self.marker, catalog_title="Assignment race", created_by=self.user))
        self.version = self.remember(TrainingVersion.objects.create(
            training=self.training, version_number=1, title="Published race fixture", created_by=self.user,
        ))
        module = self.remember(Module.objects.create(training_version=self.version, title="Read", position=1))
        self.remember(Lesson.objects.create(module=module, title="Read", position=1, content_type="TEXT", body="Disposable fixture"))
        question = self.remember(Question.objects.create(code=self.marker, topic="Isolated", created_by=self.user))
        revision = self.remember(QuestionRevision.objects.create(question=question, revision_number=1, prompt="Fixture?", created_by=self.user))
        self.remember(QuestionOption.objects.create(question_revision=revision, text="Yes", position=1, is_correct=True))
        self.remember(QuestionOption.objects.create(question_revision=revision, text="No", position=2))
        revision.status, revision.frozen_at = "FROZEN", timezone.now()
        revision.save()
        final = self.remember(Assessment.objects.create(training_version=self.version, kind="FINAL", title="Final"))
        self.remember(AssessmentQuestion.objects.create(assessment=final, question_revision=revision, position=1))
        self.version.status, self.version.published_at, self.version.published_by = "PUBLISHED", timezone.now(), self.user
        self.version.save()
        self.access = str(RefreshToken.for_user(self.user).access_token)

    def remember(self, instance):
        self.fixture_ids.setdefault(type(instance), []).append(instance.pk)
        return instance

    def cleanup_curriculum(self):
        employee_ids = self.fixture_ids.get(Employee, [])
        version_ids = self.fixture_ids.get(TrainingVersion, [])
        assignment_ids = list(TrainingAssignment.objects.filter(
            employee_id__in=employee_ids, training_version_id__in=version_ids,
        ).values_list("pk", flat=True))
        models.QuerySet(Notification, using="default").filter(assignment_id__in=assignment_ids)._raw_delete("default")
        models.QuerySet(TrainingAssignment, using="default").filter(pk__in=assignment_ids)._raw_delete("default")
        # Exact IDs created above, ordered for FK integrity. Production history
        # protections are unchanged; this runs only after the inherited DB guard.
        for model in (AssessmentQuestion, Assessment, Lesson, Module, TrainingVersion, Training,
                      QuestionOption, QuestionRevision, Question, Employee):
            models.QuerySet(model, using="default").filter(pk__in=self.fixture_ids.get(model, []))._raw_delete("default")
        self.user.groups.clear()
        self.user.user_permissions.clear()
        if self.created_manager_group:
            self.assertFalse(self.manager_group.user_set.exists())
            self.assertFalse(self.manager_group.permissions.exists())
            self.manager_group.delete()

    def test_simultaneous_valid_requests_create_one_assignment_notification_and_audit(self):
        ready = Barrier(2)
        save = TrainingAssignmentForm.save

        def synchronized_save(form, *args, **kwargs):
            # Both forms have passed is_valid before either takes hierarchy locks.
            ready.wait(timeout=15)
            return save(form, *args, **kwargs)

        def request():
            self.assertEqual(connection.settings_dict["NAME"], self.test_database)
            with connection.cursor() as cursor:
                cursor.execute("SELECT DATABASE()")
                self.assertEqual(cursor.fetchone(), (self.test_database,))
            client = APIClient()
            client.credentials(HTTP_AUTHORIZATION="Bearer " + self.access)
            return client.post("/api/v1/management/assignments/", {
                "employee_id": self.recipient.pk, "training_version_id": self.version.pk,
            }, format="json")

        with patch.object(TrainingAssignmentForm, "save", synchronized_save):
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(self.worker, request) for _ in range(2)]
                responses = [future.result(timeout=30) for future in futures]
        self.assertEqual(sorted(response.status_code for response in responses), [201, 400])
        rejected = next(response for response in responses if response.status_code == 400)
        self.assertIn("non_field_errors", rejected.data["error"]["fields"])
        assignment = TrainingAssignment.objects.get(employee=self.recipient, training_version=self.version)
        self.assertEqual(assignment.assigned_by_id, self.user.pk)
        self.assertEqual(Notification.objects.filter(assignment=assignment, event_type="ASSIGNED").count(), 1)
        self.assertEqual(AuditLog.objects.filter(
            actor=self.user, action="training.trainingassignment.created", entity_id=str(assignment.pk),
        ).count(), 1)
