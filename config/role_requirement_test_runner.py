"""Explicit, single-process create-once/retain-only disposable MySQL lifecycle.

Normal Django create/reuse/clone/destroy hooks are not called. The schema is
created only after preflight, never reused, and retained even if migrations fail.
No DROP privilege is accepted. Cleanup/provisioning need separate owner approval.
"""

from contextlib import ExitStack
import os
from unittest.mock import patch

from django.conf import settings
from django.core.management import call_command
from django.db import connections
from django.db.backends.base.base import BaseDatabaseWrapper
from django.test import TestCase, TransactionTestCase
from django.test.runner import DiscoverRunner
from django.test.utils import iter_test_cases

from .role_requirement_test_config import (
    UnsafeTestTarget, mark_verified, preflight, validate_execution_approval,
    validate_database, validate_settings, verify_identity,
)


TEST_MODULES = (
    "api.v1.test_role_requirements",
    "api.v1.test_role_requirement_concurrency",
)
CONCURRENCY_CLASS = "api.v1.test_role_requirement_concurrency.RoleRequirementConcurrencyTests"
CONCURRENCY_METHODS = frozenset({
    "test_duplicate_batches_serialize_and_emit_one_notification_per_assignment",
    "test_disabling_first_prevents_batch_without_partial_writes",
    "test_batch_first_completes_before_requirement_is_disabled",
    "test_manual_first_remains_pinned_and_batch_skips_it",
    "test_batch_first_causes_manual_duplicate_validation_not_overwrite",
    "test_concurrent_requirement_creation_preserves_unique_pair",
})
CONCURRENCY_IDS = frozenset(f"{CONCURRENCY_CLASS}.{method}" for method in CONCURRENCY_METHODS)
_active_runner = None


def require_authorized_connection(connection):
    runner = _active_runner
    if runner is None or runner.config is not validate_settings(settings):
        raise UnsafeTestTarget("Database access requires the active guarded runner.")
    validate_execution_approval(os.environ, runner.config.owner)
    runner.validate_connection(connection)


class RoleRequirementTestRunner(DiscoverRunner):
    def run_tests(self, test_labels=None, **kwargs):
        self.config = validate_settings(settings, setup=True)
        if self.parallel not in (0, 1) or not self.keepdb or self.interactive or self.debug_sql:
            raise UnsafeTestTarget("Use --keepdb --noinput --parallel=1; SQL debugging is forbidden.")
        validate_execution_approval(os.environ, self.config.owner)
        if self.tags or self.exclude_tags or self.test_name_patterns:
            raise UnsafeTestTarget("Filtering this focused checkpoint is not supported.")
        if any(connection.connection is not None for connection in connections.all()):
            raise UnsafeTestTarget("Start a fresh process with no existing database connections.")
        labels = tuple(test_labels or TEST_MODULES)
        if labels != TEST_MODULES:
            raise UnsafeTestTarget("Only the two complete role-requirement modules are supported.")
        self.phase = "discovery"
        self.original_connect = BaseDatabaseWrapper.connect
        mark_verified(None)
        with ExitStack() as self.stack:
            self.stack.enter_context(patch(__name__ + "._active_runner", self))
            # This affects only this private runner process, including its threads.
            self.stack.enter_context(patch.object(
                BaseDatabaseWrapper, "connect",
                lambda connection: self.connect_checked(connection),
            ))
            try:
                return super().run_tests(labels, **kwargs)
            finally:
                mark_verified(None)
                self.phase = "finished"
                connections.close_all()

    def build_suite(self, test_labels=None, **kwargs):
        suite = super().build_suite(test_labels, **kwargs)
        tests = list(iter_test_cases(suite))
        concurrency_ids = []
        for test in tests:
            module = type(test).__module__
            if module not in TEST_MODULES or getattr(test, "serialized_rollback", False):
                raise UnsafeTestTarget("Unexpected test or serialized-rollback lifecycle.")
            if isinstance(test, TransactionTestCase) and not isinstance(test, TestCase):
                raise UnsafeTestTarget("Database-wide flush test lifecycles are forbidden by this runner.")
            if module == TEST_MODULES[1]:
                concurrency_ids.append(test.id())
                if "role_requirement_isolated_mysql" not in getattr(test, "tags", ()):
                    raise UnsafeTestTarget("Required concurrency scenarios must retain their dedicated tag.")
        if set(concurrency_ids) != CONCURRENCY_IDS or len(concurrency_ids) != len(CONCURRENCY_IDS):
            raise UnsafeTestTarget("All six required concurrency scenarios must be discovered exactly once.")
        self.checkpoint_test_count = len(tests)
        self.log("Required concurrency coverage: 6/6 discovered.")
        return suite

    def suite_result(self, suite, result, **kwargs):
        # Discovery alone is insufficient: skips/expected failures cannot satisfy
        # this required checkpoint, and early termination must remain a failure.
        if result.testsRun != self.checkpoint_test_count:
            raise UnsafeTestTarget("The complete isolated checkpoint did not execute.")
        if result.skipped or result.expectedFailures:
            raise UnsafeTestTarget("Skipped or expected-failure tests cannot satisfy the isolated checkpoint.")
        failures = super().suite_result(suite, result, **kwargs)
        if not failures:
            self.log("Required concurrency coverage: 6/6 passed without skips.")
        return failures

    def validate_connection(self, connection):
        maintenance = connection.alias == "__no_db__" and self.phase == "preflight"
        if not maintenance and (connection.alias != "default" or self.phase not in {"migrating", "running"}):
            raise UnsafeTestTarget("Database access outside the verified test lifecycle.")
        validate_database(self.config, connection.settings_dict, maintenance=maintenance)
        return maintenance

    def connect_checked(self, connection):
        maintenance = self.validate_connection(connection)
        try:
            self.original_connect(connection)
            # Verify through the DB-API cursor before returning a usable connection.
            cursor = connection.connection.cursor()
            try:
                verify_identity(cursor, self.config, None if maintenance else self.config.database)
            finally:
                cursor.close()
        except Exception:
            connection.close()
            raise UnsafeTestTarget("Disposable connection identity verification failed; no fallback attempted.") from None

    def setup_databases(self, **kwargs):
        validate_settings(settings, setup=True)
        if set(kwargs.get("aliases", ())) != {"default"} or kwargs.get("serialized_aliases"):
            raise UnsafeTestTarget("Only one non-serialized disposable database is supported.")
        self.phase = "preflight"
        connection = connections["default"]
        # This maintenance connection selects no database and holds the owner
        # advisory lock until the entire run (including failures) has ended.
        cursor = self.stack.enter_context(connection._nodb_cursor())
        preflight(cursor, self.config)
        cursor.execute(
            f"CREATE DATABASE `{self.config.database}` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"
        )
        # CREATE errors propagate: no DROP, IF NOT EXISTS, retry or reuse path.
        self.phase = "migrating"
        mark_verified(self.config)
        with connection.cursor() as selected:
            verify_identity(selected, self.config, self.config.database)
        call_command(
            "migrate", database="default", interactive=False,
            verbosity=max(self.verbosity - 1, 0), run_syncdb=True,
        )
        self.phase = "running"
        return self.config.database

    def teardown_databases(self, old_config, **kwargs):
        # Deliberately never invoke Django's destroy_test_db(), even on failure.
        self.phase = "teardown"
        connections.close_all()
