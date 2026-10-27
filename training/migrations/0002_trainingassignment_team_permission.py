from django.db import migrations


class Migration(migrations.Migration):
    dependencies = [("training", "0001_initial")]

    operations = [
        migrations.AlterModelOptions(
            name="trainingassignment",
            options={
                "permissions": [
                    ("assign_team_trainingassignment", "Can assign training to reporting hierarchy"),
                ],
            },
        ),
    ]
