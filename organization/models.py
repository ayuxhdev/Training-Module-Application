from django.conf import settings
from django.contrib.auth import get_user_model
from django.db import models, transaction
from django.db.models import Q
from django.utils import timezone

from config.model_utils import TimestampedModel, protect_delete, require


class Department(TimestampedModel):
    code = models.CharField(max_length=30, unique=True)
    name = models.CharField(max_length=120, db_index=True)
    description = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)

    def __str__(self):
        return self.name

    def delete(self, *args, **kwargs):
        protect_delete("Deactivate departments instead of deleting them.")


class JobRole(TimestampedModel):
    code = models.CharField(max_length=30, unique=True)
    name = models.CharField(max_length=120)
    description = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)

    def __str__(self):
        return self.name

    def delete(self, *args, **kwargs):
        protect_delete("Deactivate job roles instead of deleting them.")


class Employee(TimestampedModel):
    employee_code = models.CharField(max_length=30, unique=True)
    display_name = models.CharField(max_length=150)
    user = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.PROTECT,
                               null=True, blank=True, related_name="employee")
    department = models.ForeignKey(Department, on_delete=models.PROTECT, related_name="employees")
    job_role = models.ForeignKey(JobRole, on_delete=models.PROTECT, related_name="employees")
    reporting_manager = models.ForeignKey("self", on_delete=models.PROTECT, null=True,
                                          blank=True, related_name="direct_reports")
    date_joined = models.DateField()
    is_active = models.BooleanField(default=True)
    deactivated_at = models.DateTimeField(null=True, blank=True)
    deactivation_reason = models.TextField(blank=True)

    class Meta:
        constraints = [
            # MySQL CHECK expressions cannot reference the auto-increment PK.
            # Self-reporting and longer cycles are validated in clean().
            models.CheckConstraint(condition=(Q(is_active=True, deactivated_at__isnull=True) |
                                              Q(is_active=False, deactivated_at__isnull=False)),
                                   name="employee_active_dates"),
        ]
        indexes = [models.Index(fields=["department", "is_active"], name="employee_dept_active_idx"),
                   models.Index(fields=["job_role", "is_active"], name="employee_role_active_idx")]

    def clean(self):
        super().clean()
        old = self.original()
        self.require_unchanged(old, ["employee_code"])
        if old and old.user_id:
            self.require_unchanged(old, ["user_id"])
        visited = {self.pk} if self.pk else set()
        manager_id = self.reporting_manager_id
        while manager_id:
            require(manager_id not in visited, "Reporting relationships cannot contain a cycle.")
            visited.add(manager_id)
            manager_id = Employee.objects.filter(pk=manager_id).values_list("reporting_manager_id", flat=True).first()
        require(self.is_active or bool(self.deactivation_reason.strip()), "Deactivation requires a reason.")

    def lock_parents(self, using):
        old = self.original()
        if self.reporting_manager_id and (not old or old.reporting_manager_id != self.reporting_manager_id):
            # Hierarchy edits are rare in this single-factory V1. Serialize them
            # to prevent two concurrent individually-valid edits forming a cycle.
            list(Employee.objects.using(using).order_by("pk").select_for_update().values_list("pk", flat=True))

    def save(self, *args, **kwargs):
        # An inactive employee must never retain an enabled linked login.
        with transaction.atomic(using=kwargs.get("using") or self._state.db):
            if not self.is_active and self.deactivated_at is None:
                self.deactivated_at = timezone.now()
            result = super().save(*args, **kwargs)
            if not self.is_active and self.user_id:
                get_user_model().objects.using(self._state.db).filter(pk=self.user_id).update(is_active=False)
            return result

    def delete(self, *args, **kwargs):
        protect_delete("Deactivate employees instead of deleting their history.")

    def __str__(self):
        return f"{self.employee_code} - {self.display_name}"
