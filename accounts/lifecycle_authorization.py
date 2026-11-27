"""Hold the authority for a lifecycle transition until its transaction ends."""

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import PermissionDenied
from django.db import connections
from django.db.transaction import TransactionManagementError


def _share_locked_first(queryset):
    # MySQL 8 shared locks conflict with revocation writes while remaining
    # compatible with FK checks on audit actors and concurrent readers.
    using = queryset.db
    sql, params = queryset.order_by("pk")[:1].query.get_compiler(using).as_sql()
    rows = queryset.model._default_manager.raw(sql + " FOR SHARE", params, using=using)
    return next(iter(rows), None)


def require_lifecycle_permission(actor, permission, *, using):
    connection = connections[using]
    if not connection.in_atomic_block or connection.vendor != "mysql":
        raise TransactionManagementError("Lifecycle authorization requires an active MySQL transaction.")

    user_model = get_user_model()
    current = _share_locked_first(user_model.objects.using(using).filter(pk=actor.pk))
    if current is None or not current.is_active or not current.has_perm(permission):
        raise PermissionDenied
    if current.is_superuser:
        return current

    app_label, codename = permission.split(".", 1)
    permission_ids = list(Permission.objects.using(using).filter(
        content_type__app_label=app_label, codename=codename,
    ).values_list("pk", flat=True))
    if not permission_ids:
        raise PermissionDenied
    direct = user_model.user_permissions.through.objects.using(using)
    if _share_locked_first(direct.filter(user_id=current.pk, permission_id__in=permission_ids)):
        return current

    memberships = user_model.groups.through.objects.using(using)
    grants = Group.permissions.through.objects.using(using)
    # Candidate discovery can race. A candidate authorizes only if both through
    # rows still exist when locked. Group is locked first, as in admin writes.
    group_grants = list(grants.filter(
        group_id__in=memberships.filter(user_id=current.pk).values("group_id"),
        permission_id__in=permission_ids,
    ).order_by("group_id", "pk").values_list("group_id", "pk"))
    for group_id, grant_id in group_grants:
        if (
            _share_locked_first(Group.objects.using(using).filter(pk=group_id))
            and _share_locked_first(grants.filter(pk=grant_id, group_id=group_id, permission_id__in=permission_ids))
            and _share_locked_first(memberships.filter(user_id=current.pk, group_id=group_id))
        ):
            return current
    raise PermissionDenied
