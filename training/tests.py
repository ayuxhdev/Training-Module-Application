from datetime import timedelta
from decimal import Decimal

from django.core.exceptions import ValidationError
from django.db import IntegrityError, models, transaction

from config.model_test_utils import CurriculumTestCase
from .models import Lesson, LessonProgress, Module, RoleTrainingRequirement, TrainingAssignment, VideoWatchSession


class CurriculumTests(CurriculumTestCase):
    def test_published_version_content_cannot_be_changed(self):
        for obj, field, value in [(self.version, "title", "Changed"), (self.module, "title", "Changed"),
                                   (self.video_lesson, "video_file", "replacement.mp4"),
                                   (self.quiz, "pass_percentage", Decimal("10.00")),
                                   (self.quiz_item, "points", Decimal("10.00"))]:
            with self.subTest(model=type(obj).__name__):
                setattr(obj, field, value)
                with self.assertRaises(ValidationError):
                    obj.save()

    def test_publication_requires_complete_assessment_structure(self):
        version = self.new_version()
        version.status = "PUBLISHED"
        version.published_at = self.now
        version.published_by = self.user
        with self.assertRaises(ValidationError):
            version.save()

    def test_published_children_cannot_be_added_or_deleted(self):
        with self.assertRaises(ValidationError):
            Module.objects.create(training_version=self.version, title="Extra", position=2)
        with self.assertRaises(ValidationError):
            self.text_lesson.delete()
        with self.assertRaises(ValidationError):
            self.version.delete()

    def test_new_version_preserves_old_assignment(self):
        version = self.new_version()
        version.title = "Revised safety"
        version.save()
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.training_version_id, self.version.pk)
        self.assertNotEqual(version.pk, self.version.pk)

    def test_retired_version_cannot_revert_to_draft(self):
        self.version.status = "RETIRED"
        self.version.save()
        self.version.status = "DRAFT"
        with self.assertRaises(ValidationError):
            self.version.save()

    def test_bulk_writes_cannot_bypass_publication_guards(self):
        with self.assertRaises(ValidationError):
            Lesson.objects.filter(pk=self.text_lesson.pk).update(body="Changed")
        with self.assertRaises(ValidationError):
            Lesson.objects.bulk_update([self.text_lesson], ["body"])


class AssignmentTests(CurriculumTestCase):
    def duplicate(self, **overrides):
        values = dict(employee=self.employee, training_version=self.version, department_at_assignment=self.department,
                      job_role_at_assignment=self.role, assigned_by=self.user)
        values.update(overrides)
        return TrainingAssignment(**values)

    def test_database_rejects_duplicate_assignment_even_without_model_validation(self):
        with self.assertRaises(IntegrityError), transaction.atomic():
            models.Model.save(self.duplicate(), force_insert=True)

    def test_role_and_manual_sources_cannot_duplicate_assignment(self):
        rule = RoleTrainingRequirement.objects.create(job_role=self.role, training_version=self.version, created_by=self.user)
        with self.assertRaises(ValidationError):
            self.duplicate(source="ROLE", role_requirement=rule).save()

    def test_role_requirements_are_unique_and_version_bound(self):
        rule = RoleTrainingRequirement.objects.create(job_role=self.role, training_version=self.version, created_by=self.user)
        with self.assertRaises(ValidationError):
            RoleTrainingRequirement.objects.create(job_role=self.role, training_version=self.version, created_by=self.user)
        rule.training_version = self.new_version()
        with self.assertRaises(ValidationError):
            rule.save()

    def test_cancelled_assignment_cannot_be_duplicated(self):
        self.assignment.status = "CANCELLED"
        self.assignment.cancelled_at = self.now + timedelta(seconds=1)
        self.assignment.cancellation_reason = "Role changed"
        self.assignment.save()
        with self.assertRaises(ValidationError):
            self.duplicate().save()

    def test_assignment_cannot_change_employee_or_version(self):
        self.assignment.training_version = self.new_version()
        with self.assertRaises(ValidationError):
            self.assignment.save()

    def test_premature_completion_rejected(self):
        self.assignment.status = "COMPLETED"
        self.assignment.completed_at = self.now + timedelta(seconds=1)
        with self.assertRaises(ValidationError):
            self.assignment.save()

    def test_inactive_employee_cannot_reopen_assignment(self):
        self.assignment.status = "CANCELLED"
        self.assignment.cancelled_at = self.now
        self.assignment.cancellation_reason = "Left"
        self.assignment.save()
        self.employee.is_active = False
        self.employee.deactivation_reason = "Left"
        self.employee.save()
        self.assignment.status = "IN_PROGRESS"
        self.assignment.cancelled_at = None
        with self.assertRaises(ValidationError):
            self.assignment.save()


