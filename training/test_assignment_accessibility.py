from datetime import datetime
from types import SimpleNamespace

from django.contrib.auth.models import AnonymousUser
from django.template.loader import render_to_string
from django.test import RequestFactory, SimpleTestCase


class AssignmentDetailAccessibilityTests(SimpleTestCase):
    databases = set()

    def setUp(self):
        super().setUp()
        self.factory = RequestFactory()
        self.request = self.factory.get('/training/assignments/1/')
        self.request.user = AnonymousUser()

        mock_training = SimpleNamespace(catalog_title="Safety Training")
        mock_version = SimpleNamespace(
            training=mock_training,
            title="Safety v1",
            version_number=1,
        )
        self.assignment = SimpleNamespace(
            pk=1,
            status="IN_PROGRESS",
            get_status_display="In Progress",
            is_overdue=False,
            training_version=mock_version,
            due_date=None,
            completed_at=None,
        )

        self.lesson_completed = SimpleNamespace(
            pk=10,
            title="Safety Introduction",
            get_content_type_display="Text",
            is_required=True,
            position=1,
        )
        self.progress_completed = SimpleNamespace(completed_at=datetime(2026, 1, 1))

        self.lesson_incomplete = SimpleNamespace(
            pk=11,
            title="Field Procedures",
            get_content_type_display="Video",
            is_required=False,
            position=2,
        )
        self.progress_incomplete = SimpleNamespace(completed_at=None)

        self.module = SimpleNamespace(title="Module 1", description="Intro module")
        self.module_items = [
            {
                "module": self.module,
                "lessons": [
                    {"lesson": self.lesson_completed, "progress": self.progress_completed},
                    {"lesson": self.lesson_incomplete, "progress": self.progress_incomplete},
                ],
            }
        ]

    def test_lesson_links_include_visually_hidden_completion_state(self):
        context = {
            "request": self.request,
            "assignment": self.assignment,
            "module_items": self.module_items,
            "selected_lesson": None,
            "selected_progress": None,
            "can_learn": True,
        }
        html = render_to_string("training/assignment_detail.html", context, request=self.request)

        # 1. Accessible name of lesson link includes completion status via visually-hidden span
        self.assertIn(
            '<span>Safety Introduction</span><span class="visually-hidden">, Completed</span>',
            html,
        )
        self.assertIn(
            '<span>Field Procedures</span><span class="visually-hidden">, Incomplete</span>',
            html,
        )

        # 2. Status icon remains decorative with aria-hidden="true"
        self.assertIn('<span class="lesson-status-icon" aria-hidden="true">', html)

        # 3. Visible status badge has aria-hidden="true" to avoid redundant announcements
        self.assertIn(
            '<span class="status-badge status-completed" aria-hidden="true">Completed</span>',
            html,
        )
        self.assertIn(
            '<span class="status-badge" aria-hidden="true">Incomplete</span>',
            html,
        )
