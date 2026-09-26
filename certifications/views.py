from django.contrib.auth.decorators import login_required
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import transaction
from django.http import HttpResponseBadRequest, HttpResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.utils import timezone
from django.views.decorators.http import require_POST

from audit.services import record_event
from organization.models import Employee

from .models import Certificate


VIEW_CERTIFICATES_PERMISSION = "certifications.view_certificate"
CHANGE_CERTIFICATES_PERMISSION = "certifications.change_certificate"
MAX_REVOCATION_REASON_LENGTH = 1000


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
	return render(request, "certifications/certificate_list.html", {
		"certificates": certificates,
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
		certificate = get_object_or_404(Certificate.objects.select_related("assignment"), pk=pk)
		if certificate.revoked_at:
			return HttpResponse("This certificate is already revoked.", status=409)
		before = {"revoked_at": None}
		certificate.revoked_at = timezone.now()
		certificate.revoked_by = request.user
		certificate.revocation_reason = reason
		try:
			certificate.save()
		except ValidationError as exc:
			return HttpResponseBadRequest(str(exc))
		record_event(
			request.user,
			"certifications.certificate.revoked",
			certificate,
			before=before,
			after={"revoked_at": certificate.revoked_at.isoformat(), "revoked_by_id": request.user.pk},
			reason=reason,
		)
	return redirect("certifications:certificate-detail", pk=certificate.pk)
