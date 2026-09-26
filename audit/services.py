from decimal import Decimal

from django.db import transaction

from .models import AuditLog


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
	actor = actor if getattr(actor, "is_authenticated", False) else None
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

	def write_event():
		AuditLog.objects.create(**values)

	transaction.on_commit(write_event, robust=True)