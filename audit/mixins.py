from django.core.exceptions import ValidationError
from django.db import IntegrityError, transaction

from .services import audit_snapshot, record_event


class AuditedFormMixin:
	def form_valid(self, form):
		try:
			with transaction.atomic():
				creating = self.object is None
				before = audit_snapshot(type(self.object).objects.get(pk=self.object.pk)) if not creating else {}
				changed_fields = list(form.changed_data)
				response = super().form_valid(form)
				if creating or changed_fields:
					model_label = self.object._meta.label_lower
					verb = "created" if creating else "updated"
					record_event(
						self.request.user,
						f"{model_label}.{verb}",
						self.object,
						before=before,
						after={**audit_snapshot(self.object), "changed_fields": changed_fields},
					)
				return response
		except ValidationError as exc:
			if hasattr(exc, "error_dict"):
				for field, errors in exc.error_dict.items():
					form.add_error(field if field in form.fields else None, errors)
			else:
				form.add_error(None, exc)
			return self.form_invalid(form)
		except IntegrityError:
			form.add_error(None, "This record conflicts with an existing record.")
			return self.form_invalid(form)
