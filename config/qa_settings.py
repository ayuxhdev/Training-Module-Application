"""Opt-in settings for the disposable, loopback-proxied Android QA runtime.

This profile never provisions its database or media directories. Set DB_NAME,
DB_HOST and DB_PORT explicitly before invoking --settings=config.qa_settings.
Keep the existing development DJANGO_SECRET_KEY available for key-separation
checks; supply a different QA_SECRET_KEY (and optionally QA_JWT_SIGNING_KEY).
The trusted proxy must be Tailscale Serve forwarding to 127.0.0.1 only.
"""

import os
from copy import deepcopy
from pathlib import Path
from secrets import compare_digest

from .settings import *  # noqa: F403


def _required(name):
    value = os.environ.get(name, "")
    if not value or value != value.strip():
        raise RuntimeError(f"{name} must be explicitly configured for isolated QA.")
    return value


def _qa_key(name, shared_keys):
    value = _required(name)
    if (
        len(value) < 50
        or len(set(value)) < 20
        or not value.isascii()
        or any(character.isspace() for character in value)
        or any(marker in value.lower() for marker in (
            "django-insecure-", "changeme", "change-me", "replace-me",
            "default", "development", "example",
        ))
    ):
        raise RuntimeError(f"{name} must be a strong, randomly generated QA-only key.")
    if any(compare_digest(value.encode(), key.encode()) for key in shared_keys if key):
        raise RuntimeError(f"{name} must not reuse a development or inherited signing key.")
    return value


def _overlaps(first, second):
    return first.is_relative_to(second) or second.is_relative_to(first)


QA_PROFILE = True
DEBUG = False

# Copy nested settings: importing this overlay must not mutate config.settings.
DATABASES = deepcopy(DATABASES)
if set(DATABASES) != {"default"} or globals().get("DATABASE_ROUTERS"):
    raise RuntimeError("Isolated QA requires one database and no database routers.")
_database = DATABASES["default"]
if (
    set(_database) != {"ENGINE", "NAME", "USER", "PASSWORD", "HOST", "PORT", "OPTIONS"}
    or _database["ENGINE"] != "django.db.backends.mysql"
    or _database["NAME"] != "gardens_training_qa_isolated"
    or _required("DB_NAME") != "gardens_training_qa_isolated"
    or _database["HOST"] != "127.0.0.1"
    or _required("DB_HOST") != "127.0.0.1"
    or str(_database["PORT"]) != "3306"
    or _required("DB_PORT") != "3306"
    or _database["OPTIONS"] != {"charset": "utf8mb4"}
    or not _database["USER"]
    or not _database["PASSWORD"]
    or _database["USER"].casefold() == "root"
):
    raise RuntimeError(
        "QA requires gardens_training_qa_isolated on 127.0.0.1:3306 and a non-root account."
    )

_shared_keys = [SECRET_KEY, *globals().get("SECRET_KEY_FALLBACKS", [])]
SIMPLE_JWT = deepcopy(SIMPLE_JWT)
_shared_keys.append(SIMPLE_JWT.get("SIGNING_KEY", SECRET_KEY))
if (
    SIMPLE_JWT.get("ALGORITHM", "HS256") != "HS256"
    or SIMPLE_JWT.get("JWK_URL")
    or SIMPLE_JWT.get("VERIFYING_KEY")
):
    raise RuntimeError("QA requires the existing local HS256 authentication configuration.")
SECRET_KEY = _qa_key("QA_SECRET_KEY", _shared_keys)
SECRET_KEY_FALLBACKS = []
SIMPLE_JWT["SIGNING_KEY"] = (
    _qa_key("QA_JWT_SIGNING_KEY", _shared_keys)
    if "QA_JWT_SIGNING_KEY" in os.environ else SECRET_KEY
)

_inherited_media = globals().get("MEDIA_ROOT")
_media = Path(_required("QA_MEDIA_ROOT"))
if not _media.is_absolute() or _media.as_posix().startswith("//"):
    raise RuntimeError("QA_MEDIA_ROOT must be an absolute local isolated directory.")
if _media.is_symlink() or _media.is_junction():
    raise RuntimeError("QA_MEDIA_ROOT must not be a symbolic link or junction.")
MEDIA_ROOT = _media.resolve()
_protected_roots = [BASE_DIR.resolve(), Path.cwd().resolve(), Path(STATIC_ROOT).resolve()]
# Development currently leaves MEDIA_ROOT unset, so storage defaults to cwd.
# The checkout is protected above; explicitly configured shared roots are too.
for _location in (
    _inherited_media, os.environ.get("MEDIA_ROOT"), os.environ.get("PRIVATE_MEDIA_ROOT"),
):
    if _location:
        _protected_roots.append(Path(_location).resolve())
if (
    MEDIA_ROOT == Path(MEDIA_ROOT.anchor)
    or any(_overlaps(MEDIA_ROOT, root) for root in _protected_roots)
    or (MEDIA_ROOT.exists() and not MEDIA_ROOT.is_dir())
):
    raise RuntimeError(
        "QA_MEDIA_ROOT must be disjoint from shared media, static files and the checkout."
    )


def _unreadable_media(_error):
    raise RuntimeError("QA media directories must be readable for isolation checks.") from None


# Existing reparse points could otherwise escape FileSystemStorage.safe_join().
# Inspect names/metadata only, without opening, creating or changing any media.
if MEDIA_ROOT.exists():
    for _directory, _folders, _files in os.walk(
        MEDIA_ROOT, followlinks=False, onerror=_unreadable_media,
    ):
        for _name in _folders + _files:
            _entry = Path(_directory) / _name
            if _entry.is_symlink() or _entry.is_junction():
                raise RuntimeError("QA media must not contain symbolic links or junctions.")

STORAGES = deepcopy(STORAGES)
if (
    set(STORAGES) != {"default", "staticfiles"}
    or STORAGES["default"] != {"BACKEND": "django.core.files.storage.FileSystemStorage"}
):
    raise RuntimeError("QA requires default FileSystemStorage without a pinned shared location.")
# Temporary private QA only: runserver --insecure serves finder-discovered assets
# with DEBUG=False, without requiring collectstatic or a manifest.
STORAGES["staticfiles"] = {
    "BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage",
}
MEDIA_URL = ""  # No public media route; existing authorized streaming stays authoritative.

_origin = _required("QA_HTTPS_ORIGIN")
if _origin != "https://desktop-53r9jk9.tail5917a3.ts.net":
    raise RuntimeError("QA_HTTPS_ORIGIN must be the approved private Tailscale HTTPS origin.")
if _required("QA_TRUST_LOOPBACK_PROXY") != "1":
    raise RuntimeError("QA requires explicit loopback-only trusted HTTPS proxy acknowledgement.")
ALLOWED_HOSTS = ["desktop-53r9jk9.tail5917a3.ts.net"]
CSRF_TRUSTED_ORIGINS = [_origin]
SECURE_SSL_REDIRECT = True
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
USE_X_FORWARDED_HOST = False
SESSION_COOKIE_SECURE = CSRF_COOKIE_SECURE = True
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = CSRF_COOKIE_SAMESITE = "Lax"
SESSION_COOKIE_NAME = "gardens_qa_sessionid"
CSRF_COOKIE_NAME = "gardens_qa_csrftoken"
SECURE_HSTS_SECONDS = 0  # Do not persist a temporary runtime's transport policy.
SECURE_HSTS_INCLUDE_SUBDOMAINS = SECURE_HSTS_PRELOAD = False
NOTIFICATIONS_ACTIVATED_AT = ""  # Never activate reminders for a disposable run.
