"""Website notification checks.

Presentation tests are database-free. Database tests require an approved,
exclusively owned disposable MySQL schema; never use a preserved schema.
"""

from datetime import timedelta
from types import SimpleNamespace
from unittest.mock import Mock, patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import AnonymousUser, Group
from django.contrib.messages import get_messages
from django.contrib.messages.storage.fallback import FallbackStorage
from django.core.exceptions import PermissionDenied
from django.http import Http404, HttpResponse
from django.middleware.csrf import CsrfViewMiddleware, get_token
from django.template.loader import render_to_string
from django.test import Client, RequestFactory, SimpleTestCase
from django.urls import resolve, reverse
from django.utils import timezone

from config.model_test_utils import CurriculumTestCase
from organization.models import Employee
from training.models import TrainingAssignment

from . import queries, views
from .models import Notification, notification_key
from .services import create_assignment_notification, mark_notifications_read
from .templatetags.notification_tags import notification_bell


def notification_row(pk):
    return SimpleNamespace(
        pk=pk, assignment_id=pk + 100, title=f"Training update {pk}",
        message="Training <update> & reminder", read_at=None,
        created_at=timezone.now() - timedelta(seconds=pk),
    )


class BoundedRows:
    def __init__(self, count):
        self.rows = [notification_row(pk) for pk in range(1, count + 1)]
        self.slices = []
        self.ordering = None
        self.count_calls = 0

    def order_by(self, *fields):
        self.ordering = fields
        return self

    def count(self):
        self.count_calls += 1
        return len(self.rows)

    def __iter__(self):
        raise AssertionError("Do not evaluate the whole notification history.")

    def __getitem__(self, window):
        if not isinstance(window, slice) or window.stop - window.start > 20:
            raise AssertionError("Only a bounded page may be fetched.")
        self.slices.append((window.start, window.stop))
        return self.rows[window]


