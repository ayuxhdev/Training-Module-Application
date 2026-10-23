from io import StringIO
import json
import logging
import os
from pathlib import Path
import runpy
import subprocess
import sys
from tempfile import TemporaryDirectory
from types import ModuleType, SimpleNamespace
from unittest.mock import patch

from django.core.exceptions import ImproperlyConfigured
from django.core.checks import Warning
from django.core.management import call_command
from django.core.management.base import CommandError
from django.db import DatabaseError, connection
from django.test import RequestFactory, SimpleTestCase, TestCase, override_settings
from django.urls import resolve, Resolver404
from rest_framework.test import APIRequestFactory, force_authenticate

from config.health import live, ReadinessView
from config.operational_logging import OperationalJSONFormatter
from ops.mysql_backup import backup, BackupError, verify


class ProductionProfileTests(TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.environment = {
            "DEBUG": "false", "DJANGO_ENVIRONMENT": "staging",
            "DJANGO_SECRET_KEY": "test-only-" + "abcdefghij0123456789" * 3,
            "ALLOWED_HOSTS": "training.example.test", "DB_NAME": "test_only",
            "DB_USER": "test_app", "DB_PASSWORD": "test-only-unused",
            "DB_HOST": "127.0.0.1", "DB_PORT": "3306",
            "STATIC_ROOT": str(root / "static"), "PRIVATE_MEDIA_ROOT": str(root / "private"),
        }

    def load(self, **changes):
        values = {**self.environment, **changes}
        with patch.dict(os.environ, values, clear=True), patch("dotenv.load_dotenv"):
            base = runpy.run_path(str(Path(__file__).resolve().parents[1] / "config/settings.py"))
            module = ModuleType("config.settings")
            module.__dict__.update(base)
            with patch.dict(sys.modules, {"config.settings": module}):
                return runpy.run_module("config.production", run_name="config._production_test")

    def test_valid_profile_enforces_transport_and_keeps_hsts_subdomains_opt_in(self):
        values = self.load(SECURE_SSL_REDIRECT="false", SESSION_COOKIE_SECURE="false")
        self.assertFalse(values["DEBUG"])
        self.assertTrue(values["SECURE_SSL_REDIRECT"])
        self.assertTrue(values["SESSION_COOKIE_SECURE"])
        self.assertTrue(values["CSRF_COOKIE_SECURE"])
        self.assertEqual(values["SECURE_HSTS_SECONDS"], 3600)
        self.assertFalse(values["SECURE_HSTS_INCLUDE_SUBDOMAINS"])
        self.assertIsNone(values["SECURE_PROXY_SSL_HEADER"])
        self.assertFalse(values["USE_X_FORWARDED_HOST"])
        self.assertIn("ManifestStaticFilesStorage", values["STORAGES"]["staticfiles"]["BACKEND"])

    def test_missing_or_weak_production_configuration_fails_closed(self):
        for changes in (
            {"DEBUG": "true"}, {"DJANGO_ENVIRONMENT": "development"}, {"DJANGO_SECRET_KEY": ""},
            {"DJANGO_SECRET_KEY": "x" * 70}, {"ALLOWED_HOSTS": ""}, {"ALLOWED_HOSTS": "*"},
            {"ALLOWED_HOSTS": ".example.test"}, {"ALLOWED_HOSTS": "https://example.test"},
            {"DB_PASSWORD": ""}, {"DB_USER": "root"}, {"DB_PORT": "invalid"},
        ):
            with self.subTest(changes=list(changes)), self.assertRaises(ImproperlyConfigured):
                self.load(**changes)

    def test_proxy_trust_and_cross_origin_csrf_are_explicit(self):
        values = self.load(TRUST_X_FORWARDED_PROTO="true", CSRF_TRUSTED_ORIGINS="https://portal.example.test")
        self.assertEqual(values["SECURE_PROXY_SSL_HEADER"], ("HTTP_X_FORWARDED_PROTO", "https"))
        self.assertEqual(values["CSRF_TRUSTED_ORIGINS"], ["https://portal.example.test"])
        for origin in ("http://example.test", "https://*.example.test", "https://example.test/path", "https://user:password@example.test"):
            with self.subTest(origin=origin), self.assertRaises(ImproperlyConfigured):
                self.load(CSRF_TRUSTED_ORIGINS=origin)
        with self.assertRaises(ImproperlyConfigured):
            self.load(TRUST_X_FORWARDED_PROTO="typo")

    def test_hsts_and_connection_bounds_are_validated(self):
        for changes in ({"SECURE_HSTS_SECONDS": "0"}, {"SECURE_HSTS_SECONDS": "invalid"},
                        {"SECURE_HSTS_PRELOAD": "true"}, {"DB_CONNECT_TIMEOUT": "0"}, {"DB_READ_TIMEOUT": "9999"}):
            with self.subTest(changes=changes), self.assertRaises(ImproperlyConfigured):
                self.load(**changes)
        values = self.load()
        self.assertTrue(values["DATABASES"]["default"]["CONN_HEALTH_CHECKS"])
        self.assertEqual(values["DATABASES"]["default"]["OPTIONS"]["connect_timeout"], 5)
        command = values["DATABASES"]["default"]["OPTIONS"]["init_command"]
        with connection.cursor() as cursor:
            cursor.execute("SELECT @@SESSION.sql_mode")
            original = cursor.fetchone()[0]
            try:
                cursor.execute(command)
                cursor.execute("SELECT @@SESSION.sql_mode")
                modes = set(cursor.fetchone()[0].split(","))
                self.assertIn("STRICT_TRANS_TABLES", modes)
                self.assertTrue(set(original.split(",")) - {""} <= modes)
            finally:
                cursor.execute("SET SESSION sql_mode=%s", [original])

    def test_remote_database_requires_identity_verified_tls(self):
        with self.assertRaises(ImproperlyConfigured):
            self.load(DB_HOST="mysql.example.test")
        ca = Path(self.temp.name) / "ca.pem"
        ca.write_text("test-only-not-a-real-ca", encoding="utf-8")
        values = self.load(DB_HOST="mysql.example.test", DB_SSL_CA=str(ca))
        self.assertEqual(values["DATABASES"]["default"]["OPTIONS"]["ssl_mode"], "VERIFY_IDENTITY")

    def test_media_cannot_overlap_application_or_static_tree(self):
        base = Path(__file__).resolve().parents[1]
        for changes in ({"PRIVATE_MEDIA_ROOT": str(base / "media")}, {"PRIVATE_MEDIA_ROOT": "relative"},
                        {"PRIVATE_MEDIA_ROOT": self.environment["STATIC_ROOT"]}, {"STATIC_ROOT": str(base)}):
            with self.subTest(changes=changes), self.assertRaises(ImproperlyConfigured):
                self.load(**changes)


class OperationalLoggingTests(SimpleTestCase):
    def test_structured_untrusted_event_cannot_break_redaction(self):
        record = logging.LogRecord("django.request", logging.ERROR, __file__, 1, "private-sentinel", (), None)
        record.event = {"token": "private-sentinel"}
        self.assertNotIn("private-sentinel", OperationalJSONFormatter().format(record))

    def test_sensitive_message_request_arguments_and_exception_text_are_omitted(self):
        secret = "private-test-sentinel-password-and-jwt"
        try:
            raise RuntimeError(secret)
        except RuntimeError:
            record = logging.LogRecord("django.request", logging.ERROR, __file__, 1,
                "Authorization: %s", (secret,), sys.exc_info())
        record.request = SimpleNamespace(GET={"token": secret}, body=secret)
        record.event = secret
        record.status_code = 500
        encoded = OperationalJSONFormatter().format(record)
        self.assertNotIn(secret, encoded)
        self.assertNotIn(str(Path(__file__).parent), encoded)
        payload = json.loads(encoded)
        self.assertEqual(payload["event"], "application_log")
        self.assertEqual(payload["exception_type"], "RuntimeError")
        self.assertEqual(payload["status"], 500)
        self.assertEqual(len(payload["fingerprint"]), 16)

    def test_only_allowed_event_metrics_are_logged(self):
        record = logging.LogRecord("operations", logging.INFO, __file__, 1, "unused", (), None)
        record.event, record.created_count, record.duration_ms = "reminders_completed", 3, 120
        record.employee_id, record.token = 99, "private-sentinel"
        payload = json.loads(OperationalJSONFormatter().format(record))
        self.assertEqual(payload["created_count"], 3)
        self.assertNotIn("employee_id", payload)
        self.assertNotIn("token", payload)


class HealthTests(SimpleTestCase):
    def test_application_has_no_public_media_or_static_video_route(self):
        for path in ("/media/training/videos/lesson.mp4", "/static/training/videos/lesson.mp4", "/training/videos/lesson.mp4"):
            with self.subTest(path=path), self.assertRaises(Resolver404):
                resolve(path)

    def test_liveness_is_public_read_only_and_does_not_query_database(self):
        response = live(RequestFactory().get("/health/live/"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(json.loads(response.content), {"status": "ok"})
        self.assertEqual(response["Cache-Control"], "no-store")
        self.assertEqual(live(RequestFactory().post("/health/live/")).status_code, 405)

    def request(self, user=None, method="get"):
        request = getattr(APIRequestFactory(), method)("/health/ready/")
        if user:
            force_authenticate(request, user=user)
        return ReadinessView.as_view()(request)

    def test_readiness_requires_active_superuser_and_never_leaks_diagnostics(self):
        self.assertEqual(self.request().status_code, 401)
        ordinary = SimpleNamespace(is_authenticated=True, is_active=True, is_superuser=False)
        self.assertEqual(self.request(ordinary).status_code, 403)
        inactive = SimpleNamespace(is_authenticated=True, is_active=False, is_superuser=True)
        self.assertEqual(self.request(inactive).status_code, 403)

    def test_superuser_readiness_runs_one_small_query(self):
        user = SimpleNamespace(is_authenticated=True, is_active=True, is_superuser=True)
        with patch("config.health.connection") as database:
            cursor = database.cursor.return_value.__enter__.return_value
            cursor.fetchone.return_value = (1,)
            response = self.request(user)
            cursor.execute.assert_called_once_with("SELECT 1")
        self.assertEqual(response.data, {"status": "ok"})
        self.assertEqual(response["Cache-Control"], "no-store")
        self.assertEqual(self.request(user, method="post").status_code, 405)

    def test_database_failure_is_generic_503_even_during_authentication(self):
        user = SimpleNamespace(is_authenticated=True, is_active=True, is_superuser=True)
        with patch("config.health.connection") as database, self.assertLogs("operations", "WARNING"):
            database.cursor.side_effect = DatabaseError("secret-sentinel")
            response = self.request(user)
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.data, {"status": "unavailable"})
        with patch("config.health.JWTAuthentication.authenticate", side_effect=DatabaseError("secret-sentinel")), self.assertLogs("operations", "WARNING"):
            response = self.request()
        self.assertEqual(response.status_code, 503)
        self.assertNotIn("secret-sentinel", str(response.data))


class ProductionPreflightTests(SimpleTestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.override = override_settings(PRODUCTION_PROFILE=True, DEBUG=False, MEDIA_ROOT=self.temp.name)
        self.override.enable()
        self.addCleanup(self.override.disable)
        checks = patch("accounts.management.commands.production_preflight.run_checks", return_value=[])
        checks.start()
        self.addCleanup(checks.stop)
        tool = patch("accounts.management.commands.production_preflight.shutil.which", return_value="ffprobe")
        tool.start()
        self.addCleanup(tool.stop)
        storage = patch("accounts.management.commands.production_preflight.staticfiles_storage")
        self.storage = storage.start()
        self.addCleanup(storage.stop)
        self.storage.manifest_hash = "test-manifest"
        self.storage.stored_name.side_effect = lambda name: name + ".hash"
        self.storage.exists.return_value = True

    def run_command(self, **kwargs):
        output = StringIO()
        call_command("production_preflight", stdout=output, **kwargs)
        return output.getvalue()

    def test_valid_local_gates_do_not_claim_deployment_rehearsal(self):
        self.assertIn("operator gates", self.run_command())

    def test_wrong_profile_missing_media_or_missing_ffprobe_fail(self):
        for changes in ({"PRODUCTION_PROFILE": False}, {"DEBUG": True}, {"MEDIA_ROOT": str(Path(self.temp.name) / "missing")}):
            with self.subTest(changes=changes), override_settings(**changes), self.assertRaises(CommandError):
                self.run_command()
        with patch("accounts.management.commands.production_preflight.shutil.which", return_value=None), self.assertRaises(CommandError):
            self.run_command()

    def test_missing_manifest_or_hashed_file_fails(self):
        self.storage.manifest_hash = ""
        with self.assertRaises(CommandError):
            self.run_command()
        self.storage.manifest_hash = "test-manifest"
        self.storage.exists.return_value = False
        with self.assertRaises(CommandError):
            self.run_command()

    def test_reminder_gate_requires_fixed_aware_activation(self):
        for cutoff in ("", "invalid", "2026-01-01", "2999-01-01T00:00:00Z"):
            with override_settings(NOTIFICATIONS_ACTIVATED_AT=cutoff), self.assertRaises(CommandError):
                self.run_command(require_reminders=True)
        with override_settings(NOTIFICATIONS_ACTIVATED_AT="2020-01-01T00:00:00Z"):
            self.assertIn("passed", self.run_command(require_reminders=True))

    def test_only_staged_hsts_warnings_can_be_explicitly_acknowledged(self):
        checks = [Warning("Staged HSTS", id="security.W005"), Warning("Not preloaded", id="security.W021")]
        with patch("accounts.management.commands.production_preflight.run_checks", return_value=checks):
            with self.assertRaises(CommandError):
                self.run_command()
            self.assertIn("Acknowledged staged HSTS", self.run_command(acknowledge_staged_hsts=True))
        checks.append(Warning("Unsafe redirect", id="security.W008"))
        with patch("accounts.management.commands.production_preflight.run_checks", return_value=checks), self.assertRaises(CommandError):
            self.run_command(acknowledge_staged_hsts=True)

    def test_database_errors_or_nontransactional_tables_fail_without_disclosing_details(self):
        from accounts.management.commands.production_preflight import Command
        with patch("accounts.management.commands.production_preflight.connection") as database:
            database.vendor = "mysql"
            database.cursor.side_effect = DatabaseError("private-sentinel")
            with self.assertRaises(CommandError) as raised:
                Command().check_database()
            self.assertNotIn("private-sentinel", str(raised.exception))
            database.cursor.side_effect = None
            database.cursor.return_value.__enter__.return_value.fetchone.side_effect = [(1,), (1,)]
            with self.assertRaisesMessage(CommandError, "Non-transactional"):
                Command().check_database()

    def test_pending_migrations_fail_without_execution(self):
        from accounts.management.commands.production_preflight import Command
        with patch("accounts.management.commands.production_preflight.connection") as database, patch("accounts.management.commands.production_preflight.MigrationLoader") as loader:
            database.vendor = "mysql"
            database.cursor.return_value.__enter__.return_value.fetchone.side_effect = [(1,), (0,)]
            loader.return_value.disk_migrations = {("test_app", "0001_initial"): object()}
            loader.return_value.applied_migrations = {}
            with self.assertRaisesMessage(CommandError, "Unapplied migrations"):
                Command().check_database()


class ProductionDatabasePreflightTests(TestCase):
    def test_real_mysql_schema_check_is_read_only_and_accepts_current_migrations(self):
        from accounts.management.commands.production_preflight import Command
        Command().check_database()


class BackupToolTests(SimpleTestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.options = self.root / "client.cnf"
        self.options.write_text("[client]\npassword=test-only-not-real\n", encoding="utf-8")
        self.options.chmod(0o600)
        self.backups = self.root / "backups"
        self.backups.mkdir(mode=0o700)
        self.kwargs = dict(defaults_file=self.options, database="test_only", host="127.0.0.1", port=3306,
            expected_server="test-server", environment="development", output_dir=self.backups, media_snapshot_id="isolated-test-snapshot")

    def successful_client(self, args, **kwargs):
        if "--batch" in args:
            return subprocess.CompletedProcess(args, 0, stdout=b"test_only\ttest-server\t0\n")
        kwargs["stdout"].write(b"CREATE TABLE isolated_fixture (id INT);\n")
        return subprocess.CompletedProcess(args, 0)

    def test_backup_is_consistent_private_unique_and_credentials_never_enter_arguments(self):
        with patch("ops.mysql_backup.subprocess.run", side_effect=self.successful_client) as run:
            first = backup(**self.kwargs)
            second = backup(**self.kwargs)
        self.assertNotEqual(first, second)
        manifest = verify(first)
        self.assertEqual(manifest["database"], "test_only")
        self.assertEqual(manifest["media_snapshot_id"], "isolated-test-snapshot")
        dump = run.call_args_list[1].args[0]
        self.assertIn("--single-transaction", dump)
        self.assertIn("--skip-add-drop-table", dump)
        self.assertNotIn("test-only-not-real", str(run.call_args_list))
        self.assertTrue(dump[1].startswith("--defaults-file="))
        self.assertNotIn("MYSQL_PWD", run.call_args.kwargs["env"])

    def test_dump_explicitly_includes_routines_events_and_triggers_and_stops_on_errors(self):
        with patch("ops.mysql_backup.subprocess.run", side_effect=self.successful_client) as run:
            backup(**self.kwargs)
        dump = run.call_args_list[1]
        for option in ("--routines", "--events", "--triggers", "--skip-force"):
            self.assertEqual(dump.args[0].count(option), 1)
        self.assertTrue(dump.args[0][1].startswith("--defaults-file="))
        self.assertTrue(dump.kwargs["check"])
        self.assertNotIn("--force", dump.args[0])

    def test_object_export_failure_never_publishes_partial_sql_as_a_complete_backup(self):
        with patch("ops.mysql_backup.subprocess.run", side_effect=self.successful_client):
            existing = backup(**self.kwargs)
        original_sql = (existing / "database.sql").read_bytes()
        original_manifest = (existing / "manifest.json").read_bytes()
        for object_type in ("routine", "event", "trigger"):
            def denied_export(args, **kwargs):
                if "--batch" in args:
                    return self.successful_client(args, **kwargs)
                kwargs["stdout"].write(b"CREATE TABLE isolated_fixture (id INT);\n")
                raise subprocess.CalledProcessError(
                    2, "mysqldump", stderr=f"{object_type} export denied: private-sentinel".encode(),
                )
            with self.subTest(object_type=object_type):
                with patch("ops.mysql_backup.subprocess.run", side_effect=denied_export), self.assertRaises(BackupError) as raised:
                    backup(**self.kwargs)
                self.assertNotIn("private-sentinel", str(raised.exception))
        self.assertEqual(list(self.backups.glob("*/manifest.json")), [existing / "manifest.json"])
        self.assertEqual(list(self.backups.glob("*/database.sql")), [existing / "database.sql"])
        self.assertEqual(len(list(self.backups.glob("*/database.sql.partial"))), 3)
        self.assertEqual((existing / "database.sql").read_bytes(), original_sql)
        self.assertEqual((existing / "manifest.json").read_bytes(), original_manifest)
        verify(existing)

    def test_cli_does_not_report_success_after_an_export_failure(self):
        from ops.mysql_backup import main
        arguments = ["mysql_backup", "create"]
        for name, value in self.kwargs.items():
            arguments.extend(["--" + name.replace("_", "-"), str(value)])
        output, errors = StringIO(), StringIO()
        with patch.object(sys, "argv", arguments), patch("sys.stdout", output), patch("sys.stderr", errors):
            with patch("ops.mysql_backup.backup", side_effect=BackupError("Backup failed; incomplete bundle retained.")):
                with self.assertRaises(SystemExit) as raised:
                    main()
        self.assertEqual(raised.exception.code, 1)
        self.assertEqual(output.getvalue(), "")
        self.assertIn("Backup failed", errors.getvalue())

    def test_wrong_target_or_nontransactional_tables_never_create_bundle(self):
        for output in (b"wrong\ttest-server\t0", b"test_only\tforeign-server\t0", b"test_only\ttest-server\t1"):
            with patch("ops.mysql_backup.subprocess.run", return_value=subprocess.CompletedProcess([], 0, stdout=output)), self.assertRaises(BackupError):
                backup(**self.kwargs)
        self.assertEqual(list(self.backups.iterdir()), [])

    def test_invalid_input_cannot_be_used_as_command_options_or_public_output(self):
        for changes in ({"database": "--all-databases"}, {"environment": "unknown"}, {"media_snapshot_id": ""},
                        {"output_dir": Path(__file__).parent}, {"defaults_file": "relative.cnf"}):
            with self.subTest(changes=list(changes)), self.assertRaises(BackupError):
                backup(**{**self.kwargs, **changes})

    def test_failed_or_timed_out_dump_keeps_existing_backups_and_no_completion_manifest(self):
        with patch("ops.mysql_backup.subprocess.run", side_effect=self.successful_client):
            valid = backup(**self.kwargs)
        for error in (subprocess.TimeoutExpired("mysqldump", 1), subprocess.CalledProcessError(1, "mysqldump", stderr=b"secret-sentinel")):
            def fail_dump(args, **kwargs):
                if "--batch" in args:
                    return self.successful_client(args, **kwargs)
                raise error
            with patch("ops.mysql_backup.subprocess.run", side_effect=fail_dump), self.assertRaises(BackupError) as raised:
                backup(**self.kwargs)
            self.assertNotIn("secret-sentinel", str(raised.exception))
        self.assertEqual(len(list(self.backups.glob("*/manifest.json"))), 1)
        verify(valid)

    def test_corruption_empty_and_missing_manifests_fail_verification(self):
        with patch("ops.mysql_backup.subprocess.run", side_effect=self.successful_client):
            bundle = backup(**self.kwargs)
        (bundle / "database.sql").write_bytes(b"tampered")
        with self.assertRaises(BackupError):
            verify(bundle)
        (bundle / "manifest.json").write_text("invalid", encoding="utf-8")
        with self.assertRaises(BackupError):
            verify(bundle)

    def test_empty_dump_never_gets_a_completion_manifest(self):
        def empty_dump(args, **kwargs):
            if "--batch" in args:
                return self.successful_client(args, **kwargs)
            return subprocess.CompletedProcess(args, 0)
        with patch("ops.mysql_backup.subprocess.run", side_effect=empty_dump), self.assertRaises(BackupError):
            backup(**self.kwargs)
        self.assertEqual(list(self.backups.glob("*/manifest.json")), [])
