"""Opt-in disposable MySQL test safeguards. No environment loading or provisioning.

Only RR_TEST_* values are used; development/QA settings and .env are never read.
The owner must provision a separate loopback MySQL 8 instance before execution.
"""

from dataclasses import dataclass, field
from datetime import datetime
import re
import stat
from pathlib import Path
import tempfile


class UnsafeTestTarget(RuntimeError):
    pass


PROTECTED_DATABASES = frozenset({
    "gardens_training", "test_gardens_training", "gardens_training_qa_isolated",
})
RUNNER = "config.role_requirement_test_runner.RoleRequirementTestRunner"
PROFILE = "config.role_requirement_test_settings"
REQUIRED_PRIVILEGES = frozenset({
    "SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "INDEX", "REFERENCES",
})
IDENTITY_SQL = (
    "SELECT @@server_uuid, @@hostname, @@port, CURRENT_USER(), DATABASE(), "
    "VERSION(), @@session.transaction_isolation, @@default_storage_engine, @@partial_revokes"
)
_verified_config = None


def required(environment, name):
    value = environment.get(name)
    if not isinstance(value, str) or not value or value != value.strip():
        raise UnsafeTestTarget(f"{name} must be explicitly configured.")
    return value


@dataclass(frozen=True)
class DisposableConfig:
    database: str
    owner: str
    server_uuid: str
    server_hostname: str
    user: str
    account: str
    media: Path
    password: str = field(repr=False)
    secret_key: str = field(repr=False)

    @classmethod
    def from_environment(cls, environment):
        names = {
            "DATABASE", "APPROVED_DATABASE", "OWNER", "SERVER_UUID", "SERVER_HOSTNAME",
            "HOST", "PORT", "USER", "ACCOUNT", "PASSWORD", "SECRET_KEY", "MEDIA_ROOT",
            "ISOLATION", "ALLOW_CREATE", "EXCLUSIVE_OWNER",
        }
        if any(key.startswith("RR_TEST_") and key[8:] not in names for key in environment):
            raise UnsafeTestTarget("Unexpected RR_TEST_* configuration.")
        database = required(environment, "RR_TEST_DATABASE")
        match = re.fullmatch(r"test_gn_rr_(\d{8})_([0-9a-f]{32})", database)
        if database.casefold() in PROTECTED_DATABASES or not match:
            raise UnsafeTestTarget("A unique disposable GUID database name is required.")
        try:
            datetime.strptime(match[1], "%Y%m%d")
        except ValueError:
            raise UnsafeTestTarget("Invalid disposable database date.") from None
        owner = required(environment, "RR_TEST_OWNER")
        if owner != match[2] or required(environment, "RR_TEST_APPROVED_DATABASE") != database:
            raise UnsafeTestTarget("Explicit database approval and ownership must match.")
        if required(environment, "RR_TEST_HOST") != "127.0.0.1" or required(environment, "RR_TEST_PORT") != "3308":
            raise UnsafeTestTarget("Only the separately provisioned 127.0.0.1:3308 target is allowed.")
        server_uuid = required(environment, "RR_TEST_SERVER_UUID")
        if not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", server_uuid):
            raise UnsafeTestTarget("An explicit MySQL server UUID is required.")
        hostname = required(environment, "RR_TEST_SERVER_HOSTNAME")
        user = required(environment, "RR_TEST_USER")
        if not re.fullmatch(r"gn_rr_[0-9a-f]{16}", user):
            raise UnsafeTestTarget("A dedicated gn_rr_<16 hex characters> account is required.")
        account = required(environment, "RR_TEST_ACCOUNT")
        if account not in {f"{user}@localhost", f"{user}@127.0.0.1"}:
            raise UnsafeTestTarget("The expected account must be restricted to loopback.")
        if required(environment, "RR_TEST_ISOLATION") != "read committed":
            raise UnsafeTestTarget("Explicit READ COMMITTED isolation is required.")
        password = required(environment, "RR_TEST_PASSWORD")
        secret = required(environment, "RR_TEST_SECRET_KEY")
        if len(secret) < 50 or len(set(secret)) < 20 or "django-insecure" in secret:
            raise UnsafeTestTarget("A strong test-only signing key is required.")
        media = validate_media(required(environment, "RR_TEST_MEDIA_ROOT"), owner)
        return cls(database, owner, server_uuid, hostname, user, account, media, password, secret)

    def database_settings(self):
        return {
            "ENGINE": "django.db.backends.mysql", "NAME": self.database,
            "USER": self.user, "PASSWORD": self.password, "HOST": "127.0.0.1", "PORT": "3308",
            "OPTIONS": {"charset": "utf8mb4", "isolation_level": "read committed", "connect_timeout": 5},
            "ATOMIC_REQUESTS": False, "AUTOCOMMIT": True, "CONN_MAX_AGE": 0,
            "CONN_HEALTH_CHECKS": False, "TIME_ZONE": None,
            "TEST": {"NAME": self.database, "CHARSET": "utf8mb4", "COLLATION": "utf8mb4_0900_ai_ci",
                     "MIGRATE": True, "MIRROR": None, "DEPENDENCIES": []},
        }


