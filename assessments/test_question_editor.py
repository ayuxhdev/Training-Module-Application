"""Focused editor checks that never connect to a database."""
from contextlib import contextmanager
from html import unescape
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from django.contrib.auth.models import Group
from django.core.exceptions import PermissionDenied, ValidationError
from django.http import Http404, HttpResponse
from django.template import Context, Engine
from django.test import RequestFactory, SimpleTestCase, override_settings
from django.urls import include, path

from config.model_test_utils import CurriculumTestCase

from .forms import QuestionOptionFormSet, QuestionRevisionForm
from .models import QuestionOption, QuestionRevision
from .views import edit_question_revision, freeze_question_revision


def placeholder(request, **kwargs):
    return HttpResponse()


urlpatterns = [
    path("", include(([
        path("questions/", placeholder, name="question-list"),
        path("questions/<int:pk>/", placeholder, name="question-detail"),
        path("revisions/<int:pk>/edit/", placeholder, name="revision-update"),
        path("revisions/<int:pk>/freeze/", placeholder, name="revision-freeze"),
    ], "assessments"))),
    path("", include(([path("", placeholder, name="dashboard")], "reports"))),
]


@override_settings(ROOT_URLCONF=__name__)
class QuestionEditorTests(SimpleTestCase):
    databases = set()

    def setUp(self):
        super().setUp()
        lookup = patch.object(QuestionOptionFormSet, "get_queryset", return_value=[])
        lookup.start()
        self.addCleanup(lookup.stop)

    def render_editor(self, name, context):
        engine = Engine(
            dirs=[str(Path(__file__).resolve().parents[1] / "templates")],
            libraries={"static": "django.templatetags.static"},
            loaders=[("django.template.loaders.locmem.Loader", {
                "base.html": "{% block content %}{% endblock %}",
            }), "django.template.loaders.filesystem.Loader"],
        )
        return engine.get_template(name).render(Context(context))

    def new_revision(self, kind="SINGLE_CHOICE"):
        return QuestionRevision(question_type=kind, prompt="A draft question?")

    @contextmanager
    def option_validation_without_database(self):
        # Only model DB lookups are mocked. Real forms/formset validation runs.
        with patch.object(QuestionOption, "clean"), patch.object(
            QuestionOption, "validate_unique"
        ), patch.object(QuestionOption, "validate_constraints"):
            yield

    def submitted_options(self, rows, kind="SINGLE_CHOICE"):
        data = {"options-TOTAL_FORMS": str(len(rows)), "options-INITIAL_FORMS": "0"}
        for index, row in enumerate(rows):
            for field, value in row.items():
                data[f"options-{index}-{field}"] = value
        return QuestionOptionFormSet(data, instance=self.new_revision(kind))

    def test_initial_editor_has_two_ordered_options_and_add_control(self):
        revision = self.new_revision()
        options = QuestionOptionFormSet(instance=revision)
        self.assertEqual(len(options.forms), 2)
        page = self.render_editor("assessments/revision_form.html", {
            "question": SimpleNamespace(pk=1, code="QA-QUESTION"),
            "revision": revision, "form": QuestionRevisionForm(instance=revision), "options": options,
        })
        self.assertTrue("data-add-option" in page, "Accessible Add option control is missing")
        self.assertIn("__prefix__", page)
        self.assertIn("question_editor.js", page)
        self.assertEqual([form["position"].value() for form in options], [1, 2])

    def test_existing_true_false_draft_has_no_extra_blank_options(self):
        revision = self.new_revision("TRUE_FALSE")
        revision.pk = 8
        saved = [QuestionOption(pk=1, question_revision=revision, text="True", position=1, is_correct=True),
                 QuestionOption(pk=2, question_revision=revision, text="False", position=2)]
        with patch.object(QuestionOptionFormSet, "get_queryset", return_value=saved):
            formset = QuestionOptionFormSet(instance=revision)
            self.assertEqual(len(formset.forms), 2)
            self.assertEqual([f["text"].value() for f in formset], ["True", "False"])
            self.assertEqual([f["id"].value() for f in formset], [1, 2])

    def test_four_options_keep_their_order_and_correct_answer(self):
        rows = [{"text": text, "position": index + 1, **({"is_correct": "on"} if index == 2 else {})}
                for index, text in enumerate(["A", "B", "C", "D"])]
        with self.option_validation_without_database():
            formset = self.submitted_options(rows)
            self.assertTrue(formset.is_valid(), formset.errors)
            self.assertEqual([f.cleaned_data["position"] for f in formset], [1, 2, 3, 4])
            self.assertEqual([f.cleaned_data["is_correct"] for f in formset], [False, False, True, False])

    def test_no_or_multiple_correct_answers_are_rejected(self):
        for flags in [(False, False), (True, True)]:
            rows = [{"text": text, "position": index+1, **({"is_correct": "on"} if flags[index] else {})}
                    for index, text in enumerate(["A", "B"])]
            with self.subTest(flags=flags), self.option_validation_without_database():
                formset = self.submitted_options(rows)
                self.assertFalse(formset.is_valid())
                self.assertIn("exactly one", str(formset.non_form_errors()))

    def test_true_false_labels_and_two_options_are_authoritative(self):
        for labels, valid in [(["True", "False"], True), (["Yes", "No"], False),
                              (["True", "False", "Maybe"], False)]:
            rows = [{"text": text, "position": index+1, **({"is_correct": "on"} if index == 0 else {})}
                    for index, text in enumerate(labels)]
            with self.subTest(labels=labels), self.option_validation_without_database():
                self.assertEqual(self.submitted_options(rows, "TRUE_FALSE").is_valid(), valid)

    def test_invalid_positions_are_rejected(self):
        with self.option_validation_without_database():
            formset = self.submitted_options([
                {"text": "A", "position": 0, "is_correct": "on"}, {"text": "B", "position": 2},
            ])
            self.assertFalse(formset.is_valid())
            self.assertIn("position", formset.errors[0])

    def test_duplicate_option_positions_are_rejected(self):
        with self.option_validation_without_database():
            formset = self.submitted_options([
                {"text": "A", "position": 1, "is_correct": "on"}, {"text": "B", "position": 1},
            ])
            self.assertFalse(formset.is_valid())

    def test_frozen_revision_and_option_model_guards_remain_authoritative(self):
        original = QuestionRevision(pk=7, question_id=1, prompt="Original", status="FROZEN")
        changed = QuestionRevision(pk=7, question_id=1, prompt="Changed", status="FROZEN")
        with patch.object(QuestionRevision, "original", return_value=original):
            with self.assertRaises(ValidationError):
                changed.clean()
        option = QuestionOption(pk=1, question_revision_id=7, text="Changed", position=1)
        with patch.object(QuestionOption, "original", return_value=option), patch(
            "assessments.models.QuestionRevision.objects.get", return_value=original
        ):
            with self.assertRaisesMessage(ValidationError, "Frozen question options cannot be changed"):
                option.clean()

    def test_edit_route_keeps_permission_and_draft_only_guards(self):
        request = RequestFactory().get("/revisions/7/edit/")
        request.user = SimpleNamespace(is_authenticated=True, has_perm=lambda permission: False)
        with patch("assessments.views.get_object_or_404") as lookup:
            with self.assertRaises(PermissionDenied):
                edit_question_revision(request, pk=7)
            lookup.assert_not_called()
        request.user.has_perm = lambda permission: True
        with patch("assessments.views.get_object_or_404", side_effect=Http404) as lookup:
            with self.assertRaises(Http404):
                edit_question_revision(request, pk=7)
            lookup.assert_called_once_with(QuestionRevision, pk=7, status=QuestionRevision.Status.DRAFT)

    def test_freeze_field_errors_are_readable_and_escaped(self):
        message = "Question prompt must be updated from the default placeholder before freezing."
        revision = SimpleNamespace(pk=7, question_id=1, question=SimpleNamespace(pk=1, code="QA"),
                                   _state=SimpleNamespace(db="default"),
                                   options=SimpleNamespace(all=lambda: []), status="DRAFT",
                                   save=Mock(side_effect=ValidationError({"prompt": [message, "<script>bad</script>"]})),
                                   refresh_from_db=Mock())
        request = RequestFactory().post("/revisions/7/freeze/")
        request.user = SimpleNamespace(is_authenticated=True, has_perm=lambda permission: True)
        with patch("assessments.views.get_object_or_404", return_value=revision), patch(
            "assessments.views.audit_snapshot", return_value={}
        ), patch("django.db.transaction.Atomic.__enter__", return_value=None), patch(
            "django.db.transaction.Atomic.__exit__", return_value=False,
        ), patch("assessments.views.require_lifecycle_permission", return_value=request.user), patch(
            "assessments.views.render"
        ) as render, patch("assessments.views.record_event") as audit:
            freeze_question_revision(request, pk=7)
            context = render.call_args.args[2]
            page = self.render_editor("assessments/revision_detail.html", context)
            self.assertIn(message, page)
            self.assertFalse("{'prompt':" in unescape(page), "ValidationError was rendered as a dictionary")
            self.assertIn("&lt;script&gt;bad&lt;/script&gt;", page)
            self.assertNotIn("<script>bad</script>", page)
            self.assertEqual(render.call_args.kwargs["status"], 400)
            audit.assert_not_called()
            revision.refresh_from_db.assert_called_once()


