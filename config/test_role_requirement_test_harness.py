"""Database-free: python -B -m unittest config.test_role_requirement_test_harness.

All MySQL connection entry points are blocked. Fake cursors exercise guard
decisions and SQL ordering, not real server isolation or migration behavior.
"""

from contextlib import contextmanager, ExitStack
from copy import deepcopy
from dataclasses import replace
import ast
import os
from pathlib import Path
import runpy
import secrets
import stat
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, Mock, patch
from uuid import uuid4

from django.test import SimpleTestCase, TestCase, TransactionTestCase

from .role_requirement_test_config import (
    DisposableConfig, IDENTITY_SQL, PROFILE, PROTECTED_DATABASES, REQUIRED_PRIVILEGES,
    RUNNER, UnsafeTestTarget, mark_verified, preflight, require_verified_database,
    validate_database, validate_settings, verify_grants, verify_identity,
)
from .role_requirement_test_runner import CONCURRENCY_IDS, RoleRequirementTestRunner, TEST_MODULES


class FakeCursor:
    def __init__(self, config, *, collision=False, lock=1, others=0, create_error=False):
        self.config = config
        self.collision, self.lock, self.others = collision, lock, others
        self.create_error = create_error
        self.calls = []

    def execute(self, sql, params=None):
        self.calls.append((sql, params))
        if self.create_error and sql.startswith("CREATE DATABASE"):
            raise RuntimeError("Simulated create collision")

    def fetchone(self):
        sql = self.calls[-1][0]
        if sql == IDENTITY_SQL:
            return identity(self.config, None)
        if "GET_LOCK" in sql:
            return (self.lock,)
        if "PROCESSLIST" in sql:
            return (self.others,)
        if "SCHEMATA" in sql:
            return (self.config.database,) if self.collision else None
        raise AssertionError("Unexpected fake query")

    def fetchall(self):
        return grants(self.config)


def identity(config, database):
    return (config.server_uuid, config.server_hostname, 3308, config.account,
            database, "8.0.40", "READ-COMMITTED", "InnoDB", 0)


def grants(config, *, partial_revokes=False):
    user, host = config.account.split("@")
    recipient = f"`{user}`@`{host}`"
    schema = config.database if partial_revokes else config.database.replace("_", r"\_")
    return [(f"GRANT USAGE ON *.* TO {recipient}",),
            (f"GRANT {', '.join(sorted(REQUIRED_PRIVILEGES))} ON `{schema}`.* TO {recipient}",)]


