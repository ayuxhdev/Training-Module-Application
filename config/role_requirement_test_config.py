"""Opt-in disposable MySQL test safeguards. No environment loading or provisioning.

Only profile-specific test values are used; development/QA settings and .env
are never read. RR_TEST_* retains its separate-server CI contract; MYSQL_TEST_*
uses a new disposable schema on the existing loopback MySQL 8 server.
"""

from dataclasses import dataclass, field
from datetime import datetime
import re
import stat
from pathlib import Path
import tempfile
from typing import ClassVar


class UnsafeTestTarget(RuntimeError):
    pass


PROTECTED_DATABASES = frozenset({
    "gardens_training", "test_gardens_training", "gardens_training_qa_isolated",
})
RUNNER = "config.role_requirement_test_runner.RoleRequirementTestRunner"
PROFILE = "config.role_requirement_test_settings"
ENGINE = "config.role_requirement_test_backend"
INTEGRATION_PROFILE = "config.integration_test_settings"
INTEGRATION_RUNNER = "config.integration_test_runner.IntegrationTestRunner"
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
    prefix: ClassVar[str] = "RR_TEST_"
    schema_prefix: ClassVar[str] = "test_gn_rr_"
    user_prefix: ClassVar[str] = "gn_rr_"
    media_prefix: ClassVar[str] = "gn-rr-media-"
    lock_prefix: ClassVar[str] = "gn_rr:"
    port: ClassVar[int] = 3308
    profile: ClassVar[str] = PROFILE
    runner: ClassVar[str] = RUNNER
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
        if cls is IntegrationConfig:
            names.update({"ALLOW_RESET", "RETENTION"})
        prefix = cls.prefix
        if any(key.startswith(prefix) and key[len(prefix):] not in names for key in environment):
            raise UnsafeTestTarget(f"Unexpected {prefix} configuration.")
        database = required(environment, prefix + "DATABASE")
        match = re.fullmatch(re.escape(cls.schema_prefix) + r"(\d{8})_([0-9a-f]{32})", database)
        if database.casefold() in PROTECTED_DATABASES or not match:
            raise UnsafeTestTarget("A unique disposable GUID database name is required.")
        try:
            datetime.strptime(match[1], "%Y%m%d")
        except ValueError:
            raise UnsafeTestTarget("Invalid disposable database date.") from None
        owner = required(environment, prefix + "OWNER")
        if owner != match[2] or required(environment, prefix + "APPROVED_DATABASE") != database:
            raise UnsafeTestTarget("Explicit database approval and ownership must match.")
        validate_execution_approval(environment, owner, prefix=prefix)
        if required(environment, prefix + "HOST") != "127.0.0.1" or required(environment, prefix + "PORT") != str(cls.port):
            raise UnsafeTestTarget("The explicitly approved loopback endpoint is required.")
        server_uuid = required(environment, prefix + "SERVER_UUID")
        if not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", server_uuid):
            raise UnsafeTestTarget("An explicit MySQL server UUID is required.")
        hostname = required(environment, prefix + "SERVER_HOSTNAME")
        user = required(environment, prefix + "USER")
        if not re.fullmatch(re.escape(cls.user_prefix) + r"[0-9a-f]{16}", user):
            raise UnsafeTestTarget("A dedicated owner-named test account is required.")
        account = required(environment, prefix + "ACCOUNT")
        if account not in {f"{user}@localhost", f"{user}@127.0.0.1"}:
            raise UnsafeTestTarget("The expected account must be restricted to loopback.")
        if required(environment, prefix + "ISOLATION") != "read committed":
            raise UnsafeTestTarget("Explicit READ COMMITTED isolation is required.")
        password = required(environment, prefix + "PASSWORD")
        secret = required(environment, prefix + "SECRET_KEY")
        if len(secret) < 50 or len(set(secret)) < 20 or "django-insecure" in secret:
            raise UnsafeTestTarget("A strong test-only signing key is required.")
        if cls is IntegrationConfig:
            if user != cls.user_prefix + owner[:16] or account != user + "@127.0.0.1":
                raise UnsafeTestTarget("Integration account must match its owner and loopback host.")
            if environment.get("DJANGO_SETTINGS_MODULE") not in (None, "", cls.profile):
                raise UnsafeTestTarget("Unexpected Django settings override.")
            if not secret.isascii() or any(character.isspace() for character in secret):
                raise UnsafeTestTarget("A strong test-only signing key is required.")
            if any(ord(character) < 32 or ord(character) == 127 for character in password):
                raise UnsafeTestTarget("Database password must not contain control characters.")
        media_value = required(environment, prefix + "MEDIA_ROOT")
        media = validate_media(media_value, owner, media_prefix=cls.media_prefix)
        if cls is IntegrationConfig and media_value != str(media):
            raise UnsafeTestTarget("MYSQL_TEST_MEDIA_ROOT must use the canonical absolute path.")
        return cls(database, owner, server_uuid, hostname, user, account, media, password, secret)

    def database_settings(self):
        return {
            "ENGINE": ENGINE, "NAME": self.database,
            "USER": self.user, "PASSWORD": self.password, "HOST": "127.0.0.1", "PORT": str(self.port),
            "OPTIONS": {"charset": "utf8mb4", "isolation_level": "read committed", "connect_timeout": 5},
            "ATOMIC_REQUESTS": False, "AUTOCOMMIT": True, "CONN_MAX_AGE": 0,
            "CONN_HEALTH_CHECKS": False, "TIME_ZONE": None,
            "TEST": {"NAME": self.database, "CHARSET": "utf8mb4", "COLLATION": "utf8mb4_0900_ai_ci",
                     "MIGRATE": True, "MIRROR": None, "DEPENDENCIES": []},
        }


