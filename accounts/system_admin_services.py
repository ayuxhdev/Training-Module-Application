"""Transaction boundaries for the Superuser Center; no credential provisioning."""

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import IntegrityError, transaction

from audit.services import record_event
from organization.models import Employee

from .system_admin_forms import BUSINESS_GROUP_NAMES


def ensure_editable_target(actor, target):
    # Stage 2 cannot change the current account or any existing Superuser.
    if target.pk == actor.pk or target.is_superuser:
        raise PermissionDenied


def _lock_users(actor, target_id=None):
    ids = {actor.pk}
    if target_id is not None:
        ids.add(target_id)
    users = {
        user.pk: user
        for user in get_user_model().objects.select_for_update().only(
            "id", "username", "is_active", "is_staff", "is_superuser",
        ).filter(pk__in=ids).order_by("pk")
    }
    current_actor = users.get(actor.pk)
    if current_actor is None or not current_actor.is_active or not current_actor.is_superuser:
        raise PermissionDenied
    target = users.get(target_id)
    if target_id is not None:
        if target is None:
            raise ValidationError("This account is no longer available. Reload the directory.")
        ensure_editable_target(current_actor, target)
    return current_actor, target


def _lock_employee(employee_id):
    employee = Employee.objects.select_for_update().filter(pk=employee_id).first()
    if employee is None:
        raise ValidationError({"employee": "This Employee is no longer available."})
    return employee


def _approved_group_ids(groups):
    requested = {group.pk for group in groups}
    # Recheck inside the transaction; never accept arbitrary Group IDs.
    selected = set(
        Group.objects.select_for_update().filter(
            pk__in=requested, name__in=BUSINESS_GROUP_NAMES,
        ).order_by("pk").values_list("pk", flat=True)
    )
    if selected != requested:
        raise ValidationError({"groups": "A selected business Group is no longer available. Reload the form."})
    return selected


def _group_snapshot(user):
    # Business audit readers need the memberships this operation controls,
    # not unrelated technical Group membership information.
    return {
        "groups": list(user.groups.filter(name__in=BUSINESS_GROUP_NAMES).order_by("pk").values("id", "name")),
    }


def _link_employee(actor, target, employee):
    if employee.user_id is not None:
        raise ValidationError({"employee": "This Employee already has an account link. Existing links cannot be replaced."})
    if Employee.objects.filter(user_id=target.pk).exists():
        raise ValidationError({"employee": "This account is already linked to an Employee. Existing links cannot be replaced."})
    if not employee.is_active and target.is_active:
        raise ValidationError({"employee": "An inactive Employee cannot be linked to an active account here."})
    employee.user = target
    # Use normal validated model behavior, from a fresh locked Employee.
    employee.save()
    record_event(
        actor, "accounts.user.employee_linked", target,
        before={"employee_id": None}, after={"employee_id": employee.pk},
    )


def _duplicate(error):
    return bool(error.args) and error.args[0] == 1062


def create_system_user(actor, cleaned):
    try:
        with transaction.atomic():
            employee = _lock_employee(cleaned["employee"].pk) if cleaned.get("employee") else None
            current_actor, _ = _lock_users(actor)
            groups = _approved_group_ids(cleaned["groups"])
            user = get_user_model()(
                **{name: cleaned[name] for name in ("username", "first_name", "last_name", "email")},
                is_active=False, is_staff=False, is_superuser=False,
            )
            user.set_unusable_password()
            user.full_clean()
            user.save(force_insert=True)
            user.groups.add(*groups)
            if employee is not None:
                _link_employee(current_actor, user, employee)
            record_event(
                current_actor, "accounts.user.created", user,
                after={
                    "username": user.username, "is_active": False,
                    "is_staff": False, "is_superuser": False,
                    "group_ids": sorted(groups),
                    "employee_id": employee.pk if employee else None,
                },
            )
            return user
    except IntegrityError as error:
        if _duplicate(error) and get_user_model().objects.filter(username=cleaned["username"]).exists():
            raise ValidationError({"username": "A user with that username already exists."}) from error
        raise


def update_system_user_groups(actor, target_id, groups):
    with transaction.atomic():
        current_actor, target = _lock_users(actor, target_id)
        selected = _approved_group_ids(groups)
        before = _group_snapshot(target)
        current = set(target.groups.filter(name__in=BUSINESS_GROUP_NAMES).values_list("pk", flat=True))
        if current == selected:
            return False
        target.groups.remove(*(current - selected))
        target.groups.add(*(selected - current))
        record_event(
            current_actor, "accounts.user.groups_changed", target,
            before=before, after=_group_snapshot(target),
        )
        return True


def link_system_user_employee(actor, target_id, employee_id):
    try:
        with transaction.atomic():
            # Match the existing Employee -> User order; never hold a User lock
            # while waiting for an Employee lock.
            employee = _lock_employee(employee_id)
            current_actor, target = _lock_users(actor, target_id)
            _link_employee(current_actor, target, employee)
    except IntegrityError as error:
        if _duplicate(error) and Employee.objects.filter(user_id=target_id).exists():
            raise ValidationError({"employee": "This account is already linked to an Employee. Reload the account."}) from error
        raise
