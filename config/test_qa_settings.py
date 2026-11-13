"""Database-free guards: python -B -m unittest config.test_qa_settings."""

from copy import deepcopy
import os
from pathlib import Path
import runpy
import secrets
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import ANY, patch

import jwt
from django.core.files.storage import FileSystemStorage


class QASettingsTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[1]
        protected = [self.root, Path.cwd().resolve()]
        for name in ("MEDIA_ROOT", "PRIVATE_MEDIA_ROOT"):
            if os.environ.get(name):
                protected.append(Path(os.environ[name]).resolve())
        # A fresh sibling remains disjoint even when the checkout is under TEMP.
        # Register cleanup before guards so they stop before fixture removal.
        for parent in dict.fromkeys((Path(tempfile.gettempdir()).resolve(), self.root.parent)):
            if any(parent.is_relative_to(root) for root in protected):
                continue
            directory = self.enterContext(tempfile.TemporaryDirectory(
                prefix="gardens-qa-settings-", dir=parent,
            ))
            self.media = Path(directory).resolve()
            self.assertEqual(self.media.parent, parent)
            self.assertFalse(any(
                self.media.is_relative_to(root) or root.is_relative_to(self.media)
                for root in protected
            ))
            break
        else:
            self.fail("No isolated temporary media parent is available.")
        self.environment = {
            "DEBUG": "true",
            "DJANGO_SECRET_KEY": secrets.token_urlsafe(64),
            "QA_SECRET_KEY": secrets.token_urlsafe(64),
            "DB_NAME": "gardens_training_qa_isolated",
            "DB_HOST": "127.0.0.1",
            "DB_PORT": "3306",
            "DB_USER": "qa_unit_test_only",
            "DB_PASSWORD": "unused-not-a-real-credential",
            "QA_MEDIA_ROOT": str(self.media),
            "QA_HTTPS_ORIGIN": "https://desktop-53r9jk9.tail5917a3.ts.net",
            "QA_TRUST_LOOPBACK_PROXY": "1",
        }
        # Fail immediately if import ever attempts database access or provisioning.
        for target in (
            "django.db.backends.base.base.BaseDatabaseWrapper.connect",
            "pathlib.Path.mkdir", "pathlib.Path.write_text", "pathlib.Path.write_bytes",
            "os.mkdir", "socket.socket.connect",
        ):
            guard = patch(target, side_effect=AssertionError("Settings must be read-only."))
            guard.start()
            self.addCleanup(guard.stop)

    def load(self, changes=None, base_changes=None):
        environment = {**self.environment, **(changes or {})}
        environment = {name: value for name, value in environment.items() if value is not None}
        with patch.dict(os.environ, environment, clear=True), patch("dotenv.load_dotenv"):
            base = runpy.run_path(str(self.root / "config/settings.py"))
            base.update(base_changes or {})
            original = deepcopy({name: value for name, value in base.items() if name.isupper()})
            module = ModuleType("config.settings")
            module.__dict__.update(base)
            with patch.dict(sys.modules, {"config.settings": module}):
                values = runpy.run_module("config.qa_settings", run_name="config._qa_settings_test")
            self.assertEqual(
                original, {name: value for name, value in base.items() if name.isupper()}
            )
            return values, base

    def test_missing_empty_weak_default_and_whitespace_secrets_fail_closed(self):
        for key in (
            None, "", "short", "x" * 80,
            "django-insecure-" + secrets.token_urlsafe(64),
            "change-me-" + secrets.token_urlsafe(64),
            "default-" + secrets.token_urlsafe(64),
            " " + secrets.token_urlsafe(64),
        ):
            with self.subTest(kind="missing" if key is None else "invalid"):
                with self.assertRaises(RuntimeError):
                    self.load({"QA_SECRET_KEY": key})

    def test_development_secret_and_explicit_signing_key_cannot_be_reused(self):
        shared = self.environment["DJANGO_SECRET_KEY"]
        for name in ("QA_SECRET_KEY", "QA_JWT_SIGNING_KEY"):
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                self.load({name: shared})
        inherited_signing_key = secrets.token_urlsafe(64)
        for name in ("QA_SECRET_KEY", "QA_JWT_SIGNING_KEY"):
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                self.load(
                    {name: inherited_signing_key},
                    {"SIMPLE_JWT": {"SIGNING_KEY": inherited_signing_key}},
                )
        with self.assertRaises(RuntimeError):
            self.load(
                {"QA_SECRET_KEY": shared},
                {"SECRET_KEY": secrets.token_urlsafe(64), "SECRET_KEY_FALLBACKS": [shared]},
            )

    def test_explicit_qa_signing_key_must_itself_be_strong(self):
        for key in ("", "weak", "x" * 80):
            with self.subTest(kind="invalid"), self.assertRaises(RuntimeError):
                self.load({"QA_JWT_SIGNING_KEY": key})

    def test_protected_missing_and_unexpected_database_names_are_rejected(self):
        for name in (
            None, "", "gardens_training", "test_gardens_training",
            "another_database", "Gardens_Training_QA_Isolated",
        ):
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                self.load({"DB_NAME": name})

    def test_remote_missing_and_unexpected_database_connection_fields_are_rejected(self):
        for changes in (
            {"DB_HOST": "localhost"}, {"DB_HOST": "192.0.2.1"}, {"DB_HOST": None},
            {"DB_PORT": "3307"}, {"DB_PORT": None}, {"DB_USER": ""}, {"DB_PASSWORD": ""},
            {"DB_USER": "root"}, {"DB_USER": "ROOT"},
        ):
            with self.subTest(fields=list(changes)), self.assertRaises(RuntimeError):
                self.load(changes)

    def test_database_aliases_routers_and_option_file_overrides_are_rejected(self):
        values, _ = self.load()
        database = values["DATABASES"]["default"]
        for databases in (
            {"default": database, "other": deepcopy(database)},
            {"default": {**database, "ENGINE": "django.db.backends.sqlite3"}},
            {"default": {**database, "OPTIONS": {"read_default_file": "unused.cnf"}}},
            {"default": {**database, "TEST": {"NAME": "gardens_training"}}},
        ):
            with self.subTest(kind="unexpected configuration"), self.assertRaises(RuntimeError):
                self.load(base_changes={"DATABASES": databases})
        with self.assertRaises(RuntimeError):
            self.load(base_changes={"DATABASE_ROUTERS": ["unused.Router"]})

    def test_missing_relative_repository_ancestor_and_file_media_paths_are_rejected(self):
        for location in (
            None, "", "media", "//server/share/qa", str(self.root), str(self.root.parent),
            str(self.root / "training/videos"), str(self.root / "staticfiles/private"),
            str(Path(self.media.anchor)), str(Path(os.__file__).resolve()),
        ):
            with self.subTest(location=location), self.assertRaises(RuntimeError):
                self.load({"QA_MEDIA_ROOT": location})

    def test_shared_media_static_roots_and_descendants_are_rejected(self):
        for setting in ("MEDIA_ROOT", "PRIVATE_MEDIA_ROOT"):
            for shared in (self.media, self.media.parent, self.media / "child"):
                with self.subTest(setting=setting), self.assertRaises(RuntimeError):
                    self.load({setting: str(shared)})
        with self.assertRaises(RuntimeError):
            self.load(base_changes={"MEDIA_ROOT": self.media})
        with self.assertRaises(RuntimeError):
            self.load(base_changes={"STATIC_ROOT": self.media})

    def test_media_alias_resolving_into_checkout_is_rejected(self):
        resolve = Path.resolve

        def redirected(path, *args, **kwargs):
            return self.root if path == self.media else resolve(path, *args, **kwargs)

        with patch.object(Path, "resolve", redirected), self.assertRaises(RuntimeError):
            self.load()

    def test_existing_media_links_fail_closed(self):
        for link_method in ("is_symlink", "is_junction"):
            with self.subTest(link_method=link_method):
                with patch.object(Path, link_method, return_value=True):
                    with self.assertRaisesRegex(
                        RuntimeError,
                        "^QA_MEDIA_ROOT must not be a symbolic link or junction\\.$",
                    ):
                        self.load()
                original = getattr(Path, link_method)

                def child_link(path, _original=original):
                    return path == self.media / "linked-child" or _original(path)

                with patch(
                    "os.walk", return_value=[(str(self.media), ["linked-child"], [])],
                ) as walk:
                    with patch.object(Path, link_method, child_link):
                        with self.assertRaisesRegex(
                            RuntimeError,
                            "^QA media must not contain symbolic links or junctions\\.$",
                        ):
                            self.load()
                    walk.assert_called_once_with(self.media, followlinks=False, onerror=ANY)

    def test_unreadable_media_tree_fails_closed(self):
        def inaccessible(_root, **kwargs):
            kwargs["onerror"](PermissionError())

        with patch("os.walk", side_effect=inaccessible) as walk:
            with self.assertRaisesRegex(
                RuntimeError, "^QA media directories must be readable for isolation checks\\.$",
            ):
                self.load()
            walk.assert_called_once_with(self.media, followlinks=False, onerror=ANY)

    def test_video_and_certificate_storage_paths_are_rooted_in_qa_media(self):
        values, _ = self.load()
        file_settings = SimpleNamespace(MEDIA_ROOT=values["MEDIA_ROOT"])
        with patch("django.core.files.storage.filesystem.settings", file_settings):
            storage = FileSystemStorage()
            for key in ("training/videos/2026/11/synthetic.mp4", "certificates/2026/11/qa.pdf"):
                self.assertEqual(Path(storage.path(key)), self.media / key)

    def test_pinned_or_custom_storage_is_rejected(self):
        for default in (
            {
                "BACKEND": "django.core.files.storage.FileSystemStorage",
                "OPTIONS": {"location": str(self.root)},
            },
            {"BACKEND": "unused.SharedStorage"},
        ):
            with self.subTest(kind="unsafe storage"), self.assertRaises(RuntimeError):
                self.load(base_changes={"STORAGES": {"default": default, "staticfiles": {}}})

    def test_https_origin_and_proxy_acknowledgement_are_required(self):
        for origin in (
            None, "", "http://desktop-53r9jk9.tail5917a3.ts.net", "https://example.test",
            "https://*.ts.net", self.environment["QA_HTTPS_ORIGIN"] + "/path",
        ):
            with self.subTest(origin=origin), self.assertRaises(RuntimeError):
                self.load({"QA_HTTPS_ORIGIN": origin})
        for acknowledgement in (None, "", "0", "true"):
            with self.subTest(acknowledgement=acknowledgement), self.assertRaises(RuntimeError):
                self.load({"QA_TRUST_LOOPBACK_PROXY": acknowledgement})

    def test_remote_jwt_key_sources_or_changed_algorithm_are_rejected(self):
        for jwt_settings in (
            {"ALGORITHM": "RS256"}, {"JWK_URL": "https://example.test/keys"},
            {"VERIFYING_KEY": "unused-external-key"},
        ):
            with self.subTest(fields=list(jwt_settings)), self.assertRaises(RuntimeError):
                self.load(base_changes={"SIMPLE_JWT": jwt_settings})

    def test_qa_staticfiles_override_keeps_debug_off_and_other_storage_unchanged(self):
        values, base = self.load({"DEBUG": "false"})
        self.assertFalse(values["DEBUG"])
        self.assertFalse(base["DEBUG"])
        self.assertEqual(values["STORAGES"]["staticfiles"], {
            "BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage",
        })
        self.assertEqual(base["STORAGES"]["staticfiles"], {
            "BACKEND": "django.contrib.staticfiles.storage.ManifestStaticFilesStorage",
        })
        self.assertEqual(values["STORAGES"]["default"], base["STORAGES"]["default"])
        self.assertEqual(values["STATIC_ROOT"], base["STATIC_ROOT"])
        self.assertEqual(values["STATIC_URL"], base["STATIC_URL"])
        self.assertEqual(values["MEDIA_ROOT"], self.media)
        self.assertEqual(values["MEDIA_URL"], "")

    def test_valid_configuration_loads_without_mutation_or_provisioning(self):
        values, base = self.load({"ALLOWED_HOSTS": "*", "NOTIFICATIONS_ACTIVATED_AT": "unused"})
        self.assertTrue(values["QA_PROFILE"])
        self.assertFalse(values["DEBUG"])
        self.assertTrue(base["DEBUG"])
        self.assertEqual(values["DATABASES"]["default"]["NAME"], "gardens_training_qa_isolated")
        self.assertEqual(values["MEDIA_ROOT"], self.media)
        self.assertEqual(
            values["STORAGES"]["default"]["BACKEND"],
            "django.core.files.storage.FileSystemStorage",
        )
        self.assertNotIn("MEDIA_ROOT", base)
        self.assertEqual(values["SIMPLE_JWT"]["SIGNING_KEY"], self.environment["QA_SECRET_KEY"])
        self.assertEqual(values["SECRET_KEY_FALLBACKS"], [])
        for name in ("ACCESS_TOKEN_LIFETIME", "REFRESH_TOKEN_LIFETIME"):
            self.assertEqual(values["SIMPLE_JWT"][name], base["SIMPLE_JWT"][name])
        self.assertTrue(values["SIMPLE_JWT"]["ROTATE_REFRESH_TOKENS"])
        self.assertTrue(values["SIMPLE_JWT"]["BLACKLIST_AFTER_ROTATION"])
        self.assertEqual(values["ALLOWED_HOSTS"], ["desktop-53r9jk9.tail5917a3.ts.net"])
        self.assertEqual(values["CSRF_TRUSTED_ORIGINS"], [self.environment["QA_HTTPS_ORIGIN"]])
        self.assertEqual(values["SECURE_PROXY_SSL_HEADER"], ("HTTP_X_FORWARDED_PROTO", "https"))
        self.assertTrue(values["SECURE_SSL_REDIRECT"])
        self.assertTrue(values["SESSION_COOKIE_SECURE"])
        self.assertTrue(values["CSRF_COOKIE_SECURE"])
        self.assertFalse(values["USE_X_FORWARDED_HOST"])
        self.assertEqual(values["SESSION_COOKIE_NAME"], "gardens_qa_sessionid")
        self.assertEqual(values["CSRF_COOKIE_NAME"], "gardens_qa_csrftoken")
        self.assertEqual(values["NOTIFICATIONS_ACTIVATED_AT"], "")

    def test_qa_and_development_jwts_do_not_verify_across_environments(self):
        for signing_override in ({}, {"QA_JWT_SIGNING_KEY": secrets.token_urlsafe(64)}):
            values, base = self.load(signing_override)
            qa_key = values["SIMPLE_JWT"]["SIGNING_KEY"]
            development_key = base["SECRET_KEY"]
            token = jwt.encode({"sub": "synthetic-qa-user"}, qa_key, algorithm="HS256")
            self.assertEqual(
                jwt.decode(token, qa_key, algorithms=["HS256"])["sub"], "synthetic-qa-user"
            )
            with self.assertRaises(jwt.InvalidSignatureError):
                jwt.decode(token, development_key, algorithms=["HS256"])
            token = jwt.encode(
                {"sub": "synthetic-development-user"}, development_key, algorithm="HS256"
            )
            with self.assertRaises(jwt.InvalidSignatureError):
                jwt.decode(token, qa_key, algorithms=["HS256"])


if __name__ == "__main__":
    unittest.main()