@dataclass(frozen=True)
class IntegrationConfig(DisposableConfig):
    prefix: ClassVar[str] = "MYSQL_TEST_"
    schema_prefix: ClassVar[str] = "test_gn_it_"
    user_prefix: ClassVar[str] = "gn_it_"
    media_prefix: ClassVar[str] = "gn-it-media-"
    lock_prefix: ClassVar[str] = "gn_it:"
    port: ClassVar[int] = 3306
    profile: ClassVar[str] = INTEGRATION_PROFILE
    runner: ClassVar[str] = INTEGRATION_RUNNER


def validate_execution_approval(environment, owner, *, prefix="RR_TEST_"):
    if required(environment, prefix + "ALLOW_CREATE") != "create-new-disposable-schema":
        raise UnsafeTestTarget("Explicit schema-creation authorization is required.")
    if required(environment, prefix + "EXCLUSIVE_OWNER") != owner:
        raise UnsafeTestTarget("An exclusive owner-approved test window is required.")
    if prefix == IntegrationConfig.prefix:
        if required(environment, prefix + "ALLOW_RESET") != "owned-schema-only":
            raise UnsafeTestTarget("Explicit owned-schema fixture-reset approval is required.")
        if required(environment, prefix + "RETENTION") != "retain-for-approved-cleanup":
            raise UnsafeTestTarget("Explicit retained-schema cleanup policy is required.")


def validate_config_approval(environment, config):
    validate_execution_approval(environment, config.owner, prefix=config.prefix)
    if type(config) is IntegrationConfig:
        # Recheck configuration without requiring the media root to remain empty
        # after tests start writing their own isolated fixtures.
        expected = {
            "DATABASE": config.database, "APPROVED_DATABASE": config.database,
            "OWNER": config.owner, "HOST": "127.0.0.1", "PORT": str(config.port),
            "SERVER_UUID": config.server_uuid, "SERVER_HOSTNAME": config.server_hostname,
            "USER": config.user, "ACCOUNT": config.account, "PASSWORD": config.password,
            "SECRET_KEY": config.secret_key, "MEDIA_ROOT": str(config.media),
            "ISOLATION": "read committed",
        }
        allowed = {*expected, "ALLOW_CREATE", "EXCLUSIVE_OWNER", "ALLOW_RESET", "RETENTION"}
        if any(key.startswith(config.prefix) and key[len(config.prefix):] not in allowed for key in environment):
            raise UnsafeTestTarget("Unexpected integration environment override.")
        if any(required(environment, config.prefix + key) != value for key, value in expected.items()):
            raise UnsafeTestTarget("Integration configuration changed during execution.")
        if environment.get("DJANGO_SETTINGS_MODULE") not in (None, "", config.profile):
            raise UnsafeTestTarget("Unexpected Django settings override.")


