"""Safe audit presentation: no raw snapshots, reasons or arbitrary metadata."""

from types import SimpleNamespace
from decimal import Decimal, InvalidOperation
import re

from django.utils.dateparse import parse_datetime
from rest_framework import serializers

from audit.templatetags.audit_presentation import (
    ACTION_LABELS, ENTITY_LABELS, STATUS_LABELS, audit_action_label, audit_changes,
    audit_detail_kind, audit_display_value, audit_entity_label, audit_field_label,
    audit_snapshot_notice,
)


class AuditLogQuerySerializer(serializers.Serializer):
    actor = serializers.IntegerField(min_value=1, required=False)
    action = serializers.CharField(max_length=80, required=False)
    start_date = serializers.DateField(required=False)
    end_date = serializers.DateField(required=False)
    target_type = serializers.CharField(max_length=100, required=False)

    def validate(self, values):
        if values.get("start_date") and values.get("end_date"):
            if values["start_date"] > values["end_date"]:
                raise serializers.ValidationError({"end_date": "End date must not precede start date."})
        return values


# Deliberately exclude names, content, free text, paths, tokens and nested data.
# Unknown fields and values never pass through presentation-helper fallbacks.
ID_FIELDS = {
    "assignment_id", "assessment_id", "employee_id", "training_id", "training_version_id",
    "module_id", "lesson_id", "question_id", "question_revision_id", "session_id",
    "department_id", "job_role_id", "reporting_manager_id", "revoked_by_id",
}
NUMBER_FIELDS = {
    "position", "version_number", "revision_number", "attempt_number", "max_attempts",
    "created_count", "skipped_count", "time_limit_minutes",
}
PERCENTAGE_FIELDS = {"minimum_watch_percent", "pass_percentage"}
BOOLEAN_FIELDS = {"is_active", "is_required", "completed_normally", "content_updated", "passed"}
DATE_FIELDS = {"started_at", "ended_at", "completed_at", "due_at", "revoked_at"}


def safe_snapshot(snapshot):
    if not isinstance(snapshot, dict):
        return {}
    result = {}
    for name, value in snapshot.items():
        if name in PERCENTAGE_FIELDS:
            if type(value) not in (int, str):
                continue
            text = str(value)
            if re.fullmatch(r"[0-9]{1,3}(?:\.[0-9]{1,2})?", text) is None:
                continue
            try:
                percentage = Decimal(text)
            except InvalidOperation:
                continue
            if percentage.is_finite() and 0 <= percentage <= 100:
                result[name] = value
        elif name in ID_FIELDS | NUMBER_FIELDS:
            if value is None or (type(value) is int and 0 <= value <= 2**64 - 1):
                result[name] = value
        elif name in BOOLEAN_FIELDS and type(value) is bool:
            result[name] = value
        elif name == "status" and isinstance(value, str) and value in STATUS_LABELS:
            result[name] = value
        elif name in DATE_FIELDS:
            if value is None:
                result[name] = None
            elif isinstance(value, str) and len(value) <= 40:
                try:
                    parsed = parse_datetime(value)
                except ValueError:
                    parsed = None
                if parsed is not None:
                    result[name] = parsed.isoformat()
    return result


class AuditLogSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    occurred_at = serializers.DateTimeField()
    actor_id = serializers.IntegerField(allow_null=True)
    actor_label_snapshot = serializers.SerializerMethodField()
    action = serializers.SerializerMethodField()
    action_label = serializers.SerializerMethodField()
    entity_type = serializers.SerializerMethodField()
    entity_label = serializers.SerializerMethodField()
    entity_id = serializers.SerializerMethodField()
    record_summary = serializers.SerializerMethodField()
    changes = serializers.SerializerMethodField()
    detail_kind = serializers.SerializerMethodField()
    snapshot_notice = serializers.SerializerMethodField()

    def get_actor_label_snapshot(self, entry):
        # Do not echo arbitrary historical free text or substitute a renamed
        # account's current username as if it were the recorded identity.
        if entry.actor_id is None:
            return "System"
        username = entry.actor.get_username()
        return username if entry.actor_label_snapshot == username else f"Account #{entry.actor_id}"

    def get_action(self, entry):
        return entry.action if entry.action in ACTION_LABELS else "other"

    def get_action_label(self, entry):
        return audit_action_label(entry.action) if entry.action in ACTION_LABELS else "Other recorded action"

    def get_entity_type(self, entry):
        return entry.entity_type if entry.entity_type in ENTITY_LABELS else "other"

    def get_entity_label(self, entry):
        return audit_entity_label(entry.entity_type) if entry.entity_type in ENTITY_LABELS else "Record"

    def get_entity_id(self, entry):
        value = str(entry.entity_id)
        return value if value.isascii() and value.isdecimal() and len(value) <= 20 else ""

    def get_record_summary(self, entry):
        identifier = self.get_entity_id(entry)
        label = self.get_entity_label(entry)
        return f"{label} #{identifier}" if identifier else label

    @staticmethod
    def safe_entry(entry):
        return SimpleNamespace(action=entry.action, before_data=safe_snapshot(entry.before_data),
                               after_data=safe_snapshot(entry.after_data))

    def get_changes(self, entry):
        return [{"field": row["field"], "field_label": audit_field_label(row["field"]),
                 "before_display": audit_display_value(row["before"], row["field"]),
                 "after_display": audit_display_value(row["after"], row["field"]),
                 "captured": row["captured"]}
                for row in audit_changes(self.safe_entry(entry))]

    def get_detail_kind(self, entry):
        return audit_detail_kind(self.safe_entry(entry))

    def get_snapshot_notice(self, entry):
        notice = audit_snapshot_notice(self.safe_entry(entry))
        policy = "Only approved summary fields are shown; raw data and free-text reasons are omitted."
        return f"{notice} {policy}" if notice else policy
