from django.conf import settings
from django.db import migrations


GROUP_PERMISSIONS = {
    "Administrator": {"view", "add", "change"},
    "Training Coordinator": {"view", "add", "change"},
    "Manager": {"view"},
    "Trainer": {"view"},
    "Supervisor": {"view"},
    "Employee": {"view"},
}
MODELS = ("department", "jobrole", "employee")


def create_roles(apps, schema_editor):
    ContentTypeModel = apps.get_model("contenttypes", "ContentType")
    PermissionModel = apps.get_model("auth", "Permission")
    GroupModel = apps.get_model("auth", "Group")
    organization_cts = {
        model: ContentTypeModel.objects.get_or_create(app_label="organization", model=model)[0]
        for model in MODELS
    }
    for group_name, actions in GROUP_PERMISSIONS.items():
        group, _ = GroupModel.objects.get_or_create(name=group_name)
        permissions = []
        for model, content_type in organization_cts.items():
            for action in actions:
                codename = f"{action}_{model}"
                permission, _ = PermissionModel.objects.get_or_create(
                    content_type=content_type,
                    codename=codename,
                    defaults={"name": f"Can {action} {model}"},
                )
                permissions.append(permission)
        group.permissions.add(*permissions)


class Migration(migrations.Migration):
    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ("organization", "0001_initial"),
    ]

    operations = [migrations.RunPython(create_roles, migrations.RunPython.noop)]
