from decimal import Decimal

from django.core.exceptions import ValidationError
from django.db import DatabaseError, transaction

from .models import AuditLog


class AuditWriteError(RuntimeError):
	"""The required audit record could not be persisted."""


AUDIT_FIELDS = {
	"organization.employee": (
		"employee_code", "display_name", "is_active", "department_id", "job_role_id", "reporting_manager_id",
	),
	"organization.department": ("code", "name", "is_active"),
	"organization.jobrole": ("code", "name", "is_active"),
	"training.training": ("code", "catalog_title", "is_active"),
	"training.trainingversion": ("training_id", "version_number", "title", "status"),
	"training.module": ("training_version_id", "title", "position"),
	"training.lesson": (
		"module_id", "title", "position", "content_type", "is_required", "minimum_watch_percent",
	),
	"training.trainingassignment": (
		"employee_id", "training_version_id", "status", "source", "due_at", "completed_at",
	),
	"assessments.question": ("code", "topic", "is_active"),
	"assessments.questionrevision": ("question_id", "revision_number", "status"),
	"assessments.assessment": (
		"training_version_id", "kind", "module_id", "title", "sequence", "is_required",
		"pass_percentage", "max_attempts", "time_limit_minutes",
	),
	"assessments.assessmentquestion": (
		"assessment_id", "question_revision_id", "position", "points",
	),
}


def audit_snapshot(target):
	values = {}
	for name in AUDIT_FIELDS.get(target._meta.label_lower, ()):
		value = getattr(target, name)
		if hasattr(value, "isoformat"):
			value = value.isoformat()
		elif isinstance(value, Decimal):
			value = str(value)
		values[name] = value
	return values


def record_event(actor, action, target, *, before=None, after=None, reason=""):
	"""Write mandatory evidence on the target's connection before commit."""
	using = target._state.db
	if target.pk is None or target._state.adding or not using or not transaction.get_connection(using).in_atomic_block:
		raise AuditWriteError("Required audit events must accompany a saved target in its transaction.")
	actor = actor if getattr(actor, "is_authenticated", False) else None
	if actor is not None and actor._state.db != using:
		transaction.set_rollback(True, using=using)
		raise AuditWriteError("The audit actor and target must use the same database.")
	actor_label = actor.get_username()[:150] if actor else "System"
	values = {
		"actor": actor,
		"actor_label_snapshot": actor_label,
		"action": action,
		"entity_type": target._meta.label_lower,
		"entity_id": str(target.pk),
		"before_data": dict(before or {}),
		"after_data": dict(after or {}),
		"reason": reason,
	}

	try:
		AuditLog.objects.db_manager(using).create(**values)
	except (DatabaseError, ValidationError):
		# AuditLog.save() has its own savepoint. Roll back the caller's
		# transaction as well, and keep storage details out of client errors.
		transaction.set_rollback(True, using=using)
		raise AuditWriteError("Required audit event could not be saved.") from None
