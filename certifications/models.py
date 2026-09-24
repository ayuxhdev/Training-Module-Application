from django.conf import settings
from django.db import models
from django.db.models import F, Q
from django.utils import timezone

from config.model_utils import TimestampedModel, protect_delete, require


class Certificate(TimestampedModel):
    certificate_number = models.CharField(max_length=64, unique=True)
    assignment = models.OneToOneField("training.TrainingAssignment", on_delete=models.PROTECT, related_name="certificate")
    training_version = models.ForeignKey("training.TrainingVersion", on_delete=models.PROTECT, related_name="certificates")
    qualifying_final_attempt = models.OneToOneField("assessments.AssessmentAttempt", on_delete=models.PROTECT, related_name="certificate")
    issued_at = models.DateTimeField(default=timezone.now)
    employee_code_snapshot = models.CharField(max_length=30)
    employee_name_snapshot = models.CharField(max_length=150)
    training_title_snapshot = models.CharField(max_length=200)
    version_number_snapshot = models.PositiveIntegerField()
    document_file = models.FileField(upload_to="certificates/%Y/%m/", max_length=255, blank=True)
    issued_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, null=True, blank=True, related_name="issued_certificates")
    revoked_at = models.DateTimeField(null=True, blank=True)
    revocation_reason = models.TextField(blank=True)
    revoked_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, null=True, blank=True, related_name="revoked_certificates")

    class Meta:
        constraints = [
            models.CheckConstraint(condition=Q(version_number_snapshot__gte=1), name="certificate_version_positive"),
            models.CheckConstraint(condition=Q(revoked_at__isnull=True) | Q(revoked_at__gte=F("issued_at")), name="certificate_revocation_order"),
            models.CheckConstraint(condition=(Q(revoked_at__isnull=True, revoked_by__isnull=True, revocation_reason="") |
                                              (Q(revoked_at__isnull=False) & ~Q(revocation_reason=""))), name="certificate_revocation_fields"),
        ]
        indexes = [models.Index(fields=["training_version", "issued_at"], name="certificate_version_issued_idx")]

    def lock_parents(self, using):
        from training.models import TrainingAssignment
        TrainingAssignment.objects.using(using).select_for_update().get(pk=self.assignment_id)

    def clean(self):
        super().clean()
        old = self.original()
        if old:
            self.require_frozen(old, except_fields=["revoked_at", "revoked_by", "revocation_reason"])
            if old.revoked_at:
                self.require_frozen(old)
        else:
            from assessments.models import AssessmentAttempt
            from training.models import TrainingAssignment, TrainingVersion
            assignment = TrainingAssignment.objects.select_related("employee").get(pk=self.assignment_id)
            attempt = AssessmentAttempt.objects.select_related("assessment").get(pk=self.qualifying_final_attempt_id)
            version = TrainingVersion.objects.get(pk=self.training_version_id)
            require(assignment.status == "COMPLETED", "Only completed assignments can be certified.")
            require(assignment.training_version_id == self.training_version_id and attempt.assignment_id == self.assignment_id and
                    attempt.assessment.training_version_id == self.training_version_id,
                    "Certificate, assignment, and final attempt must reference the exact same training version.")
            require(attempt.status == "SUBMITTED" and attempt.passed and attempt.assessment.kind == "FINAL",
                    "A certificate requires a submitted, passing final-assessment attempt.")
            require(self.issued_at >= assignment.completed_at and self.issued_at >= attempt.submitted_at,
                    "Certificate issuance must follow completion and the qualifying attempt.")
            employee = assignment.employee
            require(self.employee_code_snapshot == employee.employee_code and self.employee_name_snapshot == employee.display_name and
                    self.training_title_snapshot == version.title and self.version_number_snapshot == version.version_number,
                    "Certificate snapshots must match the employee and training version at issuance.")
        if self.revoked_at:
            require(bool(self.revocation_reason.strip()), "Revocation requires a reason.")

    def delete(self, *args, **kwargs):
        protect_delete("Revoke certificates instead of deleting them.")
