import json
from datetime import timedelta
from decimal import Decimal, InvalidOperation

from django.contrib.auth.decorators import login_required
from django.contrib.auth.mixins import LoginRequiredMixin, PermissionRequiredMixin
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import IntegrityError, transaction
from django.http import Http404, JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse, reverse_lazy
from django.utils import timezone
from django.views.generic import CreateView, DetailView, ListView, UpdateView

from audit.mixins import AuditedFormMixin
from audit.services import audit_snapshot, record_event
from organization.models import Employee
from training.models import Lesson, LessonProgress, Module, TrainingAssignment, TrainingVersion

from .forms import (
	AssessmentForm,
	AssessmentQuestionForm,
	QuestionForm,
	QuestionOptionFormSet,
	QuestionRevisionForm,
)
from .models import (
	Assessment,
	AssessmentAttempt,
	AssessmentQuestion,
	AttemptAnswer,
	Question,
	QuestionOption,
	QuestionRevision,
)


class AssessmentPermissionMixin(AuditedFormMixin, LoginRequiredMixin, PermissionRequiredMixin):
	raise_exception = True


class QuestionListView(AssessmentPermissionMixin, ListView):
	permission_required = "assessments.view_question"
	model = Question
	template_name = "assessments/question_list.html"
	context_object_name = "questions"


class QuestionDetailView(AssessmentPermissionMixin, DetailView):
	permission_required = "assessments.view_question"
	model = Question
	template_name = "assessments/question_detail.html"
	context_object_name = "question"


class QuestionCreateView(AssessmentPermissionMixin, CreateView):
	permission_required = "assessments.add_question"
	model = Question
	form_class = QuestionForm
	template_name = "assessments/question_form.html"

	def form_valid(self, form):
		with transaction.atomic():
			form.instance.created_by = self.request.user
			response = super().form_valid(form)
			revision = QuestionRevision.objects.create(
				question=self.object,
				revision_number=1,
				prompt="Draft question",
				created_by=self.request.user,
			)
			record_event(
				self.request.user,
				"assessments.questionrevision.created",
				revision,
				after=audit_snapshot(revision),
			)
		return response

	def get_success_url(self):
		return reverse("assessments:question-detail", kwargs={"pk": self.object.pk})


class QuestionUpdateView(AssessmentPermissionMixin, UpdateView):
	permission_required = "assessments.change_question"
	model = Question
	form_class = QuestionForm
	template_name = "assessments/question_form.html"

	def get_success_url(self):
		return reverse("assessments:question-detail", kwargs={"pk": self.object.pk})


def _check_permission(request, permission):
	if not request.user.has_perm(permission):
		raise PermissionDenied


@login_required
def create_question_revision(request, pk):
	_check_permission(request, "assessments.add_questionrevision")
	question = get_object_or_404(Question, pk=pk)
	if request.method == "POST":
		form = QuestionRevisionForm(request.POST)
		if form.is_valid():
			with transaction.atomic():
				question = Question.objects.select_for_update().get(pk=question.pk)
				number = (question.revisions.order_by("-revision_number").values_list("revision_number", flat=True).first() or 0) + 1
				revision = form.save(commit=False)
				revision.question = question
				revision.revision_number = number
				revision.created_by = request.user
				revision.save()
				record_event(
					request.user,
					"assessments.questionrevision.created",
					revision,
					after=audit_snapshot(revision),
				)
			return redirect("assessments:revision-detail", pk=revision.pk)
	else:
		form = QuestionRevisionForm()
	return render(request, "assessments/revision_form.html", {"form": form, "question": question})


