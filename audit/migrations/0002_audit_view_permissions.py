from django.conf import settings
from django.db import migrations


def grant_audit_view_permission(apps, schema_editor):
	ContentType = apps.get_model("contenttypes", "ContentType")
	Permission = apps.get_model("auth", "Permission")
	Group = apps.get_model("auth", "Group")
	content_type, _ = ContentType.objects.get_or_create(app_label="audit", model="auditlog")
	permission, _ = Permission.objects.get_or_create(
		content_type=content_type,
		codename="view_auditlog",
		defaults={"name": "Can view audit log"},
	)
	for name in ("Administrator", "Training Coordinator"):
		Group.objects.get_or_create(name=name)[0].permissions.add(permission)


class Migration(migrations.Migration):
	dependencies = [
		migrations.swappable_dependency(settings.AUTH_USER_MODEL),
		("accounts", "0004_assessment_permissions"),
		("audit", "0001_initial"),
	]

	operations = [migrations.RunPython(grant_audit_view_permission, migrations.RunPython.noop)]