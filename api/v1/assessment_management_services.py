"""Locked adapters for the website's assessment and question-bank forms."""

from django.core.exceptions import ValidationError
from django.db import transaction
from django.http import Http404
from django.shortcuts import get_object_or_404
from django.utils import timezone

from assessments.forms import (
    AssessmentForm, AssessmentQuestionForm, QuestionForm,
    QuestionOptionFormSet, QuestionRevisionForm,
)
from assessments.models import Assessment, AssessmentQuestion, Question, QuestionOption, QuestionRevision
from audit.services import audit_snapshot, record_event

from .training_management_services import _locked_draft, _save_form


@transaction.atomic
def save_assessment(actor, version_id, values, assessment_id=None):
    version = _locked_draft(version_id)
    instance = Assessment(training_version=version) if assessment_id is None else get_object_or_404(
        Assessment.objects.select_for_update(), pk=assessment_id, training_version=version,
    )
    data = {field: getattr(instance, "module_id" if field == "module" else field) for field in AssessmentForm.Meta.fields}
    data.update({"module" if key == "module_id" else key: value for key, value in values.items()})
    form = AssessmentForm(data=data, instance=instance, training_version=version)
    if assessment_id is not None and "title" not in values:
        form.fields["title"].strip = False
    return _save_form(form, actor, creating=assessment_id is None)


@transaction.atomic
def save_assessment_question(actor, version_id, assessment_id, values, item_id=None):
    _locked_draft(version_id)
    assessment = get_object_or_404(Assessment.objects.select_for_update(), pk=assessment_id, training_version_id=version_id)
    instance = AssessmentQuestion(assessment=assessment) if item_id is None else get_object_or_404(
        AssessmentQuestion.objects.select_for_update(), pk=item_id, assessment=assessment,
    )
    data = {"question_revision": instance.question_revision_id, "position": instance.position, "points": instance.points}
    data.update({"question_revision" if key == "question_revision_id" else key: value for key, value in values.items()})
    form = AssessmentQuestionForm(data=data, instance=instance)
    # The model clean() dereferences this required relation even when a form
    # field is invalid. Use its existing scoped choice validator before that
    # model hook, so a rejected reference produces 400 rather than an exception.
    try:
        selected = form.fields["question_revision"].clean(data["question_revision"])
    except ValidationError as exc:
        raise ValidationError({"question_revision": exc.messages}) from exc
    if item_id is None:
        instance.question_revision = selected
    # An edit already has a valid relation. Leave it intact until _save_form()
    # captures its before snapshot; form validation then applies the new choice.
    return _save_form(form, actor, creating=item_id is None)


@transaction.atomic
def create_question(actor, values):
    question = _save_form(QuestionForm(data=values, instance=Question(created_by=actor)), actor, creating=True)
    # Match the website: creating a bank entry creates its initial draft too.
    revision = QuestionRevision.objects.create(question=question, revision_number=1, prompt="Draft question", created_by=actor)
    record_event(actor, "assessments.questionrevision.created", revision, after=audit_snapshot(revision))
    return question


@transaction.atomic
def update_question(actor, question_id, values):
    question = get_object_or_404(Question.objects.select_for_update(), pk=question_id)
    data = {field: getattr(question, field) for field in QuestionForm.Meta.fields}
    data.update(values)
    form = QuestionForm(data=data, instance=question)
    for field in ("code", "topic"):
        if field not in values:
            form.fields[field].strip = False
    return _save_form(form, actor, creating=False)


@transaction.atomic
def create_revision(actor, question_id, values):
    question = get_object_or_404(Question.objects.select_for_update(), pk=question_id)
    number = (question.revisions.order_by("-revision_number").values_list("revision_number", flat=True).first() or 0) + 1
    instance = QuestionRevision(question=question, revision_number=number, created_by=actor)
    return _save_form(QuestionRevisionForm(data=values, instance=instance), actor, creating=True)


def _locked_revision(question_id, revision_id):
    get_object_or_404(Question.objects.select_for_update(), pk=question_id)
    return get_object_or_404(
        QuestionRevision.objects.select_for_update(), pk=revision_id, question_id=question_id,
        status=QuestionRevision.Status.DRAFT,
    )


def _option_formset(revision, changes):
    queryset = QuestionOption.objects.filter(question_revision=revision).order_by("position", "pk")
    existing = list(queryset)
    existing_ids = {option.pk for option in existing}
    updates, additions = {}, []
    for values in changes:
        if "id" in values:
            option_id = values["id"]
            if option_id not in existing_ids:
                raise Http404
            if option_id in updates:
                raise ValidationError({"options": ["Submit each option ID only once."]})
            updates[option_id] = values
        else:
            additions.append(values)
    rows = []
    for option in existing:
        row = {field: getattr(option, field) for field in ("id", "text", "position", "is_correct")}
        row.update(updates.get(option.pk, {}))
        rows.append(row)
    rows.extend({"is_correct": False, **values} for values in additions)
    data = {"options-TOTAL_FORMS": len(rows), "options-INITIAL_FORMS": len(existing)}
    for index, row in enumerate(rows):
        for key, value in row.items():
            data[f"options-{index}-{'DELETE' if key == 'delete' else key}"] = value
    formset = QuestionOptionFormSet(data=data, instance=revision, prefix="options", queryset=queryset)
    for option, form in zip(existing, formset.initial_forms):
        if "text" not in updates.get(option.pk, {}):
            form.fields["text"].strip = False
    return formset


@transaction.atomic
def update_revision(actor, question_id, revision_id, values):
    revision = _locked_revision(question_id, revision_id)
    before = audit_snapshot(revision)
    data = {field: getattr(revision, field) for field in QuestionRevisionForm.Meta.fields}
    data.update({key: value for key, value in values.items() if key != "options"})
    form = QuestionRevisionForm(data=data, instance=revision)
    for field in ("prompt", "explanation"):
        if field not in values:
            form.fields[field].strip = False
    options = _option_formset(revision, values.get("options", []))
    valid_form, valid_options = form.is_valid(), options.is_valid()
    errors = dict(form.errors)
    if not valid_options:
        errors["options"] = list(options.non_form_errors()) + [
            f"Option {index + 1}: {field}: {' '.join(messages)}"
            for index, fields in enumerate(options.errors) for field, messages in fields.items()
        ]
    if not valid_form or not valid_options:
        raise ValidationError(errors)
    changed = list(form.changed_data)
    if not changed and not options.has_changed():
        return revision
    form.save()
    options.save()
    record_event(actor, "assessments.questionrevision.updated", revision, before=before, after={
        **audit_snapshot(revision), "changed_fields": changed,
        "content_updated": True, "options_updated": options.has_changed(),
    })
    return revision


@transaction.atomic
def freeze_revision(actor, question_id, revision_id, values):
    revision = _locked_revision(question_id, revision_id)
    before = audit_snapshot(revision)
    revision.status = QuestionRevision.Status.FROZEN
    revision.frozen_at = timezone.now()
    # Existing model validation enforces >=2 options, exactly one correct, and
    # exactly True/False labels for TRUE_FALSE. No alternate scoring rules.
    revision.save()
    record_event(actor, "assessments.questionrevision.frozen", revision, before=before, after=audit_snapshot(revision))
    return revision
