"""Isolated fallback when the development MySQL user cannot create test databases.

Run: python manage.py test --settings=config.test_settings
The regular config.settings remains the MySQL integration-test target.
"""

from .settings import *  # noqa: F403

DATABASES = {"default": {"ENGINE": "django.db.backends.sqlite3", "NAME": ":memory:"}}
PASSWORD_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]
