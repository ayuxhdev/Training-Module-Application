from django.conf import settings
from django.db import migrations


CONTENT_MODELS = ("training", "trainingversion", "module", "lesson")
CONTENT_ACTIONS = ("view", "add", "change")
MANAGER_GROUPS = ("Administrator", "Training Coordinator")


def grant_content_permissions(apps, schema_editor):
    ContentType = apps.get_model("contenttypes", "ContentType")
    Permission = apps.get_model("auth", "Permission")
    Group = apps.get_model("auth", "Group")
    groups = [Group.objects.get_or_create(name=name)[0] for name in MANAGER_GROUPS]
    for model in CONTENT_MODELS:
        content_type, _ = ContentType.objects.get_or_create(app_label="training", model=model)
        for action in CONTENT_ACTIONS:
            permission, _ = Permission.objects.get_or_create(
                content_type=content_type,
                codename=f"{action}_{model}",
                defaults={"name": f"Can {action} {model}"},
            )
            for group in groups:
                group.permissions.add(permission)


class Migration(migrations.Migration):
    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ("accounts", "0001_application_roles"),
        ("training", "0001_initial"),
    ]

    operations = [migrations.RunPython(grant_content_permissions, migrations.RunPython.noop)]
