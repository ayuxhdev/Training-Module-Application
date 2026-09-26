from django.conf import settings
from django.db import migrations


ASSESSMENT_MODELS = (
    "question",
    "questionrevision",
    "questionoption",
    "assessment",
    "assessmentquestion",
)
MANAGER_GROUPS = ("Administrator", "Training Coordinator")


def grant_assessment_permissions(apps, schema_editor):
    ContentType = apps.get_model("contenttypes", "ContentType")
    Permission = apps.get_model("auth", "Permission")
    Group = apps.get_model("auth", "Group")
    groups = [Group.objects.get_or_create(name=name)[0] for name in MANAGER_GROUPS]
    for model in ASSESSMENT_MODELS:
        content_type, _ = ContentType.objects.get_or_create(app_label="assessments", model=model)
        for action in ("view", "add", "change"):
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
        ("accounts", "0003_assignment_permissions"),
        ("assessments", "0001_initial"),
    ]

    operations = [migrations.RunPython(grant_assessment_permissions, migrations.RunPython.noop)]
