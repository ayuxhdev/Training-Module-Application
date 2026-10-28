"""Real MySQL draft-allocation races with exact fixture cleanup and no flush."""

from concurrent.futures import ThreadPoolExecutor
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
from training.models import Training, TrainingVersion

from . import training_management_services as services
from .training_management_views import TrainingVersionHistoryView


@skipUnless(connection.vendor == "mysql", "MySQL row-lock concurrency tests require MySQL.")
class TrainingCatalogConcurrencyTests(SimpleTestCase):
    databases = {"default"}

    def assert_isolated_database(self):
        self.assertEqual(connection.vendor, "mysql")
        self.assertEqual(connection.settings_dict["NAME"], "test_gardens_training")
        with connection.cursor() as cursor:
            cursor.execute("SELECT DATABASE()")
            self.assertEqual(cursor.fetchone()[0], "test_gardens_training")

    def setUp(self):
        self.assert_isolated_database()
        self.assertTrue(connection.get_autocommit())
        self.marker = "catalog-race-" + uuid4().hex[:16]
        self.user_ids = []
        self.training_id = None
        self.groups_before = list(Group.objects.order_by("pk").values())
        self.grants_before = list(Group.permissions.through.objects.order_by("pk").values())
        self.addCleanup(self.cleanup_fixtures)
        self.first_actor = self.user("first")
        self.second_actor = self.user("second")
        self.training = Training.objects.create(
            code=self.marker,
            catalog_title="Isolated draft allocation",
            created_by=self.first_actor,
        )
        self.training_id = self.training.pk

    def user(self, suffix):
        user = get_user_model().objects.create_user(
            username=f"{self.marker}-{suffix}", is_superuser=True,
        )
        self.user_ids.append(user.pk)
        return user

    def cleanup_fixtures(self):
        # Only these newly created, exact fixture records are removed. No flush,
        # sequence reset, bootstrap changes or development database access.
        self.assert_isolated_database()
        for model, filters in (
            (AuditLog, {"actor_id__in": self.user_ids}),
            (TrainingVersion, {"training_id": self.training_id}),
            (Training, {"pk": self.training_id}),
            (get_user_model(), {"pk__in": self.user_ids}),
        ):
            models.QuerySet(model, using="default").filter(**filters)._raw_delete("default")
        self.assertEqual(list(Group.objects.order_by("pk").values()), self.groups_before)
        self.assertEqual(list(Group.permissions.through.objects.order_by("pk").values()), self.grants_before)
        connection.close()

    def allocate_concurrently(self, expected_numbers):
        first_saved, second_boundary, second_finished, release = (Event() for _ in range(4))
        thread = local()
        original_save_form = services._save_form
        training_table = connection.ops.quote_name(Training._meta.db_table)

        def hold_first_save(*args, **kwargs):
            instance = original_save_form(*args, **kwargs)
            if thread.role == "first":
                # The service's outer atomic block still holds the Training row
                # lock; its version and deferred audit have not committed yet.
                self.assertTrue(connection.in_atomic_block)
                first_saved.set()
                if not release.wait(30):
                    raise AssertionError("The first draft transaction was not released")
            return instance

        def observe(execute, sql, params, many, context):
            if "FOR UPDATE" in sql.upper() and training_table in sql:
                second_boundary.set()
            return execute(sql, params, many, context)

        def run(role, actor):
            thread.role = role
            close_old_connections()
            try:
                self.assert_isolated_database()
                with connection.cursor() as cursor:
                    cursor.execute("SET SESSION innodb_lock_wait_timeout=10")
                request = APIRequestFactory().post(
                    f"/api/v1/management/trainings/{self.training_id}/versions/",
                    {"title": f"Concurrent {role} draft"}, format="json",
                )
                force_authenticate(request, user=actor)
                view = TrainingVersionHistoryView.as_view()
                if role == "second":
                    with connection.execute_wrapper(observe):
                        response = view(request, pk=self.training_id)
                else:
                    response = view(request, pk=self.training_id)
                return response.status_code, response.data
            finally:
                if role == "second":
                    second_finished.set()
                connection.close()

        with patch.object(services, "_save_form", hold_first_save), ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(run, "first", self.first_actor)
            try:
                self.assertTrue(first_saved.wait(15), "First draft never reached its uncommitted boundary")
                second = pool.submit(run, "second", self.second_actor)
                self.assertTrue(second_boundary.wait(15), "Second request never attempted the Training row lock")
                # Give an unlocked request time to finish while the first lock
                # remains held, rather than sampling thread scheduling once.
                finished_while_locked = second_finished.wait(1)
            finally:
                release.set()
            results = first.result(20), second.result(20)

        self.assertFalse(finished_while_locked, "Draft allocation was not serialized by the Training row lock")
        self.assertEqual(tuple(status for status, _ in results), (201, 201), results)
        self.assertEqual(tuple(data["version_number"] for _, data in results), expected_numbers)
        self.assertNotEqual(results[0][1]["id"], results[1][1]["id"])

        versions = list(TrainingVersion.objects.filter(
            pk__in=[data["id"] for _, data in results],
        ).order_by("version_number"))
        self.assertEqual(len(versions), 2)
        for version, actor, number in zip(versions, (self.first_actor, self.second_actor), expected_numbers):
            self.assertEqual(version.training_id, self.training_id)
            self.assertEqual(version.version_number, number)
            self.assertEqual(version.created_by_id, actor.pk)
            self.assertEqual(version.status, TrainingVersion.Status.DRAFT)
            self.assertIsNone(version.published_at)
            self.assertIsNone(version.published_by_id)
            event = AuditLog.objects.get(
                actor_id=actor.pk,
                action="training.trainingversion.created",
                entity_type="training.trainingversion",
                entity_id=str(version.pk),
            )
            self.assertEqual(event.before_data, {})
            self.assertEqual(event.after_data["version_number"], number)
            self.assertEqual(event.after_data["status"], TrainingVersion.Status.DRAFT)
        self.assertEqual(AuditLog.objects.filter(actor_id__in=self.user_ids).count(), 2)

    def test_first_two_drafts_serialize_on_parent_when_no_version_rows_exist(self):
        self.assertFalse(TrainingVersion.objects.filter(training_id=self.training_id).exists())
        self.allocate_concurrently((1, 2))
        self.assertEqual(TrainingVersion.objects.filter(training_id=self.training_id).count(), 2)

    def test_concurrent_drafts_allocate_after_highest_existing_version(self):
        existing = TrainingVersion.objects.create(
            training=self.training,
            version_number=7,
            title="Existing draft",
            created_by=self.first_actor,
        )
        before = TrainingVersion.objects.filter(pk=existing.pk).values().get()
        self.allocate_concurrently((8, 9))
        self.assertEqual(TrainingVersion.objects.filter(pk=existing.pk).values().get(), before)
        self.assertEqual(TrainingVersion.objects.filter(training_id=self.training_id).count(), 3)
