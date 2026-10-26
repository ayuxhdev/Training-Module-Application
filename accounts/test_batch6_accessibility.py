"""Database-free checks for existing web announcement boundaries."""

from datetime import timedelta
from html.parser import HTMLParser
from types import SimpleNamespace

from django.contrib import messages
from django.contrib.auth.models import AnonymousUser
from django.contrib.messages.storage.fallback import FallbackStorage
from django.template.loader import render_to_string
from django.test import RequestFactory, SimpleTestCase
from django.utils import timezone


class AnnouncementRegions(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.stack = []
        self.overlaps = []
        self.roles = []
        self.message_roles = []
        self.feed(html)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        live = (
            attrs.get("role") in {"alert", "status"}
            or attrs.get("aria-live", "off") != "off"
        )
        if live and any(parent_live for _, parent_live in self.stack):
            self.overlaps.append(tag)
        if attrs.get("role"):
            self.roles.append(attrs["role"])
        if "message" in attrs.get("class", "").split():
            self.message_roles.append(attrs.get("role"))
        if tag not in {"meta", "link", "input", "br", "hr", "img", "path", "circle"}:
            self.stack.append((tag, live))

    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                break


class Batch6AccessibilityTests(SimpleTestCase):
    databases = set()

    def request(self):
        request = RequestFactory().get("/")
        request.user = AnonymousUser()
        request.session = {}
        request._messages = FallbackStorage(request)
        return request

    def test_shared_messages_have_single_nonoverlapping_announcement_regions(self):
        request = self.request()
        messages.error(request, "Check the highlighted fields.")
        messages.success(request, "Changes saved.")
        html = render_to_string("base.html", request=request)
        regions = AnnouncementRegions(html)
        self.assertEqual(regions.overlaps, [])
        self.assertEqual(regions.message_roles, ["alert", "status"])
        self.assertIn("Check the highlighted fields.", html)
        self.assertIn("Changes saved.", html)

    def test_timed_attempt_keeps_visual_timer_separate_from_one_warning_alert(self):
        attempt = SimpleNamespace(
            pk=7,
            assignment_id=1,
            assessment_id=2,
            attempt_number=1,
            assessment=SimpleNamespace(
                title="Safety", max_attempts=3, get_kind_display="Final"
            ),
            pass_percentage_snapshot=80,
            deadline_at=timezone.now() + timedelta(minutes=3),
        )
        html = render_to_string(
            "assessments/attempt.html",
            {"attempt": attempt, "questions": [], "can_submit": True},
            request=self.request(),
        )
        regions = AnnouncementRegions(html)
        self.assertEqual(regions.overlaps, [])
        self.assertEqual(regions.roles.count("timer"), 1)
        self.assertEqual(regions.roles.count("alert"), 1)
        self.assertIn(
            'id="assessment-timer-alert" class="timer-alert" role="alert" hidden', html
        )
        self.assertIn('role="timer"', html)
        self.assertNotIn('role="timer" aria-live=', html)
