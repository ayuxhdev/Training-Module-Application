"""Transactional adapters for the existing website authoring forms."""

from django.core.exceptions import ValidationError
from django.db import transaction
from django.db.models import Max
from django.shortcuts import get_object_or_404

from audit.services import audit_snapshot, record_event
from training.forms import TrainingForm, TrainingVersionForm
from training.models import Training, TrainingVersion


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
