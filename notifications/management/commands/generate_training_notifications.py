from datetime import timedelta, timezone as datetime_timezone
from itertools import batched

from django.core.management.base import BaseCommand, CommandError
from django.db.models import Q
from django.utils import timezone
from django.utils.dateparse import parse_datetime

from notifications.services import create_deadline_notification
from notifications.models import Notification, notification_key
from reports.queries import OPEN_STATUSES, overdue_condition
from training.models import TrainingAssignment, TrainingVersion


class Command(BaseCommand):
    help = "Generate in-app deadline reminders once; requires a fixed rollout activation cutoff."

    def add_arguments(self, parser):
        parser.add_argument(
            "--activation-cutoff", required=True,
            help="Fixed timezone-aware ISO-8601 rollout timestamp; reuse the same value every invocation.",
        )

    def handle(self, *args, **options):
        try:
            cutoff = parse_datetime(options["activation_cutoff"])
        except ValueError:
            cutoff = None
        if cutoff is None or timezone.is_naive(cutoff):
            raise CommandError("--activation-cutoff requires an ISO-8601 timestamp with a timezone.")
        now = timezone.now()
        cutoff = cutoff.astimezone(datetime_timezone.utc)
        if cutoff > now:
            raise CommandError("--activation-cutoff cannot be in the future.")
        candidates = TrainingAssignment.objects.filter(
            employee__is_active=True,
            training_version__status__in=(TrainingVersion.Status.PUBLISHED, TrainingVersion.Status.RETIRED),
            due_at__gte=cutoff,
        ).filter(
            overdue_condition(now) | Q(
                status__in=OPEN_STATUSES, due_at__gt=now, due_at__lte=now + timedelta(hours=24),
            ),
        ).order_by("pk").only("pk", "due_at")
        created_count = 0
        for batch in batched(candidates.iterator(chunk_size=200), 200):
            overdue_keys = {
                assignment.pk: notification_key(assignment, Notification.EventType.OVERDUE)
                for assignment in batch if assignment.due_at < now
            }
            notified = set(Notification.objects.filter(
                deduplication_key__in=overdue_keys.values(),
            ).values_list("deduplication_key", flat=True))
            for assignment in batch:
                if overdue_keys.get(assignment.pk) in notified:
                    continue
                # The prefilter is advisory; the service rechecks eligibility under locks.
                _, created = create_deadline_notification(assignment.pk, activation_cutoff=cutoff)
                created_count += created
        self.stdout.write(self.style.SUCCESS(f"Created {created_count} deadline notifications."))
