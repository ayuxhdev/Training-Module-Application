"""Strict role-requirement CI profile; no development/QA settings or .env."""
import os
from copy import deepcopy

from .isolated_test_defaults import *  # noqa: F403
from .role_requirement_test_config import DisposableConfig, RUNNER

# Importing another opt-in profile must not share mutable settings containers.
ALLOWED_HOSTS = deepcopy(ALLOWED_HOSTS)
INSTALLED_APPS = deepcopy(INSTALLED_APPS)
MIDDLEWARE = deepcopy(MIDDLEWARE)
TEMPLATES = deepcopy(TEMPLATES)
REST_FRAMEWORK = deepcopy(REST_FRAMEWORK)
STORAGES = deepcopy(STORAGES)

ROLE_REQUIREMENT_TEST_CONFIG = DisposableConfig.from_environment(os.environ)
SECRET_KEY = ROLE_REQUIREMENT_TEST_CONFIG.secret_key
DATABASES = {"default": ROLE_REQUIREMENT_TEST_CONFIG.database_settings()}
DATABASE_ROUTERS = []
MIGRATION_MODULES = {}
TEST_RUNNER = RUNNER
MEDIA_ROOT = ROLE_REQUIREMENT_TEST_CONFIG.media
SIMPLE_JWT = jwt_settings(SECRET_KEY)
