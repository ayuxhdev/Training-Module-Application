from django.db import migrations


def grant_team_assignment_permission(apps, schema_editor):
    alias = schema_editor.connection.alias
    ContentType = apps.get_model("contenttypes", "ContentType")
    Permission = apps.get_model("auth", "Permission")
    Group = apps.get_model("auth", "Group")
    content_type, _ = ContentType.objects.using(alias).get_or_create(
        app_label="training", model="trainingassignment",
    )
    permission, _ = Permission.objects.using(alias).get_or_create(
        content_type=content_type,
        codename="assign_team_trainingassignment",
        defaults={"name": "Can assign training to reporting hierarchy"},
    )
    manager, _ = Group.objects.using(alias).get_or_create(name="Manager")
    manager.permissions.add(permission)


class Migration(migrations.Migration):
    dependencies = [
        ("accounts", "0004_assessment_permissions"),
        ("training", "0002_trainingassignment_team_permission"),
    ]

    operations = [
        migrations.RunPython(grant_team_assignment_permission, migrations.RunPython.noop),
    ]
