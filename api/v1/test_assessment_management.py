"""Real API contracts for assessment authoring and protected question revisions."""

import json
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import ValidationError
from django.db import IntegrityError, OperationalError, connection, models, transaction
from django.http import Http404
from django.test import Client
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from assessments.models import (
    Assessment, AssessmentQuestion, AttemptAnswer, Question, QuestionOption, QuestionRevision,
    validate_freezable_prompt,
)
from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from organization.models import Employee
from training.models import Module, TrainingVersion

from . import assessment_management_services as services


class AssessmentManagementAPITests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.draft = TrainingVersion.objects.create(training=cls.training, version_number=2, title="Draft", created_by=cls.user)
        cls.draft_module = Module.objects.create(training_version=cls.draft, title="Draft module", position=1)
        cls.draft_assessment = Assessment.objects.create(training_version=cls.draft, module=cls.draft_module, kind="QUIZ", title="Draft quiz")
        cls.bank_question = Question.objects.create(code="AUTHORING-DRAFT", topic="Safety", created_by=cls.user)
        cls.bank_revision = QuestionRevision.objects.create(question=cls.bank_question, revision_number=1, prompt="Draft prompt", created_by=cls.user)
        cls.user.user_permissions.add(*Permission.objects.filter(
            content_type__app_label="assessments", codename__in=[
                f"{action}_{model}" for action in ("add", "view", "change")
                for model in ("question", "questionrevision", "assessment", "assessmentquestion")
            ],
        ))

    def setUp(self):
        self.client = APIClient()
        self.authenticate(self.user)

    def authenticate(self, user):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + str(RefreshToken.for_user(user).access_token))

    def identity(self, name, permission):
        user = get_user_model().objects.create_user(username=name)
        user.user_permissions.add(Permission.objects.get(content_type__app_label="assessments", codename=permission))
        return user

    def assessments_url(self, version=None):
        return f"/api/v1/management/versions/{(version or self.draft).pk}/assessments/"

    def assessment_url(self, assessment=None, version=None):
        return self.assessments_url(version) + f"{(assessment or self.draft_assessment).pk}/"

    def items_url(self, assessment=None, version=None):
        return self.assessment_url(assessment, version) + "questions/"

    def questions_url(self):
        return "/api/v1/management/questions/"

    def question_url(self, question=None):
        return self.questions_url() + f"{(question or self.bank_question).pk}/"

    def revisions_url(self, question=None):
        return self.question_url(question) + "revisions/"

    def revision_url(self, revision=None, question=None):
        return self.revisions_url(question) + f"{(revision or self.bank_revision).pk}/"

    def snapshot(self):
        from .test_training_management import TrainingManagementAPITests
        result = TrainingManagementAPITests.snapshot(self)
        for model in (Question, QuestionRevision, AssessmentQuestion, AttemptAnswer):
            result[model._meta.label] = list(model.objects.order_by("pk").values())
        return result

    def assert_field_error(self, response, field):
        self.assertEqual(response.status_code, 400, response.data)
        self.assertEqual(response.data["error"]["code"], "validation_error")
        self.assertIn(field, response.data["error"]["fields"])

    def options(self):
        return [{"text": "Yes", "position": 1, "is_correct": True}, {"text": "No", "position": 2}]

    def prepare_options(self):
        response = self.client.patch(self.revision_url(), {"options": self.options()}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        return response.data["options"]

    def test_assessment_create_uses_website_final_normalization_and_audit(self):
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(self.assessments_url(), {
                "kind": "FINAL", "title": "Final", "module_id": self.draft_module.pk,
                "sequence": 5, "is_required": False,
            }, format="json")
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data, {
            "id": response.data["id"], "training_version_id": self.draft.pk, "module_id": None,
            "kind": "FINAL", "title": "Final", "sequence": 1, "is_required": True,
            "pass_percentage": "80.00", "max_attempts": 3, "time_limit_minutes": None,
        })
        event = AuditLog.objects.get(action="assessments.assessment.created")
        self.assertEqual(event.actor_id, self.user.pk)
        self.assertNotIn("options", json.dumps(event.after_data))
        self.assertFalse(hasattr(self.user, "employee"))

    def test_assessment_partial_update_preserves_values_and_noop_audit(self):
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.patch(self.assessment_url(), {
                "pass_percentage": "75.25", "max_attempts": 4, "time_limit_minutes": 10, "is_required": False,
            }, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        response = self.client.patch(self.assessment_url(), {"title": "Updated"}, format="json")
        self.assertEqual((response.data["pass_percentage"], response.data["max_attempts"], response.data["is_required"]), ("75.25", 4, False))
        response = self.client.patch(self.assessment_url(), {"time_limit_minutes": None}, format="json")
        self.assertIsNone(response.data["time_limit_minutes"])
        before = self.snapshot()
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            self.assertEqual(self.client.patch(self.assessment_url(), {}, format="json").status_code, 200)
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    def test_assessment_invalid_settings_module_scope_and_duplicate_sequence(self):
        before = self.snapshot()
        for field, value in (("kind", "EXAM"), ("sequence", 0), ("max_attempts", 0),
                             ("time_limit_minutes", 0), ("pass_percentage", "100.01"),
                             ("pass_percentage", "NaN"), ("title", ""), ("max_attempts", True)):
            self.assert_field_error(self.client.patch(self.assessment_url(), {field: value}, format="json"), field)
        self.assert_field_error(self.client.post(self.assessments_url(), {"kind": "QUIZ", "title": "Missing module"}, format="json"), "module")
        self.assert_field_error(self.client.patch(self.assessment_url(), {"module_id": self.module.pk}, format="json"), "module")
        self.assert_field_error(self.client.post(self.assessments_url(), {
            "kind": "QUIZ", "title": "Duplicate", "module_id": self.draft_module.pk,
        }, format="json"), "sequence")
        self.assertEqual(self.snapshot(), before)

    def test_assessment_permissions_are_independent(self):
        for action in ("add", "view", "change"):
            user = self.identity("assessment-" + action, action + "_assessment")
            self.authenticate(user)
            self.assertEqual(self.client.get(self.assessment_url()).status_code, 200 if action == "view" else 403)
            self.assertEqual(self.client.post(self.assessments_url(), {"kind": "FINAL", "title": "Final"}, format="json").status_code, 201 if action == "add" else 403)
            self.assertEqual(self.client.patch(self.assessment_url(), {"title": "Edited"}, format="json").status_code, 200 if action == "change" else 403)

    def test_question_create_placeholder_revision_and_metadata_permissions(self):
        for action in ("add", "view", "change"):
            self.authenticate(self.identity("question-" + action, action + "_question"))
            self.assertEqual(self.client.get(self.question_url()).status_code, 200 if action == "view" else 403)
            with self.captureOnCommitCallbacks(execute=True):
                response = self.client.post(self.questions_url(), {"code": "BANK-NEW"}, format="json")
            self.assertEqual(response.status_code, 201 if action == "add" else 403, response.data)
            if action == "add":
                revision = QuestionRevision.objects.get(question_id=response.data["id"])
                self.assertEqual((revision.revision_number, revision.prompt, revision.status), (1, "Draft question", "DRAFT"))
                self.assertEqual(AuditLog.objects.count(), 2)
            self.assertEqual(self.client.patch(self.question_url(), {"topic": "Updated"}, format="json").status_code, 200 if action == "change" else 403)

    def test_question_code_unique_contract_and_metadata_noop(self):
        with connection.cursor() as cursor:
            constraints = connection.introspection.get_constraints(cursor, Question._meta.db_table)
        self.assertTrue(constraints["code"]["unique"])
        self.assertEqual(constraints["code"]["columns"], ["code"])
        self.assert_field_error(self.client.post(self.questions_url(), {"code": self.bank_question.code}, format="json"), "code")
        self.bank_question.topic = "   Existing topic\n"
        self.bank_question.save()
        before = self.snapshot()
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            self.assertEqual(self.client.patch(self.question_url(), {}, format="json").status_code, 200)
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    def test_real_mysql_duplicate_code_exception_maps_to_conflict(self):
        before = self.snapshot()
        try:
            with transaction.atomic():
                # Isolated fixture only: bypass model prevalidation to capture
                # MySQL's actual index error rather than inventing its message.
                duplicate = Question(code=self.bank_question.code, created_by=self.user)
                models.Model.save(duplicate, force_insert=True)
        except IntegrityError as exc:
            actual_error = exc
        else:
            self.fail("The real question-code unique index did not reject the duplicate")
        with patch.object(services, "create_question", side_effect=actual_error):
            response = self.client.post(self.questions_url(), {"code": self.bank_question.code}, format="json")
        self.assertEqual(response.status_code, 409, response.data)
        self.assertEqual(self.snapshot(), before)

    def test_question_creation_rolls_back_if_initial_revision_fails(self):
        before = self.snapshot()
        with self.captureOnCommitCallbacks(execute=True) as callbacks, patch.object(QuestionRevision, "save", side_effect=ValidationError("Isolated revision failure")):
            response = self.client.post(self.questions_url(), {"code": "ROLLBACK-QUESTION"}, format="json")
        self.assertEqual(response.status_code, 400, response.data)
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    def test_json_only_mutations_preserve_boolean_defaults(self):
        response = self.client.post(self.questions_url(), {"code": "JSON-QUESTION"}, format="json")
        self.assertEqual(response.status_code, 201, response.data)
        self.assertTrue(response.data["is_active"])
        before = self.snapshot()
        response = self.client.post(self.questions_url(), {"code": "FORM-QUESTION"}, format="multipart")
        self.assertEqual(response.status_code, 415)
        self.assertEqual(self.snapshot(), before)

    def test_revision_permissions_allocation_and_invalid_type(self):
        for action in ("add", "view", "change"):
            self.authenticate(self.identity("revision-" + action, action + "_questionrevision"))
            self.assertEqual(self.client.get(self.revision_url()).status_code, 200 if action == "view" else 403)
            response = self.client.post(self.revisions_url(), {"prompt": "Another"}, format="json")
            self.assertEqual(response.status_code, 201 if action == "add" else 403, response.data)
            if action == "add":
                self.assertEqual((response.data["revision_number"], response.data["status"]), (2, "DRAFT"))
            self.assertEqual(self.client.patch(self.revision_url(), {"prompt": "Updated"}, format="json").status_code, 200 if action == "change" else 403)
        self.authenticate(self.user)
        self.assert_field_error(self.client.patch(self.revision_url(), {"question_type": "MULTIPLE_CHOICE"}, format="json"), "question_type")

    def test_revision_edit_updates_options_atomically_and_audits_no_answers(self):
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.patch(self.revision_url(), {"prompt": "Choose safely", "explanation": "Private explanation", "options": self.options()}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual([(o["position"], o["is_correct"]) for o in response.data["options"]], [(1, True), (2, False)])
        event = AuditLog.objects.get(action="assessments.questionrevision.updated")
        self.assertTrue(event.after_data["content_updated"])
        self.assertTrue(event.after_data["options_updated"])
        for value in ("Choose safely", "Private explanation", "is_correct", '"Yes"', '"No"'):
            self.assertNotIn(value, json.dumps(event.after_data))

    def test_option_partial_edits_deletion_and_omissions_preserve_existing_content(self):
        options = self.prepare_options()
        self.bank_revision.prompt = "   Preserve prompt\n\n"
        self.bank_revision.explanation = "   Preserve explanation\n"
        self.bank_revision.save()
        response = self.client.patch(self.revision_url(), {"options": [{"id": options[0]["id"], "text": "Updated"}]}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["prompt"], self.bank_revision.prompt)
        self.assertEqual(response.data["explanation"], self.bank_revision.explanation)
        self.assertEqual(response.data["options"][1]["text"], "No")
        response = self.client.patch(self.revision_url(), {"options": [{"id": options[1]["id"], "delete": True}]}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual([o["id"] for o in response.data["options"]], [options[0]["id"]])

    def test_options_invalid_positions_duplicates_foreign_ids_and_unknown_fields(self):
        options = self.prepare_options()
        before = self.snapshot()
        for values in ([{"id": options[0]["id"]}, {"id": options[0]["id"]}],
                       [{"text": "Duplicate", "position": 1}],
                       [{"text": "Invalid", "position": 0}], [{"text": "Missing position"}],
                       [{"text": "New", "position": 3, "correct_answer": True}]):
            self.assertEqual(self.client.patch(self.revision_url(), {"options": values}, format="json").status_code, 400)
            self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.client.patch(self.revision_url(), {"options": [{"id": self.correct_option.pk, "text": "Foreign"}]}, format="json").status_code, 404)
        self.assertEqual(self.snapshot(), before)

    def test_freeze_validates_exactly_one_answer_and_is_immutable(self):
        before = self.snapshot()
        self.assertEqual(self.client.post(self.revision_url() + "freeze/", {}, format="json").status_code, 400)
        self.assertEqual(self.snapshot(), before)
        options = self.prepare_options()
        self.client.patch(self.revision_url(), {"options": [{"id": options[1]["id"], "is_correct": True}]}, format="json")
        before = self.snapshot()
        self.assertEqual(self.client.post(self.revision_url() + "freeze/", {}, format="json").status_code, 400)
        self.assertEqual(self.snapshot(), before)
        self.client.patch(self.revision_url(), {"options": [{"id": options[1]["id"], "is_correct": False}]}, format="json")
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(self.revision_url() + "freeze/", {}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["status"], "FROZEN")
        self.assertIsNotNone(response.data["frozen_at"])
        before = self.snapshot()
        self.assertEqual(self.client.patch(self.revision_url(), {"prompt": "Forbidden"}, format="json").status_code, 404)
        self.assertEqual(self.client.post(self.revision_url() + "freeze/", {}, format="json").status_code, 404)
        self.assertEqual(self.snapshot(), before)

    def test_true_false_freeze_uses_existing_model_rules(self):
        self.client.patch(self.revision_url(), {"question_type": "TRUE_FALSE", "options": self.options()}, format="json")
        self.assertEqual(self.client.post(self.revision_url() + "freeze/", {}, format="json").status_code, 400)
        options = list(self.bank_revision.options.order_by("position"))
        response = self.client.patch(self.revision_url(), {"options": [
            {"id": options[0].pk, "text": "True"}, {"id": options[1].pk, "text": "False"},
        ]}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(self.client.post(self.revision_url() + "freeze/", {}, format="json").status_code, 200)

    def test_true_false_malformed_persisted_options_cannot_freeze_or_change_audit_state(self):
        cases = (
            ("legacy", [("True", True), ("False", False), ("Legacy", False)]),
            ("duplicate true", [("True", True), ("False", False), (" true ", False)]),
            ("duplicate false", [("True", True), ("False", False), ("FALSE", False)]),
            ("only true", [("True", True)]),
            ("only false", [("False", True)]),
            ("missing true", [("Yes", True), ("False", False)]),
            ("missing false", [("True", True), ("No", False)]),
            ("no correct", [("True", False), ("False", False)]),
            ("two correct", [("True", True), ("False", True)]),
        )
        for number, (label, options) in enumerate(cases, start=2):
            with self.subTest(case=label):
                revision = QuestionRevision.objects.create(
                    question=self.bank_question, revision_number=number,
                    question_type="TRUE_FALSE", prompt="A valid prompt", created_by=self.user,
                )
                for position, (text, correct) in enumerate(options, start=1):
                    QuestionOption.objects.create(
                        question_revision=revision, position=position, text=text, is_correct=correct,
                    )
                before = self.snapshot()
                before_options = list(QuestionOption.objects.order_by("pk").values())
                before_audit = list(AuditLog.objects.order_by("pk").values())
                with self.captureOnCommitCallbacks(execute=True) as callbacks:
                    response = self.client.post(self.revision_url(revision) + "freeze/", {}, format="json")
                self.assertEqual(response.status_code, 400, response.data)
                self.assertEqual(response.data["error"]["code"], "validation_error")
                self.assertEqual(callbacks, [])
                self.assertEqual(self.snapshot(), before)
                self.assertEqual(list(QuestionOption.objects.order_by("pk").values()), before_options)
                self.assertEqual(list(AuditLog.objects.order_by("pk").values()), before_audit)
                revision.refresh_from_db()
                self.assertEqual((revision.status, revision.frozen_at), ("DRAFT", None))

    def test_true_false_normalized_labels_freeze_without_rewriting_saved_options(self):
        self.bank_revision.question_type = "TRUE_FALSE"
        self.bank_revision.save()
        for position, (text, correct) in enumerate((("  TrUe\n", True), ("\tFALSE  ", False)), start=1):
            QuestionOption.objects.create(
                question_revision=self.bank_revision, position=position, text=text, is_correct=correct,
            )
        before_options = list(self.bank_revision.options.order_by("pk").values())
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(self.revision_url() + "freeze/", {}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["status"], "FROZEN")
        self.assertEqual(list(self.bank_revision.options.order_by("pk").values()), before_options)
        event = AuditLog.objects.get(action="assessments.questionrevision.frozen")
        self.assertEqual((event.before_data["status"], event.after_data["status"]), ("DRAFT", "FROZEN"))
        before = self.snapshot()
        for changes in ({"prompt": "Forbidden"}, {"options": [{"id": before_options[0]["id"], "is_correct": False}]}):
            with self.captureOnCommitCallbacks(execute=True) as callbacks:
                response = self.client.patch(self.revision_url(), changes, format="json")
            self.assertEqual(response.status_code, 404, response.data)
            self.assertEqual(callbacks, [])
            self.assertEqual(self.snapshot(), before)
            self.assertEqual(list(self.bank_revision.options.order_by("pk").values()), before_options)
        self.assertEqual(AuditLog.objects.count(), 1)

    def test_true_false_incomplete_draft_updates_and_explicit_repairs_preserve_option_ids(self):
        response = self.client.patch(self.revision_url(), {"question_type": "TRUE_FALSE", "options": []}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual((response.data["status"], response.data["options"]), ("DRAFT", []))
        changes = [{"text": "True", "position": 1, "is_correct": False}]
        response = self.client.patch(self.revision_url(), {"options": changes}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        first_id = response.data["options"][0]["id"]
        response = self.client.patch(self.revision_url(), {"options": [
            {"text": "False", "position": 2, "is_correct": False},
            {"text": "Legacy", "position": 3, "is_correct": False},
        ]}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        options = response.data["options"]
        self.assertEqual(options[0]["id"], first_id)
        self.assertEqual(len(options), 3)
        self.assertFalse(any(option["is_correct"] for option in options))
        response = self.client.patch(self.revision_url(), {"prompt": "Author edit"}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["options"], options)
        response = self.client.patch(self.revision_url(), {"options": [
            {"id": options[2]["id"], "delete": True}, {"id": first_id, "is_correct": True},
        ]}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual([option["id"] for option in response.data["options"]], [first_id, options[1]["id"]])
        self.assertEqual(response.data["prompt"], "Author edit")
        self.assertEqual(self.client.post(self.revision_url() + "freeze/", {}, format="json").status_code, 200)

    def test_true_false_freeze_cannot_accept_repairs_in_payload_or_bypass_change_permission(self):
        response = self.client.patch(self.revision_url(), {"question_type": "TRUE_FALSE"}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        before = self.snapshot()
        self.assert_field_error(self.client.post(self.revision_url() + "freeze/", {
            "options": [{"text": "True", "position": 1, "is_correct": True}, {"text": "False", "position": 2}],
        }, format="json"), "options")
        for permission in ("view_questionrevision", "add_questionrevision"):
            self.authenticate(self.identity("true-false-" + permission, permission))
            with self.captureOnCommitCallbacks(execute=True) as callbacks:
                response = self.client.post(self.revision_url() + "freeze/", {}, format="json")
            self.assertEqual(response.status_code, 403, response.data)
            self.assertEqual(callbacks, [])
        self.bank_revision.refresh_from_db()
        self.assertEqual((self.bank_revision.status, self.bank_revision.frozen_at), ("DRAFT", None))
        self.assertEqual(self.snapshot(), before)

    def test_freeze_rejects_empty_and_whitespace_only_prompts(self):
        self.prepare_options()
        for invalid in ("", "   ", "\t\r\n", "  \n  \t  "):
            with self.subTest(prompt=invalid):
                # Stored empty / whitespace draft prompts must be blocked at freeze time
                self.bank_revision.prompt = invalid
                models.Model.save(self.bank_revision)
                self.bank_revision.refresh_from_db()
                self.assertEqual(self.bank_revision.status, QuestionRevision.Status.DRAFT)
                before = self.snapshot()

                # Freezing rejects empty or whitespace-only prompts with structured 400 error
                response = self.client.post(self.revision_url() + "freeze/", {}, format="json")
                self.assert_field_error(response, "prompt")
                self.assertIn("Question prompt cannot be blank when freezing a revision.", response.data["error"]["fields"]["prompt"])
                self.assertEqual(self.snapshot(), before)

        # Normal editing permits saving incomplete drafts without freezing
        self.bank_revision.prompt = "Draft question"
        self.bank_revision.save()
        response = self.client.patch(self.revision_url(), {"explanation": "Incomplete draft notes"}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.bank_revision.refresh_from_db()
        self.assertEqual(self.bank_revision.status, QuestionRevision.Status.DRAFT)

    def test_freeze_rejects_default_placeholder_prompt_variants(self):
        self.prepare_options()
        placeholders = (
            "Draft question",
            "draft question",
            "DRAFT QUESTION",
            "   Draft Question   \n",
            "  Draft   question  ",
            "\tDraft\nquestion\t",
        )
        for placeholder in placeholders:
            with self.subTest(placeholder=placeholder):
                # Normal editing permits saving draft with placeholder
                response = self.client.patch(self.revision_url(), {"prompt": placeholder}, format="json")
                self.assertEqual(response.status_code, 200, response.data)
                self.bank_revision.refresh_from_db()
                self.assertEqual(self.bank_revision.status, QuestionRevision.Status.DRAFT)
                before = self.snapshot()

                # Freezing rejects placeholder prompts
                response = self.client.post(self.revision_url() + "freeze/", {}, format="json")
                self.assert_field_error(response, "prompt")
                self.assertIn("Question prompt must be updated from the default placeholder before freezing.", response.data["error"]["fields"]["prompt"])
                self.assertEqual(self.snapshot(), before)

    def test_freeze_succeeds_with_valid_prompt_and_records_audit_log(self):
        self.prepare_options()
        valid_prompt = "What is the standard procedure for reporting a chemical spill?"
        response = self.client.patch(self.revision_url(), {"prompt": valid_prompt}, format="json")
        self.assertEqual(response.status_code, 200, response.data)

        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(self.revision_url() + "freeze/", {}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["status"], "FROZEN")
        self.assertIsNotNone(response.data["frozen_at"])

        self.bank_revision.refresh_from_db()
        self.assertEqual(self.bank_revision.status, QuestionRevision.Status.FROZEN)
        self.assertEqual(self.bank_revision.prompt, valid_prompt)

        event = AuditLog.objects.get(action="assessments.questionrevision.frozen", entity_id=str(self.bank_revision.pk))
        self.assertEqual(event.actor_id, self.user.pk)
        self.assertEqual(event.after_data["status"], "FROZEN")

    def test_freeze_already_frozen_revision_is_rejected_and_immutable(self):
        self.prepare_options()
        self.client.patch(self.revision_url(), {"prompt": "Valid question prompt?"}, format="json")
        response = self.client.post(self.revision_url() + "freeze/", {}, format="json")
        self.assertEqual(response.status_code, 200, response.data)

        # Once frozen, attempting another freeze via API returns 404 (draft locked query)
        response = self.client.post(self.revision_url() + "freeze/", {}, format="json")
        self.assertEqual(response.status_code, 404)

        # Direct service call also fails because _locked_revision requires DRAFT status
        with self.assertRaises(Http404):
            services.freeze_revision(self.user, self.bank_question.pk, self.bank_revision.pk, {})

        # Direct model update on frozen revision prompt is rejected by model clean
        self.bank_revision.refresh_from_db()
        self.bank_revision.prompt = "Mutated prompt"
        with self.assertRaises(ValidationError):
            self.bank_revision.save()

    def test_freeze_rejects_unauthorized_actor(self):
        unauthorized_user = self.identity("unauthorized-freeze-user", "view_questionrevision")
        self.authenticate(unauthorized_user)
        response = self.client.post(self.revision_url() + "freeze/", {}, format="json")
        self.assertEqual(response.status_code, 403)

    def test_web_freeze_view_enforces_prompt_validation(self):
        self.prepare_options()
        web_client = Client()
        web_client.force_login(self.user)

        # 1. Web freeze with placeholder prompt fails with HTTP 400
        self.bank_revision.prompt = "Draft question"
        self.bank_revision.save()
        response = web_client.post(f"/revisions/{self.bank_revision.pk}/freeze/")
        self.assertEqual(response.status_code, 400)
        self.bank_revision.refresh_from_db()
        self.assertEqual(self.bank_revision.status, QuestionRevision.Status.DRAFT)
        self.assertFalse(AuditLog.objects.filter(action="assessments.questionrevision.frozen", entity_id=str(self.bank_revision.pk)).exists())

        # 2. Web freeze with empty prompt fails with HTTP 400
        self.bank_revision.prompt = "   "
        self.bank_revision.save()
        response = web_client.post(f"/revisions/{self.bank_revision.pk}/freeze/")
        self.assertEqual(response.status_code, 400)
        self.bank_revision.refresh_from_db()
        self.assertEqual(self.bank_revision.status, QuestionRevision.Status.DRAFT)

        # 3. Web freeze with valid prompt succeeds with 302 redirect
        self.bank_revision.prompt = "Valid prompt for web freeze"
        self.bank_revision.save()
        with self.captureOnCommitCallbacks(execute=True):
            response = web_client.post(f"/revisions/{self.bank_revision.pk}/freeze/")
        self.assertEqual(response.status_code, 302)
        self.assertIn(f"/revisions/{self.bank_revision.pk}/", response.url)
        self.bank_revision.refresh_from_db()
        self.assertEqual(self.bank_revision.status, QuestionRevision.Status.FROZEN)
        self.assertTrue(AuditLog.objects.filter(action="assessments.questionrevision.frozen", entity_id=str(self.bank_revision.pk)).exists())

    def test_validate_freezable_prompt_unit(self):
        for bad_prompt in ("", "   ", "\t\n", None):
            with self.subTest(bad=bad_prompt):
                with self.assertRaises(ValidationError) as ctx:
                    validate_freezable_prompt(bad_prompt)
                self.assertIn("prompt", ctx.exception.message_dict)

        for placeholder in ("Draft question", "draft question", "DRAFT QUESTION", "  Draft   question  "):
            with self.subTest(placeholder=placeholder):
                with self.assertRaises(ValidationError) as ctx:
                    validate_freezable_prompt(placeholder)
                self.assertIn("prompt", ctx.exception.message_dict)

        # Valid prompt does not raise
        validate_freezable_prompt("Valid question prompt")

    def test_revision_noop_does_not_write_or_audit(self):
        self.prepare_options()
        before = self.snapshot()
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            response = self.client.patch(self.revision_url(), {"options": []}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    def test_omitted_option_text_preserves_formatting_and_noop_audit(self):
        self.prepare_options()
        option = self.bank_revision.options.get(position=1)
        option.text = "   Existing answer\n\n"
        option.save()
        before = self.snapshot()
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            response = self.client.patch(self.revision_url(), {}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["options"][0]["text"], option.text)
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.patch(self.revision_url(), {"prompt": "Another prompt"}, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["options"][0]["text"], option.text)
        event = AuditLog.objects.get(action="assessments.questionrevision.updated")
        self.assertFalse(event.after_data["options_updated"])

    def test_failure_after_option_write_rolls_back_revision_options_and_audit(self):
        before = self.snapshot()
        original = QuestionOption.save
        def fail_second(instance, *args, **kwargs):
            result = original(instance, *args, **kwargs)
            if instance.position == 2:
                raise ValidationError("Isolated option failure")
            return result
        with self.captureOnCommitCallbacks(execute=True) as callbacks, patch.object(QuestionOption, "save", fail_second):
            response = self.client.patch(self.revision_url(), {"prompt": "Must roll back", "options": self.options()}, format="json")
        self.assertEqual(response.status_code, 400, response.data)
        self.assertEqual(callbacks, [])
        self.assertEqual(self.snapshot(), before)

    def test_assessment_question_attachment_edit_and_validation(self):
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(self.items_url(), {"question_revision_id": self.revision.pk, "position": 4, "points": "2.25"}, format="json")
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(response.data["points"], "2.25")
        url = self.items_url() + f"{response.data['id']}/"
        response = self.client.patch(url, {"position": 7, "points": "3.50"}, format="json")
        self.assertEqual((response.status_code, response.data["position"], response.data["points"]), (200, 7, "3.50"))
        before = self.snapshot()
        for field, value in (("points", "0"), ("points", "NaN"), ("position", 0), ("question_revision_id", self.bank_revision.pk)):
            self.assert_field_error(self.client.patch(url, {field: value}, format="json"), "question_revision" if field == "question_revision_id" else field)
        self.assertEqual(self.snapshot(), before)
        with self.captureOnCommitCallbacks(execute=True) as callbacks:
            self.assertEqual(self.client.patch(url, {}, format="json").status_code, 200)
        self.assertEqual(callbacks, [])
        for revision_id in (self.bank_revision.pk, 999999):
            self.assert_field_error(self.client.post(self.items_url(), {
                "question_revision_id": revision_id, "position": 8,
            }, format="json"), "question_revision")

    def test_attachment_revision_replacement_audits_original_reference(self):
        item = AssessmentQuestion.objects.create(assessment=self.draft_assessment, question_revision=self.revision, position=1)
        self.prepare_options()
        self.assertEqual(self.client.post(self.revision_url() + "freeze/", {}, format="json").status_code, 200)
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.patch(self.items_url() + f"{item.pk}/", {
                "question_revision_id": self.bank_revision.pk,
            }, format="json")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["question_revision_id"], self.bank_revision.pk)
        event = AuditLog.objects.get(action="assessments.assessmentquestion.updated")
        self.assertEqual(event.before_data["question_revision_id"], self.revision.pk)
        self.assertEqual(event.after_data["question_revision_id"], self.bank_revision.pk)
        self.assertEqual(event.after_data["changed_fields"], ["question_revision"])

    def test_attachment_rejects_inactive_questions_duplicate_question_and_position(self):
        self.client.post(self.items_url(), {"question_revision_id": self.revision.pk, "position": 1}, format="json")
        self.prepare_options()
        self.client.post(self.revision_url() + "freeze/", {}, format="json")
        before = self.snapshot()
        self.assertEqual(self.client.post(self.items_url(), {"question_revision_id": self.bank_revision.pk, "position": 1}, format="json").status_code, 400)
        self.assertEqual(self.client.post(self.items_url(), {"question_revision_id": self.revision.pk, "position": 2}, format="json").status_code, 400)
        self.assertEqual(self.snapshot(), before)
        self.bank_question.is_active = False
        self.bank_question.save()
        self.assert_field_error(self.client.post(self.items_url(), {"question_revision_id": self.bank_revision.pk, "position": 2}, format="json"), "question_revision")

    def test_attachment_permissions_are_independent_and_do_not_reveal_answers(self):
        item = AssessmentQuestion.objects.create(assessment=self.draft_assessment, question_revision=self.revision, position=1)
        for action in ("add", "view", "change"):
            self.authenticate(self.identity("attachment-" + action, action + "_assessmentquestion"))
            response = self.client.get(self.items_url() + f"{item.pk}/")
            self.assertEqual(response.status_code, 200 if action == "view" else 403)
            if action == "view":
                self.assertEqual(set(response.data), {"id", "assessment_id", "question_revision_id", "position", "points"})
            self.assertEqual(self.client.patch(self.items_url() + f"{item.pk}/", {"points": "2.00"}, format="json").status_code, 200 if action == "change" else 403)
            # Authorized add reaches validation; all other grants are rejected before it.
            self.assertEqual(self.client.post(self.items_url(), {}, format="json").status_code, 400 if action == "add" else 403)
            self.assertEqual(self.client.get(self.revision_url(self.revision, self.question)).status_code, 403)

    def test_answer_keys_require_revision_authority_not_assessment_or_option_labels(self):
        for permission in ("view_assessment", "view_question", "view_assessmentquestion", "view_questionoption", "change_questionoption"):
            self.authenticate(self.identity("key-" + permission, permission))
            self.assertEqual(self.client.get(self.revision_url(self.revision, self.question)).status_code, 403)
            self.assertEqual(self.client.patch(self.revision_url(), {"options": self.options()}, format="json").status_code, 403)
        self.authenticate(self.identity("revision-reader", "view_questionrevision"))
        response = self.client.get(self.revision_url(self.revision, self.question))
        self.assertEqual(response.status_code, 200)
        self.assertTrue(any(option["is_correct"] for option in response.data["options"]))
        self.assertEqual(self.client.patch(self.revision_url(), {"prompt": "Denied"}, format="json").status_code, 403)

    def test_nested_parent_ids_are_checked_for_every_resource(self):
        item = AssessmentQuestion.objects.create(assessment=self.draft_assessment, question_revision=self.revision, position=1)
        before = self.snapshot()
        wrong_urls = [self.assessment_url(self.quiz), self.items_url(self.quiz),
                      self.items_url(self.quiz) + f"{item.pk}/", self.revision_url(self.revision)]
        for url in wrong_urls:
            self.assertEqual(self.client.get(url).status_code, 404)
        for url in (wrong_urls[0], wrong_urls[2], wrong_urls[3]):
            self.assertEqual(self.client.patch(url, {}, format="json").status_code, 404)
        self.assertEqual(self.client.post(wrong_urls[1], {"question_revision_id": self.revision.pk, "position": 2}, format="json").status_code, 404)
        self.assertEqual(self.snapshot(), before)

    def test_published_and_retired_assessments_remain_immutable_and_readable(self):
        for state in ("PUBLISHED", "RETIRED"):
            if state == "RETIRED":
                self.version.status = state
                self.version.save()
            before = self.snapshot()
            self.assertEqual(self.client.get(self.assessment_url(self.quiz, self.version)).status_code, 200)
            self.assertEqual(self.client.patch(self.assessment_url(self.quiz, self.version), {"title": "Forbidden"}, format="json").status_code, 404)
            self.assertEqual(self.client.post(self.assessments_url(self.version), {"kind": "FINAL", "title": "Forbidden"}, format="json").status_code, 404)
            self.assertEqual(self.client.post(self.items_url(self.quiz, self.version), {"question_revision_id": self.revision.pk, "position": 2}, format="json").status_code, 404)
            self.assertEqual(self.client.patch(self.items_url(self.quiz, self.version) + f"{self.quiz_item.pk}/", {"points": "9.00"}, format="json").status_code, 404)
            self.assertEqual(self.snapshot(), before)

    def test_jwt_mobile_eligibility_and_role_denials_prevent_enumeration(self):
        urls = [self.assessments_url(), self.assessment_url(), self.items_url(), self.questions_url(), self.question_url(), self.revisions_url(), self.revision_url()]
        self.client.credentials()
        for url in urls:
            self.assertEqual(self.client.get(url).status_code, 401)
        manager = get_user_model().objects.create_user(username="authoring-manager")
        manager.groups.add(Group.objects.get_or_create(name="Manager")[0])
        Employee.objects.create(
            employee_code="AUTHOR-MANAGER", display_name="Manager", user=manager,
            department=self.department, job_role=self.role, date_joined=self.now.date(),
        )
        for user in (self.employee_user, manager):
            self.authenticate(user)
            for url in urls:
                self.assertEqual(self.client.get(url).status_code, 403)
            self.assertEqual(self.client.patch(self.revision_url(), {}, format="json").status_code, 403)
            self.assertEqual(self.client.patch(self.revision_url().replace(str(self.bank_revision.pk) + "/", "999999/"), {}, format="json").status_code, 403)
        self.authenticate(self.user)
        self.user.is_active = False
        self.user.save()
        self.assertEqual(self.client.get(self.questions_url()).status_code, 401)

    def test_inactive_linked_employee_cannot_use_explicit_authoring_permissions(self):
        self.employee_user.user_permissions.add(Permission.objects.get(content_type__app_label="assessments", codename="change_questionrevision"))
        self.employee.is_active = False
        self.employee.deactivation_reason = "Isolated assessment fixture"
        self.employee.save()
        self.employee_user.is_active = True
        self.employee_user.save()
        self.authenticate(self.employee_user)
        self.assertEqual(self.client.patch(self.revision_url(), {}, format="json").status_code, 403)

    def test_question_list_optional_active_filter(self):
        inactive = Question.objects.create(code="FILTER-INACTIVE", is_active=False, created_by=self.user)
        self.authenticate(self.identity("question-list-reader", "view_question"))
        before = self.snapshot()
        cases = [
            ({}, [self.bank_question.pk, inactive.pk, self.question.pk]),
            ({"is_active": "true"}, [self.bank_question.pk, self.question.pk]),
            ({"is_active": "false"}, [inactive.pk]),
        ]
        for params, expected_ids in cases:
            with self.subTest(params=params):
                response = self.client.get(self.questions_url(), params)
                self.assertEqual(response.status_code, 200, response.data)
                self.assertEqual(response.data["count"], len(expected_ids))
                self.assertEqual([row["id"] for row in response.data["results"]], expected_ids)
        self.assertEqual(self.snapshot(), before)

    def test_question_list_rejects_invalid_active_filter(self):
        for value in ("not-a-boolean", "2", "null"):
            with self.subTest(value=value):
                self.assert_field_error(self.client.get(self.questions_url(), {"is_active": value}), "is_active")

    def test_question_list_search_and_pagination_combine_with_active_filter(self):
        questions = [
            Question.objects.create(code=code, topic="Filter integration", is_active=active, created_by=self.user)
            for code, active in (("FILTER-A", True), ("FILTER-B", False), ("FILTER-C", True))
        ]
        before = self.snapshot()
        params = {"search": "Filter integration", "page_size": 1}
        response = self.client.get(self.questions_url(), params)
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["count"], 3)
        self.assertEqual([row["id"] for row in response.data["results"]], [questions[0].pk])
        self.assertIsNotNone(response.data["next"])
        self.assertIsNone(response.data["previous"])
        response = self.client.get(self.questions_url(), {**params, "page": 2})
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["count"], 3)
        self.assertEqual([row["id"] for row in response.data["results"]], [questions[1].pk])
        self.assertIsNotNone(response.data["next"])
        self.assertIsNotNone(response.data["previous"])
        for value, expected_ids in (("true", [questions[0].pk, questions[2].pk]), ("false", [questions[1].pk])):
            with self.subTest(is_active=value):
                response = self.client.get(self.questions_url(), {
                    "search": "FILTER-", "is_active": value, "page_size": 2,
                })
                self.assertEqual(response.status_code, 200, response.data)
                self.assertEqual(response.data["count"], len(expected_ids))
                self.assertEqual([row["id"] for row in response.data["results"]], expected_ids)
                self.assertIsNone(response.data["next"])
        self.assertEqual(self.snapshot(), before)

    def test_question_list_empty_results_for_all_active_filters(self):
        for params in ({}, {"is_active": "true"}, {"is_active": "false"}):
            with self.subTest(params=params):
                response = self.client.get(self.questions_url(), {"search": "no-matching-question", **params})
                self.assertEqual(response.status_code, 200, response.data)
                self.assertEqual(response.data, {"count": 0, "next": None, "previous": None, "results": []})

    def test_question_list_requires_independent_view_permission_for_all_filters(self):
        for permission in ("add_question", "change_question", "view_questionrevision"):
            self.authenticate(self.identity("list-with-" + permission, permission))
            for params in ({}, {"is_active": "true"}, {"is_active": "false"}):
                with self.subTest(permission=permission, params=params):
                    self.assertEqual(self.client.get(self.questions_url(), params).status_code, 403)

    def test_lists_search_pagination_ordering_and_read_only_behavior(self):
        before = self.snapshot()
        response = self.client.get(self.questions_url(), {"search": "AUTHORING", "is_active": "true", "page_size": 1})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(set(response.data), {"count", "next", "previous", "results"})
        self.assertEqual([row["id"] for row in response.data["results"]], [self.bank_question.pk])
        for url in (self.assessments_url(), self.items_url(), self.revisions_url()):
            self.assertEqual(self.client.get(url, {"page_size": 1}).status_code, 200)
            self.assertEqual(self.client.get(url, {"page_size": 101}).status_code, 400)
        for url in (self.questions_url(), self.revisions_url(), self.assessments_url(), self.items_url(), self.question_url(), self.revision_url(), self.assessment_url()):
            self.assertEqual(self.client.get(url).status_code, 200)
        self.assertEqual(self.snapshot(), before)

    def test_malformed_payloads_unknown_fields_and_server_owned_values(self):
        writes = [("post", self.assessments_url()), ("patch", self.assessment_url()),
                  ("post", self.questions_url()), ("patch", self.question_url()),
                  ("post", self.revisions_url()), ("patch", self.revision_url()),
                  ("post", self.revision_url() + "freeze/"), ("post", self.items_url())]
        before = self.snapshot()
        for method, url in writes:
            for payload in ([], "bad", 1, True, None):
                self.assertEqual(getattr(self.client, method)(url, json.dumps(payload), content_type="application/json").status_code, 400)
            self.assertEqual(getattr(self.client, method)(url, {"created_by": self.user.pk}, format="json").status_code, 400)
        for field in ("status", "frozen_at", "question_id", "revision_number", "score", "passed"):
            self.assert_field_error(self.client.patch(self.revision_url(), {field: "forged"}, format="json"), field)
        self.assertEqual(self.snapshot(), before)

    def test_expected_integrity_and_lock_conflicts_do_not_mask_unrelated_errors(self):
        key = f"{Assessment._meta.db_table}.unique_version_assessment_seq"
        for error in (IntegrityError(1062, f"Duplicate entry 'x' for key '{key}'"), OperationalError(1213, "private SQL")):
            with patch.object(services, "save_assessment", side_effect=error):
                response = self.client.patch(self.assessment_url(), {}, format="json")
            self.assertEqual(response.status_code, 409)
            self.assertNotIn("private SQL", json.dumps(response.data))
        with patch.object(services, "save_assessment", side_effect=IntegrityError(1062, "unrelated constraint")):
            with self.assertRaises(IntegrityError):
                self.client.patch(self.assessment_url(), {}, format="json")