@login_required
def edit_question_revision(request, pk):
	_check_permission(request, "assessments.change_questionrevision")
	revision = get_object_or_404(QuestionRevision, pk=pk, status=QuestionRevision.Status.DRAFT)
	if request.method == "POST":
		form = QuestionRevisionForm(request.POST, instance=revision)
		options = QuestionOptionFormSet(request.POST, instance=revision)
		if form.is_valid() and options.is_valid():
			before = audit_snapshot(revision)
			with transaction.atomic():
				form.save()
				options.save()
				record_event(
					request.user,
					"assessments.questionrevision.updated",
					revision,
					before=before,
					after={**audit_snapshot(revision), "content_updated": True},
				)
			return redirect("assessments:revision-detail", pk=revision.pk)
	else:
		form = QuestionRevisionForm(instance=revision)
		options = QuestionOptionFormSet(instance=revision)
	return render(request, "assessments/revision_form.html", {
		"form": form, "options": options, "question": revision.question, "revision": revision,
	})


@login_required
def question_revision_detail(request, pk):
	_check_permission(request, "assessments.view_questionrevision")
	revision = get_object_or_404(QuestionRevision.objects.prefetch_related("options"), pk=pk)
	return render(request, "assessments/revision_detail.html", {"revision": revision})


@login_required
def freeze_question_revision(request, pk):
	_check_permission(request, "assessments.change_questionrevision")
	if request.method != "POST":
		raise Http404
	revision = get_object_or_404(QuestionRevision, pk=pk, status=QuestionRevision.Status.DRAFT)
	before = audit_snapshot(revision)
	revision.status = QuestionRevision.Status.FROZEN
	revision.frozen_at = timezone.now()
	try:
		revision.save()
	except ValidationError as exc:
		revision.refresh_from_db()
		return render(request, "assessments/revision_detail.html", {"revision": revision, "errors": exc}, status=400)
	record_event(
		request.user,
		"assessments.questionrevision.frozen",
		revision,
		before=before,
		after=audit_snapshot(revision),
	)
	return redirect("assessments:revision-detail", pk=revision.pk)


class VersionAssessmentListView(AssessmentPermissionMixin, ListView):
	permission_required = "assessments.view_assessment"
	model = Assessment
	template_name = "assessments/assessment_list.html"
	context_object_name = "assessments"

	def get_queryset(self):
		return Assessment.objects.filter(training_version_id=self.kwargs["version_pk"]).select_related("module").order_by("kind", "sequence")

	def get_context_data(self, **kwargs):
		context = super().get_context_data(**kwargs)
		context["version"] = get_object_or_404(TrainingVersion, pk=self.kwargs["version_pk"])
		return context


class AssessmentCreateView(AssessmentPermissionMixin, CreateView):
	permission_required = "assessments.add_assessment"
	model = Assessment
	form_class = AssessmentForm
	template_name = "assessments/assessment_form.html"

	def dispatch(self, request, *args, **kwargs):
		self.training_version = get_object_or_404(
			TrainingVersion, pk=kwargs["version_pk"], status=TrainingVersion.Status.DRAFT,
		)
		return super().dispatch(request, *args, **kwargs)

	def get_form_kwargs(self):
		kwargs = super().get_form_kwargs()
		kwargs["training_version"] = self.training_version
		kwargs["instance"] = Assessment(training_version=self.training_version)
		return kwargs

	def form_valid(self, form):
		form.instance.training_version = self.training_version
		return super().form_valid(form)

	def get_success_url(self):
		return reverse("assessments:assessment-detail", kwargs={"pk": self.object.pk})


class DraftAssessmentMixin(AssessmentPermissionMixin):
	def get_queryset(self):
		return Assessment.objects.filter(training_version__status=TrainingVersion.Status.DRAFT)

	def get_form_kwargs(self):
		kwargs = super().get_form_kwargs()
		kwargs["training_version"] = self.object.training_version if hasattr(self, "object") else self.get_object().training_version
		return kwargs


class AssessmentUpdateView(DraftAssessmentMixin, UpdateView):
	permission_required = "assessments.change_assessment"
	model = Assessment
	form_class = AssessmentForm
	template_name = "assessments/assessment_form.html"

	def get_success_url(self):
		return reverse("assessments:assessment-detail", kwargs={"pk": self.object.pk})


class AssessmentDetailView(AssessmentPermissionMixin, DetailView):
	permission_required = "assessments.view_assessment"
	model = Assessment
	template_name = "assessments/assessment_detail.html"
	context_object_name = "assessment"


