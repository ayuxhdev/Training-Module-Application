from django.db import models


class LoginAttemptBucket(models.Model):
    key = models.CharField(max_length=64, primary_key=True, editable=False)
    credit = models.PositiveBigIntegerField()
    refreshed_at = models.DateTimeField()
    expires_at = models.DateTimeField(db_index=True)