class NotificationWebsitePresentationTests(SimpleTestCase):
    databases = set()

    def setUp(self):
        self.factory = RequestFactory()
        self.user = SimpleNamespace(pk=1, is_authenticated=True, is_active=True)
        self.employee = SimpleNamespace(pk=11)

    def request(self, method="get", path="/notifications/", data=None):
        request = getattr(self.factory, method)(path, data=data or {})
        request.user = self.user
        request.session = {}
        request._messages = FallbackStorage(request)
        return request

    def context(self, count, page=None, filters=None):
        rows = BoundedRows(count)
        data = dict(filters or {})
        if page is not None:
            data["page"] = page
        request = self.request(data=data)
        with patch.object(views, "recipient_for_user", return_value=self.employee), \
                patch.object(views, "owned_notifications", return_value=rows) as owned, \
                patch.object(views, "assignment_link_ids", return_value={101}) as links, \
                patch.object(views, "render", return_value=HttpResponse()) as render:
            response = views.inbox(request)
        self.assertIn("no-store", response.headers["Cache-Control"])
        owned.assert_called_once_with(self.employee)
        if count:
            self.assertLessEqual(len(links.call_args.args[2]), 20)
        else:
            links.assert_not_called()
        return render.call_args.args[2], rows

    def test_anonymous_requests_redirect_without_query_or_mutation(self):
        for view, args in ((views.inbox, ()), (views.mark_read, (1,)), (views.mark_all_read, ())):
            request = self.request()
            request.user = AnonymousUser()
            with patch.object(views, "recipient_for_user") as recipient, \
                    patch.object(views, "mark_notifications_read") as mark:
                response = view(request, *args)
            self.assertEqual(response.status_code, 302)
            self.assertTrue(response.url.startswith(reverse("accounts:login")))
            recipient.assert_not_called()
            mark.assert_not_called()

    def test_ineligible_recipient_is_denied_by_all_views(self):
        for view, args, method in (
            (views.inbox, (), "get"), (views.mark_read, (1,), "post"),
            (views.mark_all_read, (), "post"),
        ):
            with patch.object(views, "recipient_for_user", return_value=None), \
                    patch.object(views, "mark_notifications_read") as mark:
                with self.assertRaises(PermissionDenied):
                    view(self.request(method), *args)
                mark.assert_not_called()

    def test_get_cannot_mark_read_and_post_cannot_list(self):
        with patch.object(views, "mark_notifications_read") as mark:
            self.assertEqual(views.mark_read(self.request(), 1).status_code, 405)
            self.assertEqual(views.mark_all_read(self.request()).status_code, 405)
            self.assertEqual(views.inbox(self.request("post")).status_code, 405)
        mark.assert_not_called()

    def test_one_read_checks_owned_lookup_before_calling_existing_service(self):
        owned = Mock()
        with patch.object(views, "recipient_for_user", return_value=self.employee), \
                patch.object(views, "owned_notifications", return_value=owned), \
                patch.object(views, "get_object_or_404") as lookup, \
                patch.object(views, "mark_notifications_read") as mark:
            response = views.mark_read(self.request("post"), 7)
        lookup.assert_called_once_with(owned, pk=7)
        mark.assert_called_once_with(self.employee, notification_id=7)
        self.assertEqual(response.url, reverse("notifications:inbox"))

    def test_one_read_redirect_preserves_validated_filters_and_page(self):
        request = self.request(
            "post",
            path=(
                "/notifications/7/read/?q=Batch+reminder&status=unread&page=2"
                "&next=https%3A%2F%2Fexample.invalid"
            ),
        )
        with patch.object(views, "recipient_for_user", return_value=self.employee), \
                patch.object(views, "owned_notifications") as owned, \
                patch.object(views, "get_object_or_404"), \
                patch.object(views, "mark_notifications_read") as mark:
            response = views.mark_read(request, 7)
        mark.assert_called_once_with(self.employee, notification_id=7)
        self.assertEqual(
            response.url,
            f"{reverse('notifications:inbox')}?q=Batch+reminder&status=unread&page=2",
        )
        owned.assert_called_once_with(self.employee)

    def test_one_read_redirect_discards_invalid_filters_and_page(self):
        cases = (
            (
                "/notifications/7/read/?q=" + ("x" * 101) + "&status=unread&page=2",
                reverse("notifications:inbox"),
            ),
            (
                "/notifications/7/read/?q=Batch&status=invalid&page=2",
                reverse("notifications:inbox"),
            ),
            (
                "/notifications/7/read/?q=Batch&status=unread&page=not-a-page",
                f"{reverse('notifications:inbox')}?q=Batch&status=unread",
            ),
        )
        for path, expected_url in cases:
            with self.subTest(path=path[:80]):
                request = self.request("post", path=path)
                with patch.object(
                    views,
                    "recipient_for_user",
                    return_value=self.employee,
                ), patch.object(
                    views, "owned_notifications"
                ), patch.object(
                    views, "get_object_or_404"
                ), patch.object(
                    views, "mark_notifications_read"
                ) as mark:
                    response = views.mark_read(request, 7)
                mark.assert_called_once_with(self.employee, notification_id=7)
                self.assertEqual(response.url, expected_url)

    def test_filter_forms_carry_only_the_current_return_state(self):
        with patch.object(
            views,
            "filter_notifications",
            side_effect=lambda rows, **_: rows,
        ):
            context, _ = self.context(
                45,
                filters={"q": "Batch reminder", "status": "unread", "page": 2},
            )
        html = render_to_string("notifications/inbox.html", context)
        suffix = "?q=Batch+reminder&amp;status=unread&amp;page=2"
        self.assertIn(
            f'action="/notifications/read-all/{suffix}"',
            html,
        )
        self.assertIn(
            f'action="/notifications/21/read/{suffix}"',
            html,
        )

    def test_foreign_or_missing_lookup_cannot_reach_read_service(self):
        with patch.object(views, "recipient_for_user", return_value=self.employee), \
                patch.object(views, "owned_notifications"), \
                patch.object(views, "get_object_or_404", side_effect=Http404), \
                patch.object(views, "mark_notifications_read") as mark:
            with self.assertRaises(Http404):
                views.mark_read(self.request("post"), 7)
            mark.assert_not_called()

    def test_mark_all_uses_only_current_employee_and_safe_redirect(self):
        request = self.request("post", data={"employee_id": 99, "next": "https://example.invalid"})
        with patch.object(views, "recipient_for_user", return_value=self.employee), \
                patch.object(views, "mark_notifications_read") as mark:
            response = views.mark_all_read(request)
        mark.assert_called_once_with(self.employee)
        self.assertEqual(response.url, reverse("notifications:inbox"))
        self.assertEqual([str(item) for item in get_messages(request)], [
            "All your notifications are marked as read.",
        ])

    def test_csrf_middleware_rejects_both_mutations_without_token(self):
        middleware = CsrfViewMiddleware(lambda request: HttpResponse())
        for view, kwargs in ((views.mark_read, {"pk": 1}), (views.mark_all_read, {})):
            with self.subTest(view=view.__name__):
                response = middleware.process_view(self.request("post"), view, (), kwargs)
                self.assertEqual(response.status_code, 403)
                self.assertFalse(getattr(view, "csrf_exempt", False))

    def test_valid_csrf_token_is_accepted(self):
        seed = self.request()
        token = get_token(seed)
        request = self.request("post", data={"csrfmiddlewaretoken": token})
        request.COOKIES["csrftoken"] = seed.META["CSRF_COOKIE"]
        self.assertIsNone(CsrfViewMiddleware(lambda request: HttpResponse()).process_view(
            request, views.mark_all_read, (), {},
        ))

    def test_history_is_counted_once_and_only_one_page_is_loaded(self):
        context, rows = self.context(45, 2)
        self.assertEqual(rows.count_calls, 1)
        self.assertEqual(rows.ordering, ("-created_at", "-pk"))
        self.assertEqual(rows.slices, [(20, 40)])
        self.assertEqual(len(context["notification_items"]), 20)
        html = render_to_string("notifications/inbox.html", context)
        self.assertIn("Page 2 of 3", html)
        self.assertIn('href="?page=1"', html)
        self.assertIn('href="?page=3"', html)

    def test_empty_inbox_has_no_dead_actions_or_links(self):
        context, rows = self.context(0)
        self.assertEqual(rows.slices, [(0, 0)])
        html = render_to_string("notifications/inbox.html", context)
        self.assertIn("You're all caught up", html)
        self.assertNotIn("Mark all as read", html)
        self.assertNotIn('aria-label="Notification pages"', html)

    def test_malformed_or_out_of_range_pages_have_controlled_fallbacks(self):
        for value, expected in (("invalid", 1), ("0", 3), ("-1", 3), ("999", 3)):
            with self.subTest(value=value):
                context, _ = self.context(45, value)
                self.assertEqual(context["page_obj"].number, expected)

    def test_template_distinguishes_states_escapes_content_and_has_safe_links(self):
        context, _ = self.context(2)
        second = context["notification_items"][1]["notification"]
        second.read_at = second.created_at
        html = render_to_string("notifications/inbox.html", context)
        self.assertIn(">Unread</span>", html)
        self.assertIn(">Read</span>", html)
        self.assertIn("Training &lt;update&gt; &amp; reminder", html)
        self.assertIn('href="/assignments/101/"', html)
        self.assertNotIn('href="/assignments/102/"', html)
        self.assertIn("Assignment unavailable with your current access.", html)
        self.assertIn('action="/notifications/1/read/"', html)
        self.assertNotIn('action="/notifications/2/read/"', html)
        self.assertEqual(html.count('method="post"'), 2)

    def test_bell_uses_an_owned_unread_aggregate_not_history(self):
        request = self.request()
        request.resolver_match = resolve("/notifications/")
        owned = Mock()
        owned.filter.return_value.count.return_value = 3
        with patch("notifications.templatetags.notification_tags.recipient_for_user", return_value=self.employee), \
                patch("notifications.templatetags.notification_tags.owned_notifications", return_value=owned) as scope:
            context = notification_bell({"request": request})
        scope.assert_called_once_with(self.employee)
        owned.filter.assert_called_once_with(read_at__isnull=True)
        owned.filter.return_value.count.assert_called_once_with()
        html = render_to_string("notifications/bell.html", context)
        self.assertIn('aria-label="Notifications, 3 unread"', html)
        self.assertIn('aria-current="page"', html)

    def test_bell_preserves_existing_messages_profile_and_logout_navigation(self):
        request = self.request()
        request.resolver_match = resolve("/notifications/")
        owned = Mock()
        owned.filter.return_value.count.return_value = 0
        # A real Message object supplies the same text used by the shared shell.
        from django.contrib.messages.storage.base import Message
        from django.contrib.messages.constants import SUCCESS

        message = Message(SUCCESS, "Existing success message")
        with patch("notifications.templatetags.notification_tags.recipient_for_user", return_value=self.employee), \
                patch("notifications.templatetags.notification_tags.owned_notifications", return_value=owned):
            html = render_to_string("base.html", {
                "user": self.user, "request": request, "messages": [message],
                "csrf_token": "render-only-token",
            })
        self.assertIn('href="/notifications/"', html)
        self.assertIn('href="/accounts/profile/"', html)
        self.assertIn('action="/accounts/logout/"', html)
        self.assertIn('name="csrfmiddlewaretoken"', html)
        self.assertEqual(html.count("Existing success message"), 1)
        self.assertIn('role="status"', html)
        self.assertIn('aria-label="Notifications, 0 unread"', html)

    def test_account_switch_recomputes_bell_for_new_recipient(self):
        other_employee = SimpleNamespace(pk=22)
        owned = Mock()
        owned.filter.return_value.count.side_effect = [3, 0]
        with patch("notifications.templatetags.notification_tags.recipient_for_user", side_effect=[self.employee, other_employee]), \
                patch("notifications.templatetags.notification_tags.owned_notifications", return_value=owned) as scope:
            first = notification_bell({"request": self.request()})
            self.user = SimpleNamespace(pk=2, is_authenticated=True, is_active=True)
            second = notification_bell({"request": self.request()})
        self.assertEqual(first["notification_unread_count"], 3)
        self.assertEqual(second["notification_unread_count"], 0)
        self.assertEqual([call.args[0].pk for call in scope.call_args_list], [11, 22])

    def test_anonymous_inactive_or_unlinked_users_have_no_bell_data(self):
        self.assertEqual(notification_bell({}), {"notifications_available": False})
        with patch.object(queries.Employee.objects, "filter") as employees:
            self.assertIsNone(queries.recipient_for_user(AnonymousUser()))
            self.user.is_active = False
            self.assertIsNone(queries.recipient_for_user(self.user))
            employees.assert_not_called()
        with patch("notifications.templatetags.notification_tags.recipient_for_user", return_value=None):
            self.assertEqual(notification_bell({"request": self.request()}), {"notifications_available": False})

    def test_notification_does_not_grant_assignment_view_authority(self):
        self.user.is_superuser = False
        self.user.has_perm = Mock(return_value=False)
        self.user.groups = Mock()
        self.user.groups.filter.return_value.exists.return_value = False
        with patch.object(queries.TrainingAssignment.objects, "filter") as assignments:
            self.assertEqual(queries.assignment_link_ids(self.user, self.employee, [notification_row(1)]), set())
            assignments.assert_not_called()

    def test_assignment_links_use_existing_scope_and_recipient_in_one_batch(self):
        with patch.object(queries, "can_manage_assignments", return_value=True), \
                patch.object(queries, "assignment_scope", return_value="existing-scope") as scope, \
                patch.object(queries.TrainingAssignment.objects, "filter") as assignments:
            assignments.return_value.values_list.return_value = [101]
            result = queries.assignment_link_ids(self.user, self.employee, [notification_row(1), notification_row(2)])
        scope.assert_called_once_with(self.user)
        assignments.assert_called_once_with(pk__in=[101, 102], employee_id=11, employee__in="existing-scope")
        self.assertEqual(result, {101})


