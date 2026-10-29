"""Real MySQL authoring races; exact disposable fixtures, no flush or resets."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import nullcontext
from threading import Event, local
from unittest import skipUnless
from unittest.mock import patch
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db import close_old_connections, connection, models
from django.test import SimpleTestCase
from rest_framework.test import APIRequestFactory, force_authenticate

from audit.models import AuditLog
from training.models import Lesson, Module, Training, TrainingVersion

from . import training_management_services as services
from .curriculum_management_views import ModuleCreateView, ModuleDetailView, TextLessonCreateView


@skipUnless(connection.vendor == "mysql", "MySQL row-lock concurrency tests require MySQL.")
class CurriculumConcurrencyTests(SimpleTestCase):
    databases = {"default"}

    def assert_isolated(self):
        self.assertEqual(connection.vendor, "mysql")
        self.assertEqual(connection.settings_dict["NAME"], "test_gardens_training")
        with connection.cursor() as cursor:
            cursor.execute("SELECT DATABASE()")
            self.assertEqual(cursor.fetchone()[0], "test_gardens_training")

    def setUp(self):
        self.assert_isolated()
        self.assertTrue(connection.get_autocommit())
        marker = "curriculum-race-" + uuid4().hex[:16]
        self.user_ids = []
        self.training_id = None
        self.groups = list(Group.objects.order_by("pk").values())
        self.grants = list(Group.permissions.through.objects.order_by("pk").values())
        self.addCleanup(self.cleanup_fixtures)
        self.actors = []
        for suffix in ("first", "second"):
            user = get_user_model().objects.create_user(username=f"{marker}-{suffix}", is_superuser=True)
            self.user_ids.append(user.pk)
            self.actors.append(user)
        self.training = Training.objects.create(code=marker, catalog_title="Isolated curriculum", created_by=self.actors[0])
        self.training_id = self.training.pk
        self.version = TrainingVersion.objects.create(
            training=self.training, version_number=1, title="Draft", created_by=self.actors[0],
        )
        self.module = Module.objects.create(training_version=self.version, title="Original", position=1)

    def cleanup_fixtures(self):
        self.assert_isolated()
        for model, filters in (
            (AuditLog, {"actor_id__in": self.user_ids}),
            (Lesson, {"module__training_version__training_id": self.training_id}),
            (Module, {"training_version__training_id": self.training_id}),
            (TrainingVersion, {"training_id": self.training_id}),
            (Training, {"pk": self.training_id}),
            (get_user_model(), {"pk__in": self.user_ids}),
        ):
            models.QuerySet(model, using="default").filter(**filters)._raw_delete("default")
        self.assertEqual(list(Group.objects.order_by("pk").values()), self.groups)
        self.assertEqual(list(Group.permissions.through.objects.order_by("pk").values()), self.grants)
        connection.close()

    def race(self, first_call, second_call, expected):
        held, boundary, finished, release = (Event() for _ in range(4))
        thread = local()
        original = services._save_form
        table = connection.ops.quote_name(TrainingVersion._meta.db_table)

        def hold(*args, **kwargs):
            instance = original(*args, **kwargs)
            if thread.role == "first":
                self.assertTrue(connection.in_atomic_block)
                held.set()
                if not release.wait(30):
                    raise AssertionError("First mutation was not released")
            return instance

        def observe(execute, sql, params, many, context):
            if "FOR UPDATE" in sql.upper() and table in sql:
                boundary.set()
            return execute(sql, params, many, context)

        def run(role, actor, call):
            thread.role = role
            close_old_connections()
            try:
                self.assert_isolated()
                with connection.cursor() as cursor:
                    cursor.execute("SET SESSION innodb_lock_wait_timeout=10")
                view, method, kwargs, data = call
                request = getattr(APIRequestFactory(), method)("/isolated-curriculum/", data, format="json")
                force_authenticate(request, user=actor)
                observer = connection.execute_wrapper(observe) if role == "second" else nullcontext()
                with observer:
                    response = view.as_view()(request, **kwargs)
                return response.status_code, response.data
            finally:
                if role == "second":
                    finished.set()
                connection.close()

        with patch.object(services, "_save_form", hold), ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(run, "first", self.actors[0], first_call)
            try:
                self.assertTrue(held.wait(15), "First request never reached its uncommitted boundary")
                second = pool.submit(run, "second", self.actors[1], second_call)
                self.assertTrue(boundary.wait(15), "Second request did not attempt the version lock")
                finished_while_locked = finished.wait(1)
            finally:
                release.set()
            results = first.result(20), second.result(20)
        self.assertFalse(finished_while_locked, "Requests did not serialize on the version lock")
        self.assertEqual(tuple(status for status, _ in results), expected, results)
        return results

    def test_same_module_position_creation_serializes_and_rejects_second(self):
        kwargs = {"version_pk": self.version.pk}
        call = (ModuleCreateView, "post", kwargs, {"title": "New", "position": 2})
        self.race(call, call, (201, 400))
        self.assertEqual(Module.objects.filter(training_version=self.version, position=2).count(), 1)
        self.assertEqual(AuditLog.objects.filter(actor_id__in=self.user_ids).count(), 1)

    def test_same_lesson_position_creation_serializes_and_rejects_second(self):
        kwargs = {"version_pk": self.version.pk, "module_pk": self.module.pk}
        call = (TextLessonCreateView, "post", kwargs, {"title": "New", "body": "Read", "position": 1})
        self.race(call, call, (201, 400))
        self.assertEqual(Lesson.objects.filter(module=self.module).count(), 1)
        self.assertEqual(AuditLog.objects.filter(actor_id__in=self.user_ids).count(), 1)

    def test_two_module_moves_to_same_position_do_not_partially_overwrite(self):
        other = Module.objects.create(training_version=self.version, title="Other", position=2)
        first = (ModuleDetailView, "patch", {"version_pk": self.version.pk, "pk": self.module.pk}, {"position": 5})
        second = (ModuleDetailView, "patch", {"version_pk": self.version.pk, "pk": other.pk}, {"position": 5, "title": "Rejected"})
        self.race(first, second, (200, 400))
        self.module.refresh_from_db()
        other.refresh_from_db()
        self.assertEqual(self.module.position, 5)
        self.assertEqual((other.position, other.title), (2, "Other"))
        self.assertEqual(AuditLog.objects.filter(actor_id__in=self.user_ids).count(), 1)

    def test_partial_edits_use_fresh_locked_state(self):
        kwargs = {"version_pk": self.version.pk, "pk": self.module.pk}
        first = (ModuleDetailView, "patch", kwargs, {"title": "First edit"})
        second = (ModuleDetailView, "patch", kwargs, {"description": "Second edit"})
        self.race(first, second, (200, 200))
        self.module.refresh_from_db()
        self.assertEqual((self.module.title, self.module.description), ("First edit", "Second edit"))
        events = AuditLog.objects.filter(actor_id__in=self.user_ids).order_by("pk")
        self.assertEqual(events.count(), 2)
        self.assertEqual(events.last().before_data["title"], "First edit")