class AssessmentQuestionCreateView(AssessmentPermissionMixin, CreateView):
	permission_required = "assessments.add_assessmentquestion"
	model = AssessmentQuestion
	form_class = AssessmentQuestionForm
	template_name = "assessments/assessment_question_form.html"

	def dispatch(self, request, *args, **kwargs):
		self.assessment = get_object_or_404(
			Assessment.objects.select_related("training_version"),
			pk=kwargs["assessment_pk"], training_version__status=TrainingVersion.Status.DRAFT,
		)
		return super().dispatch(request, *args, **kwargs)

	def get_form_kwargs(self):
		kwargs = super().get_form_kwargs()
		kwargs["instance"] = AssessmentQuestion(assessment=self.assessment)
		return kwargs

	def form_valid(self, form):
		form.instance.assessment = self.assessment
		try:
			return super().form_valid(form)
		except ValidationError as exc:
			form.add_error(None, exc)
			return self.form_invalid(form)

	def get_success_url(self):
		return reverse("assessments:assessment-detail", kwargs={"pk": self.assessment.pk})


class AssessmentQuestionUpdateView(AssessmentPermissionMixin, UpdateView):
	permission_required = "assessments.change_assessmentquestion"
	model = AssessmentQuestion
	form_class = AssessmentQuestionForm
	template_name = "assessments/assessment_question_form.html"

	def get_queryset(self):
		return AssessmentQuestion.objects.filter(assessment__training_version__status=TrainingVersion.Status.DRAFT)

	def form_valid(self, form):
		try:
			return super().form_valid(form)
		except ValidationError as exc:
			form.add_error(None, exc)
			return self.form_invalid(form)

	def get_success_url(self):
		return reverse("assessments:assessment-detail", kwargs={"pk": self.object.assessment_id})


def _active_employee(request):
	return get_object_or_404(Employee, user=request.user, is_active=True)


def _assignment_for_employee(request, assignment_pk, *, lock=False):
	queryset = TrainingAssignment.objects.select_related("training_version", "employee")
	if lock:
		queryset = queryset.select_for_update()
	return get_object_or_404(
		queryset,
		pk=assignment_pk,
		employee=_active_employee(request),
		status__in=(TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS),
	)


def _module_lessons_complete(assignment, module):
	required_lessons = Lesson.objects.filter(module=module, is_required=True)
	completed_ids = LessonProgress.objects.filter(
		assignment=assignment,
		lesson__in=required_lessons,
		completed_at__isnull=False,
	).values("lesson_id")
	return not required_lessons.exclude(pk__in=completed_ids).exists()


def _attempt_total(assessment):
	return sum(assessment.questions.values_list("points", flat=True), Decimal("0"))


@transaction.atomic
def _try_complete_assignment(assignment, actor=None):
	from certifications.services import issue_completed_assignment_certificate

	assignment = TrainingAssignment.objects.select_for_update().get(pk=assignment.pk)
	if assignment.status == TrainingAssignment.Status.COMPLETED:
		issue_completed_assignment_certificate(assignment.pk)
		return
	if assignment.status not in (TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS):
		return
	previous_status = assignment.status
	assignment.status = TrainingAssignment.Status.COMPLETED
	assignment.completed_at = timezone.now()
	try:
		assignment.save()
	except ValidationError:
		assignment.refresh_from_db()
	if assignment.status == TrainingAssignment.Status.COMPLETED:
		record_event(
			actor,
			"training.trainingassignment.completed",
			assignment,
			before={"status": previous_status},
			after={"status": assignment.status, "completed_at": assignment.completed_at.isoformat()},
		)
		issue_completed_assignment_certificate(assignment.pk, actor=actor)


