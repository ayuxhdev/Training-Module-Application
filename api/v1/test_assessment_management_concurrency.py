"""Committed MySQL authoring races with exact isolated-fixture cleanup."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import nullcontext
from threading import Event, local
from unittest import skipUnless
from unittest.mock import patch
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import close_old_connections, connection, models
from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APIRequestFactory, force_authenticate

from assessments.models import Assessment, AssessmentQuestion, Question, QuestionOption, QuestionRevision
from audit.models import AuditLog
from training.models import Module, Training, TrainingVersion

from .assessment_management_views import (
    AssessmentQuestionManagementView, QuestionRevisionFreezeView,
    QuestionRevisionManagementDetailView, QuestionRevisionManagementView,
    VersionAssessmentManagementView,
)


@skipUnless(connection.vendor == "mysql", "Assessment authoring races require real MySQL row locks.")
class AssessmentManagementConcurrencyTests(SimpleTestCase):
    databases = {"default"}

    def assert_isolated(self):
        self.assertEqual(connection.settings_dict["NAME"], "test_gardens_training")
        with connection.cursor() as cursor:
            cursor.execute("SELECT DATABASE()")
            self.assertEqual(cursor.fetchone()[0], "test_gardens_training")

    def setUp(self):
        self.assert_isolated()
        self.assertTrue(connection.get_autocommit())
        marker = "assess-race-" + uuid4().hex[:16]
        self.actor_ids, self.question_ids = [], []
        self.training_id = None
        self.groups = list(Group.objects.order_by("pk").values())
        self.grants = list(Group.permissions.through.objects.order_by("pk").values())
        self.addCleanup(self.cleanup_fixtures)
        self.actors = []
        for suffix in ("first", "second"):
            user = get_user_model().objects.create_user(username=f"{marker}-{suffix}", is_superuser=True)
            self.actor_ids.append(user.pk)
            self.actors.append(user)
        self.training = Training.objects.create(code=marker, catalog_title="Isolated", created_by=self.actors[0])
        self.training_id = self.training.pk
        self.version = TrainingVersion.objects.create(training=self.training, version_number=1, title="Draft", created_by=self.actors[0])
        self.module = Module.objects.create(training_version=self.version, title="Module", position=1)
        self.assessment = Assessment.objects.create(training_version=self.version, module=self.module, kind="QUIZ", title="Quiz")
        for suffix in ("draft", "frozen"):
            question = Question.objects.create(code=f"{marker}-{suffix}", created_by=self.actors[0])
            self.question_ids.append(question.pk)
            revision = QuestionRevision.objects.create(question=question, revision_number=1, prompt="Original", created_by=self.actors[0])
            QuestionOption.objects.create(question_revision=revision, text="Yes", position=1, is_correct=True)
            QuestionOption.objects.create(question_revision=revision, text="No", position=2)
            if suffix == "frozen":
                revision.status, revision.frozen_at = "FROZEN", timezone.now()
                revision.save()
                self.frozen = revision
            else:
                self.question, self.revision = question, revision

    def cleanup_fixtures(self):
        self.assert_isolated()
        for model, filters in (
            (AuditLog, {"actor_id__in": self.actor_ids}),
            (AssessmentQuestion, {"assessment__training_version__training_id": self.training_id}),
            (Assessment, {"training_version__training_id": self.training_id}),
            (QuestionOption, {"question_revision__question_id__in": self.question_ids}),
            (QuestionRevision, {"question_id__in": self.question_ids}),
            (Question, {"pk__in": self.question_ids}),
            (Module, {"training_version__training_id": self.training_id}),
            (TrainingVersion, {"training_id": self.training_id}),
            (Training, {"pk": self.training_id}),
            (get_user_model(), {"pk__in": self.actor_ids}),
        ):
            models.QuerySet(model, using="default").filter(**filters)._raw_delete("default")
        self.assertEqual(list(Group.objects.order_by("pk").values()), self.groups)
        self.assertEqual(list(Group.permissions.through.objects.order_by("pk").values()), self.grants)
        connection.close()

    def race(self, calls, expected, model, root):
        held, boundary, finished, release = (Event() for _ in range(4))
        thread = local()
        original = model.save
        table = connection.ops.quote_name(root._meta.db_table)
        def hold(instance, *args, **kwargs):
            result = original(instance, *args, **kwargs)
            if getattr(thread, "role", None) == "first":
                self.assertTrue(connection.in_atomic_block)
                held.set()
                if not release.wait(30):
                    raise AssertionError("First authoring request was not released")
            return result
        def observe(execute, sql, params, many, context):
            if "FOR UPDATE" in sql.upper() and table in sql:
                boundary.set()
            return execute(sql, params, many, context)
        def run(role, actor, call):
            thread.role = role
            close_old_connections()
            try:
                self.assert_isolated()
                with connection.cursor() as cursor:
                    cursor.execute("SET SESSION innodb_lock_wait_timeout=10")
                view, method, kwargs, data = call
                request = getattr(APIRequestFactory(), method)("/isolated-authoring/", data, format="json")
                force_authenticate(request, user=actor)
                with connection.execute_wrapper(observe) if role == "second" else nullcontext():
                    response = view.as_view()(request, **kwargs)
                return response.status_code, response.data
            finally:
                if role == "second":
                    finished.set()
                connection.close()
        with patch.object(model, "save", hold), ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(run, "first", self.actors[0], calls[0])
            try:
                self.assertTrue(held.wait(15), "First transaction never held its uncommitted write")
                second = pool.submit(run, "second", self.actors[1], calls[1])
                self.assertTrue(boundary.wait(15), "Second transaction never attempted the parent lock")
                finished_while_locked = finished.wait(1)
            finally:
                release.set()
            results = first.result(20), second.result(20)
        self.assertFalse(finished_while_locked)
        self.assertEqual(tuple(status for status, _ in results), expected, results)

    def test_concurrent_final_creation_serializes_and_preserves_one_final(self):
        call = (VersionAssessmentManagementView, "post", {"version_pk": self.version.pk}, {"kind": "FINAL", "title": "Final"})
        self.race([call, call], (201, 400), Assessment, TrainingVersion)
        self.assertEqual(Assessment.objects.filter(training_version=self.version, kind="FINAL").count(), 1)
        self.assertEqual(AuditLog.objects.filter(actor_id__in=self.actor_ids).count(), 1)

    def test_concurrent_attachment_position_has_one_item_and_audit(self):
        call = (AssessmentQuestionManagementView, "post", {"version_pk": self.version.pk, "assessment_pk": self.assessment.pk}, {"question_revision_id": self.frozen.pk, "position": 1})
        self.race([call, call], (201, 400), AssessmentQuestion, TrainingVersion)
        self.assertEqual(self.assessment.questions.count(), 1)
        self.assertEqual(AuditLog.objects.filter(actor_id__in=self.actor_ids).count(), 1)

    def test_concurrent_revision_creation_allocates_distinct_numbers(self):
        call = (QuestionRevisionManagementView, "post", {"question_pk": self.question.pk}, {"prompt": "New revision"})
        self.race([call, call], (201, 201), QuestionRevision, Question)
        self.assertEqual(list(self.question.revisions.order_by("revision_number").values_list("revision_number", flat=True)), [1, 2, 3])
        self.assertEqual(AuditLog.objects.filter(actor_id__in=self.actor_ids).count(), 2)

    def edit_call(self, values):
        return (QuestionRevisionManagementDetailView, "patch", {"question_pk": self.question.pk, "pk": self.revision.pk}, values)

    def freeze_call(self):
        return (QuestionRevisionFreezeView, "post", {"question_pk": self.question.pk, "pk": self.revision.pk}, {})

    def test_edit_then_freeze_observes_new_prompt_and_option_configuration(self):
        option = self.revision.options.get(position=1)
        self.race([self.edit_call({"prompt": "Updated", "options": [{"id": option.pk, "text": "Updated answer"}]}), self.freeze_call()], (200, 200), QuestionRevision, Question)
        self.revision.refresh_from_db()
        self.assertEqual((self.revision.prompt, self.revision.status), ("Updated", "FROZEN"))
        self.assertEqual(self.revision.options.get(position=1).text, "Updated answer")
        self.assertEqual(AuditLog.objects.filter(actor_id__in=self.actor_ids).count(), 2)

    def test_freeze_then_edit_rejects_stale_draft_mutation(self):
        self.race([self.freeze_call(), self.edit_call({"prompt": "Forbidden"})], (200, 404), QuestionRevision, Question)
        self.revision.refresh_from_db()
        self.assertEqual((self.revision.prompt, self.revision.status), ("Original", "FROZEN"))
        self.assertEqual(AuditLog.objects.filter(actor_id__in=self.actor_ids).count(), 1)

    def test_overlapping_partial_edits_merge_fresh_locked_option_state(self):
        option = self.revision.options.get(position=1)
        self.race([self.edit_call({"options": [{"id": option.pk, "text": "First"}]}), self.edit_call({"explanation": "Second"})], (200, 200), QuestionRevision, Question)
        self.revision.refresh_from_db()
        self.assertEqual(self.revision.explanation, "Second")
        self.assertEqual(self.revision.options.get(position=1).text, "First")
        self.assertEqual(AuditLog.objects.filter(actor_id__in=self.actor_ids).count(), 2)
