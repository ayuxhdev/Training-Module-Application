"""Shared fixtures for model integration tests, including a published curriculum."""

from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone

from assessments.models import Assessment, AssessmentAttempt, AssessmentQuestion, AttemptAnswer, Question, QuestionOption, QuestionRevision
from organization.models import Department, Employee, JobRole
from training.models import Lesson, LessonProgress, Module, Training, TrainingAssignment, TrainingVersion


class CurriculumTestCase(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.now = timezone.now() - timedelta(minutes=5)
        cls.user = get_user_model().objects.create_user(username="coordinator", password="test-only-password")
        cls.employee_user = get_user_model().objects.create_user(username="employee")
        cls.department = Department.objects.create(code="PROD", name="Production")
        cls.role = JobRole.objects.create(code="OP", name="Operator")
        cls.employee = Employee.objects.create(employee_code="GN-001", display_name="Employee One",
                    department=cls.department, job_role=cls.role, date_joined=cls.now.date(), user=cls.employee_user)
        cls.training = Training.objects.create(code="SAFETY", catalog_title="Safety", created_by=cls.user)
        cls.version = TrainingVersion.objects.create(training=cls.training, version_number=1, title="Safety v1", created_by=cls.user)
        cls.module = Module.objects.create(training_version=cls.version, title="Introduction", position=1)
        cls.text_lesson = Lesson.objects.create(module=cls.module, title="Read", position=1, content_type="TEXT", body="Safety instructions")
        cls.video_lesson = Lesson.objects.create(module=cls.module, title="Watch", position=2, content_type="VIDEO",
                    video_file="training/videos/safety-v1.mp4", video_duration_seconds=100, video_checksum="a" * 64)
        cls.question = Question.objects.create(code="Q-001", topic="Safety", created_by=cls.user)
        cls.revision = QuestionRevision.objects.create(question=cls.question, revision_number=1, prompt="Wear PPE?", created_by=cls.user)
        cls.correct_option = QuestionOption.objects.create(question_revision=cls.revision, text="Yes", position=1, is_correct=True)
        cls.wrong_option = QuestionOption.objects.create(question_revision=cls.revision, text="No", position=2)
        cls.revision.status = "FROZEN"
        cls.revision.frozen_at = cls.now
        cls.revision.save()
        cls.quiz = Assessment.objects.create(training_version=cls.version, module=cls.module, kind="QUIZ", title="Module quiz", time_limit_minutes=1)
        cls.final = Assessment.objects.create(training_version=cls.version, kind="FINAL", title="Final")
        cls.quiz_item = AssessmentQuestion.objects.create(assessment=cls.quiz, question_revision=cls.revision, position=1, points=Decimal("2.00"))
        cls.final_item = AssessmentQuestion.objects.create(assessment=cls.final, question_revision=cls.revision, position=1, points=Decimal("2.00"))
        cls.version.status = "PUBLISHED"
        cls.version.published_at = cls.now
        cls.version.published_by = cls.user
        cls.version.save()
        cls.assignment = TrainingAssignment.objects.create(employee=cls.employee, training_version=cls.version,
                    department_at_assignment=cls.department, job_role_at_assignment=cls.role, assigned_by=cls.user,
                    assigned_at=cls.now, started_at=cls.now, status="IN_PROGRESS")

    def new_version(self):
        return TrainingVersion.objects.create(training=self.training, version_number=2, title="Safety v2", created_by=self.user)

    def complete_lessons(self):
        completed = self.now + timedelta(seconds=110)
        for lesson, ranges in [(self.text_lesson, []), (self.video_lesson, [[0, 95]])]:
            LessonProgress.objects.create(assignment=self.assignment, lesson=lesson, started_at=self.now,
                last_accessed_at=completed, completed_at=completed, watched_ranges=ranges)

    def start_attempt(self, assessment=None):
        assessment = assessment or self.quiz
        started = self.now + timedelta(seconds=120)
        return AssessmentAttempt.objects.create(assignment=self.assignment, assessment=assessment,
                attempt_number=AssessmentAttempt.objects.filter(assignment=self.assignment, assessment=assessment).count() + 1,
                started_at=started, deadline_at=started + timedelta(minutes=assessment.time_limit_minutes) if assessment.time_limit_minutes else None,
                maximum_points=Decimal("2.00"), pass_percentage_snapshot=assessment.pass_percentage)

    def answer_attempt(self, attempt, correct=True):
        return AttemptAnswer.objects.create(attempt=attempt, assessment_question=attempt.assessment.questions.get(),
                selected_option=self.correct_option if correct else self.wrong_option, presented_position=1,
                answered_at=attempt.started_at + timedelta(seconds=1), points_possible=Decimal("2.00"),
                points_awarded=Decimal("2.00") if correct else Decimal("0.00"), is_correct=correct)

    def finish_attempt(self, assessment=None, correct=True):
        attempt = self.start_attempt(assessment)
        self.answer_attempt(attempt, correct)
        attempt.status = "SUBMITTED"
        attempt.submitted_at = attempt.started_at + timedelta(seconds=2)
        attempt.score_points = Decimal("2.00") if correct else Decimal("0.00")
        attempt.passed = correct
        attempt.save()
        return attempt

    def complete_assignment(self):
        self.complete_lessons()
        self.finish_attempt(self.quiz)
        final_attempt = self.finish_attempt(self.final)
        self.assignment.status = "COMPLETED"
        self.assignment.completed_at = self.now + timedelta(seconds=130)
        self.assignment.save()
        return final_attempt