class NotificationWebsiteDatabaseTests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.employee_user.groups.add(Group.objects.get(name="Employee"))
        cls.other_user = get_user_model().objects.create_user(username="notice-web-other")
        cls.other_user.groups.add(Group.objects.get(name="Employee"))
        cls.other_employee = Employee.objects.create(
            employee_code="NOTICE-WEB-OTHER", display_name="Other notification recipient",
            user=cls.other_user, department=cls.department, job_role=cls.role,
            date_joined=cls.now.date(),
        )
        cls.other_assignment = TrainingAssignment.objects.create(
            employee=cls.other_employee, training_version=cls.version,
            department_at_assignment=cls.department, job_role_at_assignment=cls.role,
        )
        cls.owned, _ = create_assignment_notification(cls.assignment.pk, Notification.EventType.ASSIGNED)
        cls.foreign, _ = create_assignment_notification(cls.other_assignment.pk, Notification.EventType.ASSIGNED)

    def setUp(self):
        self.client.force_login(self.employee_user)

    def read_url(self, item=None):
        return reverse("notifications:mark-read", args=[(item or self.owned).pk])

    def extra_notification(self, index):
        self.assignment.due_at = self.now + timedelta(days=7, seconds=index)
        self.assignment.save()
        return Notification.objects.create(
            employee=self.employee, assignment=self.assignment, event_type=Notification.EventType.APPROACHING,
            title=f"Deadline {index}", message="Owned reminder",
            deduplication_key=notification_key(self.assignment, Notification.EventType.APPROACHING),
        )

    def test_owned_inbox_and_badge_do_not_mark_read_or_leak_other_recipient(self):
        before = list(Notification.objects.order_by("pk").values())
        response = self.client.get(reverse("notifications:inbox"), {"employee_id": self.other_employee.pk})
        self.assertEqual(response.status_code, 200)
        self.assertEqual([item["notification"].pk for item in response.context["notification_items"]], [self.owned.pk])
        self.assertContains(response, 'aria-label="Notifications, 1 unread"')
        self.assertEqual(list(Notification.objects.order_by("pk").values()), before)
        self.assertIn("no-store", response.headers["Cache-Control"])

    def test_cross_recipient_and_missing_ids_are_404_without_mutations(self):
        for pk in (self.foreign.pk, 0, 999999999):
            response = self.client.post(
                f"{reverse('notifications:mark-read', args=[pk])}"
                "?q=Batch+reminder&status=unread&page=2",
            )
            self.assertEqual(response.status_code, 404)
        self.assertFalse(Notification.objects.filter(read_at__isnull=False).exists())

    def test_mark_one_is_idempotent_and_updates_badge_and_existing_messages(self):
        first = self.client.post(self.read_url(), follow=True)
        self.assertContains(first, "Notification marked as read.", count=1)
        self.assertContains(first, 'aria-label="Notifications, 0 unread"')
        self.owned.refresh_from_db()
        timestamp = self.owned.read_at
        self.assertIsNotNone(timestamp)
        self.client.post(self.read_url())
        self.owned.refresh_from_db()
        self.foreign.refresh_from_db()
        self.assertEqual(self.owned.read_at, timestamp)
        self.assertIsNone(self.foreign.read_at)

    def test_mark_all_is_recipient_scoped_and_preserves_event_content(self):
        self.extra_notification(1)
        before = list(Notification.objects.order_by("pk").values())
        response = self.client.post(reverse("notifications:mark-all-read"), {"employee_id": self.other_employee.pk})
        self.assertRedirects(response, reverse("notifications:inbox"))
        self.assertFalse(Notification.objects.filter(employee=self.employee, read_at__isnull=True).exists())
        self.foreign.refresh_from_db()
        self.assertIsNone(self.foreign.read_at)
        for old, new in zip(before, Notification.objects.order_by("pk").values()):
            for field in old.keys() - {"read_at", "updated_at"}:
                self.assertEqual(old[field], new[field])

    def test_read_operations_reject_get_without_any_write(self):
        before = list(Notification.objects.order_by("pk").values())
        for url in (self.read_url(), reverse("notifications:mark-all-read")):
            self.assertEqual(self.client.get(url).status_code, 405)
        self.assertEqual(list(Notification.objects.order_by("pk").values()), before)

    def test_real_csrf_middleware_requires_token_for_both_actions(self):
        client = Client(enforce_csrf_checks=True)
        client.force_login(self.employee_user)
        for url in (self.read_url(), reverse("notifications:mark-all-read")):
            self.assertEqual(client.post(url).status_code, 403)
        self.assertFalse(Notification.objects.filter(read_at__isnull=False).exists())
        page = client.get(reverse("notifications:inbox"))
        self.assertEqual(page.status_code, 200)
        self.assertEqual(client.post(self.read_url(), {"csrfmiddlewaretoken": client.cookies["csrftoken"].value}).status_code, 302)

    def test_pagination_covers_all_owned_rows_in_stable_timestamp_order(self):
        with patch("django.utils.timezone.now", return_value=timezone.now() + timedelta(seconds=1)):
            extras = [self.extra_notification(index) for index in range(22)]
        expected = [item.pk for item in reversed(extras)] + [self.owned.pk]
        actual = []
        for number, size in ((1, 20), (2, 3)):
            response = self.client.get(reverse("notifications:inbox"), {"page": number})
            items = response.context["notification_items"]
            self.assertEqual(len(items), size)
            actual.extend(item["notification"].pk for item in items)
        self.assertEqual(actual, expected)

    def test_empty_inbox_for_another_active_recipient(self):
        user = get_user_model().objects.create_user(username="notice-web-empty")
        Employee.objects.create(
            employee_code="NOTICE-WEB-EMPTY", display_name="Empty recipient", user=user,
            department=self.department, job_role=self.role, date_joined=self.now.date(),
        )
        self.client.force_login(user)
        response = self.client.get(reverse("notifications:inbox"))
        self.assertContains(response, "You're all caught up")
        self.assertContains(response, 'aria-label="Notifications, 0 unread"')
        self.assertNotContains(response, "Mark all as read")

    def test_account_switch_does_not_reuse_inbox_badge_or_read_authority(self):
        mark_notifications_read(self.employee)
        self.assertContains(self.client.get(reverse("notifications:inbox")), 'aria-label="Notifications, 0 unread"')
        self.client.logout()
        self.client.force_login(self.other_user)
        response = self.client.get(reverse("notifications:inbox"))
        self.assertEqual([item["notification"].pk for item in response.context["notification_items"]], [self.foreign.pk])
        self.assertContains(response, 'aria-label="Notifications, 1 unread"')
        self.assertEqual(self.client.post(self.read_url()).status_code, 404)

    def test_unlinked_and_inactive_employee_are_denied_independently(self):
        self.client.force_login(self.user)
        self.assertEqual(self.client.get(reverse("notifications:inbox")).status_code, 403)
        self.employee.is_active = False
        self.employee.deactivation_reason = "Website notification test"
        self.employee.save()
        self.employee_user.refresh_from_db()
        self.assertFalse(self.employee_user.is_active)
        self.employee_user.is_active = True
        self.employee_user.save()
        self.client.force_login(self.employee_user)
        for method, url in (("get", reverse("notifications:inbox")), ("post", self.read_url()), ("post", reverse("notifications:mark-all-read"))):
            self.assertEqual(getattr(self.client, method)(url).status_code, 403)
        self.assertFalse(Notification.objects.filter(read_at__isnull=False).exists())

    def test_anonymous_and_inactive_users_cannot_reach_owned_notifications(self):
        self.client.logout()
        self.assertEqual(self.client.get(reverse("notifications:inbox")).status_code, 302)
        self.client.force_login(self.employee_user)
        self.employee_user.is_active = False
        self.employee_user.save()
        self.assertEqual(self.client.get(reverse("notifications:inbox")).status_code, 302)
        self.assertEqual(self.client.post(self.read_url()).status_code, 302)

    def test_related_links_follow_existing_assignment_authorization_and_retired_history(self):
        response = self.client.get(reverse("notifications:inbox"))
        self.assertContains(response, reverse("training:assignment-detail", args=[self.assignment.pk]))
        self.assertNotContains(response, reverse("training:assignment-detail", args=[self.other_assignment.pk]))
        self.assertEqual(self.client.get(reverse("training:assignment-detail", args=[self.other_assignment.pk])).status_code, 404)
        self.version.status = "RETIRED"
        self.version.save()
        self.assertContains(self.client.get(reverse("notifications:inbox")), reverse("training:assignment-detail", args=[self.assignment.pk]))
        self.employee_user.groups.clear()
        response = self.client.get(reverse("notifications:inbox"))
        self.assertContains(response, "Assignment unavailable with your current access.")
        self.assertNotContains(response, reverse("training:assignment-detail", args=[self.assignment.pk]))

    def test_employee_trainer_and_supervisor_can_follow_owned_assignment_notifications(self):
        own_url = reverse("training:assignment-detail", args=[self.assignment.pk])
        foreign_url = reverse("training:assignment-detail", args=[self.other_assignment.pk])
        for role in ("Employee", "Trainer", "Supervisor"):
            with self.subTest(role=role):
                self.employee_user.groups.set([Group.objects.get(name=role)])
                response = self.client.get(reverse("notifications:inbox"))
                self.assertContains(response, own_url)
                self.assertNotContains(response, foreign_url)
                self.assertTrue(response.context["notification_items"][0]["can_open_assignment"])
                self.assertEqual(self.client.get(own_url).status_code, 200)
                self.assertEqual(self.client.get(foreign_url).status_code, 404)
                self.assertEqual(self.client.get(reverse("training:assignment-create")).status_code, 403)

    def test_mixed_role_manager_keeps_personal_links_and_existing_team_access(self):
        self.employee_user.groups.set(Group.objects.filter(name__in=["Manager", "Trainer", "Supervisor"]))
        self.other_employee.reporting_manager = self.employee
        self.other_employee.save()
        own_url = reverse("training:assignment-detail", args=[self.assignment.pk])
        team_url = reverse("training:assignment-detail", args=[self.other_assignment.pk])
        response = self.client.get(reverse("notifications:inbox"))
        self.assertContains(response, own_url)
        self.assertNotContains(response, team_url)
        self.assertEqual([item["notification"].pk for item in response.context["notification_items"]], [self.owned.pk])
        self.assertEqual(self.client.get(own_url).status_code, 200)
        team_detail = self.client.get(team_url)
        self.assertEqual(team_detail.status_code, 200)
        self.assertFalse(team_detail.context.get("can_learn", False))
        personal = self.client.get(reverse("training:assignment-list"), {"scope": "mine"})
        self.assertEqual({row.pk for row in personal.context["assignments"]}, {self.assignment.pk})
        team = self.client.get(reverse("training:assignment-list"))
        self.assertEqual({row.pk for row in team.context["assignments"]}, {self.assignment.pk, self.other_assignment.pk})

    def test_linked_administrator_keeps_own_notification_links_without_foreign_inbox_data(self):
        self.employee_user.groups.set([Group.objects.get(name="Administrator")])
        response = self.client.get(reverse("notifications:inbox"))
        self.assertContains(response, reverse("training:assignment-detail", args=[self.assignment.pk]))
        self.assertNotContains(response, reverse("training:assignment-detail", args=[self.other_assignment.pk]))
        self.assertEqual([item["notification"].pk for item in response.context["notification_items"]], [self.owned.pk])
        self.assertEqual(self.client.get(reverse("training:assignment-detail", args=[self.other_assignment.pk])).status_code, 200)

    def test_inactive_trainer_employee_cannot_receive_assignment_links_with_active_user(self):
        self.employee_user.groups.set([Group.objects.get(name="Trainer")])
        self.employee.is_active = False
        self.employee.deactivation_reason = "Notification learner eligibility fixture"
        self.employee.save()
        self.employee_user.refresh_from_db()
        self.employee_user.is_active = True
        self.employee_user.save(update_fields=["is_active"])
        self.assertTrue(self.employee_user.is_active)
        self.assertEqual(queries.assignment_link_ids(self.employee_user, self.employee, [self.owned]), set())
        self.client.force_login(self.employee_user)
        self.assertEqual(self.client.get(reverse("notifications:inbox")).status_code, 403)
        self.assertEqual(self.client.get(reverse("training:assignment-detail", args=[self.assignment.pk])).status_code, 403)

    def test_unlinked_trainer_and_supervisor_cannot_open_notification_inbox(self):
        for role in ("Trainer", "Supervisor"):
            with self.subTest(role=role):
                self.user.groups.set([Group.objects.get(name=role)])
                self.client.force_login(self.user)
                self.assertIsNone(queries.recipient_for_user(self.user))
                self.assertEqual(self.client.get(reverse("notifications:inbox")).status_code, 403)
                self.assertEqual(self.client.get(reverse("training:assignment-detail", args=[self.assignment.pk])).status_code, 403)

    def test_assignment_link_batch_rejects_other_employee_references_for_all_eligible_roles(self):
        for role in ("Employee", "Trainer", "Supervisor", "Manager", "Administrator"):
            with self.subTest(role=role):
                self.employee_user.groups.set([Group.objects.get(name=role)])
                user = get_user_model().objects.get(pk=self.employee_user.pk)
                self.assertEqual(
                    queries.assignment_link_ids(user, self.employee, [self.owned, self.foreign]),
                    {self.assignment.pk},
                )
                self.assertEqual(queries.assignment_link_ids(user, self.employee, [self.foreign]), set())

    def test_trainer_and_supervisor_account_switch_keeps_notification_and_assignment_isolation(self):
        for role in ("Trainer", "Supervisor"):
            with self.subTest(role=role):
                self.employee_user.groups.set([Group.objects.get(name=role)])
                self.client.force_login(self.employee_user)
                before = self.client.get(reverse("notifications:inbox"), {"employee_id": self.other_employee.pk})
                self.assertEqual([item["notification"].pk for item in before.context["notification_items"]], [self.owned.pk])
                self.client.logout()
                self.client.force_login(self.other_user)
                after = self.client.get(reverse("notifications:inbox"), {"employee_id": self.employee.pk})
                self.assertEqual([item["notification"].pk for item in after.context["notification_items"]], [self.foreign.pk])
                self.assertNotContains(after, reverse("training:assignment-detail", args=[self.assignment.pk]))
                self.assertEqual(self.client.get(reverse("training:assignment-detail", args=[self.assignment.pk])).status_code, 404)

    def test_removing_learner_role_removes_link_without_changing_notification_content(self):
        self.employee_user.groups.set([Group.objects.get(name="Trainer")])
        original = (self.owned.title, self.owned.message, self.owned.read_at)
        own_url = reverse("training:assignment-detail", args=[self.assignment.pk])
        self.assertContains(self.client.get(reverse("notifications:inbox")), own_url)
        self.employee_user.groups.clear()
        response = self.client.get(reverse("notifications:inbox"))
        self.assertContains(response, "Assignment unavailable with your current access.")
        self.assertNotContains(response, own_url)
        self.assertEqual(self.client.get(own_url).status_code, 403)
        self.owned.refresh_from_db()
        self.assertEqual((self.owned.title, self.owned.message, self.owned.read_at), original)
