"""Shared validation and history safeguards; no concrete database tables."""

from django.core.exceptions import ValidationError
from django.db import models, router, transaction


class ValidatedQuerySet(models.QuerySet):
    def update(self, **kwargs):
        raise ValidationError("Use individual save() calls so history rules are validated.")

    def bulk_create(self, objs, **kwargs):
        raise ValidationError("Use individual save() calls so relationships are validated.")

    def bulk_update(self, objs, fields, **kwargs):
        raise ValidationError("Use individual save() calls so history rules are validated.")

    def delete(self):
        count, details = 0, {}
        with transaction.atomic(using=self.db):
            for obj in self:
                deleted, labels = obj.delete(using=self.db)
                count += deleted
                for label, value in labels.items():
                    details[label] = details.get(label, 0) + value
        return count, details


class ValidatedModel(models.Model):
    objects = ValidatedQuerySet.as_manager()

    class Meta:
        abstract = True

    def original(self):
        if self._state.adding:
            return None
        return type(self).objects.using(self._state.db).get(pk=self.pk)

    def require_unchanged(self, old, fields):
        if old and any(getattr(old, field) != getattr(self, field) for field in fields):
            raise ValidationError("Historical fields cannot be changed: " + ", ".join(fields))

    def require_frozen(self, old, except_fields=()):
        fields = [field.attname for field in self._meta.concrete_fields
                  if field.name not in {"updated_at", *except_fields}]
        self.require_unchanged(old, fields)

    def lock_parents(self, using):
        """Subclasses lock shared aggregate roots before validating a write."""

    def validate_delete(self):
        """Subclasses may permit deletion only while a record is a draft."""

    def delete(self, *args, **kwargs):
        using = kwargs.get("using") or router.db_for_write(type(self), instance=self)
        with transaction.atomic(using=using):
            self.lock_parents(using)
            type(self).objects.using(using).select_for_update().get(pk=self.pk)
            self.validate_delete()
            return super().delete(*args, **kwargs)

    def save(self, *args, **kwargs):
        using = kwargs.get("using") or router.db_for_write(type(self), instance=self)
        with transaction.atomic(using=using):
            self.lock_parents(using)
            if not self._state.adding:
                type(self).objects.using(using).select_for_update().get(pk=self.pk)
            else:
                # A freshly constructed instance with an existing PK must never
                # overwrite history by exploiting Django's update-then-insert path.
                kwargs["force_insert"] = True
            self.full_clean()
            # Persist the entire validated state; partial writes can break invariants.
            kwargs.pop("update_fields", None)
            return super().save(*args, **kwargs)


class TimestampedModel(ValidatedModel):
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def protect_delete(message):
    raise ValidationError(message)
