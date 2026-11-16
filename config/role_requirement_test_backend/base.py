"""Keep database access fail-closed even when --testrunner replaces our runner."""

from django.db.backends.mysql.base import DatabaseWrapper as MySQLDatabaseWrapper
from django.db.backends.mysql.creation import DatabaseCreation as MySQLDatabaseCreation

from config.role_requirement_test_config import UnsafeTestTarget


class DatabaseCreation(MySQLDatabaseCreation):
    def create_test_db(self, *args, **kwargs):
        raise UnsafeTestTarget("Only the guarded runner may create a new disposable schema; reuse is forbidden.")

    def clone_test_db(self, *args, **kwargs):
        raise UnsafeTestTarget("Disposable schemas must never be cloned.")

    def destroy_test_db(self, *args, **kwargs):
        raise UnsafeTestTarget("Disposable schemas must never be dropped by a test runner.")


class DatabaseWrapper(MySQLDatabaseWrapper):
    creation_class = DatabaseCreation

    def get_new_connection(self, conn_params):
        # This guard is part of the configured backend, not an optional runner
        # patch. Direct migrate commands and replacement runners cannot connect.
        from config.role_requirement_test_runner import require_authorized_connection

        require_authorized_connection(self)
        return super().get_new_connection(conn_params)
