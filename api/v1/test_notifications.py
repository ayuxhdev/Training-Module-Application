from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from tempfile import TemporaryDirectory
from threading import Barrier
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError
from django.db import connection, connections, transaction
from django.test import TransactionTestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from config.model_test_utils import CurriculumTestCase
from notifications.models import Notification, notification_key
from notifications.services import create_assignment_notification, mark_notifications_read
from organization.models import Employee
from training.models import TrainingAssignment


class NotificationAPITests(CurriculumTestCase):
    base_url = "/api/v1/notifications/"

    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.other_user = get_user_model().objects.create_user(username="notification-other")
        cls.other_employee = Employee.objects.create(
            employee_code="NOTIFY-OTHER", display_name="Other notification owner",
            user=cls.other_user, department=cls.department, job_role=cls.role, date_joined=cls.now.date(),
        )
        cls.other_assignment = TrainingAssignment.objects.create(
            employee=cls.other_employee, training_version=cls.version,
            department_at_assignment=cls.department, job_role_at_assignment=cls.role,
        )
        cls.owned, _ = create_assignment_notification(cls.assignment.pk, Notification.EventType.ASSIGNED)
        cls.foreign, _ = create_assignment_notification(cls.other_assignment.pk, Notification.EventType.ASSIGNED)

    def setUp(self):
        self.api = self.authenticated_client(self.employee_user)

    def authenticated_client(self, user):
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION=f"Bearer {RefreshToken.for_user(user).access_token}")
        return client

    def read_url(self, notification=None):
        return f"{self.base_url}{(notification or self.owned).pk}/read/"

    def endpoints(self):
        return [
            ("get", self.base_url), ("get", self.base_url + "unread-count/"),
            ("post", self.read_url()), ("post", self.base_url + "read-all/"),
        ]

    def assert_error(self, response, status):
        self.assertEqual(response.status_code, status, response.data)
        self.assertEqual(set(response.data), {"error"})
        self.assertEqual(set(response.data["error"]), {"code", "message", "fields"})

    def extra_notification(self):
        # Isolated historical deadline-event fixtures, not reminder generation.
        self.assignment.due_at = self.now + timedelta(days=7, seconds=Notification.objects.count())
        self.assignment.save()
        return Notification.objects.create(
            employee=self.employee, assignment=self.assignment, event_type=Notification.EventType.APPROACHING,
            title="Deadline approaching", message="Your assigned training is due soon.",
            deduplication_key=notification_key(self.assignment, Notification.EventType.APPROACHING),
        )

    def test_every_endpoint_requires_authentication(self):
        client = APIClient()
        for method, url in self.endpoints():
            with self.subTest(url=url):
                self.assert_error(getattr(client, method)(url), 401)
        self.assertFalse(Notification.objects.filter(read_at__isnull=False).exists())

    def test_invalid_and_expired_jwt_are_rejected(self):
        expired = RefreshToken.for_user(self.employee_user).access_token
        expired.set_exp(lifetime=timedelta(minutes=-1))
        for token in ("invalid-token", str(expired)):
            self.api.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
            for method, url in self.endpoints():
                with self.subTest(url=url, expired=token != "invalid-token"):
                    self.assert_error(getattr(self.api, method)(url), 401)

    def test_web_session_alone_cannot_authenticate_these_jwt_endpoints(self):
        client = APIClient()
        client.force_login(self.employee_user)
        for method, url in self.endpoints():
            self.assert_error(getattr(client, method)(url), 401)

    def test_account_without_employee_is_rejected(self):
        client = self.authenticated_client(self.user)
        for method, url in self.endpoints():
            self.assert_error(getattr(client, method)(url), 403)

    def test_inactive_login_is_rejected_with_an_existing_token(self):
        self.employee_user.is_active = False
        self.employee_user.save()
        for method, url in self.endpoints():
            self.assert_error(getattr(self.api, method)(url), 401)

    def test_inactive_employee_is_rejected_even_if_login_is_enabled(self):
        self.employee.is_active = False
        self.employee.deactivation_reason = "Isolated test"
        self.employee.save()
        # Exercise IsActiveEmployee independently of JWT's inactive-user check.
        self.employee_user.is_active = True
        self.employee_user.save()
        for method, url in self.endpoints():
            self.assert_error(getattr(self.api, method)(url), 403)
        self.assertFalse(Notification.objects.filter(read_at__isnull=False).exists())

    def test_list_is_owned_and_exposes_only_the_read_only_contract(self):
        response = self.api.get(self.base_url, {
            "employee_id": self.other_employee.pk, "assignment_id": self.other_assignment.pk,
        })
        self.assertEqual(response.status_code, 200)
        self.assertEqual(set(response.data), {"count", "next", "previous", "results"})
        self.assertEqual(response.data["count"], 1)
        item = response.data["results"][0]
        self.assertEqual(set(item), {"id", "type", "title", "message", "assignment_id", "created_at", "is_read", "read_at"})
        self.assertEqual(item["id"], self.owned.pk)
        self.assertEqual(item["type"], "ASSIGNED")
        self.assertEqual(item["title"], self.owned.title)
        self.assertEqual(item["message"], self.owned.message)
        self.assertEqual(item["assignment_id"], self.assignment.pk)
        self.assertTrue(item["created_at"])
        self.assertFalse(item["is_read"])
        self.assertIsNone(item["read_at"])

    def test_empty_list_zero_count_and_read_all_are_safe(self):
        user = get_user_model().objects.create_user(username="notification-empty")
        Employee.objects.create(
            employee_code="NOTIFY-EMPTY", display_name="Empty owner", user=user,
            department=self.department, job_role=self.role, date_joined=self.now.date(),
        )
        client = self.authenticated_client(user)
        response = client.get(self.base_url)
        self.assertEqual(response.data, {"count": 0, "next": None, "previous": None, "results": []})
        self.assertEqual(client.get(self.base_url + "unread-count/").data, {"unread_count": 0})
        self.assertEqual(client.post(self.base_url + "read-all/", {}, format="json").data, {"updated_count": 0})
        self.assertFalse(Notification.objects.filter(read_at__isnull=False).exists())

    def test_default_pagination_and_timestamp_ties_have_stable_newest_first_order(self):
        with patch("django.utils.timezone.now", return_value=timezone.now() + timedelta(seconds=1)):
            extras = [self.extra_notification() for _ in range(22)]
        expected = [item.pk for item in reversed(extras)] + [self.owned.pk]
        first = self.api.get(self.base_url)
        self.assertEqual(first.data["count"], 23)
        self.assertEqual(len(first.data["results"]), 20)
        self.assertIsNotNone(first.data["next"])
        second = self.api.get(self.base_url, {"page": 2})
        ids = [item["id"] for item in first.data["results"] + second.data["results"]]
        self.assertEqual(ids, expected)
        self.assertEqual(self.api.get(self.base_url).data["results"], first.data["results"])

    def test_page_size_uses_the_existing_hundred_item_limit(self):
        for _ in range(100):
            self.extra_notification()
        response = self.api.get(self.base_url, {"page_size": 1000})
        self.assertEqual(response.data["count"], 101)
        self.assertEqual(len(response.data["results"]), 100)
        self.assertIsNotNone(response.data["next"])

    def test_bad_page_and_malformed_notification_ids_return_controlled_404(self):
        self.assert_error(self.api.get(self.base_url, {"page": 999}), 404)
        for identifier in ("0", "-1", "not-an-id", "1.5", "9" * 30):
            with self.subTest(identifier=identifier):
                self.assert_error(self.api.post(f"{self.base_url}{identifier}/read/", {}, format="json"), 404)

    def test_get_and_head_requests_never_change_notification_state(self):
        before = list(Notification.objects.order_by("pk").values())
        for method in (self.api.get, self.api.head):
            self.assertEqual(method(self.base_url).status_code, 200)
            self.assertEqual(method(self.base_url + "unread-count/").status_code, 200)
        self.assertEqual(list(Notification.objects.order_by("pk").values()), before)

    def test_individual_read_preserves_the_first_timestamp_and_immutable_fields(self):
        before = Notification.objects.values().get(pk=self.owned.pk)
        self.assertEqual(self.api.get(self.base_url + "unread-count/").data, {"unread_count": 1})
        first = self.api.post(self.read_url(), {}, format="json")
        self.assertEqual(first.status_code, 200)
        self.assertTrue(first.data["is_read"])
        self.assertIsNotNone(first.data["read_at"])
        self.assertEqual(self.api.post(self.read_url(), {}, format="json").data, first.data)
        self.assertEqual(self.api.get(self.base_url + "unread-count/").data, {"unread_count": 0})
        after = Notification.objects.values().get(pk=self.owned.pk)
        for field in before.keys() - {"read_at", "updated_at"}:
            self.assertEqual(before[field], after[field], field)
        self.assertIsNone(Notification.objects.get(pk=self.foreign.pk).read_at)
        self.assertEqual(self.api.get(self.base_url).data["results"], [first.data])

    def test_foreign_id_is_404_before_any_payload_is_parsed(self):
        for body, content_type in (("{}", "application/json"), ("{", "application/json")):
            response = self.api.post(self.read_url(self.foreign), body, content_type=content_type)
            self.assert_error(response, 404)
        self.assertFalse(Notification.objects.filter(read_at__isnull=False).exists())

    def test_read_all_is_scoped_idempotent_and_uses_one_bulk_update(self):
        already = self.extra_notification()
        self.api.post(self.read_url(already), {}, format="json")
        already.refresh_from_db()
        original_read_at = already.read_at
        for _ in range(3):
            self.extra_notification()
        before = list(Notification.objects.order_by("pk").values())
        with CaptureQueriesContext(connection) as queries:
            response = self.api.post(self.base_url + "read-all/", {}, format="json")
        updates = [query["sql"] for query in queries if query["sql"].lstrip().upper().startswith("UPDATE")]
        self.assertEqual(len(updates), 1)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data, {"updated_count": 4})
        self.assertEqual(self.api.post(self.base_url + "read-all/", {}, format="json").data, {"updated_count": 0})
        self.assertEqual(self.api.get(self.base_url + "unread-count/").data, {"unread_count": 0})
        already.refresh_from_db()
        self.assertEqual(already.read_at, original_read_at)
        self.foreign.refresh_from_db()
        self.assertIsNone(self.foreign.read_at)
        after = list(Notification.objects.order_by("pk").values())
        for old, new in zip(before, after):
            for field in old.keys() - {"read_at", "updated_at"}:
                self.assertEqual(old[field], new[field], field)

    def test_read_actions_reject_posted_ownership_content_and_read_state(self):
        forged = {
            "employee_id": self.other_employee.pk, "assignment_id": self.other_assignment.pk,
            "title": "Forged", "message": "Forged", "read_at": "2000-01-01T00:00:00Z", "is_read": False,
        }
        for url in (self.read_url(), self.base_url + "read-all/"):
            self.assert_error(self.api.post(url, forged, format="json"), 400)
        self.assertFalse(Notification.objects.filter(read_at__isnull=False).exists())

    def test_malformed_json_and_non_object_payloads_are_controlled(self):
        for url in (self.read_url(), self.base_url + "read-all/"):
            self.assert_error(self.api.post(url, "{", content_type="application/json"), 400)
            self.assert_error(self.api.post(url, [], format="json"), 400)
        self.assertFalse(Notification.objects.filter(read_at__isnull=False).exists())

    def test_unsupported_methods_cannot_create_edit_delete_or_mark_read(self):
        for url in (self.base_url, self.base_url + "unread-count/"):
            for method in ("post", "put", "patch", "delete"):
                self.assert_error(getattr(self.api, method)(url, {}, format="json"), 405)
        for url in (self.read_url(), self.base_url + "read-all/"):
            for method in ("get", "put", "patch", "delete"):
                self.assert_error(getattr(self.api, method)(url), 405)
        self.assertEqual(Notification.objects.count(), 2)
        self.assertFalse(Notification.objects.filter(read_at__isnull=False).exists())

    def test_read_time_cannot_precede_creation_after_a_backwards_clock_adjustment(self):
        with patch("notifications.services.timezone.now", return_value=self.owned.created_at - timedelta(seconds=1)):
            response = self.api.post(self.read_url(), {}, format="json")
        self.assertEqual(response.status_code, 200)
        self.owned.refresh_from_db()
        self.assertEqual(self.owned.read_at, self.owned.created_at)
        self.owned.full_clean()

    def test_general_queryset_updates_remain_prohibited(self):
        with self.assertRaises(ValidationError):
            Notification.objects.filter(employee=self.employee).update(message="Forged")
        self.api.post(self.base_url + "read-all/", {}, format="json")
        self.owned.refresh_from_db()
        self.owned.message = "Forged"
        with self.assertRaises(ValidationError):
            self.owned.save()

    def test_read_metadata_updates_roll_back_with_the_callers_transaction(self):
        with self.assertRaises(RuntimeError), transaction.atomic():
            self.assertEqual(mark_notifications_read(self.employee), 1)
            raise RuntimeError("Rollback read state")
        self.assertFalse(Notification.objects.filter(read_at__isnull=False).exists())


