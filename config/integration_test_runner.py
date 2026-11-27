"""Fresh-schema integration runner; provisioning and cleanup remain operator tasks."""
import argparse
from contextlib import ExitStack, contextmanager, redirect_stderr, redirect_stdout
import getpass
import json
import os
from pathlib import Path
import re
import secrets
import sys
import threading
from unittest.mock import patch
import warnings

from django.conf import settings
from django.db import Error as DjangoDatabaseError, connections
from django.db.backends.base.base import BaseDatabaseWrapper
from django.test.runner import DiscoverRunner
from django.test.utils import iter_test_cases
from MySQLdb import Error as DriverError

from . import role_requirement_test_runner as guarded
from .role_requirement_test_config import (
    IntegrationConfig, INTEGRATION_PROFILE, UnsafeTestTarget, preflight,
    validate_config_approval, validate_media, validate_settings, verify_identity,
    verify_no_other_sessions,
)


PROJECT_APPS = frozenset({
    "api", "accounts", "organization", "training", "notifications", "assessments",
    "certifications", "reports", "audit",
})

MYSQL_INITIALIZATION_READ = (
    "SELECT VERSION(), @@sql_mode, @@default_storage_engine, @@sql_auto_is_null, "
    "@@lower_case_table_names, CONVERT_TZ('2001-01-01 01:00:00', 'UTC', 'UTC') IS NOT NULL"
)
MYSQL_ISOLATION_STATEMENTS = frozenset({
    "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED",
    "SET SQL_AUTO_IS_NULL = 0; SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED",
})
EXECUTION_RECEIPT = ".gn-integration-execution.json"
MYSQL_TRANSPORT_LOSS = frozenset({2006, 2013, 2055})


def validate_labels(labels):
    if not labels or len(set(labels)) != len(labels):
        raise UnsafeTestTarget("Supply distinct, explicit project test labels.")
    for label in labels:
        parts = label.split(".")
        if (not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)+", label)
                or parts[0] not in PROJECT_APPS
                or not any(part == "tests" or part.startswith("test_") for part in parts[1:])
                or "test_role_requirement_concurrency" in parts):
            raise UnsafeTestTarget("Only explicit project test modules/classes/methods are supported.")
    return tuple(labels)


@contextmanager
def _reserve_process():
    # Use the strict runner's lock as well, so the two profiles cannot overlap.
    if not guarded._runner_lock.acquire(blocking=False):
        raise UnsafeTestTarget("Another guarded runner already owns this process.")
    try:
        yield
    finally:
        guarded._runner_lock.release()


class _OwnershipLost(UnsafeTestTarget):
    pass


