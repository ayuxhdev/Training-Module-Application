"""Website-only team assignment authorization and transactional revalidation."""

from datetime import time, timedelta
from decimal import Decimal
from types import SimpleNamespace
from unittest import skipUnless
from unittest.mock import MagicMock, patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import AnonymousUser, Group, Permission
from django.core.exceptions import ValidationError
from django.db import IntegrityError, connection
from django.template.loader import render_to_string
from django.test import Client, RequestFactory, SimpleTestCase
from django.utils import timezone

from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from notifications.models import Notification
from organization.models import Department, Employee, JobRole
from training.forms import TrainingAssignmentForm
from training.models import TrainingAssignment
from training.views import TrainingAssignmentDetailView


class ManagerProgressSummaryUnitTests(SimpleTestCase):
    """Database-free presentation checks; hierarchy integration is tested below."""

    def setUp(self):
        from assessments.models import Assessment, AssessmentAttempt
        from training.models import Lesson, LessonProgress, Module, Training, TrainingVersion

        self.request = RequestFactory().get("/assignments/1/")
        self.request.user = SimpleNamespace(
            pk=10, is_authenticated=True, is_active=True, is_superuser=False,
            has_perm=lambda permission: False, groups=MagicMock(),
        )
        self.request.user.groups.filter.return_value.exists.return_value = True
        self.assignment = TrainingAssignment(
            pk=1, employee=Employee(pk=2, user_id=20, is_active=True),
            training_version=TrainingVersion(pk=3, status="PUBLISHED", title="Safety v1",
                version_number=1, training=Training(pk=4, catalog_title="Safety")),
            status="IN_PROGRESS",
        )
        self.assignment._state.fields_cache["certificate"] = None
        self.module = Module(pk=5, title="Introduction", position=1)
        self.lesson = Lesson(pk=6, module=self.module, title="Watch", content_type="VIDEO",
            video_duration_seconds=100, minimum_watch_percent=90, is_required=True)
        self.module._prefetched_objects_cache = {"lessons": [self.lesson]}
        self.progress = LessonProgress(assignment=self.assignment, lesson=self.lesson,
            watched_ranges=[[0, 20]], last_position_seconds=95)
        self.assessment = Assessment(pk=7, title="Final", kind="FINAL", is_required=True)
        self.attempt = AssessmentAttempt(assessment=self.assessment, assignment=self.assignment,
            attempt_number=1, status="SUBMITTED", score_points=Decimal("1.00"),
            maximum_points=Decimal("2.00"), passed=False, submitted_at=timezone.now())
        self.rows = {
            "training.views.Module.objects.filter": [self.module],
            "training.views.LessonProgress.objects.filter": [self.progress],
            "assessments.models.Assessment.objects.filter": [self.assessment],
            "assessments.models.AssessmentAttempt.objects.filter": [self.attempt],
        }

    def context(self, *, active_identity=True):
        from contextlib import ExitStack
        from django.views.generic import DetailView

        with ExitStack() as stack:
            self.filters = {}
            for target, rows in self.rows.items():
                queryset = MagicMock()
                for method in ("only", "prefetch_related", "select_related", "order_by"):
                    getattr(queryset, method).return_value = queryset
                queryset.__iter__.side_effect = lambda rows=rows: iter(rows)
                self.filters[target] = stack.enter_context(patch(target, return_value=queryset))
            stack.enter_context(patch("training.views.has_active_learner_identity", return_value=active_identity))
            stack.enter_context(patch.object(DetailView, "get_context_data", return_value={"assignment": self.assignment}))
            view = TrainingAssignmentDetailView()
            view.request, view.object = self.request, self.assignment
            return view.get_context_data()

    def render(self, context):
        request = RequestFactory().get("/assignments/1/")
        request.user = AnonymousUser()
        return render_to_string("training/assignment_detail.html", context, request=request)

    def test_summary_uses_stored_coverage_not_resume_and_exposes_no_learner_actions(self):
        context = self.context()
        html = self.render(context)
        self.assertIn("management_progress", context)
        self.assertIn("20%", html)
        self.assertIn("20.0 / 100 seconds", html)
        self.assertIn("0 of 1 lessons completed", html)
        self.assertIn("Not passed", html)
        self.assertIn("1.00 / 2.00", html)
        self.assertIn("Not issued", html)
        for forbidden in ("95%", "<video", "Mark lesson complete", "View assessment", "data-progress-url", "/sessions/", "/replay/media/"):
            self.assertNotIn(forbidden, html)
        self.assertFalse(context.get("can_learn", False))

    def test_empty_and_unstarted_progress_is_explicit(self):
        self.rows["training.views.LessonProgress.objects.filter"] = []
        self.rows["assessments.models.AssessmentAttempt.objects.filter"] = []
        html = self.render(self.context())
        self.assertIn("Not started", html)
        self.assertIn("0%", html)
        self.assertIn("Not attempted", html)
        self.rows["training.views.Module.objects.filter"] = []
        self.rows["assessments.models.Assessment.objects.filter"] = []
        html = self.render(self.context())
        self.assertIn("No lessons are available", html)
        self.assertIn("No assessments are available", html)

    def test_completion_uses_recorded_timestamp_not_percentage(self):
        self.progress.watched_ranges = [[0, 95]]
        self.assertIn("0 of 1 lessons completed", self.render(self.context()))
        self.progress.completed_at = timezone.now()
        self.assertIn("1 of 1 lessons completed", self.render(self.context()))

    def test_unfinished_attempt_does_not_present_a_score_or_pass(self):
        for status in ("IN_PROGRESS", "ABANDONED"):
            with self.subTest(status=status):
                self.attempt.status, self.attempt.passed, self.attempt.score_points = status, None, None
                html = self.render(self.context())
                self.assertNotIn("1.00 / 2.00", html)
                self.assertNotIn("Not passed", html)

    def test_revoked_certificate_status_has_no_unpermitted_link_or_reason(self):
        from certifications.models import Certificate
        self.assignment._state.fields_cache["certificate"] = Certificate(
            pk=8, issued_at=timezone.now(), revoked_at=timezone.now(),
            revocation_reason="Private revocation reason", certificate_number="PRIVATE-NUMBER",
        )
        html = self.render(self.context())
        self.assertIn("Revoked", html)
        for forbidden in ("Private revocation reason", "PRIVATE-NUMBER", "/certificates/8/", 'action="/certificates/'):
            self.assertNotIn(forbidden, html)

    def test_inactive_or_nonmanagement_viewer_gets_no_summary(self):
        self.assertNotIn("management_progress", self.context(active_identity=False))
        self.request.user.is_active = False
        self.assertNotIn("management_progress", self.context())
        self.request.user.is_active = True
        self.request.user.groups.filter.return_value.exists.return_value = False
        self.assertNotIn("management_progress", self.context())

    def test_company_authority_does_not_require_a_learner_identity(self):
        self.request.user.has_perm = lambda permission: permission == "training.add_trainingassignment"
        self.assertIn("management_progress", self.context(active_identity=False))

    def test_result_queries_stay_on_the_selected_assignment_and_pinned_version(self):
        self.context()
        self.filters["training.views.LessonProgress.objects.filter"].assert_called_once_with(
            assignment=self.assignment, lesson__module__training_version=self.assignment.training_version,
        )
        self.filters["assessments.models.AssessmentAttempt.objects.filter"].assert_called_once_with(
            assignment=self.assignment, assessment__training_version=self.assignment.training_version,
        )
        for target in ("training.views.Module.objects.filter", "assessments.models.Assessment.objects.filter"):
            self.filters[target].assert_called_once_with(training_version=self.assignment.training_version)

    def test_latest_attempt_and_localized_coverage_are_unambiguous(self):
        from assessments.models import AssessmentAttempt
        from django.test import override_settings

        latest = AssessmentAttempt(assessment=self.assessment, assignment=self.assignment,
            attempt_number=2, status="SUBMITTED", score_points=Decimal("2.00"),
            maximum_points=Decimal("2.00"), passed=True, submitted_at=timezone.now())
        self.rows["assessments.models.AssessmentAttempt.objects.filter"] = [latest, self.attempt]
        self.progress.watched_ranges = [[0, 20.5]]
        with override_settings(LANGUAGE_CODE="de"):
            html = self.render(self.context())
        self.assertIn('value="20.5"', html)
        self.assertIn("Latest attempt: 2", html)
        self.assertNotIn("Not passed", html)
        self.assertIn("Passed", html)

    def test_summary_labels_are_escaped_and_do_not_render_lesson_content(self):
        self.lesson.title = '<script>alert("lesson")</script>'
        self.lesson.body = "PRIVATE LESSON CONTENT"
        self.lesson.video_file = "private/video.mp4"
        html = self.render(self.context())
        self.assertIn("&lt;script&gt;", html)
        self.assertNotIn('<script>alert("lesson")</script>', html)
        self.assertNotIn("PRIVATE LESSON CONTENT", html)
        self.assertNotIn("private/video.mp4", html)

    def test_lesson_query_parameter_remains_forbidden_for_management(self):
        from django.http import Http404
        self.request.GET = {"lesson": str(self.lesson.pk)}
        with self.assertRaises(Http404):
            self.context()


