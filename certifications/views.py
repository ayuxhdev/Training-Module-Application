from django.contrib.auth.decorators import login_required
from django.contrib.auth import get_user_model
from django.core.exceptions import PermissionDenied, ValidationError
from django.core.paginator import Paginator
from django.db import transaction
from django.http import HttpResponseBadRequest, HttpResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.utils import timezone
from django.views.decorators.http import require_POST

from audit.models import AuditLog
from organization.models import Employee
from training.models import TrainingAssignment

from .models import Certificate


VIEW_CERTIFICATES_PERMISSION = "certifications.view_certificate"
CHANGE_CERTIFICATES_PERMISSION = "certifications.change_certificate"
MAX_REVOCATION_REASON_LENGTH = 1000
CERTIFICATE_LIST_PAGE_SIZE = 50


def _has_certificate_permission(user, permission):
	return user.is_superuser or user.has_perm(permission)


def _certificate_queryset(user):
	certificates = Certificate.objects.select_related("assignment__employee", "training_version")
	if _has_certificate_permission(user, VIEW_CERTIFICATES_PERMISSION):
		return certificates
	employee = get_object_or_404(Employee, user=user, is_active=True)
	return certificates.filter(assignment__employee=employee)


@login_required
def certificate_list(request):
	certificates = _certificate_queryset(request.user).order_by("-issued_at", "pk")
	paginator = Paginator(certificates, CERTIFICATE_LIST_PAGE_SIZE)
	page_obj = paginator.get_page(request.GET.get("page"))
	page_query = request.GET.copy()
	page_query.pop("page", None)
	return render(request, "certifications/certificate_list.html", {
		"certificates": page_obj.object_list,
		"page_obj": page_obj,
		"paginator": paginator,
		"page_query": page_query.urlencode(),
		"can_revoke": _has_certificate_permission(request.user, CHANGE_CERTIFICATES_PERMISSION),
	})


@login_required
def certificate_detail(request, pk):
	certificate = get_object_or_404(_certificate_queryset(request.user), pk=pk)
	return render(request, "certifications/certificate_detail.html", {
		"certificate": certificate,
		"can_revoke": _has_certificate_permission(request.user, CHANGE_CERTIFICATES_PERMISSION),
	})


@login_required
@require_POST
def revoke_certificate(request, pk):
	if not _has_certificate_permission(request.user, CHANGE_CERTIFICATES_PERMISSION):
		raise PermissionDenied
	reason = request.POST.get("reason", "").strip()
	if not reason:
		return HttpResponseBadRequest("A revocation reason is required.")
	if len(reason) > MAX_REVOCATION_REASON_LENGTH:
		return HttpResponseBadRequest("The revocation reason is too long.")

	with transaction.atomic():
		reference = get_object_or_404(Certificate.objects.only("assignment_id"), pk=pk)
		# Match issuance, the API and Certificate.save(): Assignment before Certificate.
		get_object_or_404(TrainingAssignment.objects.select_for_update(), pk=reference.assignment_id)
		certificate = get_object_or_404(Certificate.objects.select_for_update(), pk=pk)
		# Permissions/account status may have changed while waiting. Do not reuse
		# request.user's permission cache or impose mobile-only eligibility on the web.
		actor = get_user_model().objects.filter(pk=request.user.pk, is_active=True).first()
		if actor is None or not _has_certificate_permission(actor, CHANGE_CERTIFICATES_PERMISSION):
			raise PermissionDenied
		if certificate.revoked_at:
			return HttpResponse("This certificate is already revoked.", status=409)
		before = {"revoked_at": None}
		certificate.revoked_at = timezone.now()
		certificate.revoked_by = actor
		certificate.revocation_reason = reason
		try:
			certificate.save()
		except ValidationError as exc:
			return HttpResponseBadRequest(str(exc))
		# Required evidence belongs to this transaction. The shared audit helper
		# writes after commit and cannot roll back revocation on audit failure.
		AuditLog.objects.create(
			actor=actor,
			actor_label_snapshot=actor.get_username()[:150],
			action="certifications.certificate.revoked",
			entity_type=certificate._meta.label_lower,
			entity_id=str(certificate.pk),
			before_data=before,
			after_data={"revoked_at": certificate.revoked_at.isoformat(), "revoked_by_id": actor.pk},
			reason=reason,
		)
	return redirect("certifications:certificate-detail", pk=certificate.pk)