def validate_media(value, owner, *, media_prefix="gn-rr-media-"):
    path = Path(value)
    root = Path(__file__).resolve().parents[1]
    temporary_root = Path(tempfile.gettempdir()).resolve()
    if not path.is_absolute() or path.name != media_prefix + owner:
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
        type(config) not in (DisposableConfig, IntegrationConfig)
        or config.database.casefold() in PROTECTED_DATABASES
        or not re.fullmatch(re.escape(config.schema_prefix) + r"\d{8}_[0-9a-f]{32}", config.database)
        or not re.fullmatch(r"[0-9a-f]{32}", config.owner)
        or not config.database.endswith("_" + config.owner)
    ):
        raise UnsafeTestTarget("The approved target is not a disposable GUID schema.")
    if type(config) is IntegrationConfig and (
        config.user != config.user_prefix + config.owner[:16]
        or config.account != config.user + "@127.0.0.1"
    ):
        raise UnsafeTestTarget("Integration connection ownership does not match the approved run.")
    expected = config.database_settings()
    if maintenance:
        expected["NAME"] = None
    if database != expected:
        raise UnsafeTestTarget("Database settings differ from the approved disposable target.")


def validate_settings(settings, *, setup=False):
    from django.conf import LazySettings, Settings, UserSettingsHolder

    profile = getattr(settings, "SETTINGS_MODULE", None)
    if isinstance(settings, LazySettings):
        # override_settings() masks SETTINGS_MODULE with its holder's class
        # attribute (None). Resolve only Django's genuine override chain; all
        # mutable settings below must still be validated through the live view.
        original = settings._wrapped
        while type(original) is UserSettingsHolder:
            if "SETTINGS_MODULE" in vars(original) or "SETTINGS_MODULE" in original._deleted:
                raise UnsafeTestTarget("The disposable settings profile must not be overridden.")
            original = original.default_settings
        if type(original) is not Settings:
            raise UnsafeTestTarget("The dedicated disposable test profile is required.")
        profile = original.SETTINGS_MODULE
    if profile == PROFILE:
        config = getattr(settings, "ROLE_REQUIREMENT_TEST_CONFIG", None)
        expected_type = DisposableConfig
    elif profile == INTEGRATION_PROFILE:
        config = getattr(settings, "INTEGRATION_TEST_CONFIG", None)
        expected_type = IntegrationConfig
    else:
        raise UnsafeTestTarget("The dedicated disposable test profile is required.")
    if type(config) is not expected_type:
        raise UnsafeTestTarget("The dedicated disposable test profile is required.")
    if settings.TEST_RUNNER != config.runner:
        raise UnsafeTestTarget("The dedicated profile and runner must be used together.")
    if set(settings.DATABASES) != {"default"} or settings.DATABASE_ROUTERS or settings.MIGRATION_MODULES:
        raise UnsafeTestTarget("Extra aliases, routers and migration overrides are forbidden.")
    validate_database(config, settings.DATABASES["default"])
    if setup:
        if Path(settings.MEDIA_ROOT) != config.media:
            raise UnsafeTestTarget("The isolated media configuration changed.")
        validate_media(str(config.media), config.owner, media_prefix=config.media_prefix)
    # CurriculumTestCase supplies its own temporary media override during tests.
    # The approved initial root is checked before any database connection.
    return config


def verify_identity(cursor, config, database, *, initializing=False):
    # Only the integration runner's exact Django initialization statement may
    # inspect a new session before it has applied READ COMMITTED. All server,
    # account and schema checks still apply, and runtime checks remain strict.
    isolations = {"read committed"}
    if initializing:
        if type(config) is not IntegrationConfig or database != config.database:
            raise UnsafeTestTarget("Only an owned integration session may initialize isolation.")
        isolations.update({"repeatable read", "read uncommitted", "serializable"})
    cursor.execute(IDENTITY_SQL)
    row = cursor.fetchone()
    if not row or len(row) != 9 or (
        row[:5] != (config.server_uuid, config.server_hostname, config.port, config.account, database)
        or not re.match(r"8\.\d+\.\d+", str(row[5]))
        or "mariadb" in str(row[5]).lower()
        or str(row[6]).replace("-", " ").lower() not in isolations
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
    cursor.execute("SELECT GET_LOCK(%s, 0)", (config.lock_prefix + config.owner,))
    if cursor.fetchone() != (1,):
        raise UnsafeTestTarget("Another runner owns the disposable target.")
    cursor.execute("SHOW GRANTS FOR CURRENT_USER")
    verify_grants(cursor.fetchall(), config, partial_revokes)
    verify_no_other_sessions(cursor, config)
    cursor.execute("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = %s", (config.database,))
    if cursor.fetchone() is not None:
        raise UnsafeTestTarget("Schema collision: existing databases are never reused or deleted.")


def verify_no_other_sessions(cursor, config):
    cursor.execute(
        "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER = %s AND ID <> CONNECTION_ID()",
        (config.user,),
    )
    if cursor.fetchone() != (0,):
        raise UnsafeTestTarget("The test account has another active connection.")


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
