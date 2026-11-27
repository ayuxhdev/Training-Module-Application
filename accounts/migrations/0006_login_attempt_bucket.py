from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("accounts", "0005_team_assignment_permission")]

    operations = [
        migrations.CreateModel(
            name="LoginAttemptBucket",
            fields=[
                ("key", models.CharField(editable=False, max_length=64, primary_key=True, serialize=False)),
                ("credit", models.PositiveBigIntegerField()),
                ("refreshed_at", models.DateTimeField()),
                ("expires_at", models.DateTimeField(db_index=True)),
            ],
        ),
    ]
