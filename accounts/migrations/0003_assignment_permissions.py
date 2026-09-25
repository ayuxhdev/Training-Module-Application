from django.conf import settings
from django.db import migrations


def grant_assignment_permissions(apps, schema_editor):
    ContentType = apps.get_model("contenttypes", "ContentType")
    Permission = apps.get_model("auth", "Permission")
    Group = apps.get_model("auth", "Group")
    content_type = ContentType.objects.get_or_create(app_label="training", model="trainingassignment")[0]
    for action in ("view", "add", "change"):
        permission, _ = Permission.objects.get_or_create(
            content_type=content_type,
            codename=f"{action}_trainingassignment",
            defaults={"name": f"Can {action} training assignment"},
        )
        for group_name in ("Administrator", "Training Coordinator"):
            Group.objects.get_or_create(name=group_name)[0].permissions.add(permission)


class Migration(migrations.Migration):
    dependencies = [("accounts", "0002_training_content_permissions")]
    operations = [migrations.RunPython(grant_assignment_permissions, migrations.RunPython.noop)]