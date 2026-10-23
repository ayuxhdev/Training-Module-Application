"""Opt-in, fail-closed staging/production profile; local settings stay unchanged."""

import os
from pathlib import Path
from urllib.parse import urlsplit

from django.core.exceptions import ImproperlyConfigured
from django.http.request import split_domain_port

from .settings import *  # noqa: F403


def required(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise ImproperlyConfigured(f"{name} is required for the production profile.")
    return value


def flag(name, default=False):
    value = os.environ.get(name, str(default)).strip().lower()
    if value not in {"true", "false", "1", "0"}:
        raise ImproperlyConfigured(f"{name} must be true or false.")
    return value in {"true", "1"}


def integer(name, default, minimum, maximum):
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError:
        raise ImproperlyConfigured(f"{name} must be an integer.") from None
    if not minimum <= value <= maximum:
        raise ImproperlyConfigured(f"{name} is outside its supported range.")
    return value


def absolute_directory(name):
    path = Path(required(name))
    if not path.is_absolute():
        raise ImproperlyConfigured(f"{name} must be an absolute directory.")
    return path.resolve()


PRODUCTION_PROFILE = True
DEPLOYMENT_ENVIRONMENT = required("DJANGO_ENVIRONMENT")
if DEPLOYMENT_ENVIRONMENT not in {"staging", "production"} or DEBUG:
    raise ImproperlyConfigured("Production profile requires staging/production and DEBUG=False.")
if len(SECRET_KEY) < 50 or len(set(SECRET_KEY)) < 5 or SECRET_KEY.startswith("django-insecure-"):
    raise ImproperlyConfigured("Production requires a strong, unique DJANGO_SECRET_KEY.")
if not ALLOWED_HOSTS or any(
    "*" in host or host.startswith(".") or not split_domain_port(host)[0] or split_domain_port(host)[1]
    for host in ALLOWED_HOSTS
):
    raise ImproperlyConfigured("Production requires explicit ALLOWED_HOSTS without wildcards.")

SECURE_SSL_REDIRECT = True
SECURE_HSTS_SECONDS = integer("SECURE_HSTS_SECONDS", 3600, 1, 63072000)
SECURE_HSTS_INCLUDE_SUBDOMAINS = flag("SECURE_HSTS_INCLUDE_SUBDOMAINS")
SECURE_HSTS_PRELOAD = flag("SECURE_HSTS_PRELOAD")
if SECURE_HSTS_PRELOAD and (not SECURE_HSTS_INCLUDE_SUBDOMAINS or SECURE_HSTS_SECONDS < 31536000):
    raise ImproperlyConfigured("HSTS preload requires reviewed subdomain coverage and at least one year.")
# Only opt in when the edge strips client headers and Django is network-isolated.
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https") if flag("TRUST_X_FORWARDED_PROTO") else None
USE_X_FORWARDED_HOST = False
SESSION_COOKIE_SECURE = CSRF_COOKIE_SECURE = True
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = CSRF_COOKIE_SAMESITE = "Lax"
SECURE_REFERRER_POLICY = "same-origin"
X_FRAME_OPTIONS = "DENY"
CSRF_TRUSTED_ORIGINS = [origin.strip() for origin in os.environ.get("CSRF_TRUSTED_ORIGINS", "").split(",") if origin.strip()]
for origin in CSRF_TRUSTED_ORIGINS:
    parsed = urlsplit(origin)
    if (parsed.scheme != "https" or not parsed.hostname or "*" in origin
            or parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment):
        raise ImproperlyConfigured("CSRF_TRUSTED_ORIGINS must contain explicit HTTPS origins.")

for name in ("DB_NAME", "DB_USER", "DB_PASSWORD", "DB_HOST", "DB_PORT"):
    required(name)
DATABASES["default"]["PORT"] = integer("DB_PORT", 3306, 1, 65535)
if DATABASES["default"]["USER"].lower() == "root":
    raise ImproperlyConfigured("Production must use a dedicated non-root database account.")
DATABASES["default"]["CONN_MAX_AGE"] = integer("DB_CONN_MAX_AGE", 60, 0, 600)
DATABASES["default"]["CONN_HEALTH_CHECKS"] = True
DATABASES["default"]["OPTIONS"].update(
    connect_timeout=integer("DB_CONNECT_TIMEOUT", 5, 1, 30),
    read_timeout=integer("DB_READ_TIMEOUT", 30, 1, 120),
    write_timeout=integer("DB_WRITE_TIMEOUT", 30, 1, 120),
    init_command="SET SESSION sql_mode=CONCAT_WS(',', NULLIF(@@SESSION.sql_mode, ''), 'STRICT_TRANS_TABLES')",
)
if DATABASES["default"]["HOST"] not in {"localhost", "127.0.0.1", "::1"}:
    ca = Path(required("DB_SSL_CA"))
    if not ca.is_absolute() or not ca.is_file():
        raise ImproperlyConfigured("DB_SSL_CA must reference a readable absolute CA file for remote MySQL.")
    DATABASES["default"]["OPTIONS"].update(ssl={"ca": str(ca)}, ssl_mode="VERIFY_IDENTITY")

STATIC_URL = "/static/"
STATIC_ROOT = absolute_directory("STATIC_ROOT")
MEDIA_ROOT = absolute_directory("PRIVATE_MEDIA_ROOT")
if (MEDIA_ROOT.is_relative_to(BASE_DIR) or BASE_DIR.is_relative_to(MEDIA_ROOT)
        or MEDIA_ROOT.is_relative_to(STATIC_ROOT) or STATIC_ROOT.is_relative_to(MEDIA_ROOT)
        or BASE_DIR.is_relative_to(STATIC_ROOT)):
    raise ImproperlyConfigured("Private media must be outside the application tree and disjoint from static storage.")

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {"safe_json": {"()": "config.operational_logging.OperationalJSONFormatter"}},
    "handlers": {"console": {"class": "logging.StreamHandler", "formatter": "safe_json"}},
    "root": {"handlers": ["console"], "level": "WARNING"},
    "loggers": {
        "django": {"handlers": ["console"], "level": "INFO", "propagate": False},
        "django.server": {"handlers": ["console"], "level": "INFO", "propagate": False},
        "operations": {"handlers": ["console"], "level": "INFO", "propagate": False},
    },
}
