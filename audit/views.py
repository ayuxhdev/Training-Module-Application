from django.contrib.auth.decorators import login_required
from django.contrib.auth import get_user_model
from django.core.exceptions import PermissionDenied
from django.shortcuts import render

from .forms import AuditLogFilterForm
from .models import AuditLog


@login_required
def audit_log_list(request):
	if not request.user.has_perm("audit.view_auditlog"):
		raise PermissionDenied

	actors = AuditLog.objects.exclude(actor=None).values_list("actor_id", flat=True).distinct()
	form = AuditLogFilterForm(request.GET, actors=get_user_model().objects.filter(pk__in=actors))
	logs = AuditLog.objects.select_related("actor")
	valid = form.is_valid()
	if valid:
		filters = form.cleaned_data
		if filters["actor"]:
			logs = logs.filter(actor=filters["actor"])
		if filters["action"]:
			logs = logs.filter(action__icontains=filters["action"])
		if filters["start_date"]:
			logs = logs.filter(occurred_at__date__gte=filters["start_date"])
		if filters["end_date"]:
			logs = logs.filter(occurred_at__date__lte=filters["end_date"])
		if filters["target_type"]:
			logs = logs.filter(entity_type__iexact=filters["target_type"].strip())
	else:
		logs = logs.none()
	return render(request, "audit/audit_log_list.html", {
		"filter_form": form,
		"audit_logs": logs.order_by("-occurred_at", "-pk")[:200],
	}, status=200 if valid else 400)
