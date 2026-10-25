from decimal import Decimal
from types import SimpleNamespace

from django.contrib.auth.models import AnonymousUser
from django.template.loader import render_to_string
from django.test import RequestFactory, SimpleTestCase
from django.utils import timezone


class AssessmentTemplateAccessibilityTests(SimpleTestCase):
    databases = set()

    def setUp(self):
        super().setUp()
        self.factory = RequestFactory()
        self.request = self.factory.get('/assessments/attempts/1/')
        self.request.user = AnonymousUser()

        self.mock_assessment = SimpleNamespace(
            pk=1,
            title="Soil Science Final Assessment",
            max_attempts=3,
            get_kind_display="Final Assessment",
        )

    def test_attempt_fieldset_legend_ordering_and_aria_hidden(self):
        attempt = SimpleNamespace(
            pk=1,
            assignment_id=10,
            assessment_id=1,
            assessment=self.mock_assessment,
            attempt_number=1,
            pass_percentage_snapshot=Decimal("80.00"),
            deadline_at=None,
        )

        option_a = SimpleNamespace(pk=101, text="Nitrogen")
        option_b = SimpleNamespace(pk=102, text="Argon")
        mock_options = SimpleNamespace(all=lambda: [option_a, option_b])

        question_revision_1 = SimpleNamespace(
            prompt="Which nutrient is most critical for leaf development?",
            options=mock_options,
        )
        question_revision_2 = SimpleNamespace(
            prompt="What is the ideal pH for soil testing?",
            options=mock_options,
        )

        q1 = SimpleNamespace(
            pk=1,
            position=1,
            points=1,
            question_revision=question_revision_1,
            selected_option_id=None,
        )
        q2 = SimpleNamespace(
            pk=2,
            position=2,
            points=2,
            question_revision=question_revision_2,
            selected_option_id=None,
        )

        rendered = render_to_string(
            "assessments/attempt.html",
            {
                "attempt": attempt,
                "questions": [q1, q2],
                "form_error": None,
                "can_submit": True,
            },
            request=self.request,
        )

        # 1. Legend must be the first element child inside fieldset (before visual header)
        fieldset_start = rendered.find('<fieldset class="assessment-question">')
        self.assertNotEqual(fieldset_start, -1)

        legend_pos = rendered.find('<legend', fieldset_start)
        header_pos = rendered.find('<div class="assessment-question-header"', fieldset_start)

        self.assertNotEqual(legend_pos, -1)
        self.assertNotEqual(header_pos, -1)
        self.assertLess(
            legend_pos,
            header_pos,
            "HTML standard requires <legend> to precede any child elements inside <fieldset>",
        )

        # 2. Visual question header must have aria-hidden="true" to prevent redundant announcements
        self.assertIn(
            '<div class="assessment-question-header" aria-hidden="true">',
            rendered,
        )

        # 3. Legend text must describe position, prompt, and correct point pluralization
        self.assertIn("1. Which nutrient is most critical for leaf development? (1 point)", rendered)
        self.assertIn("2. What is the ideal pH for soil testing? (2 points)", rendered)

    def test_result_submitted_passed(self):
        attempt = SimpleNamespace(
            pk=1,
            assignment_id=10,
            assessment_id=1,
            assessment=self.mock_assessment,
            attempt_number=1,
            status="SUBMITTED",
            get_status_display="Submitted",
            passed=True,
            score_points=Decimal("10.00"),
            maximum_points=Decimal("10.00"),
            pass_percentage_snapshot=Decimal("80.00"),
            submitted_at=timezone.now(),
            answers=SimpleNamespace(
                all=lambda: [
                    SimpleNamespace(
                        assessment_question=SimpleNamespace(
                            question_revision=SimpleNamespace(prompt="Question 1")
                        ),
                        selected_option=SimpleNamespace(text="Answer A"),
                        points_awarded=Decimal("10.00"),
                        points_possible=Decimal("10.00"),
                    )
                ]
            ),
        )

        rendered = render_to_string(
            "assessments/result.html",
            {"attempt": attempt},
            request=self.request,
        )

        self.assertIn("result-score-banner--passed", rendered)
        self.assertNotIn("result-score-banner--failed", rendered)
        self.assertNotIn("result-score-banner--neutral", rendered)
        self.assertIn("Passed", rendered)
        self.assertIn("Requirement satisfied", rendered)
        self.assertIn("10.00 / 10.00", rendered)
        self.assertIn("is-correct", rendered)
        self.assertNotIn("Below passing threshold", rendered)

    def test_result_submitted_failed_nonzero_score(self):
        attempt = SimpleNamespace(
            pk=2,
            assignment_id=10,
            assessment_id=1,
            assessment=self.mock_assessment,
            attempt_number=1,
            status="SUBMITTED",
            get_status_display="Submitted",
            passed=False,
            score_points=Decimal("5.00"),
            maximum_points=Decimal("10.00"),
            pass_percentage_snapshot=Decimal("80.00"),
            submitted_at=timezone.now(),
            answers=SimpleNamespace(
                all=lambda: [
                    SimpleNamespace(
                        assessment_question=SimpleNamespace(
                            question_revision=SimpleNamespace(prompt="Question 1")
                        ),
                        selected_option=SimpleNamespace(text="Answer B"),
                        points_awarded=Decimal("0.00"),
                        points_possible=Decimal("10.00"),
                    )
                ]
            ),
        )

        rendered = render_to_string(
            "assessments/result.html",
            {"attempt": attempt},
            request=self.request,
        )

        self.assertIn("result-score-banner--failed", rendered)
        self.assertNotIn("result-score-banner--passed", rendered)
        self.assertNotIn("result-score-banner--neutral", rendered)
        self.assertIn("Not passed", rendered)
        self.assertIn("Below passing threshold (80.00% required)", rendered)
        self.assertIn("5.00 / 10.00", rendered)
        self.assertIn("is-incorrect", rendered)

    def test_result_submitted_failed_with_zero_score(self):
        """A submitted attempt scoring 0.00 is a genuine graded failure, not unsubmitted/ungraded."""
        attempt = SimpleNamespace(
            pk=3,
            assignment_id=10,
            assessment_id=1,
            assessment=self.mock_assessment,
            attempt_number=1,
            status="SUBMITTED",
            get_status_display="Submitted",
            passed=False,
            score_points=Decimal("0.00"),
            maximum_points=Decimal("10.00"),
            pass_percentage_snapshot=Decimal("80.00"),
            submitted_at=timezone.now(),
            answers=SimpleNamespace(
                all=lambda: [
                    SimpleNamespace(
                        assessment_question=SimpleNamespace(
                            question_revision=SimpleNamespace(prompt="Question 1")
                        ),
                        selected_option=SimpleNamespace(text="Wrong Answer"),
                        points_awarded=Decimal("0.00"),
                        points_possible=Decimal("10.00"),
                    )
                ]
            ),
        )

        rendered = render_to_string(
            "assessments/result.html",
            {"attempt": attempt},
            request=self.request,
        )

        self.assertIn("result-score-banner--failed", rendered)
        self.assertNotIn("result-score-banner--neutral", rendered)
        self.assertIn("Not passed", rendered)
        self.assertIn("Below passing threshold (80.00% required)", rendered)
        self.assertIn("0.00 / 10.00", rendered)
        self.assertNotIn("Not graded", rendered)

    def test_result_expired_unsubmitted(self):
        """An attempt that expired without being submitted must be displayed neutrally without failure wording."""
        attempt = SimpleNamespace(
            pk=4,
            assignment_id=10,
            assessment_id=1,
            assessment=self.mock_assessment,
            attempt_number=1,
            status="EXPIRED",
            get_status_display="Expired",
            passed=False,
            score_points=None,
            maximum_points=Decimal("10.00"),
            pass_percentage_snapshot=Decimal("80.00"),
            submitted_at=None,
            answers=SimpleNamespace(all=lambda: []),
        )

        rendered = render_to_string(
            "assessments/result.html",
            {"attempt": attempt},
            request=self.request,
        )

        self.assertIn("result-score-banner--neutral", rendered)
        self.assertNotIn("result-score-banner--failed", rendered)
        self.assertNotIn("result-score-banner--passed", rendered)
        self.assertIn("Expired · Not submitted", rendered)
        self.assertIn("Not graded", rendered)
        self.assertNotIn("Not passed", rendered)
        self.assertNotIn("Below passing threshold", rendered)
        self.assertIn("This attempt reached the deadline before it was submitted.", rendered)

    def test_result_expired_submitted_late(self):
        """An attempt submitted after the deadline is marked expired and displayed neutrally."""
        attempt = SimpleNamespace(
            pk=5,
            assignment_id=10,
            assessment_id=1,
            assessment=self.mock_assessment,
            attempt_number=1,
            status="EXPIRED",
            get_status_display="Expired",
            passed=False,
            score_points=Decimal("6.00"),
            maximum_points=Decimal("10.00"),
            pass_percentage_snapshot=Decimal("80.00"),
            submitted_at=timezone.now(),
            answers=SimpleNamespace(
                all=lambda: [
                    SimpleNamespace(
                        assessment_question=SimpleNamespace(
                            question_revision=SimpleNamespace(prompt="Question 1")
                        ),
                        selected_option=SimpleNamespace(text="Answer A"),
                        points_awarded=Decimal("6.00"),
                        points_possible=Decimal("10.00"),
                    )
                ]
            ),
        )

        rendered = render_to_string(
            "assessments/result.html",
            {"attempt": attempt},
            request=self.request,
        )

        self.assertIn("result-score-banner--neutral", rendered)
        self.assertNotIn("result-score-banner--failed", rendered)
        self.assertNotIn("result-score-banner--passed", rendered)
        self.assertIn("Expired", rendered)
        self.assertNotIn("Not passed", rendered)
        self.assertNotIn("Below passing threshold", rendered)
        self.assertIn("Submission recorded after deadline", rendered)
        self.assertIn("is-ungraded", rendered)

    def test_result_abandoned_state(self):
        attempt = SimpleNamespace(
            pk=6,
            assignment_id=10,
            assessment_id=1,
            assessment=self.mock_assessment,
            attempt_number=1,
            status="ABANDONED",
            get_status_display="Abandoned",
            passed=None,
            score_points=None,
            maximum_points=Decimal("10.00"),
            pass_percentage_snapshot=Decimal("80.00"),
            submitted_at=None,
            answers=SimpleNamespace(all=lambda: []),
        )

        rendered = render_to_string(
            "assessments/result.html",
            {"attempt": attempt},
            request=self.request,
        )

        self.assertIn("result-score-banner--neutral", rendered)
        self.assertIn("Not graded", rendered)
        self.assertNotIn("Below passing threshold", rendered)
        self.assertNotIn("Not passed", rendered)
        self.assertIn("Attempt abandoned", rendered)