def validate_media(value, owner):
    path = Path(value)
    root = Path(__file__).resolve().parents[1]
    temporary_root = Path(tempfile.gettempdir()).resolve()
    if not path.is_absolute() or path.name != f"gn-rr-media-{owner}":
        raise UnsafeTestTarget("A dedicated, owner-named temporary media directory is required.")
    for ancestor in (path, *path.parents):
        try:
            metadata = ancestor.lstat()
        except FileNotFoundError:
            continue
        except OSError:
            raise UnsafeTestTarget("Cannot safely inspect media path metadata.") from None
        # Python 3.11 has no Path.is_junction(). lstat exposes Windows name-
        # surrogate reparse points without following them, including junctions.
        reparse_point = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        if stat.S_ISLNK(metadata.st_mode) or getattr(metadata, "st_file_attributes", 0) & reparse_point:
            raise UnsafeTestTarget("Linked media paths are not allowed.")
    resolved = path.resolve()
    if resolved.parent != temporary_root or resolved.is_relative_to(root) or root.is_relative_to(resolved):
        raise UnsafeTestTarget("Media must be outside the repository in the system temporary directory.")
    if not resolved.is_dir() or any(resolved.iterdir()):
        raise UnsafeTestTarget("The owner must supply a new empty media directory.")
    return resolved


def validate_database(config, database, *, maintenance=False):
    if (
        config.database.casefold() in PROTECTED_DATABASES
        or not re.fullmatch(r"test_gn_rr_\d{8}_[0-9a-f]{32}", config.database)
        or not re.fullmatch(r"[0-9a-f]{32}", config.owner)
        or not config.database.endswith("_" + config.owner)
    ):
        raise UnsafeTestTarget("The approved target is not a disposable GUID schema.")
    expected = config.database_settings()
    if maintenance:
        expected["NAME"] = None
    if database != expected:
        raise UnsafeTestTarget("Database settings differ from the approved disposable target.")


def validate_settings(settings, *, setup=False):
    config = getattr(settings, "ROLE_REQUIREMENT_TEST_CONFIG", None)
    if not isinstance(config, DisposableConfig):
        raise UnsafeTestTarget("The dedicated disposable test profile is required.")
    if settings.SETTINGS_MODULE != PROFILE or settings.TEST_RUNNER != RUNNER:
        raise UnsafeTestTarget("The dedicated profile and runner must be used together.")
    if set(settings.DATABASES) != {"default"} or settings.DATABASE_ROUTERS or settings.MIGRATION_MODULES:
        raise UnsafeTestTarget("Extra aliases, routers and migration overrides are forbidden.")
    validate_database(config, settings.DATABASES["default"])
    if setup:
        if Path(settings.MEDIA_ROOT) != config.media:
            raise UnsafeTestTarget("The isolated media configuration changed.")
        validate_media(str(config.media), config.owner)
    # CurriculumTestCase supplies its own temporary media override during tests.
    # The approved initial root is checked before any database connection.
    return config


def verify_identity(cursor, config, database):
    cursor.execute(IDENTITY_SQL)
    row = cursor.fetchone()
    if not row or len(row) != 9 or (
        row[:5] != (config.server_uuid, config.server_hostname, 3308, config.account, database)
        or not re.match(r"8\.\d+\.\d+", str(row[5]))
        or "mariadb" in str(row[5]).lower()
        or str(row[6]).replace("-", " ").lower() != "read committed"
        or str(row[7]).lower() != "innodb" or row[8] not in (0, 1)
    ):
        raise UnsafeTestTarget("MySQL server, account, database or isolation identity mismatch.")
    return bool(row[8])


def verify_grants(rows, config, partial_revokes):
    user, host = config.account.split("@")
    recipient = f"`{user}`@`{host}`"
    schema = config.database if partial_revokes else config.database.replace("_", r"\_")
    expected_scope = f"`{schema}`.*"
    privileges = set()
    for (grant,) in rows:
        match = re.fullmatch(r"GRANT ([A-Z, ]+) ON (.+) TO (.+)", grant)
        if not match or match[3] != recipient:
            raise UnsafeTestTarget("Roles, grant options and unrecognized grants are forbidden.")
        current = set(match[1].split(", "))
        if match[2] == "*.*" and current == {"USAGE"}:
            continue
        if match[2] != expected_scope or not current <= REQUIRED_PRIVILEGES:
            raise UnsafeTestTarget("Privileges must be limited to the exact disposable schema; no DROP or global grants.")
        privileges.update(current)
    if privileges != REQUIRED_PRIVILEGES:
        raise UnsafeTestTarget("Required disposable-schema privileges are missing.")


def preflight(cursor, config):
    partial_revokes = verify_identity(cursor, config, None)
    cursor.execute("SELECT GET_LOCK(%s, 0)", ("gn_rr:" + config.owner,))
    if cursor.fetchone() != (1,):
        raise UnsafeTestTarget("Another runner owns the disposable target.")
    cursor.execute("SHOW GRANTS FOR CURRENT_USER")
    verify_grants(cursor.fetchall(), config, partial_revokes)
    cursor.execute(
        "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER = %s AND ID <> CONNECTION_ID()",
        (config.user,),
    )
    if cursor.fetchone() != (0,):
        raise UnsafeTestTarget("The test account has another active connection.")
    cursor.execute("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = %s", (config.database,))
    if cursor.fetchone() is not None:
        raise UnsafeTestTarget("Schema collision: existing databases are never reused or deleted.")


def mark_verified(config):
    global _verified_config
    _verified_config = config


def require_verified_database(connection, settings):
    config = validate_settings(settings)
    validate_database(config, connection.settings_dict)
    if connection.alias != "default" or connection.vendor != "mysql" or _verified_config is not config:
        raise UnsafeTestTarget("Completed disposable-runner preflight is required before fixture access.")
    with connection.cursor() as cursor:
        verify_identity(cursor, config, config.database)
