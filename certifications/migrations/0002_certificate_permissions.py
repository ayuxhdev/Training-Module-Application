from django.conf import settings
from django.db import migrations


def grant_certificate_permissions(apps, schema_editor):
    ContentType = apps.get_model("contenttypes", "ContentType")
    Permission = apps.get_model("auth", "Permission")
    Group = apps.get_model("auth", "Group")
    content_type, _ = ContentType.objects.get_or_create(app_label="certifications", model="certificate")
    groups = [Group.objects.get_or_create(name=name)[0] for name in ("Administrator", "Training Coordinator")]
    for action in ("view", "change"):
        permission, _ = Permission.objects.get_or_create(
            content_type=content_type,
            codename=f"{action}_certificate",
            defaults={"name": f"Can {action} certificate"},
        )
        for group in groups:
            group.permissions.add(permission)


class Migration(migrations.Migration):
    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ("accounts", "0004_assessment_permissions"),
        ("certifications", "0001_initial"),
    ]

    operations = [migrations.RunPython(grant_certificate_permissions, migrations.RunPython.noop)]