@login_required
def start_attempt(request, assignment_pk, assessment_pk):
	if request.method != "POST":
		raise Http404
	try:
		with transaction.atomic():
			assignment = _assignment_for_employee(request, assignment_pk)
			Employee.objects.select_for_update().get(pk=assignment.employee_id)
			TrainingVersion.objects.select_for_update().get(pk=assignment.training_version_id)
			assignment = _assignment_for_employee(request, assignment_pk, lock=True)
			assessment = get_object_or_404(
				Assessment.objects.select_related("training_version", "module"),
				pk=assessment_pk,
				training_version_id=assignment.training_version_id,
				training_version__status__in=(TrainingVersion.Status.PUBLISHED, TrainingVersion.Status.RETIRED),
			)
			if assessment.kind == Assessment.Kind.QUIZ and not _module_lessons_complete(assignment, assessment.module):
				return JsonResponse({"error": "Complete the required module lessons before starting this quiz."}, status=409)
			maximum = _attempt_total(assessment)
			if maximum <= 0:
				return JsonResponse({"error": "This assessment has no scorable questions."}, status=409)
			existing = AssessmentAttempt.objects.filter(
				assignment=assignment, assessment=assessment, status=AssessmentAttempt.Status.IN_PROGRESS,
			).first()
			if existing:
				return redirect("assessments:attempt-detail", pk=existing.pk)
			count = AssessmentAttempt.objects.filter(assignment=assignment, assessment=assessment).count()
			if count >= assessment.max_attempts:
				return JsonResponse({"error": "The attempt limit has been reached."}, status=409)
			started = timezone.now()
			attempt = AssessmentAttempt.objects.create(
				assignment=assignment,
				assessment=assessment,
				attempt_number=count + 1,
				started_at=started,
				deadline_at=started + timedelta(minutes=assessment.time_limit_minutes) if assessment.time_limit_minutes else None,
				maximum_points=maximum,
				pass_percentage_snapshot=assessment.pass_percentage,
			)
			record_event(
				request.user,
				"assessments.attempt.started",
				attempt,
				after={
					"assignment_id": assignment.pk,
					"assessment_id": assessment.pk,
					"attempt_number": attempt.attempt_number,
					"status": attempt.status,
				},
			)
			if assignment.status == TrainingAssignment.Status.ASSIGNED:
				assignment.status = TrainingAssignment.Status.IN_PROGRESS
				assignment.started_at = started
				assignment.save()
		return redirect("assessments:attempt-detail", pk=attempt.pk)
	except (ValidationError, IntegrityError) as exc:
		return JsonResponse({"error": str(exc)}, status=409)


@login_required
def attempt_detail(request, pk):
	attempt = get_object_or_404(
		AssessmentAttempt.objects.select_related("assessment", "assignment__employee"),
		pk=pk,
		assignment__employee__user=request.user,
		assignment__employee__is_active=True,
	)
	if attempt.status == AssessmentAttempt.Status.IN_PROGRESS:
		questions = attempt.assessment.questions.select_related("question_revision").prefetch_related("question_revision__options")
		return render(request, "assessments/attempt.html", {"attempt": attempt, "questions": questions})
	return render(request, "assessments/result.html", {"attempt": attempt})


def _posted_answers(request):
	if request.content_type == "application/json":
		try:
			payload = json.loads(request.body or "{}")
		except (TypeError, ValueError):
			raise ValidationError("Request body must be valid JSON.")
		if not isinstance(payload, dict) or not isinstance(payload.get("answers", {}), dict):
			raise ValidationError("Answers must be an object keyed by assessment question ID.")
		raw = payload.get("answers", {})
		pairs = raw.items()
	else:
		pairs = []
		for key in request.POST:
			if key.startswith("answer_"):
				values = request.POST.getlist(key)
				if len(values) != 1:
					raise ValidationError("Each question may have only one answer.")
				pairs.append((key[7:], values[0]))
	answers = {}
	for question_id, option_id in pairs:
		if isinstance(question_id, bool) or not isinstance(question_id, (str, int)):
			raise ValidationError("Question IDs must be integers.")
		try:
			parsed_question = int(question_id)
		except (TypeError, ValueError):
			raise ValidationError("Question IDs must be integers.")
		if parsed_question <= 0 or parsed_question in answers:
			raise ValidationError("Question IDs must be unique positive integers.")
		if option_id in (None, ""):
			answers[parsed_question] = None
			continue
		if isinstance(option_id, bool) or not isinstance(option_id, (str, int)):
			raise ValidationError("Option IDs must be integers.")
		try:
			parsed_option = int(option_id)
		except (TypeError, ValueError):
			raise ValidationError("Option IDs must be integers.")
		if parsed_option <= 0:
			raise ValidationError("Option IDs must be positive integers.")
		answers[parsed_question] = parsed_option
	return answers