class ManagerAssignmentProgressTests(CurriculumTestCase):
    """Real hierarchy/result queries; run only on approved disposable MySQL."""

    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.employee_user.groups.add(Group.objects.get(name="Employee"))
        cls.user.groups.add(Group.objects.get(name="Training Coordinator"))
        cls.manager_user = get_user_model().objects.create_user(username="progress-manager")
        cls.manager_user.groups.add(Group.objects.get(name="Manager"))
        cls.manager = Employee.objects.create(
            employee_code="PROGRESS-MANAGER", display_name="Progress Manager",
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(), user=cls.manager_user,
        )
        cls.employee.reporting_manager = cls.manager
        cls.employee.save()

    def setUp(self):
        self.client.force_login(self.manager_user)

    def page(self, assignment=None):
        return f"/assignments/{(assignment or self.assignment).pk}/"

    def recipient_assignment(self, code, *, manager=None, user=None):
        employee = Employee.objects.create(
            employee_code=code, display_name=code, department=self.department, job_role=self.role,
            date_joined=self.now.date(), reporting_manager=manager, user=user,
        )
        return TrainingAssignment.objects.create(
            employee=employee, training_version=self.version, department_at_assignment=self.department,
            job_role_at_assignment=self.role, assigned_by=self.user,
        )

    def test_direct_report_results_are_read_only_and_do_not_expose_learning_content(self):
        from assessments.models import AssessmentAttempt, AttemptAnswer
        from certifications.models import Certificate
        from training.models import LessonProgress, VideoWatchSession

        self.complete_lessons()
        self.finish_attempt(self.quiz, correct=False)
        models = (TrainingAssignment, LessonProgress, VideoWatchSession, AssessmentAttempt,
                  AttemptAnswer, Certificate, AuditLog, Notification)
        before = {model: list(model.objects.order_by("pk").values()) for model in models}
        response = self.client.get(self.page())
        self.assertContains(response, "Training progress summary")
        self.assertContains(response, "2 of 2 lessons completed")
        self.assertContains(response, "95%")
        self.assertContains(response, "Not passed")
        self.assertContains(response, "Not attempted")
        for forbidden in ("Safety instructions", "Wear PPE?", "View assessment", "Mark lesson complete",
                          'id="lesson-video"', "data-media-url", "/sessions/", "/replay/media/"):
            self.assertNotContains(response, forbidden)
        self.assertFalse(response.context.get("can_learn", False))
        for model in models:
            self.assertEqual(list(model.objects.order_by("pk").values()), before[model])

    def test_direct_and_indirect_reports_are_visible_but_unrelated_same_department_is_not(self):
        indirect = self.recipient_assignment("PROGRESS-INDIRECT", manager=self.employee)
        unrelated = self.recipient_assignment("PROGRESS-FOREIGN")
        self.assertContains(self.client.get(self.page(indirect)), "Training progress summary")
        self.assertEqual(self.client.get(self.page(unrelated)).status_code, 404)
        self.assertEqual(self.client.get(self.page(unrelated), {"scope": "company", "employee": self.employee.pk}).status_code, 404)
        self.employee.reporting_manager = None
        self.employee.save()
        self.assertEqual(self.client.get(self.page()).status_code, 404)

    def test_employee_trainer_and_supervisor_cannot_inspect_their_direct_reports(self):
        subordinate = self.recipient_assignment("PROGRESS-SUBORDINATE", manager=self.employee)
        for role in ("Employee", "Trainer", "Supervisor"):
            with self.subTest(role=role):
                self.employee_user.groups.set([Group.objects.get(name=role)])
                self.client.force_login(self.employee_user)
                self.assertEqual(self.client.get(self.page(subordinate)).status_code, 404)
                response = self.client.get(self.page())
                self.assertEqual(response.status_code, 200)
                self.assertNotIn("management_progress", response.context)

    def test_inactive_or_unlinked_manager_cannot_obtain_a_progress_summary(self):
        self.manager.is_active = False
        self.manager.deactivation_reason = "Isolated test deactivation"
        self.manager.save()
        self.manager_user.is_active = True
        self.manager_user.save()
        self.client.force_login(self.manager_user)
        # Existing assignment-overview authority is unchanged; new progress access is denied.
        response = self.client.get(self.page())
        self.assertEqual(response.status_code, 200)
        self.assertNotIn("management_progress", response.context)
        unlinked = get_user_model().objects.create_user(username="unlinked-progress-manager")
        unlinked.groups.add(Group.objects.get(name="Manager"))
        self.client.force_login(unlinked)
        self.assertEqual(self.client.get(self.page()).status_code, 404)
        self.manager_user.is_active = False
        self.manager_user.save()
        self.client.force_login(self.manager_user)
        self.assertEqual(self.client.get(self.page()).status_code, 403)

    def test_company_authority_remains_independent_of_employee_identity(self):
        self.client.force_login(self.user)
        self.assertContains(self.client.get(self.page()), "Training progress summary")

    def test_summary_does_not_authorize_learning_mutations_or_media(self):
        from django.urls import reverse
        from assessments.models import AssessmentAttempt
        from training.models import LessonProgress, VideoWatchSession

        before = (LessonProgress.objects.count(), VideoWatchSession.objects.count(), AssessmentAttempt.objects.count())
        operations = (
            ("training:text-lesson-complete", {"assignment_pk": self.assignment.pk, "lesson_pk": self.text_lesson.pk}),
            ("training:video-session-start", {"assignment_pk": self.assignment.pk, "lesson_pk": self.video_lesson.pk}),
            ("assessments:attempt-start", {"assignment_pk": self.assignment.pk, "assessment_pk": self.quiz.pk}),
        )
        for name, kwargs in operations:
            with self.subTest(route=name):
                self.assertEqual(self.client.post(reverse(name, kwargs=kwargs), {}).status_code, 404)
        replay = reverse("training:video-replay-media", kwargs={"assignment_pk": self.assignment.pk, "lesson_pk": self.video_lesson.pk})
        self.assertEqual(self.client.get(replay).status_code, 404)
        self.assertEqual((LessonProgress.objects.count(), VideoWatchSession.objects.count(), AssessmentAttempt.objects.count()), before)

    def test_mixed_role_manager_keeps_own_learner_controls(self):
        own = TrainingAssignment.objects.create(
            employee=self.manager, training_version=self.version, department_at_assignment=self.department,
            job_role_at_assignment=self.role, assigned_by=self.user,
        )
        response = self.client.get(self.page(own))
        self.assertTrue(response.context["can_learn"])
        self.assertNotIn("management_progress", response.context)
        self.assertContains(response, "Mark lesson complete")
        self.assertContains(response, "View assessment")

    def test_pinned_retired_version_is_used_and_lesson_parameters_stay_forbidden(self):
        draft = self.new_version()
        self.version.status = "RETIRED"
        self.version.save()
        response = self.client.get(self.page(), {"training_version_id": draft.pk})
        self.assertContains(response, "Safety v1")
        self.assertNotContains(response, draft.title)
        self.assertContains(response, "Training progress summary")
        for lesson_id in (self.video_lesson.pk, 999999, "invalid"):
            self.assertEqual(self.client.get(self.page(), {"lesson": lesson_id}).status_code, 404)
        self.assertEqual(self.client.get("/assignments/999999/").status_code, 404)

    def test_latest_assessment_result_and_issued_revoked_certificate_preserve_permissions(self):
        from certifications.services import issue_completed_assignment_certificate

        self.complete_lessons()
        self.finish_attempt(self.quiz, correct=False)
        self.finish_attempt(self.quiz, correct=True)
        self.finish_attempt(self.final)
        self.assignment.status = "COMPLETED"
        self.assignment.completed_at = timezone.now()
        self.assignment.save()
        certificate = issue_completed_assignment_certificate(self.assignment.pk, actor=self.user)
        response = self.client.get(self.page())
        self.assertEqual(response.context["management_progress"]["certificate_status"], "Issued")
        self.assertContains(response, "Latest attempt: 2")
        self.assertNotContains(response, "Not passed")
        self.assertNotContains(response, f'href="/certificates/{certificate.pk}/"')
        self.assertNotContains(response, certificate.certificate_number)
        certificate.revoked_at = timezone.now()
        certificate.revoked_by = self.user
        certificate.revocation_reason = "Private isolated fixture reason"
        certificate.save()
        response = self.client.get(self.page())
        self.assertEqual(response.context["management_progress"]["certificate_status"], "Revoked")
        self.assertNotContains(response, certificate.revocation_reason)


