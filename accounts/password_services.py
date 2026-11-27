"""Self-service password changes, shared by website and mobile authentication."""

from django.contrib.auth import get_user_model
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import transaction
from django.utils import timezone
from django.utils.crypto import constant_time_compare
from django.views.decorators.debug import sensitive_variables
from rest_framework.throttling import UserRateThrottle
from rest_framework_simplejwt.token_blacklist.models import BlacklistedToken, OutstandingToken

from api.capabilities import can_use_mobile
from audit.services import record_event
from organization.models import Employee

from .password_forms import OwnPasswordChangeForm


class PasswordChangeThrottle(UserRateThrottle):
    # Same authenticated-user bucket for website and API attempts. As with login
    # throttling, multi-process deployments require a shared Django cache.
    scope = "password_change"
    rate = "5/min"


def eligible_password_account(user):
    return user.is_authenticated and user.is_active and not Employee.objects.filter(
        user_id=user.pk, is_active=False,
    ).exists()


@sensitive_variables()
def change_own_password(actor, data, *, mobile=False):
    with transaction.atomic():
        # User before OutstandingToken matches refresh rotation. Employee
        # deactivation updates this User in its transaction, so this lock also
        # serializes the account-disable commit without a reverse Employee lock.
        user = get_user_model().objects.select_for_update().get(pk=actor.pk)
        if not eligible_password_account(user) or (mobile and not can_use_mobile(user)):
            raise PermissionDenied("This account cannot change its password.")
        if not constant_time_compare(actor.password, user.password):
            raise ValidationError({"old_password": ["Your credentials changed. Sign in again to continue."]})
        form = OwnPasswordChangeForm(user, data=data)
        if not form.is_valid():
            raise ValidationError(form.errors.as_data())
        user = form.save()
        tokens = OutstandingToken.objects.select_for_update().filter(
            user_id=user.pk, expires_at__gt=timezone.now(),
        ).order_by("pk")
        for token in tokens:
            BlacklistedToken.objects.get_or_create(token=token)
        # Never snapshot the User: password hashes and submitted values must not
        # enter audit data. The existing audit service emits only after commit.
        record_event(user, "auth.password.changed", user)
        return user