class IntegrationTestRunner(guarded.GuardedMySQLRunner):
    def _authorize(self):
        self.config = validate_settings(settings, setup=True)
        if type(self.config) is not IntegrationConfig:
            raise UnsafeTestTarget("The integration profile is required.")
        validate_config_approval(os.environ, self.config)
        if self.keepdb or self.parallel != 1 or self.interactive or self.debug_sql or self.debug_mode or self.pdb:
            raise UnsafeTestTarget("Use --noinput --parallel=1; keepdb and SQL debugging are forbidden.")
        if self.tags or self.exclude_tags or self.test_name_patterns or self.shuffle or self.reverse:
            raise UnsafeTestTarget("Test filtering, shuffling and reversed ordering are forbidden.")
        if any(connection.connection is not None for connection in connections.all()):
            raise UnsafeTestTarget("Start a fresh process with no existing database connections.")
        self._owner_thread = threading.get_ident()
        self._maintenance_connection = None
        self._maintenance_session = None
        self._lock_owner = None
        self._initializing = threading.local()
        self._execution_requested = False
        self._admission_lock = threading.Lock()
        self._in_flight = 0
        self._ownership_lost = threading.Event()
        self._worker_sessions = {}

    def run_tests(self, test_labels=None, **kwargs):
        with _reserve_process():
            return self._run_owned(test_labels, **kwargs)

    def preflight_only(self):
        with _reserve_process():
            return self._run_owned(preflight_only=True)

    def _run_owned(self, labels=None, *, preflight_only=False, **kwargs):
        with self._private_output():
            if not preflight_only:
                labels = validate_labels(tuple(labels or ()))
            self._authorize_safely()
            self._execution_requested = not preflight_only
            try:
                if not preflight_only:
                    return self._run_guarded(labels, **kwargs)
                with self._guarded_lifecycle():
                    self.phase = "preflight"
                    cursor = self.stack.enter_context(connections["default"]._nodb_cursor())
                    preflight(cursor, self.config)
                    self.preflight_complete(cursor)
                self.log("Preflight passed: no schema created, migrated, reused or reset.")
                return 0
            except Exception as error:
                # Even a direct caller may report this exception after redaction ends.
                if self._ownership_lost.is_set():
                    raise _OwnershipLost("Database ownership was lost; the target is quarantined.") from None
                raise UnsafeTestTarget("Integration execution failed. " + _public_diagnostic(error)) from None

    @contextmanager
    def _guarded_lifecycle(self):
        if type(self) is not IntegrationTestRunner or guarded._active_runner is not None:
            raise UnsafeTestTarget("The configured integration runner must own execution.")
        with ExitStack() as stack:
            self.stack = stack
            self.phase = "discovery"
            self.original_connect = BaseDatabaseWrapper.connect
            stack.enter_context(patch.object(guarded, "_active_runner", self))
            stack.enter_context(patch.object(BaseDatabaseWrapper, "connect",
                                             lambda connection: self.connect_checked(connection)))
            guarded.mark_verified(None)
            try:
                yield
            finally:
                with self._admission_lock:
                    self.phase = "finished"
                    if self._in_flight:
                        self._ownership_lost.set()
                guarded.mark_verified(None)
                connections.close_all()
            if self._ownership_lost.is_set():
                raise _OwnershipLost("The run lost database ownership; its target is quarantined.")
            self._verify_maintenance_at_finish()

    @contextmanager
    def _admit(self):
        # This is the process-local admission point. Keep network I/O outside
        # the mutex so already-admitted operations in different sessions can overlap.
        with self._admission_lock:
            if self._ownership_lost.is_set() or self.phase not in {"preflight", "migrating", "running"}:
                raise _OwnershipLost("The run has already lost database ownership or ended.")
            self._in_flight += 1
        try:
            yield
        finally:
            with self._admission_lock:
                self._in_flight -= 1

    def _lost(self, message):
        with self._admission_lock:
            self._ownership_lost.set()
        return _OwnershipLost(message)

    def _authorize_safely(self):
        try:
            self._authorize()
        except Exception:
            # Direct callers can print the exception after redirection exits.
            # Do not propagate credential-bearing messages or exception chains.
            raise UnsafeTestTarget("Integration authorization failed; no preflight or tests executed.") from None

    @contextmanager
    def _private_output(self):
        # Authorization can fail before self.config is assigned. Seed redaction
        # from the private process environment without initializing settings.
        values = [os.environ.get("MYSQL_TEST_PASSWORD"), os.environ.get("MYSQL_TEST_SECRET_KEY")]
        configs = [getattr(self, "config", None)]
        if getattr(settings, "configured", True):
            configs.append(getattr(settings, "INTEGRATION_TEST_CONFIG", None))
        for config in configs:
            if type(config) is IntegrationConfig:
                values.extend((config.password, config.secret_key))
        stdout = _PrivateOutput(sys.stdout, values)
        stderr = _PrivateOutput(sys.stderr, stdout.values)
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                yield
        finally:
            stdout.finish()
            stderr.finish()

    def build_suite(self, test_labels=None, **kwargs):
        validate_labels(tuple(test_labels or ()))
        # DiscoverRunner retains Django's normal TestCase/TransactionTestCase order.
        suite = super().build_suite(test_labels, **kwargs)
        tests = list(iter_test_cases(suite))
        identifiers = [test.id() for test in tests]
        if not tests or len(set(identifiers)) != len(tests):
            raise UnsafeTestTarget("Empty or overlapping test selection is forbidden.")
        for test in tests:
            module = type(test).__module__
            root = module.split(".")[0]
            if (root not in PROJECT_APPS or getattr(test, "serialized_rollback", False)
                    or getattr(test, "available_apps", None) is not None
                    or "role_requirement_isolated_mysql" in getattr(test, "tags", ())):
                raise UnsafeTestTarget("Unsupported test lifecycle or strict role-requirement checkpoint.")
            if set(getattr(test, "databases", ())) - {"default"}:
                raise UnsafeTestTarget("Only the approved default database is supported.")
            source = sys.modules.get(module)
            filename = getattr(source, "__file__", None)
            if not filename or not Path(filename).resolve().is_relative_to(Path(settings.BASE_DIR).resolve()):
                raise UnsafeTestTarget("Tests must come from the current project checkout.")
        self.checkpoint_test_count = len(tests)
        return suite

    def suite_result(self, suite, result, **kwargs):
        if result.testsRun != self.checkpoint_test_count or result.skipped or result.expectedFailures:
            raise UnsafeTestTarget("Incomplete, skipped or expected-failure execution cannot pass verification.")
        return DiscoverRunner.suite_result(self, suite, result, **kwargs)

    def validate_connection(self, connection):
        maintenance = super().validate_connection(connection)
        if maintenance:
            if threading.get_ident() != self._owner_thread:
                raise UnsafeTestTarget("Only the owning runner thread may open maintenance access.")
            if self._maintenance_connection is None:
                self._maintenance_connection = connection
                if self._execution_requested:
                    self._write_execution_receipt()
            elif self._maintenance_connection is not connection:
                raise UnsafeTestTarget("Alternate maintenance connections are forbidden.")
        return maintenance

    def _write_execution_receipt(self):
        # Once execution is attempted, retain this receipt even if the server
        # never confirms CREATE DATABASE. Metadata-only preflight is repeatable.
        media = validate_media(str(self.config.media), self.config.owner, media_prefix=self.config.media_prefix)
        with (media / EXECUTION_RECEIPT).open("x", encoding="ascii") as receipt:
            json.dump({"owner": self.config.owner, "schema": self.config.database,
                       "account": self.config.account}, receipt)
            receipt.write("\n")
            receipt.flush()
            os.fsync(receipt.fileno())

    def preflight_complete(self, cursor):
        cursor.execute("SELECT CONNECTION_ID()")
        row = cursor.fetchone()
        if not row or len(row) != 1 or type(row[0]) is not int or row[0] <= 0:
            raise UnsafeTestTarget("Cannot establish advisory-lock ownership.")
        self._lock_owner = row[0]
        self._maintenance_session = self._maintenance_connection.connection
        self._verify_leases(cursor)

    def _verify_maintenance_at_finish(self):
        raw = self._maintenance_session
        if raw is None:
            return
        try:
            if self._maintenance_connection.connection is not raw:
                raise UnsafeTestTarget("The maintenance session was replaced.")
            with raw.cursor() as cursor:
                verify_identity(cursor, self.config, None)
                self._verify_leases(cursor)
                verify_no_other_sessions(cursor, self.config)
        except Exception:
            raise self._lost("Cannot verify exclusive ownership at shutdown.") from None

    def _verify_owned_connection(self, connection, *, initializing=False):
        guarded.require_authorized_connection(connection)
        raw = connection.connection
        session = self._worker_sessions.get(connection)
        if not initializing and (session is None or session[0] is not raw):
            raise self._lost("The worker connection has no verified session lease.")
        try:
            with raw.cursor() as cursor:
                verify_identity(cursor, self.config, self.config.database, initializing=initializing)
                self._verify_leases(cursor, None if initializing else session[1])
        except UnsafeTestTarget:
            raise
        except Exception:
            raise self._lost("Cannot verify the worker session before dispatch.") from None
        return raw

    def _verify_leases(self, cursor, worker_lock=None):
        cursor.execute("SELECT IS_USED_LOCK(%s)", (self.config.lock_prefix + self.config.owner,))
        if self._lock_owner is None or cursor.fetchone() != (self._lock_owner,):
            raise self._lost("The exclusive advisory lock is no longer owned by this run.")
        if worker_lock is not None:
            cursor.execute("SELECT IS_USED_LOCK(%s) = CONNECTION_ID()", (worker_lock,))
            if cursor.fetchone() != (1,):
                raise self._lost("The worker session no longer holds its lease.")

    def _bind_worker_session(self, connection):
        raw = connection.connection
        with raw.cursor() as cursor:
            self._verify_leases(cursor)
            cursor.execute("SELECT CONNECTION_ID()")
            row = cursor.fetchone()
            if not row or len(row) != 1 or type(row[0]) is not int or row[0] <= 0:
                raise UnsafeTestTarget("Cannot identify the worker session.")
            owner = row[0]
            lock = f"{self.config.lock_prefix}{self.config.owner}:{owner}"
            with self._admit():
                cursor.execute("SELECT GET_LOCK(%s, 0)", (lock,))
            if cursor.fetchone() != (1,):
                raise UnsafeTestTarget("Cannot acquire the worker session lease.")
            self._verify_leases(cursor, lock)
        self._worker_sessions[connection] = (raw, lock)

    def _dispatch_owned(self, connection, operation, *args):
        if self._ownership_lost.is_set():
            raise _OwnershipLost("The run has already lost database ownership.")
        raw = self._verify_owned_connection(connection)
        # Authorization is bound to the leased DB-API session. A dead worker
        # session cannot execute on a replacement. A separate maintenance
        # session can still die during an admitted operation, including DDL or
        # COMMIT. Detect that outcome and fail the run without retry or reuse.
        with self._admit():
            if connection.connection is not raw:
                raise self._lost("The authorized worker connection was replaced.")
            try:
                result = operation(*args)
            except Exception as error:
                if isinstance(error, OSError) or _mysql_error_code(error) in MYSQL_TRANSPORT_LOSS:
                    raise self._lost("Transport failed during an admitted operation; outcome may be durable.") from None
                raise
            finally:
                try:
                    with raw.cursor() as cursor:
                        self._verify_leases(cursor, self._worker_sessions[connection][1])
                except Exception:
                    raise self._lost("Database ownership was lost during dispatch; outcome may be durable.") from None
            if self._ownership_lost.is_set():
                raise _OwnershipLost("The run lost ownership while this operation was admitted.")
            return result

    def _guard_transaction(self, connection, operation, *args):
        if args == (True,) and getattr(self._initializing, "connection", None) is connection:
            # Django enables autocommit only on the newly connected session
            # before initializing READ COMMITTED. It has no pending writes.
            if connection.alias == "default":
                self._verify_owned_connection(connection, initializing=True)
            else:
                guarded.require_authorized_connection(connection)
            with self._admit():
                return operation(connection, *args)
        return self._dispatch_owned(connection, operation, connection, *args)

    def _guard_execute(self, execute, sql, params, many, context):
        # Also gate already-open connections: approval loss, settings changes or
        # lock loss must stop a later fixture flush, not just a new connection.
        connection = context["connection"]
        initializing = (
            getattr(self._initializing, "connection", None) is connection
            and not many and params is None and isinstance(sql, str)
            and (sql in MYSQL_ISOLATION_STATEMENTS or " ".join(sql.split()) == MYSQL_INITIALIZATION_READ)
        )
        # Django may read server metadata before setting isolation on a new
        # session. Permit only its exact startup statements without a worker lease.
        if not initializing:
            return self._dispatch_owned(connection, execute, sql, params, many, context)
        self._verify_owned_connection(connection, initializing=True)
        with self._admit():
            result = execute(sql, params, many, context)
        if sql in MYSQL_ISOLATION_STATEMENTS:
            with connection.connection.cursor() as cursor:
                verify_identity(cursor, self.config, self.config.database)
                self._verify_leases(cursor)
        return result

    def connect_checked(self, connection):
        with self._admit():
            self._open_owned_connection(connection)

    def _open_owned_connection(self, connection):
        if connection.alias == "__no_db__" and self._maintenance_connection is not None:
            raise self._lost("The maintenance session cannot reconnect.")
        previous = getattr(self._initializing, "connection", None)
        self._initializing.connection = connection
        try:
            if connection.alias in {"__no_db__", "default"}:
                self._guard_connection_methods(connection)
            super().connect_checked(connection)
            if connection.alias == "default":
                try:
                    self._bind_worker_session(connection)
                    self._verify_owned_connection(connection)
                except Exception as error:
                    raise guarded.connection_failure(connection, error, "owned_connection") from None
        finally:
            self._initializing.connection = previous

    def _guard_connection_methods(self, connection):
        # These hooks stay on the disposable wrapper. A worker surviving
        # shutdown must still be denied SQL, commit and reconnect on it.
        commit = type(connection)._commit
        set_autocommit = type(connection)._set_autocommit
        connection.connect = lambda: self.connect_checked(connection)
        connection._commit = lambda: self._guard_transaction(connection, commit)
        connection._set_autocommit = (
            lambda enabled: self._guard_transaction(connection, set_autocommit, enabled)
        )
        if connection.alias == "default" and self._guard_execute not in connection.execute_wrappers:
            connection.execute_wrappers.append(self._guard_execute)


