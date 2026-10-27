import json

from django import template


register = template.Library()


ENTITY_LABELS = {
    "organization.employee": "Employee",
    "organization.department": "Department",
    "organization.jobrole": "Job role",
    "training.training": "Training",
    "training.trainingversion": "Training version",
    "training.module": "Module",
    "training.lesson": "Lesson",
    "training.trainingassignment": "Training assignment",
    "training.lessonprogress": "Lesson progress",
    "training.videowatchsession": "Video watch session",
    "training.roletrainingrequirement": "Job-role training requirement",
    "assessments.question": "Question",
    "assessments.questionrevision": "Question revision",
    "assessments.assessment": "Assessment",
    "assessments.assessmentquestion": "Assessment question",
    "assessments.assessmentattempt": "Assessment attempt",
    "certifications.certificate": "Certificate",
}

ACTION_LABELS = {
    "organization.employee.created": "Employee created",
    "organization.employee.updated": "Employee updated",
    "organization.employee.deactivated": "Employee deactivated",
    "organization.department.created": "Department created",
    "organization.department.updated": "Department updated",
    "organization.jobrole.created": "Job role created",
    "organization.jobrole.updated": "Job role updated",
    "training.training.created": "Training created",
    "training.training.updated": "Training updated",
    "training.trainingversion.created": "Training version created",
    "training.trainingversion.updated": "Training version updated",
    "training.trainingversion.published": "Training version published",
    "training.trainingversion.retired": "Training version retired",
    "training.module.created": "Module created",
    "training.module.updated": "Module updated",
    "training.lesson.created": "Lesson created",
    "training.lesson.updated": "Lesson updated",
    "training.trainingassignment.created": "Training assignment created",
    "training.trainingassignment.updated": "Training assignment updated",
    "training.trainingassignment.completed": "Training assignment completed",
    "training.role_assignment.batch_created": "Role-based assignments created",
    "training.lessonprogress.completed": "Lesson completed",
    "training.videowatchsession.started": "Video watch session started",
    "training.videowatchsession.ended": "Video watch session ended",
    "assessments.question.created": "Question created",
    "assessments.question.updated": "Question updated",
    "assessments.questionrevision.created": "Question revision created",
    "assessments.questionrevision.updated": "Question revision updated",
    "assessments.questionrevision.frozen": "Question revision frozen",
    "assessments.assessment.created": "Assessment created",
    "assessments.assessment.updated": "Assessment updated",
    "assessments.assessmentquestion.created": "Question added to assessment",
    "assessments.assessmentquestion.updated": "Assessment question updated",
    "assessments.attempt.started": "Assessment attempt started",
    "assessments.attempt.submitted": "Assessment attempt submitted",
    "assessments.attempt.expired": "Assessment attempt expired",
    "certifications.certificate.issued": "Certificate issued",
    "certifications.certificate.revoked": "Certificate revoked",
}

FIELD_LABELS = {
    "actor_label_snapshot": "Recorded actor",
    "assignment_id": "Assignment ID",
    "assessment_id": "Assessment ID",
    "attempt_number": "Attempt number",
    "completed_at": "Completed at",
    "completed_normally": "Playback completed normally",
    "content_updated": "Content updated",
    "created_count": "Assignments created",
    "due_at": "Due at",
    "ended_at": "Ended at",
    "lesson_id": "Lesson ID",
    "max_attempts": "Maximum attempts",
    "question_id": "Question ID",
    "question_revision_id": "Question revision ID",
    "revoked_at": "Revoked at",
    "revoked_by_id": "Revoked by account ID",
    "session_id": "Video session ID",
    "skipped_count": "Assignments skipped",
    "started_at": "Started at",
    "time_limit_minutes": "Time limit (minutes)",
    "catalog_title": "Training title",
    "changed_fields": "Changed fields",
    "content_type": "Lesson type",
    "department_id": "Department ID",
    "display_name": "Name",
    "employee_code": "Employee code",
    "employee_id": "Employee ID",
    "is_active": "Active",
    "is_required": "Required",
    "job_role_id": "Job role ID",
    "minimum_watch_percent": "Minimum watch percentage",
    "module_id": "Module ID",
    "pass_percentage": "Pass percentage",
    "position": "Position",
    "reporting_manager_id": "Reporting manager ID",
    "revision_number": "Revision number",
    "training_id": "Training ID",
    "training_version_id": "Training version ID",
    "version_number": "Version number",
}

BOOLEAN_FIELDS = {"is_active", "is_required", "completed_normally", "content_updated", "passed"}
STATUS_LABELS = {
    "ASSIGNED": "Assigned",
    "ABANDONED": "Abandoned",
    "CANCELLED": "Cancelled",
    "EXPIRED": "Expired",
    "FROZEN": "Frozen",
    "COMPLETED": "Completed",
    "DRAFT": "Draft",
    "IN_PROGRESS": "In progress",
    "OVERDUE": "Overdue",
    "PUBLISHED": "Published",
    "RETIRED": "Retired",
    "SUBMITTED": "Submitted",
}

