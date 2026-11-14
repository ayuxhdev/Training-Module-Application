"""Standalone test-only settings; never import development/QA settings or .env.

Execution additionally requires RR_TEST_ALLOW_CREATE=create-new-disposable-schema
and RR_TEST_EXCLUSIVE_OWNER matching the owner GUID. Nothing is provisioned here.
"""

from datetime import timedelta
import os
from pathlib import Path

from .role_requirement_test_config import DisposableConfig, RUNNER


ROLE_REQUIREMENT_TEST_CONFIG = DisposableConfig.from_environment(os.environ)
BASE_DIR = Path(__file__).resolve().parents[1]
SECRET_KEY = ROLE_REQUIREMENT_TEST_CONFIG.secret_key
DEBUG = False
ALLOWED_HOSTS = ["testserver", "localhost", "127.0.0.1"]
DATABASES = {"default": ROLE_REQUIREMENT_TEST_CONFIG.database_settings()}
DATABASE_ROUTERS = []
MIGRATION_MODULES = {}
TEST_RUNNER = RUNNER
MEDIA_ROOT = ROLE_REQUIREMENT_TEST_CONFIG.media
MEDIA_URL = "/media/"
STATIC_URL = "/static/"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
USE_TZ = True
TIME_ZONE = "UTC"
ROOT_URLCONF = "config.urls"
INSTALLED_APPS = [
    "django.contrib.admin", "django.contrib.auth", "django.contrib.contenttypes",
    "django.contrib.sessions", "django.contrib.messages", "django.contrib.staticfiles",
    "rest_framework", "rest_framework_simplejwt", "rest_framework_simplejwt.token_blacklist",
    "api", "accounts", "organization", "training", "notifications", "assessments",
    "certifications", "reports", "audit",
]
MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware", "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware", "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware", "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]
TEMPLATES = [{
    "BACKEND": "django.template.backends.django.DjangoTemplates", "DIRS": [BASE_DIR / "templates"],
    "APP_DIRS": True, "OPTIONS": {"context_processors": [
        "django.template.context_processors.request", "django.contrib.auth.context_processors.auth",
        "django.contrib.messages.context_processors.messages", "config.context_processors.shell_navigation",
    ]},
}]
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "rest_framework_simplejwt.authentication.JWTAuthentication",
        "rest_framework.authentication.SessionAuthentication",
    ],
    "DEFAULT_PERMISSION_CLASSES": ["rest_framework.permissions.IsAuthenticated"],
    "DEFAULT_PAGINATION_CLASS": "api.pagination.StandardResultsSetPagination", "PAGE_SIZE": 20,
    "EXCEPTION_HANDLER": "api.exceptions.custom_exception_handler",
}
SIMPLE_JWT = {
    "ACCESS_TOKEN_LIFETIME": timedelta(minutes=30), "REFRESH_TOKEN_LIFETIME": timedelta(days=7),
    "ROTATE_REFRESH_TOKENS": True, "BLACKLIST_AFTER_ROTATION": True,
    "UPDATE_LAST_LOGIN": False, "AUTH_HEADER_TYPES": ("Bearer",), "SIGNING_KEY": SECRET_KEY,
}
STORAGES = {
    "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
    "staticfiles": {"BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage"},
}
EMAIL_BACKEND = "django.core.mail.backends.locmem.EmailBackend"
