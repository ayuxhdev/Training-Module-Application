from datetime import timedelta

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.db.models import F
from django.urls import reverse
from django.utils import timezone

from config.model_test_utils import CurriculumTestCase
from organization.models import Employee
from training.models import TrainingAssignment

from .models import Notification, notification_key


class NotificationInboxFilterTests(CurriculumTestCase):
    def setUp(self):
        Group.objects.get(name="Employee").user_set.add(self.employee_user)
        self.client.force_login(self.employee_user)
        self.inbox_url = reverse("notifications:inbox")

        self.unread = self.create_notification(
            Notification.EventType.ASSIGNED,
            "Safety update",
            "Review the equipment checklist",
        )
        self.read = self.create_notification(
            Notification.EventType.APPROACHING,
            "Forklift course reminder",
            "Your forklift training is ready",
            due_offset=timedelta(days=3),
            read=True,
        )
        self.second_unread = self.create_notification(
            Notification.EventType.OVERDUE,
            "Safety follow-up",
            "Confirm the protective equipment check",
            due_offset=timedelta(days=5),
        )

        self.other_user = get_user_model().objects.create_user(
            username="notification-filter-outsider",
        )
        self.other_employee = Employee.objects.create(
            employee_code="NOTICE-FILTER-OTHER",
            display_name="Other recipient",
            user=self.other_user,
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
        )
        self.other_assignment = TrainingAssignment.objects.create(
            employee=self.other_employee,
            training_version=self.version,
            status=TrainingAssignment.Status.ASSIGNED,
            department_at_assignment=self.department,
            job_role_at_assignment=self.role,
            assigned_by=self.user,
            assigned_at=timezone.now(),
        )
        self.foreign = Notification.objects.create(
            employee=self.other_employee,
            assignment=self.other_assignment,
            event_type=Notification.EventType.ASSIGNED,
            title="Private outsider notification",
            message="This content must not appear in another inbox",
            deduplication_key=notification_key(
                self.other_assignment,
                Notification.EventType.ASSIGNED,
            ),
        )

    def create_notification(
        self,
        event_type,
        title,
        message,
        *,
        due_offset=None,
        read=False,
    ):
        if due_offset is not None:
            self.assignment.due_at = timezone.now() + due_offset
            self.assignment.save()
        notification = Notification.objects.create(
            employee=self.employee,
            assignment=self.assignment,
            event_type=event_type,
            title=title,
            message=message,
            deduplication_key=notification_key(self.assignment, event_type),
        )
        if read:
            Notification.objects.filter(pk=notification.pk).update(read_at=F("created_at"))
            notification.refresh_from_db()
        return notification

    def test_all_unread_and_read_filters_count_only_the_current_recipient(self):
        expected = {
            "all": {self.unread.pk, self.read.pk, self.second_unread.pk},
            "unread": {self.unread.pk, self.second_unread.pk},
            "read": {self.read.pk},
        }
        for status, notification_ids in expected.items():
            with self.subTest(status=status):
                response = self.client.get(self.inbox_url, {"status": status})
                self.assertEqual(response.status_code, 200)
                self.assertEqual(
                    {
                        item["notification"].pk
                        for item in response.context["notification_items"]
                    },
                    notification_ids,
                )
                self.assertEqual(
                    response.context["page_obj"].paginator.count,
                    len(notification_ids),
                )
                self.assertContains(response, 'aria-label="Notifications, 2 unread"')
                self.assertNotContains(response, self.foreign.title)

        self.assertEqual(
            Notification.objects.filter(
                employee=self.employee,
                read_at__isnull=True,
            ).count(),
            2,
        )

    def test_search_covers_title_and_message_and_combines_with_read_status(self):
        title_match = self.client.get(self.inbox_url, {"q": "Forklift"})
        self.assertEqual(
            [item["notification"].pk for item in title_match.context["notification_items"]],
            [self.read.pk],
        )

        message_match = self.client.get(
            self.inbox_url,
            {"q": "protective equipment check"},
        )
        self.assertEqual(
            {
                item["notification"].pk
                for item in message_match.context["notification_items"]
            },
            {self.second_unread.pk},
        )

        combined = self.client.get(
            self.inbox_url,
            {"q": "Forklift", "status": "read"},
        )
        self.assertEqual(
            [item["notification"].pk for item in combined.context["notification_items"]],
            [self.read.pk],
        )
        no_combined_match = self.client.get(
            self.inbox_url,
            {"q": "Forklift", "status": "unread"},
        )
        self.assertEqual(no_combined_match.context["page_obj"].paginator.count, 0)
        self.assertContains(no_combined_match, "No matching notifications")

    def test_search_and_status_are_validated_and_invalid_filters_fail_closed(self):
        for query in (
            {"status": "unknown"},
            {"q": "x" * 101},
        ):
            with self.subTest(query=query):
                response = self.client.get(self.inbox_url, query)
                self.assertEqual(response.status_code, 400)
                self.assertEqual(response.context["page_obj"].paginator.count, 0)
                self.assertEqual(response.context["notification_items"], [])
                self.assertContains(
                    response,
                    "Please correct the notification filters.",
                    status_code=400,
                )

    def test_pagination_preserves_active_filters_and_clear_resets_them(self):
        for number in range(22):
            self.create_notification(
                Notification.EventType.APPROACHING,
                f"Batch reminder {number:02}",
                "A searchable batch reminder",
                due_offset=timedelta(days=10, seconds=number),
            )

        filters = {"q": "Batch reminder", "status": "unread"}
        first_page = self.client.get(self.inbox_url, {**filters, "page": 1})
        self.assertEqual(first_page.context["page_obj"].paginator.count, 22)
        self.assertEqual(len(first_page.context["notification_items"]), 20)
        self.assertContains(
            first_page,
            "?q=Batch+reminder&amp;status=unread&amp;page=2",
        )
        self.assertContains(first_page, "Showing 1-20 of 22 notifications.")

        second_page = self.client.get(self.inbox_url, {**filters, "page": 2})
        self.assertEqual(second_page.context["page_obj"].number, 2)
        self.assertEqual(len(second_page.context["notification_items"]), 2)
        self.assertContains(
            second_page,
            "?q=Batch+reminder&amp;status=unread&amp;page=1",
        )

        empty = self.client.get(self.inbox_url, {"q": "no matching notice"})
        self.assertEqual(empty.context["page_obj"].paginator.count, 0)
        self.assertContains(empty, "No matching notifications")
        self.assertContains(empty, "Clear search and filters")
        self.assertContains(empty, 'href="/notifications/"')