RECORD_NAME_FIELDS = {
    "organization.employee": ("display_name",),
    "organization.department": ("name",),
    "organization.jobrole": ("name",),
    "training.training": ("catalog_title",),
    "training.trainingversion": ("title",),
    "training.module": ("title",),
    "training.lesson": ("title",),
    "assessments.question": ("code",),
    "assessments.assessment": ("title",),
}


@register.filter
def audit_action_label(action):
    return ACTION_LABELS.get(action, action)


@register.filter
def audit_entity_label(entity_type):
    return ENTITY_LABELS.get(entity_type, entity_type)


@register.filter
def audit_field_label(field_name):
    if field_name in FIELD_LABELS:
        return FIELD_LABELS[field_name]
    return str(field_name).replace("_", " ").capitalize()


@register.filter
def audit_display_value(value, field_name=""):
    if value is None:
        return "Not set"
    if field_name in BOOLEAN_FIELDS and isinstance(value, bool):
        return "Yes" if value else "No"
    if field_name == "status" and isinstance(value, str) and value in STATUS_LABELS:
        return STATUS_LABELS[value]
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, indent=2)
    return str(value)


METADATA_FIELDS = {"changed_fields"}


def _snapshot_values(snapshot):
    if not isinstance(snapshot, dict):
        return {}
    return {k: v for k, v in snapshot.items() if k not in METADATA_FIELDS}


@register.filter
def audit_detail_kind(entry):
    before = _snapshot_values(getattr(entry, "before_data", None))
    after = _snapshot_values(getattr(entry, "after_data", None))
    if before and after:
        return "changes"
    action = getattr(entry, "action", "") or ""
    if not before and after and (
        action.endswith(".created")
        or action in {
            "training.videowatchsession.started",
            "assessments.attempt.started",
            "certifications.certificate.issued",
        }
    ):
        return "creation"
    return "snapshot"


@register.filter
def audit_snapshot_side(entry):
    has_before = bool(_snapshot_values(getattr(entry, "before_data", None)))
    has_after = bool(_snapshot_values(getattr(entry, "after_data", None)))
    if has_after and not has_before:
        return "after"
    if has_before and not has_after:
        return "before"
    if has_before and has_after:
        return "both"
    return "none"


@register.filter
def audit_snapshot_notice(entry):
    side = audit_snapshot_side(entry)
    if side == "both":
        return ""
    if side == "after":
        return "Only an after snapshot was recorded."
    if side == "before":
        return "Only a before snapshot was recorded."
    before_raw = getattr(entry, "before_data", None)
    after_raw = getattr(entry, "after_data", None)
    has_meta = (
        isinstance(after_raw, dict) and bool(after_raw.get("changed_fields"))
    ) or (
        isinstance(before_raw, dict) and bool(before_raw.get("changed_fields"))
    )
    if has_meta:
        return "Only changed field names were recorded without snapshot values."
    return "No field snapshots were recorded."


@register.filter
def audit_changes(entry):
    before = entry.before_data if isinstance(getattr(entry, "before_data", None), dict) else {}
    after = entry.after_data if isinstance(getattr(entry, "after_data", None), dict) else {}
    # Compare recorded values even when changed_fields is incomplete. Keep named
    # but uncaptured fields visible without inventing their confidential values.
    fields = list(before)
    fields.extend(name for name in after if name not in before)
    for snapshot in (after, before):
        changed_fields = snapshot.get("changed_fields")
        if isinstance(changed_fields, list):
            fields.extend(
                name for name in changed_fields
                if isinstance(name, str) and name not in fields
            )

    changes = []
    for name in dict.fromkeys(fields):
        if name in METADATA_FIELDS:
            continue
        if name in before and name in after:
            # Canonical JSON ignores object-key order but preserves distinctions
            # such as false versus 0, including within nested structures.
            before_json = json.dumps(before[name], sort_keys=True)
            after_json = json.dumps(after[name], sort_keys=True)
            if before_json == after_json:
                continue
        changes.append({
            "field": name,
            "before": before.get(name, "Not recorded"),
            "after": after.get(name, "Not recorded"),
            "recorded": after.get(name, before.get(name, "Not recorded")),
            "captured": name in before or name in after,
        })
    return changes


@register.filter
def audit_record_summary(entry):
    fields = RECORD_NAME_FIELDS.get(entry.entity_type, ())
    for snapshot in (entry.after_data, entry.before_data):
        if not isinstance(snapshot, dict):
            continue
        for field_name in fields:
            value = snapshot.get(field_name)
            if value not in (None, ""):
                return value
    return f"Record #{entry.entity_id}"


@register.filter
def audit_json(value):
    return json.dumps(value, ensure_ascii=False, indent=2)
