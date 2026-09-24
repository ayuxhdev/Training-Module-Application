from django.conf import settings
from django.db import models
from django.utils import timezone

from config.model_utils import ValidatedModel, protect_delete, require


class AuditLog(ValidatedModel):
    occurred_at = models.DateTimeField(default=timezone.now)
    actor = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, null=True, blank=True, related_name="audit_logs")
    actor_label_snapshot = models.CharField(max_length=150)
    action = models.CharField(max_length=80)
    entity_type = models.CharField(max_length=100, help_text="Django app_label.model_name")
    entity_id = models.CharField(max_length=64)
    before_data = models.JSONField(default=dict, blank=True)
    after_data = models.JSONField(default=dict, blank=True)
    reason = models.TextField(blank=True)
    request_id = models.UUIDField(null=True, blank=True)

    class Meta:
        indexes = [models.Index(fields=["entity_type", "entity_id", "occurred_at"], name="audit_entity_time_idx"),
                   models.Index(fields=["actor", "occurred_at"], name="audit_actor_time_idx"),
                   models.Index(fields=["action", "occurred_at"], name="audit_action_time_idx")]

    def clean(self):
        super().clean()
        require(self._state.adding, "Audit logs are append-only.")
        require(isinstance(self.before_data, dict) and isinstance(self.after_data, dict), "Audit snapshots must be JSON objects.")

    def delete(self, *args, **kwargs):
        protect_delete("Audit logs are append-only.")