class _PrivateOutput:
    """Redact credential values, including values split across writes in a line."""
    def __init__(self, stream, values):
        self.stream = stream
        self.values = tuple(sorted({variant for value in values if value
                                    for variant in (value, repr(value)[1:-1], json.dumps(value)[1:-1])},
                                   key=len, reverse=True))
        self.pending = ""
        self.lock = threading.RLock()

    def write(self, text):
        with self.lock:
            self.pending += text
            while "\n" in self.pending:
                line, self.pending = self.pending.split("\n", 1)
                self._emit(line + "\n")
        return len(text)

    def _emit(self, text):
        for value in self.values:
            text = text.replace(value, "[REDACTED]")
        text = re.sub(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", "[REDACTED TOKEN]", text)
        self.stream.write(text)

    def flush(self):
        self.stream.flush()

    def finish(self):
        with self.lock:
            self._emit(self.pending)
            self.pending = ""
            self.flush()


class _ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse normally echoes rejected values; an accidental credential
        # argument must not be repeated in the console or captured logs.
        self.exit(2, "Invalid integration-runner arguments; use --help. Argument values are not displayed.\n")


def _mysql_error_code(error):
    if isinstance(error, (DjangoDatabaseError, DriverError)) and error.args:
        code = error.args[0]
        if type(code) is int and 0 < code <= 65535:
            return code
    return None


def _public_diagnostic(error):
    if isinstance(error, _OwnershipLost):
        return "category=ownership-lost"
    if isinstance(error, UnsafeTestTarget):
        return "category=safety-check"
    if isinstance(error, (DjangoDatabaseError, DriverError)):
        code = _mysql_error_code(error)
        if code is not None:
            return f"category=database, mysql_error_code={code}"
        return "category=database"
    return "category=execution"


def main(argv=None):
    parser = _ArgumentParser(description=__doc__)
    parser.add_argument("labels", nargs="*")
    parser.add_argument("--preflight-only", action="store_true")
    parser.add_argument("--noinput", action="store_true")
    parser.add_argument("--parallel", type=int, choices=(1,), default=1)
    args = parser.parse_args(argv)
    with _reserve_process():
        return _main_owned(args)


def _main_owned(args):
    if args.preflight_only:
        if args.labels:
            raise UnsafeTestTarget("Preflight mode does not execute test labels.")
    else:
        validate_labels(args.labels)
        if not args.noinput:
            raise UnsafeTestTarget("Test execution requires --noinput.")
    if settings.configured or os.environ.get("DJANGO_SETTINGS_MODULE") not in (None, "", INTEGRATION_PROFILE):
        raise UnsafeTestTarget("Start a fresh process without an alternate settings profile.")
    # Validate all non-secret approvals before prompting. Synthetic placeholders
    # exist only in this temporary mapping, never as usable connection settings.
    candidate = dict(os.environ)
    candidate.setdefault("MYSQL_TEST_PASSWORD", "pending-hidden-entry")
    candidate.setdefault("MYSQL_TEST_SECRET_KEY", secrets.token_urlsafe(64))
    IntegrationConfig.from_environment(candidate)
    original = {key: os.environ.get(key) for key in (
        "MYSQL_TEST_PASSWORD", "MYSQL_TEST_SECRET_KEY", "DJANGO_SETTINGS_MODULE",
    )}
    try:
        if "MYSQL_TEST_PASSWORD" not in os.environ:
            if not sys.stdin.isatty():
                raise UnsafeTestTarget("Hidden local password entry or securely supplied process environment is required.")
            with warnings.catch_warnings():
                warnings.simplefilter("error", getpass.GetPassWarning)
                password = getpass.getpass("Dedicated integration-test database password (hidden): ")
            if not password:
                raise UnsafeTestTarget("No password supplied.")
            os.environ["MYSQL_TEST_PASSWORD"] = password
            del password
        os.environ.setdefault("MYSQL_TEST_SECRET_KEY", candidate["MYSQL_TEST_SECRET_KEY"])
        os.environ["DJANGO_SETTINGS_MODULE"] = INTEGRATION_PROFILE
        stdout = _PrivateOutput(sys.stdout, (os.environ["MYSQL_TEST_PASSWORD"], os.environ["MYSQL_TEST_SECRET_KEY"]))
        stderr = _PrivateOutput(sys.stderr, stdout.values)
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                import django
                django.setup()
                # Import by canonical module name even when invoked with -m.
                from django.test.utils import get_runner
                runner = get_runner(settings)(interactive=False, parallel=1, keepdb=False)
                result = runner._run_owned(args.labels, preflight_only=args.preflight_only)
        finally:
            stdout.finish()
            stderr.finish()
        return bool(result)
    finally:
        for key, value in original.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def _cli():
    try:
        return main()
    except KeyboardInterrupt:
        print("Integration run interrupted; any created schema is retained for approved cleanup.")
    except Exception as error:
        diagnostic = _public_diagnostic(error)
        print(f"BLOCKED: integration preflight or execution failed. {diagnostic}. Any created schema is retained.")
    return 1


if __name__ == "__main__":
    from config.integration_test_runner import _cli as run_cli

    sys.exit(run_cli())