class DisposableHarnessTests(unittest.TestCase):
    concurrency_methods = (
        "test_duplicate_batches_serialize_and_emit_one_notification_per_assignment",
        "test_disabling_first_prevents_batch_without_partial_writes",
        "test_batch_first_completes_before_requirement_is_disabled",
        "test_manual_first_remains_pinned_and_batch_skips_it",
        "test_batch_first_causes_manual_duplicate_validation_not_overwrite",
        "test_concurrent_requirement_creation_preserves_unique_pair",
    )

    def concurrency_suite(self, methods=None):
        methods = self.concurrency_methods if methods is None else methods
        case = type("RoleRequirementConcurrencyTests", (SimpleTestCase,), {
            "__module__": "api.v1.test_role_requirement_concurrency",
            "tags": {"role_requirement_isolated_mysql"},
            **{method: lambda self: None for method in methods},
        })
        return unittest.defaultTestLoader.loadTestsFromTestCase(case)

    def setUp(self):
        self.owner = uuid4().hex
        self.media = Path(tempfile.gettempdir()).resolve() / f"gn-rr-media-{self.owner}"
        repository = Path(__file__).resolve().parents[1]
        if self.media.is_relative_to(repository):
            self.fail("A temporary media fixture outside the repository is required.")
        self.media.mkdir()
        self.addCleanup(shutil.rmtree, self.media)
        user = "gn_rr_" + self.owner[:16]
        self.environment = {
            "RR_TEST_DATABASE": f"test_gn_rr_20261113_{self.owner}",
            "RR_TEST_APPROVED_DATABASE": f"test_gn_rr_20261113_{self.owner}",
            "RR_TEST_OWNER": self.owner, "RR_TEST_HOST": "127.0.0.1", "RR_TEST_PORT": "3308",
            "RR_TEST_SERVER_UUID": "12345678-1234-1234-1234-123456789abc",
            "RR_TEST_SERVER_HOSTNAME": "disposable-only", "RR_TEST_USER": user,
            "RR_TEST_ACCOUNT": user + "@localhost", "RR_TEST_PASSWORD": "unit-test-only-never-used",
            "RR_TEST_SECRET_KEY": secrets.token_urlsafe(64), "RR_TEST_MEDIA_ROOT": str(self.media),
            "RR_TEST_ISOLATION": "read committed", "RR_TEST_ALLOW_CREATE": "create-new-disposable-schema",
            "RR_TEST_EXCLUSIVE_OWNER": self.owner,
        }
        self.config = DisposableConfig.from_environment(self.environment)
        self.addCleanup(mark_verified, None)
        self.connection_guards = []
        for target in ("MySQLdb.connect", "socket.socket.connect",
                       "django.db.backends.base.base.BaseDatabaseWrapper.connect"):
            guard = patch(target, side_effect=AssertionError("Real database/network access forbidden."))
            self.connection_guards.append(guard.start())
            self.addCleanup(guard.stop)

    def tearDown(self):
        for guard in self.connection_guards:
            guard.assert_not_called()

    def settings(self, **changes):
        values = dict(
            ROLE_REQUIREMENT_TEST_CONFIG=self.config, SETTINGS_MODULE=PROFILE, TEST_RUNNER=RUNNER,
            DATABASES={"default": self.config.database_settings()}, DATABASE_ROUTERS=[],
            MIGRATION_MODULES={}, MEDIA_ROOT=self.media,
        )
        values.update(changes)
        return SimpleNamespace(**values)

    def test_valid_explicit_configuration_and_standalone_read_only_import(self):
        with patch.dict(os.environ, self.environment, clear=True), \
             patch("dotenv.load_dotenv", side_effect=AssertionError("No .env access")), \
             patch("pathlib.Path.mkdir", side_effect=AssertionError("No provisioning")):
            values = runpy.run_module(PROFILE, run_name="config._rr_settings_unit_test")
        self.assertEqual(values["DATABASES"]["default"]["NAME"], self.config.database)
        self.assertEqual(values["DATABASES"]["default"]["TEST"]["NAME"], self.config.database)
        self.assertEqual(values["SIMPLE_JWT"]["SIGNING_KEY"], self.environment["RR_TEST_SECRET_KEY"])
        self.assertIs(validate_settings(self.settings(), setup=True), self.config)
        self.assertNotIn(self.config.password, repr(self.config))
        self.assertNotIn(self.config.secret_key, repr(self.config))

    def test_missing_configuration_does_not_fall_back_to_generic_db_environment(self):
        required_keys = set(self.environment) - {"RR_TEST_ALLOW_CREATE", "RR_TEST_EXCLUSIVE_OWNER"}
        for key in required_keys:
            with self.subTest(key=key):
                values = {**self.environment, "DB_NAME": "gardens_training", "DB_USER": "root"}
                del values[key]
                with self.assertRaises(UnsafeTestTarget):
                    DisposableConfig.from_environment(values)

    def test_protected_and_non_guid_names_rejected(self):
        for name in (*PROTECTED_DATABASES, "test_other", "test_gn_rr_20261113_not-a-guid",
                     f"test_gn_rr_20269999_{self.owner}"):
            with self.subTest(name=name), self.assertRaises(UnsafeTestTarget):
                DisposableConfig.from_environment({**self.environment, "RR_TEST_DATABASE": name})
        for name in PROTECTED_DATABASES:
            with self.assertRaises(UnsafeTestTarget):
                config = replace(self.config, database=name)
                validate_database(config, config.database_settings())

    def test_approval_owner_endpoint_identity_and_account_are_explicit(self):
        bad_values = {
            "RR_TEST_APPROVED_DATABASE": "test_other", "RR_TEST_OWNER": uuid4().hex,
            "RR_TEST_HOST": "localhost", "RR_TEST_PORT": "3306", "RR_TEST_SERVER_UUID": "unknown",
            "RR_TEST_USER": "root", "RR_TEST_ACCOUNT": self.config.user + "@%",
            "RR_TEST_ISOLATION": "repeatable read", "RR_TEST_PASSWORD": "",
            "RR_TEST_SECRET_KEY": "weak", "RR_TEST_OPTIONS": "redirect",
        }
        for key, value in bad_values.items():
            with self.subTest(key=key), self.assertRaises(UnsafeTestTarget):
                DisposableConfig.from_environment({**self.environment, key: value})

    def test_media_must_be_new_empty_owner_named_and_outside_repository(self):
        for path in (Path.cwd(), self.media.parent, Path("relative")):
            with self.subTest(path=path), self.assertRaises(UnsafeTestTarget):
                DisposableConfig.from_environment({**self.environment, "RR_TEST_MEDIA_ROOT": str(path)})
        (self.media / "occupied.txt").write_text("synthetic fixture", encoding="utf-8")
        with self.assertRaisesRegex(UnsafeTestTarget, "new empty"):
            DisposableConfig.from_environment(self.environment)

    def test_media_validation_works_without_python_312_is_junction(self):
        class LegacyPath(type(Path())):
            @property
            def is_junction(self):
                raise AttributeError("Path.is_junction is unavailable in Python 3.11")

        with patch("config.role_requirement_test_config.Path", LegacyPath):
            self.assertEqual(DisposableConfig.from_environment(self.environment).media, self.media)

    def test_media_lstat_rejects_symlinks_and_windows_reparse_points(self):
        original = Path.lstat
        for mode, attributes in ((stat.S_IFLNK, 0), (stat.S_IFDIR, 0x400)):
            def metadata(path):
                if path == self.media:
                    return SimpleNamespace(st_mode=mode, st_file_attributes=attributes)
                return original(path)

            with self.subTest(mode=mode), patch.object(Path, "lstat", metadata), \
                 self.assertRaisesRegex(UnsafeTestTarget, "Linked media paths"):
                DisposableConfig.from_environment(self.environment)

    def test_unreadable_media_metadata_fails_closed(self):
        original = Path.lstat

        def metadata(path):
            if path == self.media:
                raise PermissionError("Synthetic unreadable metadata")
            return original(path)

        with patch.object(Path, "lstat", metadata), \
             self.assertRaisesRegex(UnsafeTestTarget, "inspect media"):
            DisposableConfig.from_environment(self.environment)

    def test_aliases_routers_settings_and_connection_overrides_rejected(self):
        for values in (
            {"DATABASES": {"default": self.config.database_settings(), "other": self.config.database_settings()}},
            {"DATABASE_ROUTERS": ["unexpected.Router"]}, {"MIGRATION_MODULES": {"training": None}},
            {"TEST_RUNNER": "django.test.runner.DiscoverRunner"}, {"SETTINGS_MODULE": "config.settings"},
            {"MEDIA_ROOT": Path.cwd()}, {"ROLE_REQUIREMENT_TEST_CONFIG": None},
        ):
            with self.subTest(values=list(values)), self.assertRaises(UnsafeTestTarget):
                validate_settings(self.settings(**values), setup=True)
        for mutate in (
            lambda db: db.update(NAME="gardens_training"),
            lambda db: db["TEST"].update(NAME="test_gardens_training"),
            lambda db: db["TEST"].update(MIRROR="other"),
            lambda db: db["TEST"].update(MIGRATE=False),
            lambda db: db["OPTIONS"].update(read_default_file="unapproved.cnf"),
            lambda db: db.update(HOST="other", PORT="3306"),
        ):
            db = deepcopy(self.config.database_settings())
            mutate(db)
            with self.assertRaises(UnsafeTestTarget):
                validate_database(self.config, db)

    def test_incorrect_live_identity_rejected(self):
        row = identity(self.config, self.config.database)
        for index, wrong in ((0, "wrong-uuid"), (1, "wrong-host"), (2, 3306), (3, "root@localhost"),
                             (4, "gardens_training"), (5, "10.6-MariaDB"),
                             (6, "REPEATABLE-READ"), (7, "MyISAM")):
            changed = list(row)
            changed[index] = wrong
            cursor = Mock()
            cursor.fetchone.return_value = tuple(changed)
            with self.subTest(index=index), self.assertRaises(UnsafeTestTarget):
                verify_identity(cursor, self.config, self.config.database)

    def test_grants_allow_only_exact_schema_without_drop_or_wildcard_scope(self):
        for partial in (False, True):
            verify_grants(grants(self.config, partial_revokes=partial), self.config, partial)
        valid = grants(self.config)
        for rows in ([], [("GRANT ALL PRIVILEGES ON *.* TO `root`@`localhost`",)],
                     [valid[0], (valid[1][0].replace("SELECT,", "DROP, SELECT,"),)],
                     [valid[0], (valid[1][0].replace(r"\_", "_"),)],
                     [valid[0], (valid[1][0] + " WITH GRANT OPTION",)],
                     [valid[0], ("GRANT `a_role` TO `someone`@`localhost`",)]):
            with self.subTest(rows=len(rows)), self.assertRaises(UnsafeTestTarget):
                verify_grants(rows, self.config, False)

    def test_preflight_checks_all_conditions_before_any_schema_write(self):
        cursor = FakeCursor(self.config)
        preflight(cursor, self.config)
        self.assertEqual(cursor.calls[0][0], IDENTITY_SQL)
        self.assertFalse(any(sql.startswith(("CREATE", "DROP", "ALTER")) for sql, _ in cursor.calls))

    def test_collision_busy_lock_and_competing_account_connection_fail_closed(self):
        for changes in ({"collision": True}, {"lock": 0}, {"others": 1}):
            with self.subTest(changes=changes), self.assertRaises(UnsafeTestTarget):
                preflight(FakeCursor(self.config, **changes), self.config)

    def runner(self, **changes):
        options = dict(keepdb=True, interactive=False, parallel=1, enable_faulthandler=False)
        options.update(changes)
        runner = RoleRequirementTestRunner(**options)
        runner.config = self.config
        return runner

    def test_discovery_rejects_flush_based_tests_before_database_setup(self):
        class FlushCase(TransactionTestCase):
            def runTest(self):
                pass

        FlushCase.__module__ = "api.v1.test_role_requirements"
        suite = unittest.TestSuite([FlushCase()])
        with patch("django.test.runner.DiscoverRunner.build_suite", return_value=suite), \
             self.assertRaisesRegex(UnsafeTestTarget, "flush"):
            self.runner().build_suite()

    def test_discovery_rejects_missing_required_concurrency_scenario(self):
        suite = self.concurrency_suite(self.concurrency_methods[:-1])
        with patch("django.test.runner.DiscoverRunner.build_suite", return_value=suite), \
             self.assertRaisesRegex(UnsafeTestTarget, "six required concurrency"):
            self.runner().build_suite()

    def test_ci_ordinary_suite_has_explicit_guarded_test_exclusion(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn(
            "python manage.py test --exclude-tag=role_requirement_isolated_mysql", workflow,
        )

    def test_discovery_accepts_transaction_rollback_and_owned_fixture_tests(self):
        for base in (TestCase, SimpleTestCase):
            case = type("AllowedCase", (base,), {
                "__module__": "api.v1.test_role_requirements",
                "runTest": lambda self: None,
            })
            suite = unittest.TestSuite([case(), self.concurrency_suite()])
            with self.subTest(base=base.__name__), \
                 patch("django.test.runner.DiscoverRunner.build_suite", return_value=suite):
                self.assertIs(self.runner().build_suite(), suite)

    def test_discovery_rejects_duplicate_extra_or_untagged_concurrency_scenarios(self):
        for problem in ("duplicate", "extra", "untagged"):
            suite = self.concurrency_suite()
            tests = list(suite)
            if problem == "duplicate":
                tests.append(tests[0])
            elif problem == "extra":
                suite.addTest(unittest.FunctionTestCase(lambda: None))
                tests = list(suite)
            else:
                type(tests[0]).tags = set()
            with self.subTest(problem=problem), \
                 patch("django.test.runner.DiscoverRunner.build_suite", return_value=unittest.TestSuite(tests)), \
                 self.assertRaises(UnsafeTestTarget):
                self.runner().build_suite()

    def test_result_rejects_skips_expected_failures_and_incomplete_execution(self):
        runner = self.runner()
        runner.checkpoint_test_count = 6
        values = dict(testsRun=6, skipped=[], expectedFailures=[],
                      failures=[], errors=[], unexpectedSuccesses=[])
        for changes in ({"testsRun": 5}, {"skipped": [(Mock(), "Skipped")]},
                        {"expectedFailures": [(Mock(), "Expected failure")]}):
            with self.subTest(changes=changes), self.assertRaises(UnsafeTestTarget):
                runner.suite_result(None, SimpleNamespace(**{**values, **changes}))
        self.assertEqual(runner.suite_result(None, SimpleNamespace(**values)), 0)
        self.assertEqual(runner.suite_result(None, SimpleNamespace(**{
            **values, "errors": [(Mock(), "Real failure")],
        })), 1)

    def test_real_discovery_excludes_exactly_six_and_dedicated_runner_includes_them(self):
        # Configure only synthetic settings when invoked via plain unittest.
        # An existing Django test invocation retains its own settings unchanged.
        import django
        from django.conf import settings
        from django.test.runner import DiscoverRunner
        from django.test.utils import iter_test_cases

        if not settings.configured:
            with patch.dict(os.environ, self.environment, clear=True), \
                 patch("dotenv.load_dotenv", side_effect=AssertionError("No .env access")):
                values = runpy.run_module(PROFILE, run_name="config._rr_discovery_settings")
            settings.configure(**{key: value for key, value in values.items() if key.isupper()})
        django.setup()
        options = dict(verbosity=0, enable_faulthandler=False)
        all_tests = DiscoverRunner(**options).build_suite(TEST_MODULES)
        ordinary = DiscoverRunner(exclude_tags={"role_requirement_isolated_mysql"}, **options).build_suite(TEST_MODULES)
        all_ids = {test.id() for test in iter_test_cases(all_tests)}
        ordinary_ids = {test.id() for test in iter_test_cases(ordinary)}
        self.assertEqual(all_ids - ordinary_ids, CONCURRENCY_IDS)
        self.assertEqual(len(CONCURRENCY_IDS), 6)
        dedicated = RoleRequirementTestRunner(**options).build_suite(TEST_MODULES)
        self.assertEqual({test.id() for test in iter_test_cases(dedicated)}, all_ids)

    def test_required_ci_job_uses_strict_runner_and_failure_gate(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        isolated, gate = workflow.split("\n  role-requirement-mysql:\n", 1)[1].split("\n  required-checks:\n", 1)
        for text in (
            "--settings=config.role_requirement_test_settings",
            "--testrunner=config.role_requirement_test_runner.RoleRequirementTestRunner",
            "api.v1.test_role_requirements api.v1.test_role_requirement_concurrency",
            "--keepdb --noinput --parallel=1", "environment: disposable-mysql-tests",
            "approved-disposable-ci-only", "--port=3308", "--network host",
        ):
            self.assertIn(text, isolated)
        self.assertNotIn("continue-on-error", workflow)
        self.assertIn("needs: [test, role-requirement-mysql]", gate)
        self.assertIn("if: ${{ always() }}", gate)
        self.assertIn('test "$ORDINARY_RESULT" = success', gate)
        self.assertIn('test "$ISOLATED_RESULT" = success', gate)
        self.assertNotIn("DROP", isolated)

    def test_python_311_grammar_and_actual_concurrency_method_contract(self):
        root = Path(__file__).resolve().parents[1]
        for name in ("role_requirement_test_config.py", "role_requirement_test_runner.py",
                     "role_requirement_test_settings.py"):
            ast.parse((root / "config" / name).read_text(encoding="utf-8"), feature_version=(3, 11))
        tree = ast.parse((root / "api/v1/test_role_requirement_concurrency.py").read_text(encoding="utf-8"))
        case = next(node for node in tree.body if isinstance(node, ast.ClassDef)
                    and node.name == "RoleRequirementConcurrencyTests")
        self.assertEqual({node.name for node in case.body if isinstance(node, ast.FunctionDef)
                          and node.name.startswith("test_")}, set(self.concurrency_methods))
        tagged_classes = []
        for source in (root / "api").rglob("*.py"):
            for node in ast.walk(ast.parse(source.read_text(encoding="utf-8"))):
                if not isinstance(node, ast.ClassDef):
                    continue
                for decorator in node.decorator_list:
                    if (isinstance(decorator, ast.Call) and isinstance(decorator.func, ast.Name)
                            and decorator.func.id == "tag" and any(
                                isinstance(arg, ast.Constant) and arg.value == "role_requirement_isolated_mysql"
                                for arg in decorator.args)):
                        tagged_classes.append((source.name, node.name))
        self.assertEqual(tagged_classes, [("test_role_requirement_concurrency.py", "RoleRequirementConcurrencyTests")])

    def test_unsafe_runner_flags_and_missing_execution_approval_reject_before_connections(self):
        for changes in ({"keepdb": False}, {"interactive": True}, {"parallel": 2}, {"debug_sql": True},
                        {"exclude_tags": ["skip"]}):
            with self.subTest(changes=changes), patch.dict(os.environ, self.environment, clear=True), \
                 patch("config.role_requirement_test_runner.settings", self.settings()), \
                 patch("config.role_requirement_test_runner.connections") as connections:
                with self.assertRaises(UnsafeTestTarget):
                    self.runner(**changes).run_tests()
                connections.all.assert_not_called()
        for key in ("RR_TEST_ALLOW_CREATE", "RR_TEST_EXCLUSIVE_OWNER"):
            environment = dict(self.environment)
            del environment[key]
            with patch.dict(os.environ, environment, clear=True), \
                 patch("config.role_requirement_test_runner.settings", self.settings()), \
                 patch("config.role_requirement_test_runner.connections") as connections:
                with self.assertRaises(UnsafeTestTarget):
                    self.runner().run_tests()
                connections.all.assert_not_called()

    def test_wrong_worker_database_and_missing_preflight_rejected_before_cursor(self):
        connection = Mock(alias="default", vendor="mysql", settings_dict=self.config.database_settings())
        with self.assertRaises(UnsafeTestTarget):
            require_verified_database(connection, self.settings())
        connection.cursor.assert_not_called()
        mark_verified(self.config)
        connection.settings_dict["NAME"] = "test_gardens_training"
        with self.assertRaises(UnsafeTestTarget):
            require_verified_database(connection, self.settings())
        connection.cursor.assert_not_called()

    def test_ci_environment_does_not_replace_disposable_profile_or_preflight(self):
        connection = Mock(alias="default", vendor="mysql", settings_dict=self.config.database_settings())
        with patch.dict(os.environ, {"CI": "true", "GITHUB_ACTIONS": "true"}), \
             self.assertRaisesRegex(UnsafeTestTarget, "dedicated disposable test profile"):
            require_verified_database(connection, self.settings(ROLE_REQUIREMENT_TEST_CONFIG=None))
        connection.cursor.assert_not_called()
        with patch.dict(os.environ, {"CI": "true", "GITHUB_ACTIONS": "true"}), \
             self.assertRaisesRegex(UnsafeTestTarget, "preflight"):
            require_verified_database(connection, self.settings())
        connection.cursor.assert_not_called()

    def test_worker_rechecks_actual_selected_database_and_server(self):
        connection = Mock(alias="default", vendor="mysql", settings_dict=self.config.database_settings())
        cursor = connection.cursor.return_value.__enter__ = Mock(return_value=Mock())
        connection.cursor.return_value.__exit__ = Mock(return_value=False)
        cursor = cursor.return_value
        mark_verified(self.config)
        cursor.fetchone.return_value = identity(self.config, "gardens_training")
        with self.assertRaises(UnsafeTestTarget):
            require_verified_database(connection, self.settings())
        cursor.fetchone.return_value = identity(self.config, self.config.database)
        require_verified_database(connection, self.settings())

    def setup_runner(self, cursor, migrate):
        runner = self.runner()
        connection = MagicMock()
        connection.settings_dict = self.config.database_settings()
        connection.cursor.return_value.__enter__.return_value.fetchone.return_value = identity(self.config, self.config.database)

        @contextmanager
        def maintenance():
            yield cursor

        connection._nodb_cursor.side_effect = maintenance
        connections = MagicMock()
        connections.__getitem__.return_value = connection
        runner.stack = self.enterContext(ExitStack())
        self.enterContext(patch("config.role_requirement_test_runner.connections", connections))
        self.enterContext(patch("config.role_requirement_test_runner.settings", self.settings()))
        self.enterContext(patch("config.role_requirement_test_runner.call_command", migrate))
        return runner, connections

    def test_migration_starts_only_after_preflight_create_and_selected_database_verification(self):
        cursor = FakeCursor(self.config)
        migrate = Mock()
        runner, connections = self.setup_runner(cursor, migrate)

        def check_order(*args, **kwargs):
            self.assertTrue(cursor.calls[-1][0].startswith("CREATE DATABASE"))
            selected = connections["default"].cursor.return_value.__enter__.return_value
            selected.execute.assert_called_once_with(IDENTITY_SQL)
            selected.fetchone.assert_called_once_with()

        migrate.side_effect = check_order
        self.assertEqual(runner.setup_databases(aliases={"default": False}, serialized_aliases=set()), self.config.database)
        self.assertTrue(cursor.calls[-1][0].startswith("CREATE DATABASE"))
        migrate.assert_called_once_with("migrate", database="default", interactive=False, verbosity=0, run_syncdb=True)
        self.assertEqual(runner.phase, "running")

    def test_setup_never_migrates_colliding_or_uncreatable_schema(self):
        for changes in ({"collision": True}, {"create_error": True}):
            cursor = FakeCursor(self.config, **changes)
            migrate = Mock()
            runner, _ = self.setup_runner(cursor, migrate)
            with self.assertRaises(RuntimeError):
                runner.setup_databases(aliases={"default": False}, serialized_aliases=set())
            migrate.assert_not_called()
            self.assertFalse(any("DROP" in sql for sql, _ in cursor.calls))

    def test_migration_failure_and_teardown_never_delete_or_reuse_schema(self):
        cursor = FakeCursor(self.config)
        runner, connections = self.setup_runner(cursor, Mock(side_effect=RuntimeError("Simulated migration failure")))
        with self.assertRaisesRegex(RuntimeError, "Simulated migration failure"):
            runner.setup_databases(aliases={"default": False}, serialized_aliases=set())
        with patch("django.test.runner.DiscoverRunner.teardown_databases") as destroy:
            runner.teardown_databases(self.config.database)
        destroy.assert_not_called()
        connections.close_all.assert_called_once()
        self.assertFalse(any("DROP" in sql or "IF NOT EXISTS" in sql for sql, _ in cursor.calls))

    def test_connection_gate_rejects_redirect_before_calling_driver(self):
        runner = self.runner()
        runner.phase = "running"
        runner.original_connect = Mock()
        connection = Mock(alias="default", settings_dict=self.config.database_settings())
        connection.settings_dict["NAME"] = "gardens_training"
        with self.assertRaises(UnsafeTestTarget):
            runner.connect_checked(connection)
        runner.original_connect.assert_not_called()

    def test_selected_database_mismatch_prevents_migrations(self):
        migrate = Mock()
        runner, connections = self.setup_runner(FakeCursor(self.config), migrate)
        selected = connections["default"].cursor.return_value.__enter__.return_value
        selected.fetchone.return_value = identity(self.config, "gardens_training")
        with self.assertRaises(UnsafeTestTarget):
            runner.setup_databases(aliases={"default": False}, serialized_aliases=set())
        migrate.assert_not_called()

    def test_connection_gate_verifies_identity_and_closes_on_failure(self):
        runner = self.runner()
        runner.phase = "running"
        runner.original_connect = Mock()
        connection = Mock(alias="default", settings_dict=self.config.database_settings())
        connection.connection.cursor.return_value.fetchone.return_value = identity(self.config, self.config.database)
        runner.connect_checked(connection)
        runner.original_connect.assert_called_once_with(connection)
        connection.connection.cursor.return_value.close.assert_called_once_with()
        connection.connection.cursor.return_value.fetchone.return_value = identity(self.config, "test_gardens_training")
        with self.assertRaises(UnsafeTestTarget):
            runner.connect_checked(connection)
        connection.close.assert_called_once_with()

    def test_run_failure_releases_maintenance_context_and_verified_state_without_deletion(self):
        cursor = FakeCursor(self.config)
        migrate = Mock()
        runner, connections = self.setup_runner(cursor, migrate)
        connections.all.return_value = []
        closed = Mock()

        @contextmanager
        def maintenance():
            try:
                yield cursor
            finally:
                closed()

        connections["default"]._nodb_cursor.side_effect = maintenance

        def fail_after_setup(instance, labels, **kwargs):
            instance.setup_databases(aliases={"default": False}, serialized_aliases=set())
            raise RuntimeError("Simulated test failure")

        with patch.dict(os.environ, self.environment, clear=True), \
             patch("django.test.runner.DiscoverRunner.run_tests", fail_after_setup):
            with self.assertRaisesRegex(RuntimeError, "Simulated test failure"):
                runner.run_tests()
        closed.assert_called_once_with()
        connections.close_all.assert_called_once_with()
        worker = Mock(alias="default", vendor="mysql", settings_dict=self.config.database_settings())
        with self.assertRaises(UnsafeTestTarget):
            require_verified_database(worker, self.settings())
        worker.cursor.assert_not_called()


if __name__ == "__main__":
    unittest.main()