# These integration tests require an approved disposable MySQL environment.
class QuestionEditorPersistenceTests(CurriculumTestCase):
    def setUp(self):
        Group.objects.get(name="Training Coordinator").user_set.add(self.user)
        self.client.force_login(self.user)
        self.draft = QuestionRevision.objects.create(
            question=self.question, revision_number=2, prompt="Draft question?", created_by=self.user,
        )
        self.url = f"/revisions/{self.draft.pk}/edit/"

    def payload(self, texts, kind="SINGLE_CHOICE", saved=()):
        data = {"question_type": kind, "prompt": "A usable question?", "explanation": "",
                "options-TOTAL_FORMS": str(len(texts)), "options-INITIAL_FORMS": str(len(saved))}
        for index, text in enumerate(texts):
            data.update({f"options-{index}-text": text, f"options-{index}-position": index+1})
            if index == 0:
                data[f"options-{index}-is_correct"] = "on"
            if index < len(saved):
                data[f"options-{index}-id"] = saved[index].pk
        return data

    def test_four_options_persist_in_order_without_changing_the_frozen_revision(self):
        response = self.client.post(self.url, self.payload(["A", "B", "C", "D"]))
        self.assertEqual(response.status_code, 302)
        self.assertEqual(list(self.draft.options.values_list("text", "position", "is_correct")),
                         [("A", 1, True), ("B", 2, False), ("C", 3, False), ("D", 4, False)])
        self.revision.refresh_from_db()
        self.assertEqual(self.revision.status, "FROZEN")
        self.assertEqual(self.revision.prompt, "Wear PPE?")
        self.assertEqual(self.revision.options.count(), 2)
        self.assertEqual(self.client.post(f"/revisions/{self.revision.pk}/edit/",
                                         self.payload(["Changed", "No"])).status_code, 404)

    def test_explicit_true_false_conversion_preserves_first_ids_and_removes_only_requested_draft_extras(self):
        self.assertEqual(self.client.post(self.url, self.payload(["A", "B", "C", "D"])).status_code, 302)
        saved = list(self.draft.options.all())
        data = self.payload(["True", "False", "C", "D"], "TRUE_FALSE", saved)
        data.update({"options-2-DELETE": "on", "options-3-DELETE": "on"})
        self.assertEqual(self.client.post(self.url, data).status_code, 302)
        self.draft.refresh_from_db()
        self.assertEqual(self.draft.question_type, "TRUE_FALSE")
        self.assertEqual(list(self.draft.options.values_list("pk", "text")),
                         [(saved[0].pk, "True"), (saved[1].pk, "False")])

    def test_invalid_answer_submission_preserves_the_existing_draft(self):
        self.assertEqual(self.client.post(self.url, self.payload(["A", "B"])).status_code, 302)
        saved = list(self.draft.options.all())
        data = self.payload(["Changed A", "Changed B"], saved=saved)
        data.update({"prompt": "Changed prompt?", "options-1-is_correct": "on"})
        response = self.client.post(self.url, data)
        self.assertEqual(response.status_code, 200)
        self.draft.refresh_from_db()
        self.assertEqual(self.draft.prompt, "A usable question?")
        self.assertEqual(list(self.draft.options.values_list("text", flat=True)), ["A", "B"])
