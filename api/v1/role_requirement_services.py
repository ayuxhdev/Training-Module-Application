"""API adapters over existing requirement forms, validated models and notifications."""

from datetime import timedelta

from django.contrib.auth import get_user_model
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import transaction
from django.shortcuts import get_object_or_404
from django.utils import timezone

from audit.services import record_event
from notifications.models import Notification
from notifications.services import create_assignment_notification
from organization.models import Employee, JobRole
from training.forms import (
    RoleTrainingAssignmentForm, RoleTrainingRequirementCreateForm,
    RoleTrainingRequirementUpdateForm,
)
from training.models import RoleTrainingRequirement, TrainingAssignment, TrainingVersion
from training.permissions import can_assign_company_training


REQUIREMENT_FIELDS = ("job_role_id", "training_version_id", "due_in_days", "is_active")


def requirement_snapshot(requirement):
    return {field: getattr(requirement, field) for field in REQUIREMENT_FIELDS}


@transaction.atomic
def save_requirement(actor, values, requirement_id=None):
    creating = requirement_id is None
    original = None if creating else get_object_or_404(RoleTrainingRequirement, pk=requirement_id)
    version_id = values["training_version_id"] if creating else original.training_version_id
    role_id = values["job_role_id"] if creating else original.job_role_id
    # Match batch execution: version -> job role -> requirement. References are
    # immutable; resolve the fresh requirement only after the shared roots lock.
    get_object_or_404(TrainingVersion.objects.select_for_update(), pk=version_id)
    get_object_or_404(JobRole.objects.select_for_update(), pk=role_id)
    instance = RoleTrainingRequirement(created_by=actor) if creating else get_object_or_404(
        RoleTrainingRequirement.objects.select_for_update(), pk=requirement_id,
    )
    before = {} if creating else requirement_snapshot(instance)
    form_class = RoleTrainingRequirementCreateForm if creating else RoleTrainingRequirementUpdateForm
    data = {
        field: getattr(instance, field + "_id" if field in ("job_role", "training_version") else field)
        for field in form_class.Meta.fields
    }
    field_names = {"job_role_id": "job_role", "training_version_id": "training_version"}
    data.update({field_names.get(key, key): value for key, value in values.items()})
    form = form_class(data=data, instance=instance)
    if not form.is_valid():
        raise ValidationError(dict(form.errors))
    if not creating and not form.has_changed():
        return instance
    instance = form.save()
    action = "training.roletrainingrequirement.created" if creating else "training.roletrainingrequirement.updated"
    record_event(actor, action, instance, before=before, after=requirement_snapshot(instance))
    return instance


@transaction.atomic
def execute_role_batch(actor, requirement_id):
    reference = get_object_or_404(RoleTrainingRequirement, pk=requirement_id)
    # Employee locks precede Version/actor locks, like manual assignment and
    # hierarchy editing. Do not join FK tables into this locking query.
    employees = list(
        Employee.objects.filter(job_role_id=reference.job_role_id).order_by("pk").select_for_update()
    )
    version = get_object_or_404(TrainingVersion.objects.select_for_update(), pk=reference.training_version_id)
    get_object_or_404(JobRole.objects.select_for_update(), pk=reference.job_role_id)
    requirement = get_object_or_404(RoleTrainingRequirement.objects.select_for_update(), pk=requirement_id)
    actor = get_user_model().objects.select_for_update().filter(pk=actor.pk).first()
    if not can_assign_company_training(actor):
        raise PermissionDenied
    # Reuse the website's eligibility validator after locking current state.
    form = RoleTrainingAssignmentForm(data={"role_requirement": requirement.pk})
    if not form.is_valid():
        raise ValidationError(dict(form.errors))
    assigned_at = timezone.now()
    try:
        due_at = assigned_at + timedelta(days=requirement.due_in_days)
    except OverflowError as exc:
        raise ValidationError({"role_requirement": ["The due period is outside the supported date range."]}) from exc
    # Current reads also remain fresh under REPEATABLE READ after waiting on an
    # Employee lock. Existing cancelled/completed/manual/role rows all count.
    existing = set(TrainingAssignment.objects.select_for_update().filter(
        employee_id__in=[employee.pk for employee in employees], training_version_id=version.pk,
    ).values_list("employee_id", flat=True))
    created = 0
    for employee in employees:
        if not employee.is_active or employee.pk in existing:
            continue
        assignment = TrainingAssignment.objects.create(
            employee=employee, training_version=version, source=TrainingAssignment.Source.ROLE,
            role_requirement=requirement, department_at_assignment_id=employee.department_id,
            job_role_at_assignment_id=employee.job_role_id, assigned_by=actor,
            assigned_at=assigned_at, due_at=due_at,
        )
        create_assignment_notification(assignment.pk, Notification.EventType.ASSIGNED)
        created += 1
    result = {"job_role_id": requirement.job_role_id, "training_version_id": version.pk,
              "created_count": created, "skipped_count": len(employees) - created}
    if created:
        record_event(actor, "training.role_assignment.batch_created", requirement, after=result)
    return {"role_requirement_id": requirement.pk, **result}
