"""Transactional adapters for the existing website authoring forms."""

from django.core.exceptions import ValidationError
from django.db import transaction
from django.db.models import Max
from django.shortcuts import get_object_or_404

from audit.services import audit_snapshot, record_event
from training.forms import LessonForm, ModuleForm, TrainingForm, TrainingVersionForm
from training.models import Lesson, Module, Training, TrainingVersion


def _save_form(form, actor, *, creating):
    before = {} if creating else audit_snapshot(form.instance)
    if not form.is_valid():
        raise ValidationError(dict(form.errors))
    changed = list(form.changed_data)
    if not creating and not changed:
        return form.instance
    instance = form.save()
    verb = "created" if creating else "updated"
    record_event(
        actor, f"{instance._meta.label_lower}.{verb}", instance,
        before=before, after={**audit_snapshot(instance), "changed_fields": changed},
    )
    return instance


@transaction.atomic
def create_training(actor, values):
    instance = Training(created_by=actor)
    return _save_form(TrainingForm(data=values, instance=instance), actor, creating=True)


@transaction.atomic
def update_training(actor, training_id, values):
    # Fresh locked state prevents a partial update from overwriting another edit.
    instance = get_object_or_404(Training.objects.select_for_update(), pk=training_id)
    data = {field: getattr(instance, field) for field in TrainingForm.Meta.fields}
    data.update(values)
    return _save_form(TrainingForm(data=data, instance=instance), actor, creating=False)


@transaction.atomic
def create_draft_version(actor, training_id, values):
    # Every API allocator serializes on the existing catalog row, including the
    # first version. The unique constraint also protects concurrent web authors.
    training = get_object_or_404(Training.objects.select_for_update(), pk=training_id)
    latest = training.versions.aggregate(number=Max("version_number"))["number"] or 0
    instance = TrainingVersion(training=training, created_by=actor)
    data = {**values, "version_number": latest + 1}
    # The website permits draft authoring for inactive courses. Inactivity only
    # excludes courses from the assignment picker; do not invent a new policy.
    return _save_form(TrainingVersionForm(data=data, instance=instance), actor, creating=True)


def _locked_draft(version_id):
    # The same aggregate lock is taken by publication and VersionContent.save().
    return get_object_or_404(
        TrainingVersion.objects.select_for_update(),
        pk=version_id, status=TrainingVersion.Status.DRAFT,
    )


@transaction.atomic
def create_module(actor, version_id, values):
    version = _locked_draft(version_id)
    instance = Module(training_version=version)
    return _save_form(ModuleForm(data=values, instance=instance), actor, creating=True)


@transaction.atomic
def update_module(actor, version_id, module_id, values):
    _locked_draft(version_id)
    instance = get_object_or_404(
        Module.objects.select_for_update(), pk=module_id, training_version_id=version_id,
    )
    data = {field: getattr(instance, field) for field in ModuleForm.Meta.fields}
    data.update(values)
    return _save_form(ModuleForm(data=data, instance=instance), actor, creating=False)


def _text_lesson_form(instance, values):
    # Keep text authoring on the website's validation path. Video metadata is
    # never writable here, and existing VIDEO instances are excluded at lookup.
    data = {field: getattr(instance, field) for field in LessonForm.Meta.fields}
    data.update(values)
    data["content_type"] = Lesson.ContentType.TEXT
    form = LessonForm(data=data, instance=instance)
    if instance.pk and "body" not in values:
        # PATCH omission preserves the fresh locked value, including formatting.
        # Explicit body submissions retain the website's normal validation.
        form.fields["body"].strip = False
    return form


@transaction.atomic
def create_text_lesson(actor, version_id, module_id, values):
    _locked_draft(version_id)
    module = get_object_or_404(
        Module.objects.select_for_update(), pk=module_id, training_version_id=version_id,
    )
    instance = Lesson(module=module, content_type=Lesson.ContentType.TEXT)
    return _save_form(_text_lesson_form(instance, values), actor, creating=True)


@transaction.atomic
def update_text_lesson(actor, version_id, module_id, lesson_id, values):
    _locked_draft(version_id)
    module = get_object_or_404(
        Module.objects.select_for_update(), pk=module_id, training_version_id=version_id,
    )
    instance = get_object_or_404(
        Lesson.objects.select_for_update(), pk=lesson_id, module=module,
        content_type=Lesson.ContentType.TEXT,
    )
    return _save_form(_text_lesson_form(instance, values), actor, creating=False)