@login_required
def submit_attempt(request, pk):
	if request.method != "POST":
		raise Http404
	try:
		selected = _posted_answers(request)
		with transaction.atomic():
			attempt_ref = get_object_or_404(
				AssessmentAttempt.objects.select_related("assessment", "assignment__employee"),
				pk=pk,
				assignment__employee__user=request.user,
				assignment__employee__is_active=True,
			)
			Employee.objects.select_for_update().get(pk=attempt_ref.assignment.employee_id)
			TrainingVersion.objects.select_for_update().get(pk=attempt_ref.assignment.training_version_id)
			assignment = TrainingAssignment.objects.select_for_update().get(pk=attempt_ref.assignment_id)
			attempt = AssessmentAttempt.objects.select_for_update().select_related(
				"assessment", "assignment__employee",
			).get(pk=attempt_ref.pk)
			if attempt.status != AssessmentAttempt.Status.IN_PROGRESS:
				return JsonResponse({"error": "This attempt is already closed."}, status=409)
			if assignment.status not in (TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS):
				return JsonResponse({"error": "This assignment no longer accepts attempts."}, status=409)
			items = list(attempt.assessment.questions.select_related("question_revision"))
			allowed_ids = {item.pk for item in items}
			if set(selected) - allowed_ids:
				raise ValidationError("An answer references a question outside this assessment.")
			now = timezone.now()
			expired = bool(attempt.deadline_at and now > attempt.deadline_at)
			score = Decimal("0")
			for position, item in enumerate(items, 1):
				option = None
				if not expired and selected.get(item.pk) is not None:
					option = QuestionOption.objects.filter(
						pk=selected[item.pk], question_revision_id=item.question_revision_id,
					).first()
					if option is None:
						raise ValidationError("Selected option does not belong to this question revision.")
				correct = bool(option and option.is_correct)
				awarded = item.points if correct else Decimal("0")
				score += awarded
				AttemptAnswer.objects.create(
					attempt=attempt,
					assessment_question=item,
					selected_option=option,
					presented_position=position,
					answered_at=now if option else None,
					points_possible=item.points,
					points_awarded=awarded,
					is_correct=correct,
				)
			attempt.status = AssessmentAttempt.Status.EXPIRED if expired else AssessmentAttempt.Status.SUBMITTED
			attempt.submitted_at = now
			attempt.score_points = score
			attempt.passed = bool(
				not expired
				and score * 100 >= attempt.maximum_points * attempt.pass_percentage_snapshot
			)
			attempt.save()
			record_event(
				request.user,
				"assessments.attempt.submitted" if attempt.status == AssessmentAttempt.Status.SUBMITTED else "assessments.attempt.expired",
				attempt,
				before={"status": AssessmentAttempt.Status.IN_PROGRESS},
				after={
					"assignment_id": assignment.pk,
					"assessment_id": attempt.assessment_id,
					"attempt_number": attempt.attempt_number,
					"status": attempt.status,
					"score_points": str(attempt.score_points),
					"maximum_points": str(attempt.maximum_points),
					"passed": attempt.passed,
				},
			)
			if attempt.passed:
				_try_complete_assignment(assignment, actor=request.user)
		return redirect("assessments:attempt-detail", pk=attempt.pk)
	except (ValidationError, IntegrityError, InvalidOperation, ValueError) as exc:
		return JsonResponse({"error": str(exc)}, status=400)
