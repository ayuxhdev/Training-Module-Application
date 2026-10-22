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
    "assessments.question.created": "Question created",
    "assessments.question.updated": "Question updated",
    "assessments.questionrevision.created": "Question revision created",
    "assessments.assessmentquestion.created": "Question added to assessment",
    "assessments.attempt.started": "Assessment attempt started",
    "assessments.attempt.submitted": "Assessment attempt submitted",
    "assessments.attempt.expired": "Assessment attempt expired",
    "certifications.certificate.issued": "Certificate issued",
    "certifications.certificate.revoked": "Certificate revoked",
}

FIELD_LABELS = {
    "actor_label_snapshot": "Recorded actor",
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

BOOLEAN_FIELDS = {"is_active", "is_required"}
STATUS_LABELS = {
    "ASSIGNED": "Assigned",
    "COMPLETED": "Completed",
    "DRAFT": "Draft",
    "IN_PROGRESS": "In progress",
    "OVERDUE": "Overdue",
    "PUBLISHED": "Published",
    "RETIRED": "Retired",
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


@register.filter
def audit_changes(entry):
    before = entry.before_data if isinstance(entry.before_data, dict) else {}
    after = entry.after_data if isinstance(entry.after_data, dict) else {}
    changed_fields = after.get("changed_fields")

    if isinstance(changed_fields, list):
        fields = [name for name in changed_fields if isinstance(name, str)]
    else:
        fields = list(before)
        fields.extend(name for name in after if name not in before)

    changes = []
    for name in fields:
        if name == "changed_fields":
            continue
        changes.append({
            "field": name,
            "before": before.get(name, "Not recorded"),
            "after": after.get(name, "Not recorded"),
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
