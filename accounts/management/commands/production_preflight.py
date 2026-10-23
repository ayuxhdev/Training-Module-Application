"""Read-only release gates. No migrations, collectstatic or business mutations."""

from pathlib import Path
import shutil

from django.conf import settings
from django.contrib.staticfiles.storage import staticfiles_storage
from django.core.checks import WARNING, run_checks
from django.core.management.base import BaseCommand, CommandError
from django.db import DatabaseError, connection
from django.db.migrations.loader import MigrationLoader
from django.db.migrations.exceptions import InconsistentMigrationHistory
from django.utils import timezone
from django.utils.dateparse import parse_datetime


ASSETS = (
    "accounts/shell.css", "accounts/shell.js", "accounts/appearance.js",
    "training/playback.js", "training/video_player_ui.js", "training/video_player.css",
)


class Command(BaseCommand):
    help = "Read-only production configuration, static/media and optional database/reminder gates."
    requires_system_checks = []

    def add_arguments(self, parser):
        parser.add_argument("--database", action="store_true", help="Check MySQL connectivity, schema and transactional tables.")
        parser.add_argument("--require-reminders", action="store_true", help="Require a valid persisted notification activation cutoff.")
        parser.add_argument("--acknowledge-staged-hsts", action="store_true", help="Explicitly acknowledge only HSTS subdomain/preload rollout warnings.")

    def handle(self, *args, **options):
        if not getattr(settings, "PRODUCTION_PROFILE", False) or settings.DEBUG:
            raise CommandError("Use the config.production settings profile with DEBUG=False.")
        issues = [issue.id for issue in run_checks(include_deployment_checks=True) if issue.level >= WARNING]
        if options["acknowledge_staged_hsts"]:
            reviewed = sorted(set(issues) & {"security.W005", "security.W021"})
            if reviewed:
                self.stdout.write("Acknowledged staged HSTS warnings: " + ", ".join(reviewed))
            issues = [issue for issue in issues if issue not in reviewed]
        if issues:
            raise CommandError("Production checks failed: " + ", ".join(sorted(issues)))
        media = Path(settings.MEDIA_ROOT)
        if not media.is_dir():
            raise CommandError("Private media directory is missing or unreadable.")
        if not shutil.which(settings.VIDEO_FFPROBE_PATH):
            raise CommandError("The server-managed ffprobe executable is unavailable.")
        try:
            if not staticfiles_storage.manifest_hash:
                raise ValueError("Missing manifest")
            for asset in ASSETS:
                name = staticfiles_storage.stored_name(asset)
                if name == asset or not staticfiles_storage.exists(name):
                    raise ValueError("Missing hashed asset")
        except (ValueError, OSError, AttributeError):
            raise CommandError("Collected static manifest/assets are missing; collect for this release before activation.") from None
        if options["require_reminders"]:
            try:
                cutoff = parse_datetime(settings.NOTIFICATIONS_ACTIVATED_AT)
            except (ValueError, TypeError):
                cutoff = None
            if cutoff is None or timezone.is_naive(cutoff) or cutoff > timezone.now():
                raise CommandError("NOTIFICATIONS_ACTIVATED_AT must be a fixed, aware, non-future rollout timestamp.")
        if options["database"]:
            self.check_database()
        self.stdout.write("Production preflight passed. Proxy, serving, backup restore and runtime rehearsal remain operator gates.")

    def check_database(self):
        if connection.vendor != "mysql":
            raise CommandError("Production requires MySQL.")
        try:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
                if cursor.fetchone() != (1,):
                    raise CommandError("Database readiness failed.")
                cursor.execute(
                    "SELECT COUNT(*) FROM information_schema.TABLES "
                    "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE' AND ENGINE<>'InnoDB'"
                )
                if cursor.fetchone()[0]:
                    raise CommandError("Non-transactional database tables prevent a consistent online backup.")
            loader = MigrationLoader(connection)
            loader.check_consistent_history(connection)
            if set(loader.disk_migrations) - set(loader.applied_migrations):
                raise CommandError("Unapplied migrations remain; inspect the migration plan before activation.")
        except DatabaseError:
            raise CommandError("Database readiness failed; inspect protected operational diagnostics.") from None
        except InconsistentMigrationHistory:
            raise CommandError("Migration history is inconsistent; stop and inspect the approved schema history.") from None
