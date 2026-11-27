from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone

from accounts.models import LoginAttemptBucket


class Command(BaseCommand):
    help = "Delete one bounded batch of expired login admission buckets."

    def add_arguments(self, parser):
        parser.add_argument("--limit", type=int, default=200)

    def handle(self, *args, limit, **options):
        if not 1 <= limit <= 500:
            raise CommandError("--limit must be between 1 and 500.")
        expired = LoginAttemptBucket.objects.filter(expires_at__lte=timezone.now())
        keys = list(expired.order_by("expires_at", "pk").values_list("pk", flat=True)[:limit])
        # Recheck expiry in each DELETE. Keep transactions independent so pruning
        # cannot acquire multiple bucket locks in a different order than admission.
        deleted = sum(expired.filter(pk=key).delete()[0] for key in keys)
        self.stdout.write(f"Expired login admission buckets removed: {deleted}")