class NotificationReadConcurrencyTests(TransactionTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        media = TemporaryDirectory()
        cls.addClassCleanup(media.cleanup)
        override = override_settings(MEDIA_ROOT=media.name)
        override.enable()
        cls.addClassCleanup(override.disable)

    def setUp(self):
        if connection.vendor != "mysql":
            self.skipTest("Requires MySQL conditional-update concurrency.")
        CurriculumTestCase.setUpTestData.__func__(type(self))
        self.notification, _ = create_assignment_notification(self.assignment.pk, Notification.EventType.ASSIGNED)

    def test_simultaneous_individual_and_read_all_preserve_one_read_timestamp(self):
        barrier = Barrier(2)
        token = str(RefreshToken.for_user(self.employee_user).access_token)

        def synchronized_update(*args, **kwargs):
            barrier.wait(timeout=10)
            return mark_notifications_read(*args, **kwargs)

        def post(url):
            try:
                client = APIClient()
                client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
                response = client.post(url, {}, format="json")
                return response.status_code, response.data
            finally:
                connections.close_all()

        urls = [f"/api/v1/notifications/{self.notification.pk}/read/", "/api/v1/notifications/read-all/"]
        with patch("api.v1.notification_views.mark_notifications_read", side_effect=synchronized_update):
            with ThreadPoolExecutor(max_workers=2) as executor:
                futures = [executor.submit(post, url) for url in urls]
                results = [future.result(timeout=20) for future in futures]
        self.assertEqual([status for status, _ in results], [200, 200])
        self.notification.refresh_from_db()
        from .notification_serializers import NotificationSerializer

        self.assertEqual(results[0][1], NotificationSerializer(self.notification).data)
        self.assertIn(results[1][1]["updated_count"], (0, 1))
        self.assertEqual(Notification.objects.filter(read_at__isnull=False).count(), 1)
