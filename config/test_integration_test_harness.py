"""Database-free harness verification: driver/network calls are blocked or faked."""
from contextlib import contextmanager
from copy import deepcopy
from dataclasses import replace
import io
import json
import os
from pathlib import Path
import runpy
import secrets
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
import traceback
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from uuid import uuid4

from django.db.backends.base.base import BaseDatabaseWrapper
from django.db.utils import ConnectionHandler
from django.test import SimpleTestCase, TestCase, TransactionTestCase

from . import integration_test_runner as integration
from . import role_requirement_test_runner as guarded
from . import test_role_requirement_test_harness as fixtures
from .role_requirement_test_config import (
    IntegrationConfig, INTEGRATION_PROFILE, INTEGRATION_RUNNER, PROTECTED_DATABASES,
    IDENTITY_SQL, UnsafeTestTarget, mark_verified, preflight, validate_config_approval,
    validate_database, validate_settings, verify_grants, verify_identity,
)


REAL_CONNECT = BaseDatabaseWrapper.connect


def identity(config, database):
    row = list(fixtures.identity(config, database))
    row[2] = 3306
    return tuple(row)


class Cursor(fixtures.FakeCursor):
    def fetchone(self):
        sql = self.calls[-1][0]
        if sql == IDENTITY_SQL:
            return identity(self.config, None)
        if sql == "SELECT CONNECTION_ID()" or sql.startswith("SELECT IS_USED_LOCK"):
            return (701,)
        return super().fetchone()


class DriverCursor(fixtures.DriverCursor):
    lastrowid = 1

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def execute(self, sql, params=None):
        if self.session.closed:
            from MySQLdb import OperationalError
            raise OperationalError(2013, "Synthetic closed session")
        self.statement = (sql, params)
        super().execute(sql, params)
        if "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED" in sql:
            self.session.isolation = "READ-COMMITTED"

    def fetchall(self):
        if "information_schema.tables" in self.statement[0]:
            return [("django_content_type", "BASE TABLE", "")]
        return super().fetchall()

    def fetchone(self):
        sql, params = self.statement
        if sql == IDENTITY_SQL:
            row = list(identity(self.config, self.database))
            row[6] = self.session.isolation
            return tuple(row)
        if sql == "SELECT CONNECTION_ID()":
            return (self.session.connection_id,)
        if sql == "SELECT GET_LOCK(%s, 0)":
            if self.lock != 1:
                return (self.lock,)
            owner = self.session.leases.setdefault(params[0], self.session.connection_id)
            return (int(owner == self.session.connection_id),)
        if sql == "SELECT IS_USED_LOCK(%s) = CONNECTION_ID()":
            return (int(self.session.leases.get(params[0]) == self.session.connection_id),)
        if sql.startswith("SELECT IS_USED_LOCK"):
            return (self.session.leases.get(params[0]),)
        if "information_schema.PROCESSLIST" in sql and self.session.sessions is not None:
            return (sum(other is not self.session and not other.closed
                        for other in self.session.sessions),)
        return super().fetchone()


class DriverConnection(fixtures.DriverConnection):
    def __init__(self, config, database, leases, *, sessions=None,
                 startup_isolation="READ-COMMITTED", **changes):
        super().__init__(config, database, **changes)
        self.isolation = startup_isolation
        self.connection_id = 701
        self.leases = leases
        self.sessions = sessions
        self.transactions = []

    def autocommit(self, enabled):
        self.transactions.append(("autocommit", enabled))

    def commit(self):
        self.transactions.append(("commit",))

    def rollback(self):
        self.transactions.append(("rollback",))

    def close(self):
        super().close()
        for name, owner in list(self.leases.items()):
            if owner == self.connection_id:
                del self.leases[name]

    def cursor(self):
        cursor = DriverCursor(self.config, self.database, self.calls, **self.changes)
        cursor.session = self
        return cursor


class IntegrationHarnessTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[1]
        self.prepare_target()
        self.addCleanup(mark_verified, None)
        self.network = self.enterContext(patch("socket.socket.connect", side_effect=AssertionError("Network forbidden")))
        self.driver = self.enterContext(patch("MySQLdb.connect", side_effect=AssertionError("Database forbidden")))
        self.base = self.enterContext(patch.object(BaseDatabaseWrapper, "connect", side_effect=AssertionError("Database forbidden")))

    def prepare_target(self):
        self.owner = uuid4().hex
        self.media = Path(tempfile.gettempdir()).resolve() / ("gn-it-media-" + self.owner)
        if self.media.is_relative_to(self.root):
            self.fail("Test fixture media must be outside the checkout")
        self.media.mkdir()
        self.addCleanup(shutil.rmtree, self.media)
        user = "gn_it_" + self.owner[:16]
        database = "test_gn_it_20261121_" + self.owner
        self.environment = {
            "MYSQL_TEST_DATABASE": database, "MYSQL_TEST_APPROVED_DATABASE": database,
            "MYSQL_TEST_OWNER": self.owner, "MYSQL_TEST_EXCLUSIVE_OWNER": self.owner,
            "MYSQL_TEST_HOST": "127.0.0.1", "MYSQL_TEST_PORT": "3306",
            "MYSQL_TEST_USER": user, "MYSQL_TEST_ACCOUNT": user + "@127.0.0.1",
            "MYSQL_TEST_SERVER_UUID": "12345678-1234-1234-1234-123456789abc",
            "MYSQL_TEST_SERVER_HOSTNAME": "unit-only-server",
            "MYSQL_TEST_PASSWORD": "synthetic-unit-password-never-connected",
            "MYSQL_TEST_SECRET_KEY": secrets.token_urlsafe(64),
            "MYSQL_TEST_MEDIA_ROOT": str(self.media), "MYSQL_TEST_ISOLATION": "read committed",
            "MYSQL_TEST_ALLOW_CREATE": "create-new-disposable-schema",
            "MYSQL_TEST_ALLOW_RESET": "owned-schema-only",
            "MYSQL_TEST_RETENTION": "retain-for-approved-cleanup",
        }
        self.config = IntegrationConfig.from_environment(self.environment)

    def tearDown(self):
        self.network.assert_not_called()
        self.driver.assert_not_called()
        self.base.assert_not_called()

    def settings(self, **changes):
        values = dict(
            INTEGRATION_TEST_CONFIG=self.config, SETTINGS_MODULE=INTEGRATION_PROFILE,
            TEST_RUNNER=INTEGRATION_RUNNER, DATABASES={"default": self.config.database_settings()},
            DATABASE_ROUTERS=[], MIGRATION_MODULES={}, MEDIA_ROOT=self.media, BASE_DIR=self.root,
        )
        values.update(changes)
        return SimpleNamespace(**values)

    def runner(self, **changes):
        options = dict(interactive=False, parallel=1, keepdb=False, verbosity=0, enable_faulthandler=False)
        options.update(changes)
        return integration.IntegrationTestRunner(**options)

    def authorize(self, runner):
        self.enterContext(patch.dict(os.environ, self.environment, clear=True))
        self.enterContext(patch.object(integration, "settings", self.settings()))
        self.enterContext(patch.object(guarded, "settings", self.settings()))
        self.enterContext(patch.object(integration, "connections", Mock(all=Mock(return_value=[]))))
        runner._authorize()

    def test_standalone_settings_no_environment_file_or_provisioning(self):
        with patch.dict(os.environ, self.environment, clear=True), patch(
            "dotenv.load_dotenv", side_effect=AssertionError("No credential file")
        ), patch.object(Path, "mkdir", side_effect=AssertionError("No provisioning")):
            values = runpy.run_module(INTEGRATION_PROFILE, run_name="config._integration_unit")
        self.assertEqual(values["DATABASES"]["default"]["NAME"], self.config.database)
        self.assertEqual(values["DATABASES"]["default"]["TEST"]["NAME"], self.config.database)
        self.assertEqual(values["DATABASES"]["default"]["PORT"], "3306")
        self.assertTrue(values["SIMPLE_JWT"]["CHECK_REVOKE_TOKEN"])
        self.assertEqual(len(values["AUTH_PASSWORD_VALIDATORS"]), 4)
        from . import isolated_test_defaults
        self.assertEqual(values["STORAGES"], isolated_test_defaults.STORAGES)
        self.assertIsNot(values["STORAGES"], isolated_test_defaults.STORAGES)
        self.assertNotIn(self.config.password, repr(self.config))
        self.assertNotIn(self.config.secret_key, repr(self.config))
        self.assertIs(validate_settings(self.settings(), setup=True), self.config)

    def test_every_required_value_is_explicit_and_generic_db_values_never_fallback(self):
        for name in self.environment:
            values = {**self.environment, "DB_NAME": "gardens_training", "DB_USER": "root"}
            del values[name]
            with self.subTest(name=name), self.assertRaises(UnsafeTestTarget):
                IntegrationConfig.from_environment(values)

    def test_wrong_schema_date_owner_endpoint_account_and_approvals_fail(self):
        changes = {
            "MYSQL_TEST_DATABASE": "test_gn_it_20269999_" + self.owner,
            "MYSQL_TEST_APPROVED_DATABASE": "different", "MYSQL_TEST_OWNER": uuid4().hex,
            "MYSQL_TEST_EXCLUSIVE_OWNER": uuid4().hex, "MYSQL_TEST_HOST": "localhost",
            "MYSQL_TEST_PORT": "3308", "MYSQL_TEST_USER": "root",
            "MYSQL_TEST_ACCOUNT": self.config.user + "@%", "MYSQL_TEST_ALLOW_CREATE": "yes",
            "MYSQL_TEST_ALLOW_RESET": "yes", "MYSQL_TEST_RETENTION": "drop",
            "MYSQL_TEST_ISOLATION": "repeatable read", "MYSQL_TEST_SERVER_UUID": "unknown",
            "MYSQL_TEST_OPTIONS": "unapproved", "DJANGO_SETTINGS_MODULE": "config.qa_settings",
        }
        for name, value in changes.items():
            with self.subTest(name=name), self.assertRaises(UnsafeTestTarget):
                IntegrationConfig.from_environment({**self.environment, name: value})

    def test_protected_or_non_guid_names_never_validate_even_when_approved(self):
        for name in (*PROTECTED_DATABASES, "test_other", "TEST_GN_IT_20261121_" + self.owner):
            with self.subTest(name=name), self.assertRaises(UnsafeTestTarget):
                IntegrationConfig.from_environment({**self.environment,
                    "MYSQL_TEST_DATABASE": name, "MYSQL_TEST_APPROVED_DATABASE": name})
        for name in PROTECTED_DATABASES:
            config = replace(self.config, database=name)
            with self.assertRaises(UnsafeTestTarget):
                validate_database(config, config.database_settings())

    def test_owner_named_account_and_media_are_required(self):
        other = "gn_it_" + uuid4().hex[:16]
        for values in (
            {"MYSQL_TEST_USER": other, "MYSQL_TEST_ACCOUNT": other + "@127.0.0.1"},
            {"MYSQL_TEST_MEDIA_ROOT": str(self.root)},
        ):
            with self.assertRaises(UnsafeTestTarget):
                IntegrationConfig.from_environment({**self.environment, **values})
        (self.media / "existing").write_bytes(b"synthetic")
        with self.assertRaises(UnsafeTestTarget):
            IntegrationConfig.from_environment(self.environment)

    def test_integration_media_requires_the_canonical_spelling_at_startup(self):
        alternate = str(self.media.parent / ".." / self.media.parent.name / self.media.name)
        for spelling in (str(self.media) + os.sep, alternate):
            self.assertNotEqual(spelling, str(self.media))
            with self.subTest(spelling=spelling), self.assertRaisesRegex(UnsafeTestTarget, "canonical absolute path"):
                IntegrationConfig.from_environment(dict(self.environment, MYSQL_TEST_MEDIA_ROOT=spelling))
        validate_config_approval(self.environment, self.config)

    def test_environment_changes_are_rechecked_without_requiring_empty_media(self):
        (self.media / "test-fixture").write_bytes(b"synthetic")
        validate_config_approval(self.environment, self.config)
        for name, value in (("MYSQL_TEST_DATABASE", "gardens_training"),
                            ("MYSQL_TEST_EXCLUSIVE_OWNER", uuid4().hex),
                            ("MYSQL_TEST_OPTIONS", "other"), ("MYSQL_TEST_PASSWORD", "changed")):
            with self.subTest(name=name), self.assertRaises(UnsafeTestTarget):
                validate_config_approval({**self.environment, name: value}, self.config)

    def test_aliases_routers_backend_and_test_target_overrides_rejected(self):
        for changes in (
            {"SETTINGS_MODULE": "config.settings"}, {"TEST_RUNNER": "django.test.runner.DiscoverRunner"},
            {"INTEGRATION_TEST_CONFIG": None}, {"DATABASE_ROUTERS": ["unsafe.Router"]},
            {"MIGRATION_MODULES": {"training": None}}, {"MEDIA_ROOT": self.root},
            {"DATABASES": {"default": self.config.database_settings(), "other": self.config.database_settings()}},
        ):
            with self.subTest(changes=list(changes)), self.assertRaises(UnsafeTestTarget):
                validate_settings(self.settings(**changes), setup=True)
        for change in (
            lambda db: db.update(ENGINE="django.db.backends.mysql"),
            lambda db: db.update(NAME="gardens_training"),
            lambda db: db["TEST"].update(NAME="test_gardens_training"),
            lambda db: db["OPTIONS"].update(read_default_file="unexpected.cnf"),
            lambda db: db["TEST"].update(MIRROR="other"),
        ):
            db = deepcopy(self.config.database_settings())
            change(db)
            with self.assertRaises(UnsafeTestTarget):
                validate_database(self.config, db)

    def test_wrong_live_server_database_and_user_fail(self):
        for index, value in ((0, "wrong"), (1, "other"), (2, 3308), (3, "root@localhost"),
                             (4, "gardens_training_qa_isolated"), (5, "10.0-MariaDB"),
                             (6, "REPEATABLE-READ"), (7, "MyISAM")):
            row = list(identity(self.config, self.config.database))
            row[index] = value
            cursor = Mock()
            cursor.fetchone.return_value = tuple(row)
            with self.subTest(index=index), self.assertRaises(UnsafeTestTarget):
                verify_identity(cursor, self.config, self.config.database)

    def test_only_exact_schema_privileges_without_drop_or_roles_are_accepted(self):
        for partial in (True, False):
            verify_grants(fixtures.grants(self.config, partial_revokes=partial), self.config, partial)
        valid = fixtures.grants(self.config)
        for grant in (
            valid[1][0].replace("SELECT,", "DROP, SELECT,"),
            valid[1][0].replace(r"\_", "_"),
            valid[1][0] + " WITH GRANT OPTION",
            "GRANT SELECT ON *.* TO `" + self.config.user + "`@`127.0.0.1`",
            "GRANT `privileged_role` TO `" + self.config.user + "`@`127.0.0.1`",
        ):
            with self.subTest(grant_type=grant.split()[1]), self.assertRaises(UnsafeTestTarget):
                verify_grants([valid[0], (grant,)], self.config, False)

    def test_existing_schema_busy_lock_and_shared_account_connections_fail_before_ddl(self):
        for changes in ({"collision": True}, {"lock": 0}, {"others": 1}):
            cursor = Cursor(self.config, **changes)
            with self.subTest(changes=changes), self.assertRaises(UnsafeTestTarget):
                preflight(cursor, self.config)
            self.assertFalse(any(sql.startswith(("CREATE", "ALTER", "DROP", "DELETE")) for sql, _ in cursor.calls))

    def test_keepdb_parallel_debug_and_order_overrides_fail_before_connections(self):
        for changes in ({"keepdb": True}, {"parallel": 0}, {"parallel": 2},
                        {"interactive": True}, {"debug_sql": True}, {"debug_mode": True}, {"shuffle": True},
                        {"reverse": True}, {"tags": {"only"}}, {"test_name_patterns": ["some"]}):
            runner = self.runner(**changes)
            with self.subTest(changes=changes), patch.dict(os.environ, self.environment, clear=True), patch.object(
                integration, "settings", self.settings()
            ), self.assertRaises(UnsafeTestTarget):
                runner.run_tests(["api.v1.test_notifications"])

    def test_explicit_labels_reject_paths_external_modules_and_strict_checkpoint(self):
        for labels in ([], ["."], ["api"], ["os.test_bad"], ["api/v1/test_notifications.py"],
                       ["api.v1.test_role_requirement_concurrency"], ["notifications.tests"] * 2):
            with self.subTest(labels=labels), self.assertRaises(UnsafeTestTarget):
                integration.validate_labels(labels)
        self.assertEqual(integration.validate_labels(["notifications.tests"]), ("notifications.tests",))

    def test_discovery_preserves_normal_django_order_and_accepts_transaction_cases(self):
        self.configure_django()
        runner = self.runner()
        runner.config = self.config
        with patch.object(integration, "settings", self.settings()):
            suite = runner.build_suite(["api.v1.test_notifications", "notifications.tests",
                                       "api.v1.test_certificate_management",
                                       "assessments.test_question_editor"])
        cases = list(integration.iter_test_cases(suite))
        self.assertGreater(len(cases), 40)
        self.assertIn("QuestionEditorTests", {type(case).__name__ for case in cases})
        first_transaction = next(i for i, case in enumerate(cases)
                                 if isinstance(case, TransactionTestCase) and not isinstance(case, TestCase))
        self.assertFalse(any(isinstance(case, TestCase) for case in cases[first_transaction:]))

    def test_discovery_rejects_empty_duplicate_serialized_and_extra_database_cases(self):
        module = ModuleType("notifications.test_synthetic_harness_case")
        module.__file__ = str(self.root / "notifications/test_synthetic_harness_case.py")
        case = type("Case", (TransactionTestCase,), {"__module__": module.__name__, "runTest": lambda self: None})
        with patch.dict(sys.modules, {module.__name__: module}), patch.object(integration, "settings", self.settings()):
            for problem in ("empty", "duplicate", "serialized", "alias"):
                case.serialized_rollback = problem == "serialized"
                case.databases = {"default", "other"} if problem == "alias" else {"default"}
                tests = [] if problem == "empty" else [case()]
                if problem == "duplicate":
                    tests *= 2
                with self.subTest(problem=problem), patch("django.test.runner.DiscoverRunner.build_suite", return_value=unittest.TestSuite(tests)), self.assertRaises(UnsafeTestTarget):
                    self.runner().build_suite([module.__name__])

    def configure_django(self):
        import django
        from django.conf import settings
        if not settings.configured:
            with patch.dict(os.environ, self.environment, clear=True), patch("dotenv.load_dotenv", side_effect=AssertionError("No .env")):
                values = runpy.run_module(INTEGRATION_PROFILE, run_name="config._integration_discovery")
            settings.configure(**{key: value for key, value in values.items() if key.isupper()})
        django.setup()

    def real_runner(self, *, django_settings=False, **changes):
        self.configure_django()
        active_settings = self.settings()
        if django_settings:
            from django.conf import Settings, settings
            with patch.dict(os.environ, self.environment, clear=True):
                values = runpy.run_module(INTEGRATION_PROFILE, run_name="config._lifecycle_settings")
            module = ModuleType(INTEGRATION_PROFILE)
            module.__dict__.update(values)
            with patch.dict(sys.modules, {INTEGRATION_PROFILE: module}):
                loaded = Settings(INTEGRATION_PROFILE)
            self.enterContext(patch.object(settings, "_wrapped", loaded))
            active_settings = settings
        connections = ConnectionHandler({"default": self.config.database_settings()})
        opened = []
        leases = {}
        def driver(**parameters):
            self.assertEqual(parameters["port"], 3306)
            self.assertEqual(parameters["user"], self.config.user)
            database = parameters.get("database")
            self.assertIn(database, (None, self.config.database))
            result = DriverConnection(self.config, database, leases, sessions=opened, **changes)
            result.connection_id = 701 + len(opened)
            opened.append(result)
            return result
        self.enterContext(patch.dict(os.environ, self.environment, clear=True))
        # Keep the exact approved object, as in a real profile import.
        self.config = active_settings.INTEGRATION_TEST_CONFIG
        self.enterContext(patch.object(integration, "settings", active_settings))
        self.enterContext(patch.object(guarded, "settings", active_settings))
        self.enterContext(patch.object(integration, "connections", connections))
        self.enterContext(patch.object(guarded, "connections", connections))
        self.enterContext(patch.object(BaseDatabaseWrapper, "connect", REAL_CONNECT))
        self.enterContext(patch("django.db.backends.base.base.RAN_DB_VERSION_CHECK", set()))
        driver_mock = self.enterContext(patch("MySQLdb.connect", side_effect=driver))
        migrate = self.enterContext(patch.object(guarded, "call_command"))
        self.addCleanup(connections.close_all)
        return self.runner(), connections, opened, driver_mock, migrate

    def test_real_django_nested_media_overrides_keep_authorized_connection(self):
        from django.conf import settings
        from django.test import override_settings
        runner, connections, opened, _, _ = self.real_runner(django_settings=True)
        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            with override_settings(MEDIA_ROOT=str(self.media / "fixture")):
                self.assertIsNone(settings.SETTINGS_MODULE)
                with override_settings(ROOT_URLCONF="config.urls"):
                    with connections["default"].cursor() as cursor:
                        cursor.execute("INSERT INTO notifications_notification (id) VALUES (1)")
            self.assertEqual(settings.SETTINGS_MODULE, INTEGRATION_PROFILE)
            return 0
        with patch("django.test.runner.DiscoverRunner.run_tests", execute):
            self.assertEqual(runner.run_tests(["notifications.tests"]), 0)
        self.assertTrue(all(item.closed for item in opened))

    def test_reconnect_initializes_read_committed_before_runtime_verification(self):
        runner, connections, opened, _, _ = self.real_runner(startup_isolation="REPEATABLE-READ")
        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            connection = connections["default"]
            connection.close()
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
            self.assertEqual(connection.connection.isolation, "READ-COMMITTED")
            self.assertFalse(opened[0].closed)
            self.assertNotEqual(connection.connection.connection_id, instance._lock_owner)
            return 0
        with patch("django.test.runner.DiscoverRunner.run_tests", execute):
            self.assertEqual(runner.run_tests(["notifications.tests"]), 0)
        self.assertEqual(len(opened), 3)
        self.assertTrue(all(item.closed for item in opened))

    def test_bootstrap_permission_cannot_escape_initialization_or_change_sql(self):
        from concurrent.futures import ThreadPoolExecutor
        runner, connections, _, _, _ = self.real_runner(startup_isolation="REPEATABLE-READ")
        sql = "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED"
        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            connection = connections["default"]
            connection.connection.isolation = "REPEATABLE-READ"
            statement = Mock()
            with self.assertRaises(UnsafeTestTarget):
                instance._guard_execute(statement, sql, None, False, {"connection": connection})
            instance._initializing.connection = connection
            try:
                for query, parameters, many in (("DELETE FROM django_content_type", None, False),
                                                (sql + "; DELETE FROM django_content_type", None, False),
                                                (sql, (), False), (sql, None, True)):
                    with self.subTest(query=query), self.assertRaises(UnsafeTestTarget):
                        instance._guard_execute(statement, query, parameters, many, {"connection": connection})
                # A thread cannot borrow another thread's initialization marker.
                with ThreadPoolExecutor(max_workers=1) as pool, self.assertRaises(UnsafeTestTarget):
                    pool.submit(instance._guard_execute, statement, sql, None, False,
                                {"connection": connection}).result(timeout=10)
            finally:
                instance._initializing.connection = None
            statement.assert_not_called()
            return 0
        with patch("django.test.runner.DiscoverRunner.run_tests", execute):
            self.assertEqual(runner.run_tests(["notifications.tests"]), 0)

    def test_initialization_still_rejects_target_identity_or_lock_loss(self):
        runner, connections, _, _, _ = self.real_runner()
        original = DriverCursor.fetchone
        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            connection = connections["default"]
            connection.connection.isolation = "REPEATABLE-READ"
            instance._initializing.connection = connection
            statement = Mock()
            try:
                for field, value in ((0, str(uuid4())), (1, "wrong-host"), (2, 3308),
                                     (3, "other@127.0.0.1"), (4, "gardens_training"), (None, None)):
                    def changed(cursor):
                        query = cursor.calls[-1][0]
                        if query == IDENTITY_SQL and field is not None:
                            row = list(original(cursor))
                            row[field] = value
                            return tuple(row)
                        if query.startswith("SELECT IS_USED_LOCK") and field is None:
                            return (None,)
                        return original(cursor)
                    with patch.object(DriverCursor, "fetchone", changed), self.assertRaises(UnsafeTestTarget):
                        instance._guard_execute(statement,
                            "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED", None, False,
                            {"connection": connection})
                with patch.dict(os.environ, {"MYSQL_TEST_ALLOW_RESET": "unapproved"}), self.assertRaises(UnsafeTestTarget):
                    instance._guard_execute(statement,
                        "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED", None, False,
                        {"connection": connection})
                with patch.object(connection, "alias", "unapproved"), self.assertRaises(UnsafeTestTarget):
                    instance._guard_execute(statement,
                        "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED", None, False,
                        {"connection": connection})
            finally:
                instance._initializing.connection = None
            statement.assert_not_called()
            return 0
        with patch("django.test.runner.DiscoverRunner.run_tests", execute), self.assertRaisesRegex(
            UnsafeTestTarget, "ownership was lost",
        ):
            runner.run_tests(["notifications.tests"])

    def test_initialization_must_actually_establish_read_committed(self):
        runner, connections, opened, _, _ = self.real_runner(startup_isolation="REPEATABLE-READ")
        def ignored_isolation(cursor, sql, params=None):
            # Simulate a driver/server accepting but not applying SET.
            fixtures.DriverCursor.execute(cursor, sql, params)
        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            connections["default"].close()
            with patch.object(DriverCursor, "execute", ignored_isolation):
                with connections["default"].cursor() as cursor:
                    cursor.execute("SELECT 42")
        with patch("django.test.runner.DiscoverRunner.run_tests", execute), self.assertRaises(UnsafeTestTarget):
            runner.run_tests(["notifications.tests"])
        self.assertFalse(any(sql == "SELECT 42" for item in opened for sql, _ in item.calls))
        self.assertTrue(all(item.closed for item in opened))

    def test_preinitialization_identity_mode_is_limited_to_owned_integration_schema(self):
        cursor = Mock()
        row = list(identity(self.config, self.config.database))
        row[6] = "REPEATABLE-READ"
        cursor.fetchone.return_value = tuple(row)
        with self.assertRaises(UnsafeTestTarget):
            verify_identity(cursor, self.config, self.config.database)
        self.assertFalse(verify_identity(cursor, self.config, self.config.database, initializing=True))
        for config, database in ((self.config, None),
                                 (fixtures.DisposableConfig(**vars(self.config)), self.config.database)):
            with self.assertRaises(UnsafeTestTarget):
                verify_identity(cursor, config, database, initializing=True)
        row[6] = "unrecognized-isolation"
        cursor.fetchone.return_value = tuple(row)
        with self.assertRaises(UnsafeTestTarget):
            verify_identity(cursor, self.config, self.config.database, initializing=True)

    def test_connection_failure_can_recover_without_losing_guard_or_lock(self):
        import MySQLdb
        runner, connections, opened, _, _ = self.real_runner(startup_isolation="REPEATABLE-READ")
        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            connection = connections["default"]
            connection.close()
            with patch("MySQLdb.connect", side_effect=MySQLdb.OperationalError(2013, self.config.password)):
                with self.assertRaisesRegex(UnsafeTestTarget, "mysql_error_code=2013") as caught:
                    connection.cursor()
                self.assertNotIn(self.config.password, str(caught.exception))
            self.assertIsNone(instance._initializing.connection)
            with connection.cursor() as cursor:
                cursor.execute("SELECT 42")
            self.assertEqual(connection.execute_wrappers.count(instance._guard_execute), 1)
            return 0
        with patch("django.test.runner.DiscoverRunner.run_tests", execute):
            self.assertEqual(runner.run_tests(["notifications.tests"]), 0)
        self.assertTrue(all(item.closed for item in opened))

    def test_connection_diagnostics_never_stringify_errors_or_leak_messages(self):
        import MySQLdb
        from django.db import OperationalError
        class UnprintableError(RuntimeError):
            def __str__(self):
                raise AssertionError("Do not stringify connection exceptions")
        for error, expected_code in ((UnprintableError(self.config.password), None),
                                     (MySQLdb.OperationalError(1045, self.config.password), 1045),
                                     (OperationalError(2013, self.config.secret_key), 2013),
                                     (MySQLdb.OperationalError(self.config.password), None),
                                     (MySQLdb.OperationalError(True, self.config.password), None)):
            connection = Mock()
            connection.close.side_effect = UnprintableError(self.config.secret_key)
            message = str(guarded.connection_failure(connection, error, "server_identity"))
            self.assertIn(f"mysql_error_code={expected_code}", message)
            self.assertIn("stage=server_identity", message)
            self.assertIn("stage=connection_close", message)
            self.assertNotIn(self.config.password, message)
            self.assertNotIn(self.config.secret_key, message)

    def test_notification_deadline_fixture_stays_valid_at_timezone_boundaries(self):
        import ast
        from datetime import datetime, timedelta, timezone as dt_timezone
        from django.db.models import F, Q
        from django.utils import timezone
        self.configure_django()
        from training.models import TrainingAssignment
        tree = ast.parse((self.root / "api/v1/test_notifications.py").read_text(encoding="utf-8"))
        case = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "NotificationAPITests")
        method = next(node for node in case.body if isinstance(node, ast.FunctionDef)
                      and node.name == "test_list_server_side_filtering_search_and_pagination")
        deadlines = [node.value for node in method.body if isinstance(node, ast.Assign)
                     and ast.unparse(node.targets[0]) == "self.assignment.due_at"]
        constraint = next(item for item in TrainingAssignment._meta.constraints if item.name == "assignment_due_order")
        self.assertEqual(constraint.condition, Q(due_at__isnull=True) | Q(due_at__gte=F("assigned_at")))
        self.assertEqual(len(deadlines), 2)
        for zone in ("UTC", "Asia/Kolkata"):
            for hour, minute in ((0, 1), (18, 29), (18, 31)):
                with self.subTest(zone=zone, hour=hour, minute=minute), timezone.override(zone):
                    now = datetime(2026, 11, 23, hour, minute, tzinfo=dt_timezone.utc)
                    assigned = now - timedelta(minutes=5)
                    fixture = SimpleNamespace(now=assigned, assignment=SimpleNamespace(assigned_at=assigned))
                    values = [eval(compile(ast.Expression(node), "<notification-fixture>", "eval"),
                                   {"__builtins__": {}, "timedelta": timedelta, "self": fixture}) for node in deadlines]
                    self.assertTrue(all(value >= assigned for value in values))
                    self.assertLess(values[1], now)

    def test_real_django_testcase_and_transactioncase_write_and_flush(self):
        from django.test import override_settings
        runner, connections, opened, _, _ = self.real_runner(django_settings=True, startup_isolation="REPEATABLE-READ")
        from django.contrib.contenttypes.models import ContentType
        outer = self

        class FixtureCase(TestCase):
            @classmethod
            def setUpClass(cls):
                override = override_settings(MEDIA_ROOT=str(outer.media / "fixture"))
                override.enable()
                cls.addClassCleanup(override.disable)
                super().setUpClass()

            @classmethod
            def setUpTestData(cls):
                cls.row = ContentType.objects.create(app_label="offline", model="fixture")

            def test_write(self):
                outer.assertEqual(self.row.pk, 1)
                ContentType.objects.create(app_label="offline", model="method")

            def test_validation_rollback(self):
                from django.core.exceptions import ValidationError
                from django.db import transaction
                with self.assertRaises(ValidationError), transaction.atomic():
                    ContentType.objects.create(app_label="offline", model="invalid")
                    raise ValidationError("Synthetic model constraint failure")

        class FlushCase(TransactionTestCase):
            def setUp(self):
                self.enterContext(override_settings(MEDIA_ROOT=str(outer.media / "transaction")))
                ContentType.objects.create(app_label="offline", model="transaction")

            def test_write(self):
                ContentType.objects.create(app_label="offline", model="flush")

        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            connections["default"].features.__dict__["supports_transactions"] = True
            suite = unittest.TestSuite([FixtureCase("test_validation_rollback"),
                                       FixtureCase("test_write"), FlushCase("test_write")])
            result = unittest.TestResult()
            suite.run(result)
            outer.assertEqual(result.testsRun, 3)
            outer.assertEqual(result.errors, [])
            outer.assertEqual(result.failures, [])
            return 0

        # Exercise actual TestCase atomics, ORM inserts, MySQL introspection and
        # the actual flush command. Only the DB-API and post-migrate callbacks
        # are faked; no real schema, migrations or application fixtures exist.
        for module in ("django.db", "django.db.transaction", "django.test.testcases",
                       "django.db.models.sql.query", "django.db.models.query", "django.db.models.base",
                       "django.core.management.commands.flush"):
            self.enterContext(patch(module + ".connections", connections))
        with patch.object(DriverConnection, "rollback", create=True), patch.object(
            DriverConnection, "commit", create=True
        ), patch("django.core.management.commands.flush.emit_post_migrate_signal") as post_migrate, patch(
            "django.test.runner.DiscoverRunner.run_tests", execute
        ):
            self.assertEqual(runner.run_tests(["notifications.tests"]), 0)
        statements = [sql for item in opened for sql, _ in item.calls]
        self.assertEqual(sum(sql.startswith("INSERT INTO") for sql in statements), 5)
        self.assertTrue(any("information_schema.tables" in sql for sql in statements))
        self.assertIn("DELETE FROM `django_content_type`;", statements)
        self.assertFalse(any(sql.startswith(("DROP", "TRUNCATE")) for sql in statements))
        post_migrate.assert_called_once()
        self.assertTrue(all(item.closed for item in opened))

    def test_real_settings_overrides_cannot_redirect_or_replace_approval(self):
        from django.conf import settings
        from django.test import override_settings
        runner, connections, _, _, _ = self.real_runner(django_settings=True)
        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            changes = (
                {"SETTINGS_MODULE": None}, {"SETTINGS_MODULE": "config.qa_settings"},
                {"SETTINGS_MODULE": INTEGRATION_PROFILE},
                {"INTEGRATION_TEST_CONFIG": replace(self.config)},
                {"INTEGRATION_TEST_CONFIG": replace(self.config, owner=uuid4().hex)},
                {"TEST_RUNNER": "django.test.runner.DiscoverRunner"},
                {"DATABASES": {"default": {**self.config.database_settings(), "NAME": "gardens_training"}}},
                {"DATABASES": {"default": self.config.database_settings(), "extra": self.config.database_settings()}},
                {"DATABASE_ROUTERS": [object()]},
                {"MIGRATION_MODULES": {"notifications": None}},
            )
            for change in changes:
                with self.subTest(keys=list(change)), override_settings(**change), self.assertRaises(UnsafeTestTarget):
                    guarded.require_authorized_connection(connections["default"])
            with override_settings(MEDIA_ROOT=str(self.media / "fixture")):
                settings._wrapped._deleted.add("SETTINGS_MODULE")
                with self.assertRaises(UnsafeTestTarget):
                    guarded.require_authorized_connection(connections["default"])
            for name in self.environment:
                with self.subTest(missing=name), patch.dict(os.environ, {}, clear=False):
                    del os.environ[name]
                    with self.assertRaises(UnsafeTestTarget):
                        guarded.require_authorized_connection(connections["default"])
            return 0
        with self.assertWarns(UserWarning), patch("django.test.runner.DiscoverRunner.run_tests", execute):
            self.assertEqual(runner.run_tests(["notifications.tests"]), 0)

    def test_manual_settings_or_counterfeit_holder_cannot_claim_profile(self):
        from django.conf import LazySettings, UserSettingsHolder
        manual = LazySettings()
        manual.configure(**vars(self.settings()))
        with self.assertRaises(UnsafeTestTarget):
            validate_settings(manual)
        counterfeit = LazySettings()
        counterfeit._wrapped = UserSettingsHolder(self.settings())
        with self.assertRaises(UnsafeTestTarget):
            validate_settings(counterfeit)

    def test_open_connection_rechecks_every_authoritative_identity_field(self):
        runner, connections, opened, _, _ = self.real_runner()
        original = DriverCursor.fetchone
        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            for index, value in enumerate((str(uuid4()), "other-server", 3308,
                                           "other@127.0.0.1", "gardens_training_qa_isolated")):
                def changed(cursor):
                    if cursor.calls[-1][0] == IDENTITY_SQL:
                        row = list(identity(self.config, cursor.database))
                        row[index] = value
                        return tuple(row)
                    return original(cursor)
                with self.subTest(index=index), patch.object(DriverCursor, "fetchone", changed):
                    with self.assertRaises(UnsafeTestTarget), connections["default"].cursor() as cursor:
                        cursor.execute("DELETE FROM notifications_notification")
            return 0
        with patch("django.test.runner.DiscoverRunner.run_tests", execute):
            self.assertEqual(runner.run_tests(["notifications.tests"]), 0)
        self.assertFalse(any(sql.startswith("DELETE") for item in opened for sql, _ in item.calls))

    def test_migration_failures_and_interrupts_retain_schema_and_release_connections(self):
        for failure in (RuntimeError("synthetic migration failure"), KeyboardInterrupt()):
            with self.subTest(failure=type(failure).__name__):
                self.prepare_target()
                runner, _, opened, _, migrate = self.real_runner()
                migrate.side_effect = failure
                def execute(instance, labels, **kwargs):
                    instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
                with patch("django.test.runner.DiscoverRunner.run_tests", execute), self.assertRaises(type(failure)):
                    runner.run_tests(["notifications.tests"])
                self.assertEqual(runner.phase, "finished")
                self.assertIsNone(guarded._active_runner)
                self.assertTrue(all(item.closed for item in opened))
                statements = [sql for item in opened for sql, _ in item.calls]
                self.assertEqual(sum(sql.startswith("CREATE DATABASE") for sql in statements), 1)
                self.assertFalse(any(sql.startswith(("DROP", "TRUNCATE")) for sql in statements))

    def test_failed_test_and_connection_interruption_release_maintenance(self):
        for interrupted in (False, True):
            with self.subTest(interrupted=interrupted):
                self.prepare_target()
                runner, connections, opened, _, _ = self.real_runner()
                def execute(instance, labels, **kwargs):
                    instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
                    if interrupted:
                        # Reconnect failure must be sanitized and must not reuse
                        # the old raw handle or fall back to a different schema.
                        connections["default"].close()
                        with patch("MySQLdb.connect", side_effect=OSError(self.config.password)):
                            with connections["default"].cursor():
                                self.fail("Interrupted connection must not be usable")
                    return 1
                with patch("django.test.runner.DiscoverRunner.run_tests", execute):
                    if interrupted:
                        with self.assertRaises(UnsafeTestTarget) as caught:
                            runner.run_tests(["notifications.tests"])
                        self.assertNotIn(self.config.password, str(caught.exception))
                    else:
                        self.assertEqual(runner.run_tests(["notifications.tests"]), 1)
                self.assertIsNone(guarded._active_runner)
                self.assertTrue(all(item.closed for item in opened))

    def test_nested_runner_cannot_replace_active_ownership(self):
        runner, _, opened, _, _ = self.real_runner()
        other = self.runner()
        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            original = (runner.stack, runner.config, runner._owner_thread, runner._maintenance_connection,
                        runner._lock_owner, runner._initializing, sys.stdout, sys.stderr)
            for nested in (runner, other):
                with self.assertRaisesRegex(UnsafeTestTarget, "already owns"):
                    nested.preflight_only()
                with self.assertRaisesRegex(UnsafeTestTarget, "already owns"):
                    nested.run_tests(["notifications.tests"])
            self.assertIs(guarded._active_runner, runner)
            self.assertEqual(runner.phase, "running")
            self.assertEqual(original, (runner.stack, runner.config, runner._owner_thread,
                                       runner._maintenance_connection, runner._lock_owner, runner._initializing,
                                       sys.stdout, sys.stderr))
            self.assertFalse(opened[0].closed)
            return 0
        with patch("django.test.runner.DiscoverRunner.run_tests", execute):
            self.assertEqual(runner.run_tests(["notifications.tests"]), 0)

    def test_concurrent_runner_cannot_take_process_ownership(self):
        from concurrent.futures import ThreadPoolExecutor
        runner, _, _, _, _ = self.real_runner()
        other = self.runner()
        stdout, stderr = io.StringIO(), io.StringIO()

        def finish_stream(output):
            # Stream restoration and final redaction are both under ownership.
            self.assertIs(sys.stdout, stdout)
            self.assertIs(sys.stderr, stderr)
            with ThreadPoolExecutor(max_workers=1) as pool, self.assertRaisesRegex(UnsafeTestTarget, "already owns"):
                pool.submit(other.preflight_only).result(timeout=10)
            finish(output)

        def execute(instance, labels, **kwargs):
            streams = (sys.stdout, sys.stderr)
            with ThreadPoolExecutor(max_workers=1) as pool, self.assertRaisesRegex(UnsafeTestTarget, "already owns"):
                pool.submit(other.run_tests, labels).result(timeout=10)
            self.assertEqual((sys.stdout, sys.stderr), streams)
            print(self.config.password, end="")
            sys.stderr.write(self.config.secret_key)
            self.assertIs(guarded._active_runner, runner)
            return 0

        finish = integration._PrivateOutput.finish
        with patch("sys.stdout", stdout), patch("sys.stderr", stderr):
            with patch.object(integration._PrivateOutput, "finish", finish_stream), patch(
                "django.test.runner.DiscoverRunner.run_tests", execute,
            ):
                self.assertEqual(runner.run_tests(["notifications.tests"]), 0)
            self.assertEqual(stdout.getvalue(), "[REDACTED]")
            self.assertEqual(stderr.getvalue(), "[REDACTED]")
            self.assertEqual(other.preflight_only(), 0)

    def test_real_maintenance_gate_and_preflight_never_create_or_migrate(self):
        runner, _, opened, driver, migrate = self.real_runner()
        self.assertEqual(runner.preflight_only(), 0)
        self.assertEqual(driver.call_count, 1)
        self.assertEqual(opened[0].database, None)
        self.assertTrue(opened[0].closed)
        self.assertFalse(any(sql.startswith(("CREATE", "DROP", "ALTER", "DELETE")) for sql, _ in opened[0].calls))
        self.assertFalse((self.media / integration.EXECUTION_RECEIPT).exists())
        migrate.assert_not_called()
        self.assertIsNone(guarded._active_runner)

    def test_real_lifecycle_creates_once_migrates_owned_database_and_retains_it(self):
        runner, connections, opened, driver, migrate = self.real_runner()
        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            self.assertEqual([item.database for item in opened], [None, self.config.database])
            self.assertFalse(opened[0].closed)
            with connections["default"].cursor() as cursor:
                cursor.execute("SELECT 1")
            instance.teardown_databases(self.config.database)
            return 0
        with patch("django.test.runner.DiscoverRunner.run_tests", execute):
            self.assertEqual(runner.run_tests(["notifications.tests"]), 0)
        self.assertEqual(driver.call_count, 2)
        statements = [sql for item in opened for sql, _ in item.calls]
        self.assertEqual(sum(sql.startswith("CREATE DATABASE") for sql in statements), 1)
        self.assertFalse(any(sql.startswith(("DROP", "TRUNCATE")) for sql in statements))
        migrate.assert_called_once_with("migrate", database="default", interactive=False, verbosity=0, run_syncdb=True)
        self.assertTrue(all(item.closed for item in opened))

    def test_real_collision_or_create_race_never_reuses_drops_or_migrates(self):
        for changes in ({"collision": True}, {"create_error": True}):
            with self.subTest(changes=changes):
                self.prepare_target()
                runner, _, opened, _, migrate = self.real_runner(**changes)
                def execute(instance, labels, **kwargs):
                    return instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
                with patch("django.test.runner.DiscoverRunner.run_tests", execute), self.assertRaises(RuntimeError):
                    runner.run_tests(["notifications.tests"])
                migrate.assert_not_called()
                self.assertTrue(all(item.closed for item in opened))
                self.assertFalse(any(sql.startswith("DROP") for item in opened for sql, _ in item.calls))

    def test_uncertain_schema_creation_consumes_identity_even_if_no_schema_is_visible(self):
        from MySQLdb import OperationalError

        runner, _, opened, driver, migrate = self.real_runner()
        execute_sql = DriverCursor.execute
        receipt = self.media / integration.EXECUTION_RECEIPT

        def lose_create_response(cursor, sql, params=None):
            execute_sql(cursor, sql, params)
            if sql.startswith("CREATE DATABASE"):
                self.assertTrue(receipt.is_file())
                cursor.session.close()
                raise OperationalError(2013, self.config.password)

        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())

        with patch.object(DriverCursor, "execute", lose_create_response), patch(
            "django.test.runner.DiscoverRunner.run_tests", execute,
        ), self.assertRaises(UnsafeTestTarget):
            runner.run_tests(["notifications.tests"])
        self.assertEqual(json.loads(receipt.read_text(encoding="ascii")), {
            "owner": self.owner, "schema": self.config.database, "account": self.config.account,
        })
        migrate.assert_not_called()
        with self.assertRaises(UnsafeTestTarget):
            self.runner().run_tests(["notifications.tests"])
        with self.assertRaises(UnsafeTestTarget):
            self.runner().preflight_only()
        driver.assert_called_once()
        self.assertTrue(opened[0].closed)

    def test_open_connection_cannot_flush_after_approval_or_lock_loss(self):
        runner, connections, opened, _, _ = self.real_runner()
        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            worker = connections["default"]
            statement = Mock()
            del os.environ["MYSQL_TEST_ALLOW_RESET"]
            with self.assertRaises(UnsafeTestTarget):
                instance._guard_execute(statement, "DELETE FROM notifications_notification", None, False, {"connection": worker})
            os.environ["MYSQL_TEST_ALLOW_RESET"] = "owned-schema-only"
            original = DriverCursor.fetchone
            def lost_lock(cursor):
                if cursor.calls[-1][0].startswith("SELECT IS_USED_LOCK"):
                    return (None,)
                return original(cursor)
            with patch.object(DriverCursor, "fetchone", lost_lock), self.assertRaisesRegex(UnsafeTestTarget, "advisory lock"):
                instance._guard_execute(statement, "DELETE FROM notifications_notification", None, False, {"connection": worker})
            statement.assert_not_called()
            return 0
        with patch("django.test.runner.DiscoverRunner.run_tests", execute), self.assertRaisesRegex(
            UnsafeTestTarget, "ownership was lost",
        ):
            runner.run_tests(["notifications.tests"])
        self.assertTrue(all(item.closed for item in opened))

    def test_commit_and_autocommit_require_live_ownership_but_rollback_does_not(self):
        runner, connections, opened, _, _ = self.real_runner()

        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            connection = connections["default"]
            connection.set_autocommit(False)
            connection.commit()
            connection.set_autocommit(True)
            connection.set_autocommit(False)
            raw = opened[1]
            before = list(raw.transactions)
            with patch.dict(os.environ, {"MYSQL_TEST_ALLOW_RESET": "unapproved"}):
                with self.assertRaises(UnsafeTestTarget):
                    connection.commit()
            opened[0].close()
            for operation in (connection.commit, lambda: connection.set_autocommit(True)):
                with self.assertRaisesRegex(UnsafeTestTarget, "advisory lock"):
                    operation()
            self.assertEqual(raw.transactions, before)
            connection.rollback()
            connection.close()
            self.assertEqual(raw.transactions, [*before, ("rollback",)])
            return 0

        with patch("django.test.runner.DiscoverRunner.run_tests", execute), self.assertRaisesRegex(
            UnsafeTestTarget, "ownership was lost",
        ):
            runner.run_tests(["notifications.tests"])
        self.assertTrue(all(session.closed for session in opened))

    def test_worker_cannot_write_on_a_replaced_session_after_authorization(self):
        runner, connections, opened, _, _ = self.real_runner()
        sql = "DELETE FROM django_content_type"

        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            connection = connections["default"]
            raw = opened[1]
            verify = runner._verify_owned_connection
            replacement = DriverConnection(self.config, self.config.database, raw.leases)
            replacement.connection_id = 991

            def replace(worker, **options):
                authorized = verify(worker, **options)
                raw.close()
                worker.connection = replacement
                return authorized

            with connection.cursor() as cursor, patch.object(runner, "_verify_owned_connection", replace):
                with self.assertRaisesRegex(UnsafeTestTarget, "connection was replaced"):
                    cursor.execute(sql)
            self.assertFalse(any(query == sql for query, _ in raw.calls + replacement.calls))
            return 0

        with patch("django.test.runner.DiscoverRunner.run_tests", execute), self.assertRaises(UnsafeTestTarget):
            runner.run_tests(["notifications.tests"])

    def test_worker_fails_closed_when_its_lease_is_held_by_a_different_session(self):
        runner, connections, opened, _, _ = self.real_runner()
        write = "DELETE FROM django_content_type"

        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            connection = connections["default"]
            worker_lock = f"{self.config.lock_prefix}{self.owner}:{opened[1].connection_id}"
            opened[1].leases[worker_lock] = opened[0].connection_id
            with connection.cursor() as cursor, self.assertRaisesRegex(UnsafeTestTarget, "no longer holds"):
                cursor.execute(write)
            return 0

        with patch("django.test.runner.DiscoverRunner.run_tests", execute), self.assertRaises(UnsafeTestTarget):
            runner.run_tests(["notifications.tests"])
        self.assertFalse(any(sql == write for sql, _ in opened[1].calls))

    def test_maintenance_loss_during_admitted_dispatch_fails_run_and_stops_later_work(self):
        runner, connections, opened, _, _ = self.real_runner()
        write = "DELETE FROM django_content_type"
        later_write = "DELETE FROM notifications_notification"
        driver_execute = DriverCursor.execute

        def drop_maintenance(cursor, sql, params=None):
            if sql == write:
                opened[0].close()
            return driver_execute(cursor, sql, params)

        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            with connections["default"].cursor() as cursor:
                with self.assertRaisesRegex(UnsafeTestTarget, "outcome may be durable"):
                    cursor.execute(write)
                with self.assertRaisesRegex(UnsafeTestTarget, "already lost"):
                    cursor.execute(later_write)
            return 0

        with patch.object(DriverCursor, "execute", drop_maintenance), patch(
            "django.test.runner.DiscoverRunner.run_tests", execute,
        ), self.assertRaises(UnsafeTestTarget):
            runner.run_tests(["notifications.tests"])
        self.assertEqual([sql for sql, _ in opened[1].calls if sql.startswith("DELETE")], [write])
        self.assertTrue(all(session.closed for session in opened))

    def test_detected_loss_disqualifies_a_verified_but_not_admitted_worker(self):
        from concurrent.futures import ThreadPoolExecutor

        runner, connections, opened, driver, _ = self.real_runner()
        write = "DELETE FROM django_content_type"
        verified, release = threading.Event(), threading.Event()

        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            owner_connection = connections["default"]
            owner_connection.set_autocommit(False)
            verify = instance._verify_owned_connection

            def pause_after_verification(connection, **options):
                raw = verify(connection, **options)
                if getattr(instance._initializing, "connection", None) is None and connection is not owner_connection:
                    # Pause the ORM statement only, after the new raw session is bound.
                    verified.set()
                    self.assertTrue(release.wait(10))
                return raw

            def worker():
                try:
                    with connections["default"].cursor() as cursor:
                        with self.assertRaisesRegex(UnsafeTestTarget, "already lost"):
                            cursor.execute(write)
                finally:
                    connections.close_all()

            with patch.object(instance, "_verify_owned_connection", pause_after_verification), ThreadPoolExecutor(
                max_workers=1,
            ) as pool:
                pending = pool.submit(worker)
                try:
                    self.assertTrue(verified.wait(10))
                    opened[0].close()
                    with self.assertRaisesRegex(UnsafeTestTarget, "advisory lock"):
                        owner_connection.commit()
                    owner_connection.rollback()
                    owner_connection.close()
                    opened_count = driver.call_count
                    with self.assertRaisesRegex(UnsafeTestTarget, "already lost"):
                        owner_connection.ensure_connection()
                    self.assertEqual(driver.call_count, opened_count)
                finally:
                    release.set()
                pending.result(timeout=10)
            return 0

        with patch("django.test.runner.DiscoverRunner.run_tests", execute), self.assertRaisesRegex(
            UnsafeTestTarget, "target is quarantined",
        ):
            runner.run_tests(["notifications.tests"])
        self.assertNotIn(("commit",), opened[1].transactions)
        self.assertIn(("rollback",), opened[1].transactions)
        self.assertFalse(any(sql == write for session in opened for sql, _ in session.calls))

    def test_maintenance_wrapper_cannot_reopen_after_its_session_closes(self):
        runner, _, opened, driver, _ = self.real_runner()

        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            maintenance = instance._maintenance_connection
            maintenance.close()
            with self.assertRaisesRegex(UnsafeTestTarget, "cannot reconnect"):
                maintenance.ensure_connection()
            return 0

        with patch("django.test.runner.DiscoverRunner.run_tests", execute), self.assertRaises(UnsafeTestTarget):
            runner.run_tests(["notifications.tests"])
        self.assertEqual(driver.call_count, 2)
        self.assertTrue(all(session.closed for session in opened))

    def test_transport_loss_during_commit_quarantines_even_if_lease_probe_succeeds(self):
        from MySQLdb import OperationalError

        runner, connections, opened, _, _ = self.real_runner()

        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            connection = connections["default"]
            connection.set_autocommit(False)
            with patch.object(opened[1], "commit", side_effect=OperationalError(2013, self.config.password)) as commit:
                with self.assertRaisesRegex(UnsafeTestTarget, "outcome may be durable"):
                    connection.commit()
                with self.assertRaisesRegex(UnsafeTestTarget, "already lost"):
                    connection.commit()
                commit.assert_called_once()
            connection.rollback()
            return 0

        with patch("django.test.runner.DiscoverRunner.run_tests", execute), self.assertRaisesRegex(
            UnsafeTestTarget, "target is quarantined",
        ):
            runner.run_tests(["notifications.tests"])
        self.assertIn(("rollback",), opened[1].transactions)

    def test_admitted_operations_overlap_across_mysql_sessions(self):
        from concurrent.futures import ThreadPoolExecutor

        runner, connections, opened, _, _ = self.real_runner()
        write = "DELETE FROM django_content_type"
        overlap = threading.Barrier(2, timeout=10)
        driver_execute = DriverCursor.execute

        def overlap_writes(cursor, sql, params=None):
            if sql == write:
                overlap.wait()
            return driver_execute(cursor, sql, params)

        def worker():
            try:
                with connections["default"].cursor() as cursor:
                    cursor.execute(write)
            finally:
                connections.close_all()

        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            with ThreadPoolExecutor(max_workers=2) as pool:
                writes = [pool.submit(worker) for _ in range(2)]
                for result in writes:
                    result.result(timeout=10)
            return 0

        with patch.object(DriverCursor, "execute", overlap_writes), patch(
            "django.test.runner.DiscoverRunner.run_tests", execute,
        ):
            self.assertEqual(runner.run_tests(["notifications.tests"]), 0)
        writers = [session.connection_id for session in opened if any(sql == write for sql, _ in session.calls)]
        self.assertEqual(len(set(writers)), 2)

    def test_lost_coordinator_does_not_allow_same_account_takeover_with_active_worker(self):
        runner, _, opened, _, _ = self.real_runner()

        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            opened[0].close()
            probe = DriverConnection(self.config, None, opened[0].leases, sessions=opened)
            probe.connection_id = 903
            opened.append(probe)
            try:
                # Model a different process with no receipt. Only server metadata
                # is shared. The surviving worker still prevents preflight.
                with probe.cursor() as cursor, self.assertRaisesRegex(UnsafeTestTarget, "active connection"):
                    preflight(cursor, self.config)
            finally:
                probe.close()
            self.assertFalse(any(sql.startswith("CREATE DATABASE") for sql, _ in probe.calls))
            return 0

        with patch("django.test.runner.DiscoverRunner.run_tests", execute), self.assertRaisesRegex(
            UnsafeTestTarget, "target is quarantined",
        ):
            runner.run_tests(["notifications.tests"])

    def test_open_worker_at_shutdown_prevents_success_and_leaves_execution_receipt(self):
        from concurrent.futures import ThreadPoolExecutor

        runner, connections, opened, _, _ = self.real_runner()
        ready, release = threading.Event(), threading.Event()
        write = "DELETE FROM django_content_type"

        def worker():
            connection = connections["default"]
            try:
                with connection.cursor() as cursor:
                    cursor.execute("SELECT 1")
                ready.set()
                self.assertTrue(release.wait(10))
                with self.assertRaises(UnsafeTestTarget), connection.cursor() as cursor:
                    cursor.execute(write)
                with self.assertRaises(UnsafeTestTarget):
                    connection.commit()
                connection.rollback()
                connection.close()
                with self.assertRaises(UnsafeTestTarget):
                    connection.ensure_connection()
            finally:
                connections.close_all()

        with ThreadPoolExecutor(max_workers=1) as pool:
            def execute(instance, labels, **kwargs):
                instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
                pending = pool.submit(worker)
                self.addCleanup(pending.result, timeout=10)
                self.assertTrue(ready.wait(10))
                return 0

            try:
                with patch("django.test.runner.DiscoverRunner.run_tests", execute), self.assertRaisesRegex(
                    UnsafeTestTarget, "target is quarantined",
                ):
                    runner.run_tests(["notifications.tests"])
            finally:
                release.set()
        self.assertTrue((self.media / integration.EXECUTION_RECEIPT).is_file())
        self.assertTrue(all(session.closed for session in opened))
        self.assertFalse(any(sql == write for session in opened for sql, _ in session.calls))
        self.assertNotIn(("commit",), opened[-1].transactions)

    def test_maintenance_thread_and_connection_ownership_are_narrow(self):
        runner = self.runner()
        self.authorize(runner)
        runner.phase = "preflight"
        connection = SimpleNamespace(alias="__no_db__", settings_dict=self.config.database_settings())
        connection.settings_dict["NAME"] = None
        self.assertTrue(runner.validate_connection(connection))
        with self.assertRaises(UnsafeTestTarget):
            runner.validate_connection(SimpleNamespace(alias="__no_db__", settings_dict=connection.settings_dict))
        with patch.object(integration.threading, "get_ident", return_value=-1), self.assertRaises(UnsafeTestTarget):
            runner.validate_connection(connection)

    def test_worker_thread_connections_use_the_same_guarded_identity(self):
        from concurrent.futures import ThreadPoolExecutor
        runner, connections, opened, _, _ = self.real_runner()
        def execute(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            def worker():
                try:
                    with connections["default"].cursor() as cursor:
                        cursor.execute("SELECT 1")
                finally:
                    connections.close_all()
            with ThreadPoolExecutor(max_workers=1) as pool:
                pool.submit(worker).result(timeout=10)
            return 0
        with patch("django.test.runner.DiscoverRunner.run_tests", execute):
            self.assertEqual(runner.run_tests(["notifications.tests"]), 0)
        self.assertEqual([item.database for item in opened], [None, self.config.database, self.config.database])
        self.assertTrue(all(item.closed for item in opened))

    def test_actual_django_mysql_flush_uses_delete_without_drop_privilege(self):
        from django.core.management.color import no_style
        from .role_requirement_test_backend.base import DatabaseWrapper
        connection = DatabaseWrapper(self.config.database_settings(), alias="default")
        statements = connection.ops.sql_flush(no_style(), ["notifications_notification"], reset_sequences=False)
        self.assertIn("DELETE FROM `notifications_notification`;", statements)
        self.assertFalse(any("TRUNCATE" in sql or "DROP" in sql for sql in statements))
        self.assertIn("SET FOREIGN_KEY_CHECKS = 1;", statements)

    def test_incomplete_skipped_or_expected_failure_results_cannot_pass(self):
        runner = self.runner()
        runner.checkpoint_test_count = 2
        result = dict(testsRun=2, skipped=[], expectedFailures=[], failures=[], errors=[], unexpectedSuccesses=[])
        for changes in ({"testsRun": 1}, {"skipped": [(Mock(), "skip")]}, {"expectedFailures": [(Mock(), "expected")]}):
            with self.assertRaises(UnsafeTestTarget):
                runner.suite_result(None, SimpleNamespace(**{**result, **changes}))
        self.assertEqual(runner.suite_result(None, SimpleNamespace(**result)), 0)

    def test_output_redacts_secrets_split_across_writes(self):
        stream = io.StringIO()
        output = integration._PrivateOutput(stream, (self.config.password, self.config.secret_key))
        output.write(self.config.password[:8])
        output.flush()
        output.write(self.config.password[8:] + "\n" + self.config.secret_key)
        output.finish()
        self.assertEqual(stream.getvalue(), "[REDACTED]\n[REDACTED]")

    def test_output_redacts_escaped_values_and_jwt_strings(self):
        stream = io.StringIO()
        value = "synthetic\\quoted'password"
        output = integration._PrivateOutput(stream, (value,))
        output.write(repr(value) + "\n" + 'eyJhbGciOiJIUzI1NiJ9.payload.signature' + "\n")
        output.finish()
        self.assertNotIn(value, stream.getvalue())
        self.assertNotIn(repr(value)[1:-1], stream.getvalue())
        self.assertIn("[REDACTED TOKEN]", stream.getvalue())

    def test_direct_runner_redacts_credentials_without_the_cli_wrapper(self):
        runner, _, _, driver, migrate = self.real_runner()
        output = io.StringIO()
        def execute(instance, labels, **kwargs):
            print(instance.config.password)
            return 0
        with patch("django.test.runner.DiscoverRunner.run_tests", execute), patch("sys.stdout", output):
            self.assertEqual(runner.run_tests(["notifications.tests"]), 0)
        self.assertEqual(output.getvalue(), "[REDACTED]\n")
        driver.assert_not_called()
        migrate.assert_not_called()

    def test_direct_authorization_failure_redacts_output_and_propagated_traceback(self):
        for method in ("run_tests", "preflight_only"):
            for boundary in ("validate_settings", "validate_config_approval"):
                runner = self.runner()
                output, errors = io.StringIO(), io.StringIO()

                def reject(*args, **kwargs):
                    print(self.config.password)
                    try:
                        raise RuntimeError(self.config.secret_key)
                    except RuntimeError:
                        traceback.print_exc()
                    raise UnsafeTestTarget(self.config.password + self.config.secret_key)

                with self.subTest(method=method, boundary=boundary), patch.dict(
                    os.environ, self.environment, clear=True
                ), patch.object(integration, "validate_settings", return_value=self.config), patch.object(
                    integration, boundary, side_effect=reject
                ), patch.object(runner, "_run_guarded") as execute, patch.object(
                    integration, "preflight"
                ) as inspect, patch("sys.stdout", output), patch("sys.stderr", errors):
                    try:
                        if method == "run_tests":
                            runner.run_tests(["notifications.tests"])
                        else:
                            runner.preflight_only()
                    except UnsafeTestTarget:
                        # A direct caller may print the escaped exception too.
                        traceback.print_exc()
                    else:
                        self.fail("Authorization failure must stop execution")
                combined = output.getvalue() + errors.getvalue()
                self.assertNotIn(self.config.password, combined)
                self.assertNotIn(self.config.secret_key, combined)
                self.assertIn("[REDACTED]", combined)
                execute.assert_not_called()
                inspect.assert_not_called()

    def test_cli_rejects_runner_settings_keepdb_and_parallel_overrides_without_prompt(self):
        for arguments in (["--keepdb"], ["--testrunner=django.test.runner.DiscoverRunner"],
                          ["--settings=config.qa_settings"], ["--parallel=2"],
                          ["--password=synthetic-cli-value"]):
            errors = io.StringIO()
            with self.subTest(argument_name=arguments[0].split("=")[0]), patch.object(integration.getpass, "getpass") as password, patch("sys.stderr", errors), self.assertRaises(SystemExit):
                integration.main(arguments)
            password.assert_not_called()
            self.assertNotIn("synthetic-cli-value", errors.getvalue())

    def test_cli_checks_missing_approval_before_prompt(self):
        values = dict(self.environment)
        del values["MYSQL_TEST_ALLOW_CREATE"]
        with patch.dict(os.environ, values, clear=True), patch.object(
            integration, "settings", SimpleNamespace(configured=False)
        ), patch.object(integration.getpass, "getpass") as password, self.assertRaises(UnsafeTestTarget):
            integration.main(["--preflight-only"])
        password.assert_not_called()

    def test_cli_failure_diagnostics_do_not_stringify_untrusted_errors(self):
        from django.db import OperationalError

        class UnprintableTarget(UnsafeTestTarget):
            def __str__(self):
                raise AssertionError("Untrusted message must not be read")

        for error, expected in (
            (UnprintableTarget(self.config.password), "category=safety-check"),
            (OperationalError(1213, self.config.password), "mysql_error_code=1213"),
            (OperationalError(self.config.secret_key), "category=database"),
        ):
            output = io.StringIO()
            with self.subTest(expected=expected), patch.object(integration, "main", side_effect=error), patch(
                "sys.stdout", output,
            ):
                self.assertEqual(integration._cli(), 1)
            self.assertIn(expected, output.getvalue())
            self.assertNotIn(self.config.password, output.getvalue())
            self.assertNotIn(self.config.secret_key, output.getvalue())

    def test_cli_hidden_password_redaction_and_process_environment_restoration(self):
        values = {key: value for key, value in self.environment.items()
                  if key not in {"MYSQL_TEST_PASSWORD", "MYSQL_TEST_SECRET_KEY"}}
        runner = Mock()
        output = io.StringIO()
        supplied = "synthetic-hidden-input-only"
        def inspect_preflight(labels, *, preflight_only):
            self.assertEqual(labels, [])
            self.assertIs(preflight_only, True)
            self.assertEqual(os.environ["MYSQL_TEST_PASSWORD"], supplied)
            self.assertEqual(os.environ["DJANGO_SETTINGS_MODULE"], INTEGRATION_PROFILE)
            print(supplied)
            print(os.environ["MYSQL_TEST_SECRET_KEY"])
            return 0
        runner._run_owned.side_effect = inspect_preflight
        with patch.dict(os.environ, values, clear=True), patch.object(
            integration, "settings", SimpleNamespace(configured=False)
        ), patch.object(integration.sys.stdin, "isatty", return_value=True), patch.object(
            integration.getpass, "getpass", return_value=supplied
        ) as password, patch("django.setup"), patch(
            "django.test.utils.get_runner", return_value=Mock(return_value=runner)
        ), patch("sys.stdout", output):
            self.assertFalse(integration.main(["--preflight-only"]))
            password.assert_called_once()
            self.assertNotIn("MYSQL_TEST_PASSWORD", os.environ)
            self.assertNotIn("MYSQL_TEST_SECRET_KEY", os.environ)
            self.assertNotIn("DJANGO_SETTINGS_MODULE", os.environ)
        self.assertNotIn(supplied, output.getvalue())
        self.assertEqual(output.getvalue(), "[REDACTED]\n[REDACTED]\n")
        runner.run_tests.assert_not_called()

    def test_cli_refuses_noninteractive_or_echo_fallback_password_entry(self):
        import warnings
        values = {key: value for key, value in self.environment.items() if key != "MYSQL_TEST_PASSWORD"}
        def warning(*args):
            warnings.warn("Synthetic hidden input unavailable", getpass.GetPassWarning)
            self.fail("Must not continue after an echo warning")
        import getpass
        for terminal in (False, True):
            with self.subTest(terminal=terminal), patch.dict(os.environ, values, clear=True), patch.object(
                integration, "settings", SimpleNamespace(configured=False)
            ), patch.object(integration.sys.stdin, "isatty", return_value=terminal), patch.object(
                integration.getpass, "getpass", side_effect=warning
            ) as password, self.assertRaises((UnsafeTestTarget, getpass.GetPassWarning)):
                integration.main(["--preflight-only"])
            if not terminal:
                password.assert_not_called()

    def test_runner_override_migrate_and_flush_reject_before_real_driver_in_subprocess(self):
        script = textwrap.dedent("""
            import sys
            from unittest.mock import patch
            from config.role_requirement_test_config import UnsafeTestTarget
            with patch('MySQLdb.connect', side_effect=AssertionError('Driver forbidden')) as driver, \
                 patch('socket.socket.connect', side_effect=AssertionError('Network forbidden')) as network, \
                 patch('django.db.migrations.executor.MigrationExecutor.migrate', side_effect=AssertionError('Migration forbidden')) as migrate:
                from django.core.management import execute_from_command_line
                try:
                    execute_from_command_line(['manage.py', *sys.argv[1:], '--settings=config.integration_test_settings', '--noinput', '--verbosity=0'])
                except UnsafeTestTarget:
                    pass
                else:
                    raise AssertionError('Unauthorized command was accepted')
                for guard in (driver, network, migrate):
                    guard.assert_not_called()
                print('REJECTED BEFORE DRIVER OR MUTATION')
        """)
        commands = (["test", "api.v1.test_notifications", "--testrunner=django.test.runner.DiscoverRunner"],
                    ["test", "api.v1.test_notifications", "--testrunner=django.test.runner.DiscoverRunner", "--keepdb"],
                    ["migrate"], ["flush"])
        for command in commands:
            environment = {**os.environ, **self.environment}
            environment.pop("DJANGO_SETTINGS_MODULE", None)
            with self.subTest(command=command):
                result = subprocess.run([sys.executable, *(["-O"] if sys.flags.optimize else []), "-B", "-c", script, *command], env=environment,
                                        cwd=self.root, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("REJECTED BEFORE DRIVER OR MUTATION", result.stdout)


if __name__ == "__main__":
    unittest.main()