class ManagerWebsiteAssignmentTests(CurriculumTestCase):
    url = "/assignments/new/"

    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.user.groups.add(Group.objects.get(name="Training Coordinator"))
        cls.employee_user.groups.add(Group.objects.get(name="Employee"))
        cls.manager_user = get_user_model().objects.create_user(username="team-assign-manager")
        cls.manager_user.groups.add(Group.objects.get(name="Manager"))
        cls.manager = cls.recipient("manager", manager=cls.employee, user=cls.manager_user)
        cls.direct = cls.recipient("direct", manager=cls.manager)
        cls.indirect = cls.recipient("indirect", manager=cls.direct)
        cls.peer = cls.recipient("peer", manager=cls.employee)
        cls.foreign = cls.recipient("foreign")
        cls.inactive = cls.recipient("inactive", manager=cls.manager)
        cls.inactive.is_active = False
        cls.inactive.deactivation_reason = "Isolated test fixture"
        cls.inactive.save()

    @classmethod
    def recipient(cls, name, *, manager=None, user=None):
        return Employee.objects.create(
            employee_code="ASSIGN-" + name.upper(), display_name="Assignment " + name,
            department=cls.department, job_role=cls.role, date_joined=timezone.localdate(),
            reporting_manager=manager, user=user,
        )

    def payload(self, employee=None, **overrides):
        return {
            "employee": (employee or self.direct).pk,
            "training_version": self.version.pk, "due_date": "", **overrides,
        }

    def form(self, employee=None, user=None):
        form = TrainingAssignmentForm(user=user or self.manager_user, data=self.payload(employee))
        self.assertTrue(form.is_valid(), form.errors)
        return form

    def login(self, user=None):
        self.client.force_login(user or self.manager_user)

    def assert_no_writes(self):
        self.assertEqual(list(TrainingAssignment.objects.values_list("pk", flat=True)), [self.assignment.pk])
        self.assertFalse(Notification.objects.exists())
        self.assertFalse(AuditLog.objects.exists())

    def test_get_choices_are_active_team_only_and_published_only(self):
        draft = self.new_version()
        self.login()
        response = self.client.get(self.url)
        self.assertEqual(response.status_code, 200)
        form = response.context["form"]
        self.assertEqual(form.user.pk, self.manager_user.pk)
        self.assertEqual(set(form.fields["employee"].queryset), {self.direct, self.indirect})
        self.assertEqual(list(form.fields["training_version"].queryset), [self.version])
        self.assertNotContains(response, draft.title)
        self.assertContains(response, "reporting hierarchy")
        self.assertContains(self.client.get("/assignments/"), 'href="/assignments/new/"')
        self.assert_no_writes()

    def test_direct_and_indirect_posts_create_snapshots_audit_and_one_notification(self):
        self.login()
        for employee in (self.direct, self.indirect):
            with self.subTest(employee=employee.pk), self.captureOnCommitCallbacks(execute=True):
                response = self.client.post(self.url, self.payload(
                    employee, assigned_by=self.user.pk, source="ROLE", status="COMPLETED",
                ))
                assignment = TrainingAssignment.objects.get(employee=employee)
                self.assertRedirects(response, f"/assignments/{assignment.pk}/", fetch_redirect_response=False)
                self.assertEqual(assignment.training_version_id, self.version.pk)
                self.assertEqual(assignment.assigned_by_id, self.manager_user.pk)
                self.assertEqual(assignment.department_at_assignment_id, self.department.pk)
                self.assertEqual(assignment.job_role_at_assignment_id, self.role.pk)
                self.assertEqual(assignment.status, "ASSIGNED")
                self.assertEqual(assignment.source, "MANUAL")
                self.assertIsNone(assignment.role_requirement_id)
                notification = Notification.objects.get(assignment=assignment)
                self.assertEqual(notification.employee_id, employee.pk)
                self.assertEqual(notification.event_type, "ASSIGNED")
            event = AuditLog.objects.get(action="training.trainingassignment.created", entity_id=str(assignment.pk))
            self.assertEqual(event.actor_id, self.manager_user.pk)
            self.assertEqual(event.after_data["employee_id"], employee.pk)
        self.assertEqual(Notification.objects.count(), 2)
        self.assertEqual(AuditLog.objects.count(), 2)
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.status, "IN_PROGRESS")
        self.assertEqual(self.assignment.training_version_id, self.version.pk)

    def test_forged_self_peer_superior_foreign_inactive_and_unknown_ids_are_rejected(self):
        self.login()
        for employee_id in (self.manager.pk, self.peer.pk, self.employee.pk, self.foreign.pk,
                            self.inactive.pk, 999999):
            with self.subTest(employee=employee_id), self.captureOnCommitCallbacks(execute=True):
                response = self.client.post(self.url, {**self.payload(), "employee": employee_id})
                self.assertEqual(response.status_code, 200)
                self.assertIn("employee", response.context["form"].errors)
        self.assert_no_writes()

    def test_inactive_user_cannot_get_or_post(self):
        self.manager_user.is_active = False
        self.manager_user.save()
        self.login()
        self.assertEqual(self.client.get(self.url).status_code, 403)
        self.assertEqual(self.client.post(self.url, self.payload()).status_code, 403)
        self.assert_no_writes()

    def test_inactive_manager_employee_cannot_get_or_post_with_reenabled_user(self):
        self.manager.is_active = False
        self.manager.deactivation_reason = "Isolated test deactivation"
        self.manager.save()
        self.manager_user.is_active = True
        self.manager_user.save()
        self.login()
        self.assertEqual(self.client.get(self.url).status_code, 403)
        self.assertEqual(self.client.post(self.url, self.payload()).status_code, 403)
        self.assertNotContains(self.client.get("/assignments/"), 'href="/assignments/new/"')
        self.assert_no_writes()

    def test_employee_unlinked_manager_and_anonymous_cannot_get_or_post(self):
        unlinked = get_user_model().objects.create_user(username="unlinked-team-manager")
        unlinked.groups.add(Group.objects.get(name="Manager"))
        for user in (self.employee_user, unlinked, None):
            with self.subTest(user=user):
                self.client.logout()
                if user:
                    self.login(user)
                self.assertEqual(self.client.get(self.url).status_code, 403)
                self.assertEqual(self.client.post(self.url, self.payload()).status_code, 403)
        self.assert_no_writes()

    def test_manager_without_permission_has_no_action_get_or_post_access(self):
        permission = Permission.objects.get(codename="assign_team_trainingassignment")
        Group.objects.get(name="Manager").permissions.remove(permission)
        self.login()
        self.assertNotContains(self.client.get("/assignments/"), 'href="/assignments/new/"')
        self.assertEqual(self.client.get(self.url).status_code, 403)
        self.assertEqual(self.client.post(self.url, self.payload()).status_code, 403)
        self.assert_no_writes()

    def test_company_wide_role_configuration_remains_forbidden_on_get_and_post(self):
        self.login()
        listing = self.client.get("/assignments/")
        for path in ("/assignments/role/new/", "/assignments/requirements/", "/assignments/requirements/new/"):
            with self.subTest(path=path):
                self.assertNotContains(listing, f'href="{path}"')
                self.assertEqual(self.client.get(path).status_code, 403)
                self.assertEqual(self.client.post(path, self.payload()).status_code, 403)
        self.assert_no_writes()

    def test_draft_and_retired_versions_are_rejected_by_get_choices_and_post(self):
        draft = self.new_version()
        self.version.status = "RETIRED"
        self.version.save()
        self.login()
        self.assertFalse(self.client.get(self.url).context["form"].fields["training_version"].queryset.exists())
        for version in (draft, self.version):
            with self.subTest(version=version.pk):
                response = self.client.post(self.url, self.payload(training_version=version.pk))
                self.assertEqual(response.status_code, 200)
                self.assertIn("training_version", response.context["form"].errors)
        self.assert_no_writes()

    def test_duplicate_post_creates_no_duplicate_assignment_event_or_audit(self):
        self.login()
        with self.captureOnCommitCallbacks(execute=True):
            self.assertEqual(self.client.post(self.url, self.payload()).status_code, 302)
        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.post(self.url, self.payload())
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "already has an assignment")
        self.assertEqual(TrainingAssignment.objects.filter(employee=self.direct).count(), 1)
        self.assertEqual(Notification.objects.count(), 1)
        self.assertEqual(AuditLog.objects.count(), 1)

    def test_invalid_and_past_due_dates_are_field_errors(self):
        self.login()
        for value in ("not-a-date", (timezone.localdate() - timedelta(days=1)).isoformat()):
            with self.subTest(due_date=value):
                response = self.client.post(self.url, self.payload(due_date=value))
                self.assertEqual(response.status_code, 200)
                self.assertIn("due_date", response.context["form"].errors)
                self.assertEqual(response.context["form"].data["employee"], str(self.direct.pk))
        self.assert_no_writes()

    def test_due_today_keeps_existing_end_of_day_behavior(self):
        self.login()
        self.assertEqual(self.client.post(self.url, self.payload(due_date=timezone.localdate().isoformat())).status_code, 302)
        assignment = TrainingAssignment.objects.get(employee=self.direct)
        self.assertEqual(timezone.localtime(assignment.due_at).time(), time.max)

    def test_global_administrator_and_coordinator_keep_company_choices_and_actions(self):
        admin = get_user_model().objects.create_user(username="team-assignment-admin")
        admin.groups.add(Group.objects.get(name="Administrator"))
        for user, recipient in ((admin, self.foreign), (self.user, self.peer)):
            with self.subTest(user=user.pk):
                self.login(user)
                response = self.client.get(self.url)
                choices = response.context["form"].fields["employee"].queryset
                self.assertIn(self.manager, choices)
                self.assertIn(self.foreign, choices)
                self.assertNotIn(self.inactive, choices)
                listing = self.client.get("/assignments/")
                self.assertContains(listing, 'href="/assignments/role/new/"')
                self.assertContains(listing, 'href="/assignments/requirements/"')
                self.assertEqual(self.client.post(self.url, self.payload(recipient)).status_code, 302)
                self.assertEqual(TrainingAssignment.objects.get(employee=recipient).assigned_by_id, user.pk)

    def test_manager_post_still_requires_csrf(self):
        client = Client(enforce_csrf_checks=True)
        client.force_login(self.manager_user)
        self.assertContains(client.get(self.url), 'name="csrfmiddlewaretoken"')
        self.assertEqual(client.post(self.url, self.payload()).status_code, 403)
        self.assert_no_writes()

    def test_scope_is_rechecked_after_direct_or_ancestor_reporting_line_changes(self):
        forms = [self.form(self.direct), self.form(self.indirect)]
        self.direct.reporting_manager = self.foreign
        self.direct.save()
        for form in forms:
            with self.subTest(employee=form.instance.employee_id):
                with self.assertRaisesMessage(ValidationError, "no longer assign"):
                    form.save(assigned_by=self.manager_user)
        self.assert_no_writes()

    def test_recipient_deactivation_after_validation_is_rejected(self):
        form = self.form()
        self.direct.is_active = False
        self.direct.deactivation_reason = "Isolated fixture"
        self.direct.save()
        with self.assertRaisesMessage(ValidationError, "no longer assign"):
            form.save(assigned_by=self.manager_user)
        self.assert_no_writes()

    def test_manager_deactivation_after_validation_is_rejected(self):
        form = self.form()
        self.manager.is_active = False
        self.manager.deactivation_reason = "Isolated fixture"
        self.manager.save()
        with self.assertRaisesMessage(ValidationError, "no longer assign"):
            form.save(assigned_by=self.manager_user)
        self.assert_no_writes()

    def test_user_deactivation_after_validation_uses_fresh_user_not_request_cache(self):
        form = self.form()
        get_user_model().objects.filter(pk=self.manager_user.pk).update(is_active=False)
        with self.assertRaisesMessage(ValidationError, "no longer assign"):
            form.save(assigned_by=self.manager_user)
        self.assert_no_writes()

    def test_permission_revocation_after_validation_uses_fresh_effective_permissions(self):
        form = self.form()
        Group.objects.get(name="Manager").permissions.remove(Permission.objects.get(codename="assign_team_trainingassignment"))
        with self.assertRaisesMessage(ValidationError, "no longer assign"):
            form.save(assigned_by=self.manager_user)
        self.assert_no_writes()

    def test_global_authority_loss_does_not_fall_back_without_hierarchy_locks(self):
        self.manager_user.groups.add(Group.objects.get(name="Administrator"))
        form = self.form(self.foreign)
        self.manager_user.groups.remove(Group.objects.get(name="Administrator"))
        with self.assertRaisesMessage(ValidationError, "permissions changed"):
            form.save(assigned_by=self.manager_user)
        self.assert_no_writes()

    def test_snapshots_use_fresh_locked_employee_for_team_and_global_assignments(self):
        department = Department.objects.create(code="FRESH", name="Current department")
        role = JobRole.objects.create(code="FRESH", name="Current role")
        for actor, employee in ((self.manager_user, self.direct), (self.user, self.indirect)):
            with self.subTest(actor=actor.pk):
                form = self.form(employee, user=actor)
                employee.department = department
                employee.job_role = role
                employee.save()
                assignment = form.save(assigned_by=actor)
                self.assertEqual(assignment.department_at_assignment_id, department.pk)
                self.assertEqual(assignment.job_role_at_assignment_id, role.pk)

    def test_retirement_after_validation_is_rejected_without_notification(self):
        form = self.form()
        self.version.status = "RETIRED"
        self.version.save()
        with self.assertRaises(ValidationError):
            form.save(assigned_by=self.manager_user)
        self.assert_no_writes()

    def test_missing_actor_fails_closed_and_commit_false_or_forged_actor_cannot_write(self):
        missing_actor = TrainingAssignmentForm(data=self.payload())
        self.assertFalse(missing_actor.is_valid())
        self.assertIn("employee", missing_actor.errors)
        form = self.form()
        self.assertIsNone(form.save(commit=False, assigned_by=self.manager_user).pk)
        with self.assertRaisesMessage(ValidationError, "authenticated user"):
            self.form().save(assigned_by=self.user)
        self.assert_no_writes()

    def test_two_prevalidated_forms_still_create_only_one_assignment_and_notification(self):
        first, second = self.form(), self.form()
        first.save(assigned_by=self.manager_user)
        with self.assertRaises(ValidationError):
            second.save(assigned_by=self.manager_user)
        self.assertEqual(TrainingAssignment.objects.filter(employee=self.direct).count(), 1)
        self.assertEqual(Notification.objects.count(), 1)

    def test_notification_failure_rolls_back_assignment_and_emits_no_success_audit(self):
        self.login()
        with patch("training.forms.create_assignment_notification", side_effect=IntegrityError("Isolated failure")):
            with self.captureOnCommitCallbacks(execute=True):
                response = self.client.post(self.url, self.payload())
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.context["form"].non_field_errors())
        self.assert_no_writes()

    def test_save_validation_errors_are_attached_to_employee_field(self):
        self.login()
        with patch.object(TrainingAssignmentForm, "save", side_effect=ValidationError({"employee": "Scope changed; reload."})):
            response = self.client.post(self.url, self.payload())
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.context["form"].errors["employee"], ["Scope changed; reload."])
        self.assert_no_writes()

    @skipUnless(connection.vendor == "mysql", "MySQL row-lock SQL assertion")
    def test_team_hierarchy_and_version_locks_precede_actor_lock(self):
        form = self.form()
        queries = []

        def capture(execute, sql, params, many, context):
            if "FOR UPDATE" in sql.upper():
                queries.append(sql)
            return execute(sql, params, many, context)

        with connection.execute_wrapper(capture):
            form.save(assigned_by=self.manager_user)
        self.assertIn('FROM `organization_employee`', queries[0])
        self.assertIn('`organization_employee`.`id`', queries[0])
        self.assertRegex(queries[0], r'ORDER BY (?:1|`organization_employee`\.`id`) ASC')
        user_index = next(i for i, sql in enumerate(queries) if 'FROM `auth_user`' in sql)
        version_index = next(i for i, sql in enumerate(queries) if 'FROM `training_trainingversion`' in sql)
        self.assertGreater(version_index, 0)
        self.assertGreater(user_index, version_index)
