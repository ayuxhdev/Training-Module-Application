"""Opt-in, fresh-schema MySQL integration settings. No .env or QA imports."""
import os
from copy import deepcopy

from .isolated_test_defaults import *  # noqa: F403
from .role_requirement_test_config import IntegrationConfig, INTEGRATION_RUNNER

ALLOWED_HOSTS = deepcopy(ALLOWED_HOSTS)
INSTALLED_APPS = deepcopy(INSTALLED_APPS)
MIDDLEWARE = deepcopy(MIDDLEWARE)
TEMPLATES = deepcopy(TEMPLATES)
REST_FRAMEWORK = deepcopy(REST_FRAMEWORK)
STORAGES = deepcopy(STORAGES)

INTEGRATION_TEST_CONFIG = IntegrationConfig.from_environment(os.environ)
SECRET_KEY = INTEGRATION_TEST_CONFIG.secret_key
DATABASES = {"default": INTEGRATION_TEST_CONFIG.database_settings()}
DATABASE_ROUTERS = []
MIGRATION_MODULES = {}
TEST_RUNNER = INTEGRATION_RUNNER
MEDIA_ROOT = INTEGRATION_TEST_CONFIG.media
SIMPLE_JWT = {**jwt_settings(SECRET_KEY), "CHECK_REVOKE_TOKEN": True}
AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]
