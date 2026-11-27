from django.contrib import admin
from django.contrib.auth.admin import GroupAdmin, UserAdmin
from django.contrib.auth.models import Group, User
from django.db import router, transaction


class LockAuthorizationBeforeDelete:
    # Django admin saves the User or Group before writing its M2M grants.
    # Deletion's collector removes through rows first, so lock the parent
    # explicitly for both delete paths to use the same lock order.
    def delete_model(self, request, obj):
        using = router.db_for_write(self.model, instance=obj)
        with transaction.atomic(using=using):
            self.model._base_manager.using(using).select_for_update().get(pk=obj.pk)
            super().delete_model(request, obj)

    def delete_queryset(self, request, queryset):
        with transaction.atomic(using=queryset.db):
            list(queryset.order_by("pk").select_for_update().values_list("pk", flat=True))
            super().delete_queryset(request, queryset)


admin.site.unregister(User)
admin.site.unregister(Group)


@admin.register(User)
class LifecycleUserAdmin(LockAuthorizationBeforeDelete, UserAdmin):
    pass


@admin.register(Group)
class LifecycleGroupAdmin(LockAuthorizationBeforeDelete, GroupAdmin):
    pass