class ProgressTests(CurriculumTestCase):
    def progress(self, **kwargs):
        return LessonProgress(assignment=self.assignment, lesson=self.video_lesson, started_at=self.now,
                              last_accessed_at=self.now + timedelta(seconds=100), **kwargs)

    def test_coverage_and_resume_are_separate(self):
        progress = self.progress(watched_ranges=[[0, 20], [50, 70]], last_position_seconds=100)
        progress.save()
        self.assertEqual(progress.watched_seconds, 40)
        self.assertEqual(progress.progress_percent, 40)
        self.assertIsNone(progress.completed_at)

    def test_duplicate_progress_rejected(self):
        self.progress().save()
        with self.assertRaises(ValidationError):
            self.progress().save()

    def test_invalid_ranges_and_insufficient_coverage_rejected(self):
        for ranges in [[[0, 60], [50, 80]], [[0, 60], [60, 80]], [[-1, 10]], [[0, 101]], [[0, "bad"]], {}]:
            with self.subTest(ranges=ranges), self.assertRaises(ValidationError):
                self.progress(watched_ranges=ranges).save()
        with self.assertRaises(ValidationError):
            self.progress(watched_ranges=[[0, 50]], completed_at=self.now + timedelta(seconds=100)).save()

    def test_existing_coverage_cannot_be_discarded(self):
        progress = self.progress(watched_ranges=[[0, 40]])
        progress.save()
        progress.watched_ranges = [[0, 20]]
        with self.assertRaises(ValidationError):
            progress.save()

    def test_cached_lesson_cannot_bypass_video_threshold(self):
        self.video_lesson.minimum_watch_percent = 1
        with self.assertRaises(ValidationError):
            self.progress(watched_ranges=[[0, 20]], completed_at=self.now + timedelta(seconds=100)).save()

    def test_lesson_from_another_version_rejected(self):
        module = Module.objects.create(training_version=self.new_version(), title="New", position=1)
        lesson = Lesson.objects.create(module=module, title="New", position=1, content_type="TEXT", body="New text")
        with self.assertRaises(ValidationError):
            LessonProgress.objects.create(assignment=self.assignment, lesson=lesson)

    def test_deactivated_employee_cannot_record_progress(self):
        self.employee.is_active = False
        self.employee.deactivation_reason = "Left"
        self.employee.save()
        with self.assertRaises(ValidationError):
            self.progress().save()


class VideoWatchSessionTests(CurriculumTestCase):
    def session(self, **kwargs):
        values = dict(assignment=self.assignment, lesson=self.video_lesson, started_at=self.now,
                      starting_position_seconds=80, session_identifier="browser-session", device_identifier="shared-training-tablet")
        values.update(kwargs)
        return VideoWatchSession(**values)

    def test_multiple_sessions_preserved_without_inflating_aggregate(self):
        progress = LessonProgress.objects.create(assignment=self.assignment, lesson=self.video_lesson, watched_ranges=[[0, 20]])
        for _ in range(2):
            self.session(ended_at=self.now + timedelta(seconds=30), ending_position_seconds=20,
                         active_watch_seconds=25, completed_normally=True).save()
        self.assertEqual(self.assignment.video_watch_sessions.count(), 2)
        progress.refresh_from_db()
        self.assertEqual(progress.watched_seconds, 20)

    def test_backward_seek_is_allowed(self):
        session = self.session(ended_at=self.now + timedelta(seconds=30), ending_position_seconds=20, active_watch_seconds=25)
        session.save()
        self.assertLess(session.ending_position_seconds, session.starting_position_seconds)

    def test_invalid_session_measurements_rejected(self):
        invalid = [dict(active_watch_seconds=-1), dict(starting_position_seconds=101),
                   dict(ended_at=self.now - timedelta(seconds=1), ending_position_seconds=1),
                   dict(ended_at=self.now + timedelta(seconds=10), ending_position_seconds=90, active_watch_seconds=11),
                   dict(completed_normally=True), dict(ended_at=self.now + timedelta(seconds=10)),
                   dict(lesson=self.text_lesson)]
        for values in invalid:
            with self.subTest(values=values), self.assertRaises(ValidationError):
                self.session(**values).save()

    def test_closed_session_is_immutable_and_retained(self):
        session = self.session()
        session.save()
        session.ended_at = self.now + timedelta(seconds=20)
        session.ending_position_seconds = 100
        session.active_watch_seconds = 20
        session.completed_normally = True
        session.save()
        session.active_watch_seconds = 10
        with self.assertRaises(ValidationError):
            session.save()
        with self.assertRaises(ValidationError):
            VideoWatchSession.objects.filter(pk=session.pk).delete()

    def test_database_checks_session_time_order(self):
        session = self.session(ended_at=self.now - timedelta(seconds=1), ending_position_seconds=90)
        with self.assertRaises(IntegrityError), transaction.atomic():
            models.Model.save(session, force_insert=True)
