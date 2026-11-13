"""Hermetic arithmetic regressions; no Django setup, ORM, settings or database.

Run: python -B -m unittest training.test_video_coverage_timing -v

Select the actual production function bodies/constants rather than importing
training.views, which would initialize Django models. This deliberately does
not verify HTTP permissions, persisted validation, transactions or row locks.
"""

import ast
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation, ROUND_DOWN
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


def _accounting_functions():
    root = Path(__file__).resolve().parent
    namespace = {
        "Decimal": Decimal, "InvalidOperation": InvalidOperation, "ROUND_DOWN": ROUND_DOWN,
        "ValidationError": ValueError,
        "Lesson": SimpleNamespace(ContentType=SimpleNamespace(TEXT="TEXT")),
    }
    selections = (
        ("models.py", {"VIDEO_HEARTBEAT_TOLERANCE"}),
        ("views.py", {
            "VIDEO_HEARTBEAT_MAX_GAP", "_position", "_bounded_position", "_merge_ranges",
            "_verified_resume_position", "_apply_observed_position",
        }),
    )
    for filename, names in selections:
        tree = ast.parse((root / filename).read_text(encoding="utf-8"))
        nodes = []
        found = set()
        for node in tree.body:
            name = node.name if isinstance(node, ast.FunctionDef) else None
            if isinstance(node, ast.Assign) and len(node.targets) == 1:
                target = node.targets[0]
                name = target.id if isinstance(target, ast.Name) else None
            if name in names:
                nodes.append(node)
                found.add(name)
        if found != names:
            raise RuntimeError("Coverage helper selection needs review: " + filename)
        exec(compile(ast.Module(body=nodes, type_ignores=[]), filename, "exec"), namespace)

    # Reuse the real derived coverage properties; no duplicate credit formula.
    model = next(node for node in ast.parse((root / "models.py").read_text(encoding="utf-8")).body
                 if isinstance(node, ast.ClassDef) and node.name == "LessonProgress")
    properties = [node for node in model.body if isinstance(node, ast.FunctionDef)
                  and node.name in {"watched_seconds", "progress_percent"}]
    if len(properties) != 2:
        raise RuntimeError("Coverage property selection needs review.")
    exec(compile(ast.Module(body=properties, type_ignores=[]), "models.py", "exec"), namespace)
    state_class = type("CoverageState", (SimpleNamespace,), {
        node.name: namespace[node.name] for node in properties
    })
    return namespace, state_class


class VideoCoverageTimingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.functions, cls.state_class = _accounting_functions()

    def setUp(self):
        self.epoch = datetime(2026, 1, 1, tzinfo=timezone.utc)
        guard = patch("socket.socket.connect", side_effect=AssertionError("No network allowed."))
        guard.start()
        self.addCleanup(guard.stop)

    def at(self, seconds):
        return self.epoch + timedelta(seconds=float(seconds))

    def progress(self, ranges=None, position=0, observed_at=0, completed_at=None):
        return self.state_class(
            lesson=SimpleNamespace(content_type="VIDEO", video_duration_seconds=75,
                                   minimum_watch_percent=Decimal("80")),
            started_at=self.epoch, last_accessed_at=self.at(observed_at),
            last_position_seconds=Decimal(str(position)), watched_ranges=deepcopy(ranges or []),
            completed_at=completed_at,
        )

    def session(self, position=0, started_at=0, observed_at=None, active=0):
        return SimpleNamespace(
            started_at=self.at(started_at),
            updated_at=self.at(started_at if observed_at is None else observed_at),
            starting_position_seconds=Decimal(str(position)),
            ending_position_seconds=Decimal(str(position)),
            active_watch_seconds=Decimal(str(active)),
        )

    def observe(self, progress, session, position, seconds):
        previous_ranges = deepcopy(progress.watched_ranges)
        value = self.functions["_position"](position)
        self.functions["_apply_observed_position"](progress, session, value, self.at(seconds))
        # Simulate auto_now after a successful observation, without calling save().
        session.updated_at = self.at(seconds)
        for start, end in previous_ranges:
            self.assertTrue(any(a <= start and b >= end for a, b in progress.watched_ranges))
        tolerance = self.functions["VIDEO_HEARTBEAT_TOLERANCE"]
        self.assertLessEqual(progress.watched_seconds, Decimal(str(seconds)) + tolerance)
        elapsed = Decimal(str((self.at(seconds) - session.started_at).total_seconds()))
        self.assertLessEqual(session.active_watch_seconds, elapsed + tolerance)

    def test_continuous_playback_records_contiguous_unique_coverage(self):
        progress, session = self.progress(), self.session()
        for seconds in range(10, 71, 10):
            self.observe(progress, session, Decimal(seconds) * Decimal("0.99"), seconds)
        self.assertEqual(progress.watched_ranges, [[0.0, 69.3]])
        self.assertEqual(progress.watched_seconds, Decimal("69.3"))
        self.assertIsNotNone(progress.completed_at)

    def test_exact_timing_edge_and_followup_preserve_coverage_and_completion_budgets(self):
        progress = self.progress([[0, 42.609]], position="42.609", observed_at=50)
        session = self.session("42.609", observed_at=50, active=30)
        # This input could be delayed legitimate playback OR an unapproved seek.
        # Do not assert that today's hole/rebasing must remain forever: a future
        # security-reviewed reconciliation may recover some or all of it.
        self.observe(progress, session, "48.346", "55.600")
        self.assertGreaterEqual(progress.watched_seconds, Decimal("42.609"))
        self.assertLessEqual(progress.watched_seconds, Decimal("48.346"))
        self.assertIsNone(progress.completed_at)
        self.observe(progress, session, "74.283", "81.600")
        self.assertGreaterEqual(progress.watched_seconds, Decimal("60"))
        self.assertLessEqual(progress.watched_seconds, Decimal("74.283"))
        self.assertIsNotNone(progress.completed_at)

    def test_same_positions_with_sufficient_elapsed_time_have_no_middle_gap(self):
        progress = self.progress([[0, 42.609]], position="42.609", observed_at=50)
        session = self.session("42.609", observed_at=50, active=30)
        self.observe(progress, session, "48.346", 56)
        self.observe(progress, session, "74.283", 82)
        self.assertEqual(progress.watched_ranges, [[0.0, 74.283]])

    def test_forged_forward_jump_never_credits_unseen_positions(self):
        progress, session = self.progress(), self.session()
        self.observe(progress, session, 74, 1)
        self.assertEqual(progress.watched_ranges, [])
        self.assertEqual(progress.watched_seconds, 0)
        self.assertEqual(self.functions["_verified_resume_position"](progress), 0)
        self.assertIsNone(progress.completed_at)

    def test_backward_seek_replays_verified_content_without_duplicate_credit(self):
        progress, session = self.progress(), self.session()
        self.observe(progress, session, 20, 20)
        self.observe(progress, session, 5, 21)
        self.assertEqual(self.functions["_verified_resume_position"](progress), 5)
        self.observe(progress, session, 15, 31)
        self.assertEqual(progress.watched_ranges, [[0.0, 20.0]])
        self.assertEqual(session.active_watch_seconds, 30)

    def test_rapid_repeated_forward_requests_cannot_manufacture_completion(self):
        progress, session = self.progress(), self.session()
        for position in range(2, 75, 2):
            self.observe(progress, session, position, 0)
        self.assertLessEqual(progress.watched_seconds, self.functions["VIDEO_HEARTBEAT_TOLERANCE"])
        self.assertIsNone(progress.completed_at)

    def test_new_sessions_cannot_reissue_unique_coverage_tolerance(self):
        progress = self.progress()
        for position in range(0, 20, 2):
            session = self.session(position)
            progress.last_accessed_at = self.epoch
            self.observe(progress, session, position + 2, 0)
        self.assertLessEqual(progress.watched_seconds, self.functions["VIDEO_HEARTBEAT_TOLERANCE"])
        self.assertIsNone(progress.completed_at)

    def test_duplicate_observations_do_not_add_coverage_or_active_watch_time(self):
        progress, session = self.progress(), self.session()
        self.observe(progress, session, "9.9", 10)
        active = session.active_watch_seconds
        for _ in range(5):
            self.observe(progress, session, "9.9", 10)
        self.assertEqual(progress.watched_ranges, [[0.0, 9.9]])
        self.assertEqual(session.active_watch_seconds, active)

    def test_pause_resume_observations_preserve_coverage_without_crediting_idle_time(self):
        progress, first = self.progress(), self.session()
        self.observe(progress, first, "9.9", 10)
        self.observe(progress, first, "15.84", 16)  # Final pause observation.
        position = self.functions["_verified_resume_position"](progress)
        second = self.session(position, started_at=40)
        # Session creation updates the shared observation timestamp in the API.
        progress.last_accessed_at = self.at(40)
        self.observe(progress, second, "25.74", 50)
        self.assertEqual(progress.watched_ranges, [[0.0, 25.74]])
        self.assertEqual(second.active_watch_seconds, Decimal("9.9"))

    def test_stale_observation_does_not_turn_idle_time_into_coverage(self):
        progress, session = self.progress(), self.session()
        self.observe(progress, session, "9.9", 10)
        stale_at = 10 + self.functions["VIDEO_HEARTBEAT_MAX_GAP"] + 1
        self.observe(progress, session, 65, stale_at)
        self.assertEqual(progress.watched_ranges, [[0.0, 9.9]])
        self.assertLessEqual(self.functions["_verified_resume_position"](progress), Decimal("9.9"))
        self.assertIsNone(progress.completed_at)

    def test_clock_regression_cannot_add_credit_after_initial_tolerance_is_consumed(self):
        progress, session = self.progress(), self.session()
        self.observe(progress, session, "9.9", 10)
        self.observe(progress, session, 20, 9)
        self.assertEqual(progress.watched_ranges, [[0.0, 9.9]])
        self.assertEqual(session.active_watch_seconds, Decimal("9.9"))
        # The real model additionally rejects regressing last_accessed_at on
        # save; that persisted rollback requires separate database verification.

    def test_late_older_position_cannot_enable_a_forged_forward_jump(self):
        progress, session = self.progress(), self.session()
        self.observe(progress, session, "9.9", 10)
        self.observe(progress, session, "19.8", 20)
        self.observe(progress, session, "9.9", 21)  # Older position arrives late.
        self.assertEqual(progress.watched_seconds, Decimal("19.8"))
        self.observe(progress, session, 70, 22)
        self.assertEqual(progress.watched_ranges, [[0.0, 19.8]])
        self.assertIsNone(progress.completed_at)

    def test_continuous_playback_with_variable_arrival_intervals_remains_contiguous(self):
        progress, session = self.progress(), self.session()
        for seconds, position in ((10, "9.9"), (20.2, "19.8"),
                                  (30.15, "29.7"), (40.4, "39.6")):
            self.observe(progress, session, position, seconds)
        self.assertEqual(progress.watched_ranges, [[0.0, 39.6]])

    def test_interleaved_sessions_cannot_double_spend_the_shared_observation_budget(self):
        progress = self.progress()
        first, second = self.session(), self.session()
        self.observe(progress, first, "9.9", 10)
        self.observe(progress, second, 10, 10)
        self.assertEqual(progress.watched_seconds, Decimal("9.9"))
        self.observe(progress, second, "19.9", 20)
        self.assertLessEqual(progress.watched_seconds, Decimal("19.9"))
        self.assertIsNone(progress.completed_at)

    def test_completion_uses_unique_seconds_not_position_or_covered_span(self):
        progress = self.progress([[0, 30], [40, 69]], position=69, observed_at=100)
        session = self.session(69, observed_at=100, active=30)
        self.observe(progress, session, 69, 100)
        self.assertEqual(progress.watched_seconds, 59)
        self.assertIsNone(progress.completed_at)
        self.observe(progress, session, 70, 101)
        self.assertEqual(progress.watched_seconds, 60)
        self.assertIsNotNone(progress.completed_at)

    def test_playing_across_a_known_gap_recovers_it_and_preserves_completion_timestamp(self):
        completed_at = self.at(90)
        progress = self.progress([[0, 42.609], [48.346, 74.283]], position=40,
                                 observed_at=100, completed_at=completed_at)
        session = self.session(40, started_at=100)
        self.observe(progress, session, 50, 110)
        self.assertEqual(progress.watched_ranges, [[0.0, 74.283]])
        self.assertEqual(progress.watched_seconds, Decimal("74.283"))
        self.assertEqual(progress.completed_at, completed_at)

    def test_invalid_positions_fail_before_altering_coverage(self):
        for value in (-1, 76, True, None, "NaN", "Infinity", "not-a-number"):
            with self.subTest(value=value):
                progress, session = self.progress(), self.session()
                with self.assertRaises(ValueError):
                    self.observe(progress, session, value, 1)
                self.assertEqual(progress.watched_ranges, [])
                self.assertEqual(progress.last_position_seconds, 0)
                self.assertEqual(session.active_watch_seconds, 0)


if __name__ == "__main__":
    unittest.main()
