"""API adapter for the website's permission-based certificate revocation contract."""

from django.contrib.auth import get_user_model
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import transaction
from django.shortcuts import get_object_or_404
from django.utils import timezone

from api.capabilities import can_use_mobile
from audit.models import AuditLog
from certifications.models import Certificate
from training.models import TrainingAssignment


VIEW_PERMISSION = "certifications.view_certificate"
CHANGE_PERMISSION = "certifications.change_certificate"
MAX_REASON_LENGTH = 1000


class CertificateAlreadyRevoked(Exception):
    pass


def revocation_reason(value):
    if not isinstance(value, str) or not value.strip():
        raise ValidationError({"reason": ["A revocation reason is required."]})
    value = value.strip()
    if len(value) > MAX_REASON_LENGTH:
        raise ValidationError({"reason": ["The revocation reason is too long."]})
    return value


def _revoker(actor):
    # A fresh instance avoids request permission caches, including after waiting
    # for the assignment lock. This grants no group or hierarchy-based authority.
    current = get_user_model().objects.filter(pk=getattr(actor, "pk", None)).first()
    if not can_use_mobile(current) or not current.has_perm(CHANGE_PERMISSION):
        raise PermissionDenied
    return current


@transaction.atomic
def revoke_certificate(actor, certificate_id, reason):
    actor = _revoker(actor)
    reason = revocation_reason(reason)
    reference = get_object_or_404(Certificate.objects.only("assignment_id"), pk=certificate_id)
    # Match Certificate.save()/issuance: assignment before certificate, and read
    # the current revocation state only after acquiring those locks.
    TrainingAssignment.objects.select_for_update().get(pk=reference.assignment_id)
    certificate = get_object_or_404(Certificate.objects.select_for_update(), pk=certificate_id)
    actor = _revoker(actor)
    if certificate.revoked_at is not None:
        raise CertificateAlreadyRevoked
    certificate.revoked_at = timezone.now()
    certificate.revoked_by = actor
    certificate.revocation_reason = reason
    certificate.save()
    # Revocation requires durable audit persistence in this same transaction.
    # The shared record_event() helper defers writes until after commit, so do
    # not use it here. Preserve its server-derived event fields and snapshots.
    AuditLog.objects.create(
        actor=actor, actor_label_snapshot=actor.get_username()[:150],
        action="certifications.certificate.revoked",
        entity_type=certificate._meta.label_lower, entity_id=str(certificate.pk),
        before_data={"revoked_at": None},
        after_data={"revoked_at": certificate.revoked_at.isoformat(), "revoked_by_id": actor.pk},
        reason=reason,
    )
    return certificate
