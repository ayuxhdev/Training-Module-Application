import json
from datetime import timedelta
from decimal import Decimal, InvalidOperation

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.contrib.auth.mixins import LoginRequiredMixin, PermissionRequiredMixin
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import IntegrityError, transaction
from django.http import Http404, JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse, reverse_lazy
from django.utils import timezone
from django.views.decorators.http import require_http_methods
from django.views.generic import CreateView, DetailView, FormView, ListView, UpdateView

from audit.mixins import AuditedFormMixin
from audit.services import audit_snapshot, record_event
from organization.models import Employee
from organization.views import employee_scope

from .forms import (LessonForm, ModuleForm, RoleTrainingAssignmentForm, TrainingAssignmentForm,
					TrainingForm, TrainingVersionForm)
from .models import (Lesson, LessonProgress, Module, RoleTrainingRequirement, Training, TrainingAssignment,
					 TrainingVersion, VideoWatchSession)


class ContentPermissionMixin(AuditedFormMixin, LoginRequiredMixin, PermissionRequiredMixin):
	raise_exception = True


ASSIGNMENT_MANAGE_PERMISSION = "training.add_trainingassignment"


def can_manage_assignments(user):
	return user.is_superuser or user.has_perm(ASSIGNMENT_MANAGE_PERMISSION)


class AssignmentAccessMixin(LoginRequiredMixin):
	raise_exception = True

	def dispatch(self, request, *args, **kwargs):
		if not (can_manage_assignments(request.user) or request.user.groups.filter(name__in=["Manager", "Employee"]).exists()):
			raise PermissionDenied
		return super().dispatch(request, *args, **kwargs)


def assignment_scope(user):
	if can_manage_assignments(user):
		return Employee.objects.all()
	return employee_scope(user)


VIDEO_HEARTBEAT_TOLERANCE = Decimal("2.0")


def _json_body(request):
	try:
		body = json.loads(request.body or "{}")
	except (TypeError, ValueError):
		raise ValidationError("Request body must be valid JSON.")
	if not isinstance(body, dict):
		raise ValidationError("Request body must be a JSON object.")
	return body


def _position(value, field_name="position"):
	if isinstance(value, bool) or value is None:
		raise ValidationError(f"{field_name} must be a number.")
	try:
		position = Decimal(str(value))
	except (InvalidOperation, ValueError):
		raise ValidationError(f"{field_name} must be a number.")
	if not position.is_finite():
		raise ValidationError(f"{field_name} must be finite.")
	return position


def _merge_ranges(ranges, new_interval=None):
	intervals = [(Decimal(str(start)), Decimal(str(end))) for start, end in ranges]
	if new_interval:
		intervals.append(tuple(Decimal(str(value)) for value in new_interval))
	intervals.sort(key=lambda interval: interval[0])
	merged = []
	for start, end in intervals:
		if not merged or start > merged[-1][1]:
			merged.append([start, end])
		else:
			merged[-1][1] = max(merged[-1][1], end)
	return [[float(start), float(end)] for start, end in merged]


def _playback_context(request, assignment_pk, lesson_pk):
	assignment = get_object_or_404(
		TrainingAssignment.objects.select_related("employee", "training_version"),
		pk=assignment_pk,
		employee__user=request.user,
	)
	if not assignment.employee.is_active:
		raise PermissionDenied("Inactive employees cannot access video progress.")
	if assignment.status not in (TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS):
		return None, None, JsonResponse({"error": "This assignment does not accept progress."}, status=409)
	lesson = get_object_or_404(
		Lesson.objects.select_related("module"),
		pk=lesson_pk,
		module__training_version_id=assignment.training_version_id,
	)
	if lesson.content_type != Lesson.ContentType.VIDEO:
		return None, None, JsonResponse({"error": "Video progress requires a video lesson."}, status=400)
	return assignment, lesson, None


def _lock_playback_assignment(assignment):
	# Match TrainingAssignment.save() lock order before serializing progress writes.
	employee = Employee.objects.select_for_update().get(pk=assignment.employee_id)
	TrainingVersion.objects.select_for_update().get(pk=assignment.training_version_id)
	assignment = TrainingAssignment.objects.select_for_update().get(pk=assignment.pk)
	if not employee.is_active:
		raise PermissionDenied("Inactive employees cannot access video progress.")
	return assignment


def _progress_response(progress, session=None):
	return {
		"progress_id": progress.pk,
		"resume_position": float(progress.last_position_seconds),
		"watched_ranges": progress.watched_ranges,
		"watched_seconds": float(progress.watched_seconds),
		"progress_percent": float(progress.progress_percent),
		"completed": progress.completed_at is not None,
		"completed_at": progress.completed_at.isoformat() if progress.completed_at else None,
		"session_id": session.pk if session else None,
	}


def _apply_observed_position(progress, session, position, now):
	duration = Decimal(str(progress.lesson.video_duration_seconds))
	if position < 0 or position > duration:
		raise ValidationError("Position must be within the video duration.")
	previous_position = Decimal(str(session.ending_position_seconds if session.ending_position_seconds is not None
		else session.starting_position_seconds))
	elapsed = max(Decimal("0"), Decimal(str((now - session.updated_at).total_seconds())))
	session_elapsed = max(Decimal("0"), Decimal(str((now - session.started_at).total_seconds())))
	# Accepted movement spends the session's one-time jitter allowance, including replay.
	remaining_budget = max(Decimal("0"), session_elapsed + VIDEO_HEARTBEAT_TOLERANCE - session.active_watch_seconds)
	interval = None
	advance = position - previous_position
	if 0 < advance <= elapsed + VIDEO_HEARTBEAT_TOLERANCE and advance <= remaining_budget:
		candidate = _merge_ranges(progress.watched_ranges, (previous_position, position))
		candidate_seconds = sum((Decimal(str(end)) - Decimal(str(start)) for start, end in candidate), Decimal("0"))
		lesson_elapsed = max(Decimal("0"), Decimal(str((now - progress.started_at).total_seconds())))
		new_unique_seconds = candidate_seconds - progress.watched_seconds
		remaining_unique_budget = max(
			Decimal("0"), lesson_elapsed + VIDEO_HEARTBEAT_TOLERANCE - progress.watched_seconds
		)
		if new_unique_seconds <= remaining_unique_budget:
			interval = (previous_position, position)
			session.active_watch_seconds += advance
	progress.watched_ranges = _merge_ranges(progress.watched_ranges, interval)
	progress.last_position_seconds = position
	progress.last_accessed_at = now
	# While open, this is the session's last observed position; on end, it is final.
	session.ending_position_seconds = position
	if progress.completed_at is None and progress.progress_percent >= progress.lesson.minimum_watch_percent:
		progress.completed_at = now


@login_required
def video_progress(request, assignment_pk, lesson_pk):
	assignment, lesson, error = _playback_context(request, assignment_pk, lesson_pk)
	if error:
		return error
	if request.method == "GET":
		progress = LessonProgress.objects.filter(assignment=assignment, lesson=lesson).first()
		if progress is None:
			return JsonResponse({
				"resume_position": 0.0,
				"watched_ranges": [],
				"watched_seconds": 0.0,
				"progress_percent": 0.0,
				"completed": False,
				"completed_at": None,
				"session_id": None,
			})
		return JsonResponse(_progress_response(progress))
	if request.method != "POST":
		return JsonResponse({"error": "Only GET and POST are supported."}, status=405)
	try:
		body = _json_body(request)
		session_id = body.get("session_id")
		if type(session_id) is not int or session_id <= 0:
			raise ValidationError("session_id must be a positive integer.")
		position = _position(body.get("position"))
		with transaction.atomic():
			assignment = _lock_playback_assignment(assignment)
			if assignment.status not in (TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS):
				return JsonResponse({"error": "This assignment does not accept progress."}, status=409)
			progress = LessonProgress.objects.select_for_update().filter(
				assignment=assignment, lesson=lesson).first()
			was_completed = bool(progress and progress.completed_at)
			session = get_object_or_404(
				VideoWatchSession.objects.select_for_update(),
				pk=session_id,
				assignment=assignment,
				lesson=lesson,
				ended_at__isnull=True,
			)
			if progress is None:
				now = timezone.now()
				progress = LessonProgress(
					assignment=assignment,
					lesson=lesson,
					started_at=now,
					last_accessed_at=now,
					last_position_seconds=session.starting_position_seconds,
				)
			else:
				now = timezone.now()
			_apply_observed_position(progress, session, position, now)
			progress.save()
			session.save()
			if not was_completed and progress.completed_at:
				record_event(
					request.user,
					"training.lessonprogress.completed",
					progress,
					after={
						"assignment_id": assignment.pk,
						"lesson_id": lesson.pk,
						"completed_at": progress.completed_at.isoformat(),
					},
				)
			if assignment.status == TrainingAssignment.Status.ASSIGNED:
				assignment.status = TrainingAssignment.Status.IN_PROGRESS
				assignment.started_at = now
				assignment.save()
		return JsonResponse(_progress_response(progress, session))
	except (ValidationError, IntegrityError, ValueError) as exc:
		return JsonResponse({"error": str(exc)}, status=400)


@require_http_methods(["POST"])
@login_required
def start_video_session(request, assignment_pk, lesson_pk):
	assignment, lesson, error = _playback_context(request, assignment_pk, lesson_pk)
	if error:
		return error
	try:
		body = _json_body(request)
		requested_position = body.get("position")
		with transaction.atomic():
			assignment = _lock_playback_assignment(assignment)
			if assignment.status not in (TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS):
				return JsonResponse({"error": "This assignment does not accept progress."}, status=409)
			progress = LessonProgress.objects.select_for_update().filter(
				assignment=assignment, lesson=lesson).first()
			if requested_position is None:
				requested_position = progress.last_position_seconds if progress else 0
			position = _position(requested_position, "position")
			duration = Decimal(str(lesson.video_duration_seconds))
			if position < 0 or position > duration:
				raise ValidationError("Position must be within the video duration.")
			now = timezone.now()
			session = VideoWatchSession(
				assignment=assignment,
				lesson=lesson,
				started_at=now,
				starting_position_seconds=position,
				ending_position_seconds=position,
				session_identifier=str(body.get("session_identifier", "")),
				device_identifier=str(body.get("device_identifier", "")),
			)
			session.save()
			if progress is None:
				progress = LessonProgress(
					assignment=assignment,
					lesson=lesson,
					started_at=now,
					last_accessed_at=now,
					last_position_seconds=position,
				)
			else:
				progress.last_position_seconds = position
				progress.last_accessed_at = now
			progress.save()
			if assignment.status == TrainingAssignment.Status.ASSIGNED:
				assignment.status = TrainingAssignment.Status.IN_PROGRESS
				assignment.started_at = now
				assignment.save()
		return JsonResponse(_progress_response(progress, session), status=201)
	except (ValidationError, IntegrityError, ValueError) as exc:
		return JsonResponse({"error": str(exc)}, status=400)


@require_http_methods(["POST"])
@login_required
def end_video_session(request, assignment_pk, lesson_pk, session_pk):
	assignment, lesson, error = _playback_context(request, assignment_pk, lesson_pk)
	if error:
		return error
	try:
		body = _json_body(request)
		position = _position(body.get("position"))
		completed_normally = body.get("completed_normally", False)
		if not isinstance(completed_normally, bool):
			raise ValidationError("completed_normally must be a boolean.")
		with transaction.atomic():
			assignment = _lock_playback_assignment(assignment)
			if assignment.status not in (TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS):
				return JsonResponse({"error": "This assignment does not accept progress."}, status=409)
			progress = LessonProgress.objects.select_for_update().filter(
				assignment=assignment, lesson=lesson).first()
			was_completed = bool(progress and progress.completed_at)
			session = get_object_or_404(
				VideoWatchSession.objects.select_for_update(),
				pk=session_pk,
				assignment=assignment,
				lesson=lesson,
				ended_at__isnull=True,
			)
			if progress is None:
				now = timezone.now()
				progress = LessonProgress(
					assignment=assignment,
					lesson=lesson,
					started_at=now,
					last_accessed_at=now,
					last_position_seconds=session.starting_position_seconds,
				)
			else:
				now = timezone.now()
			_apply_observed_position(progress, session, position, now)
			progress.save()
			session.ended_at = now
			session.ending_position_seconds = position
			session.completed_normally = completed_normally
			session.active_watch_seconds = min(
				session.active_watch_seconds, Decimal(str((now - session.started_at).total_seconds()))
			)
			session.save()
			if not was_completed and progress.completed_at:
				record_event(
					request.user,
					"training.lessonprogress.completed",
					progress,
					after={
						"assignment_id": assignment.pk,
						"lesson_id": lesson.pk,
						"completed_at": progress.completed_at.isoformat(),
					},
				)
		return JsonResponse(_progress_response(progress, session))
	except (ValidationError, IntegrityError, ValueError) as exc:
		return JsonResponse({"error": str(exc)}, status=400)


class TrainingAssignmentListView(AssignmentAccessMixin, ListView):
	model = TrainingAssignment
	template_name = "training/assignment_list.html"
	context_object_name = "assignments"

	def get_queryset(self):
		return TrainingAssignment.objects.select_related(
			"employee", "training_version__training", "department_at_assignment", "job_role_at_assignment"
		).filter(employee__in=assignment_scope(self.request.user)).order_by("due_at", "pk")


class TrainingAssignmentDetailView(AssignmentAccessMixin, DetailView):
	model = TrainingAssignment
	template_name = "training/assignment_detail.html"
	context_object_name = "assignment"

	def get_queryset(self):
		return TrainingAssignment.objects.select_related(
			"employee", "training_version__training", "department_at_assignment", "job_role_at_assignment",
			"role_requirement", "assigned_by"
		).filter(employee__in=assignment_scope(self.request.user))


class TrainingAssignmentCreateView(AuditedFormMixin, LoginRequiredMixin, PermissionRequiredMixin, CreateView):
	permission_required = ASSIGNMENT_MANAGE_PERMISSION
	raise_exception = True
	form_class = TrainingAssignmentForm
	template_name = "training/assignment_form.html"

	def form_valid(self, form):
		try:
			self.object = form.save(assigned_by=self.request.user)
		except (ValidationError, IntegrityError) as exc:
			form.add_error(None, "This assignment could not be created: " + str(exc))
			return self.form_invalid(form)
		record_event(
			self.request.user,
			"training.trainingassignment.created",
			self.object,
			after=audit_snapshot(self.object),
		)
		return redirect("training:assignment-detail", pk=self.object.pk)


class RoleTrainingAssignmentCreateView(LoginRequiredMixin, PermissionRequiredMixin, FormView):
	permission_required = ASSIGNMENT_MANAGE_PERMISSION
	raise_exception = True
	form_class = RoleTrainingAssignmentForm
	template_name = "training/role_assignment_form.html"

	def form_valid(self, form):
		requirement = form.cleaned_data["role_requirement"]
		matching_employees = Employee.objects.filter(job_role=requirement.job_role)
		employees = matching_employees.filter(is_active=True).select_related("department", "job_role")
		existing_ids = set(TrainingAssignment.objects.filter(
			employee__in=matching_employees, training_version=requirement.training_version
		).values_list("employee_id", flat=True))
		created = 0
		with transaction.atomic():
			for employee in employees:
				if employee.pk in existing_ids:
					continue
				try:
					TrainingAssignment.objects.create(
						employee=employee,
						training_version=requirement.training_version,
						source=TrainingAssignment.Source.ROLE,
						role_requirement=requirement,
						department_at_assignment=employee.department,
						job_role_at_assignment=employee.job_role,
						assigned_by=self.request.user,
						due_at=timezone.now() + timedelta(days=requirement.due_in_days),
					)
					created += 1
				except IntegrityError:
					existing_ids.add(employee.pk)
			skipped = matching_employees.count() - created
			if created:
				record_event(
					self.request.user,
					"training.role_assignment.batch_created",
					requirement,
					after={
						"job_role_id": requirement.job_role_id,
						"training_version_id": requirement.training_version_id,
						"created_count": created,
						"skipped_count": skipped,
					},
				)
		messages.success(self.request, f"Created {created} assignment(s); skipped {skipped} existing or inactive employee(s).")
		return redirect("training:assignment-list")


class TrainingListView(ContentPermissionMixin, ListView):
	permission_required = "training.view_training"
	model = Training
	template_name = "training/training_list.html"
	context_object_name = "trainings"


class TrainingDetailView(ContentPermissionMixin, DetailView):
	permission_required = "training.view_training"
	model = Training
	template_name = "training/training_detail.html"
	context_object_name = "training"


class TrainingCreateView(ContentPermissionMixin, CreateView):
	permission_required = "training.add_training"
	model = Training
	form_class = TrainingForm
	template_name = "training/training_form.html"
	success_url = reverse_lazy("training:training-list")

	def form_valid(self, form):
		form.instance.created_by = self.request.user
		return super().form_valid(form)


class TrainingUpdateView(ContentPermissionMixin, UpdateView):
	permission_required = "training.change_training"
	model = Training
	form_class = TrainingForm
	template_name = "training/training_form.html"
	success_url = reverse_lazy("training:training-list")


class TrainingVersionListView(ContentPermissionMixin, ListView):
	permission_required = "training.view_trainingversion"
	model = TrainingVersion
	template_name = "training/version_list.html"
	context_object_name = "versions"

	def get_queryset(self):
		return TrainingVersion.objects.filter(training_id=self.kwargs["training_pk"]).order_by("-version_number")

	def get_context_data(self, **kwargs):
		context = super().get_context_data(**kwargs)
		context["training"] = get_object_or_404(Training, pk=self.kwargs["training_pk"])
		return context


class TrainingVersionDetailView(ContentPermissionMixin, DetailView):
	permission_required = "training.view_trainingversion"
	model = TrainingVersion
	template_name = "training/version_detail.html"
	context_object_name = "version"


class TrainingVersionCreateView(ContentPermissionMixin, CreateView):
	permission_required = "training.add_trainingversion"
	model = TrainingVersion
	form_class = TrainingVersionForm
	template_name = "training/version_form.html"

	def dispatch(self, request, *args, **kwargs):
		self.training = get_object_or_404(Training, pk=kwargs["training_pk"])
		return super().dispatch(request, *args, **kwargs)

	def get_form_kwargs(self):
		kwargs = super().get_form_kwargs()
		kwargs["instance"] = TrainingVersion(training=self.training)
		return kwargs

	def form_valid(self, form):
		form.instance.created_by = self.request.user
		return super().form_valid(form)

	def get_success_url(self):
		return reverse("training:version-detail", kwargs={"pk": self.object.pk})


class DraftVersionMixin(ContentPermissionMixin):
	def get_queryset(self):
		return super().get_queryset().filter(status=TrainingVersion.Status.DRAFT)


class TrainingVersionUpdateView(DraftVersionMixin, UpdateView):
	permission_required = "training.change_trainingversion"
	model = TrainingVersion
	form_class = TrainingVersionForm
	template_name = "training/version_form.html"

	def get_success_url(self):
		return reverse("training:version-detail", kwargs={"pk": self.object.pk})


class DraftModuleMixin(DraftVersionMixin):
	def get_version(self):
		return get_object_or_404(TrainingVersion, pk=self.kwargs["version_pk"], status=TrainingVersion.Status.DRAFT)

	def get_queryset(self):
		return Module.objects.filter(training_version=self.get_version())


class ModuleCreateView(DraftModuleMixin, CreateView):
	permission_required = "training.add_module"
	model = Module
	form_class = ModuleForm
	template_name = "training/module_form.html"

	def get_form_kwargs(self):
		kwargs = super().get_form_kwargs()
		kwargs["instance"] = Module(training_version=self.get_version())
		return kwargs

	def get_success_url(self):
		return reverse("training:version-detail", kwargs={"pk": self.object.training_version_id})


class ModuleUpdateView(DraftModuleMixin, UpdateView):
	permission_required = "training.change_module"
	model = Module
	form_class = ModuleForm
	template_name = "training/module_form.html"

	def get_queryset(self):
		return Module.objects.filter(training_version__status=TrainingVersion.Status.DRAFT)

	def get_success_url(self):
		return reverse("training:version-detail", kwargs={"pk": self.object.training_version_id})


class DraftLessonMixin(DraftVersionMixin):
	def get_module(self):
		return get_object_or_404(Module, pk=self.kwargs["module_pk"], training_version__status=TrainingVersion.Status.DRAFT)

	def get_queryset(self):
		return Lesson.objects.filter(module=self.get_module())


class LessonCreateView(DraftLessonMixin, CreateView):
	permission_required = "training.add_lesson"
	model = Lesson
	form_class = LessonForm
	template_name = "training/lesson_form.html"

	def get_form_kwargs(self):
		kwargs = super().get_form_kwargs()
		kwargs["instance"] = Lesson(module=self.get_module())
		return kwargs

	def get_success_url(self):
		return reverse("training:version-detail", kwargs={"pk": self.object.module.training_version_id})


class LessonUpdateView(DraftLessonMixin, UpdateView):
	permission_required = "training.change_lesson"
	model = Lesson
	form_class = LessonForm
	template_name = "training/lesson_form.html"

	def get_queryset(self):
		return Lesson.objects.filter(module__training_version__status=TrainingVersion.Status.DRAFT)

	def get_success_url(self):
		return reverse("training:version-detail", kwargs={"pk": self.object.module.training_version_id})


def publish_version(request, pk):
	if not request.user.is_authenticated or not request.user.has_perm("training.change_trainingversion"):
		raise PermissionDenied
	if request.method != "POST":
		raise Http404
	version = get_object_or_404(TrainingVersion, pk=pk, status=TrainingVersion.Status.DRAFT)
	before = audit_snapshot(version)
	version.status = TrainingVersion.Status.PUBLISHED
	version.published_at = timezone.now()
	version.published_by = request.user
	try:
		version.save()
	except ValidationError as exc:
		version.refresh_from_db()
		return render(request, "training/version_detail.html", {"version": version, "errors": exc}, status=400)
	record_event(
		request.user,
		"training.trainingversion.published",
		version,
		before=before,
		after=audit_snapshot(version),
	)
	return redirect("training:version-detail", pk=version.pk)


def retire_version(request, pk):
	if not request.user.is_authenticated or not request.user.has_perm("training.change_trainingversion"):
		raise PermissionDenied
	if request.method != "POST":
		raise Http404
	version = get_object_or_404(TrainingVersion, pk=pk, status=TrainingVersion.Status.PUBLISHED)
	before = audit_snapshot(version)
	version.status = TrainingVersion.Status.RETIRED
	version.save()
	record_event(
		request.user,
		"training.trainingversion.retired",
		version,
		before=before,
		after=audit_snapshot(version),
	)
	return redirect("training:version-detail", pk=version.pk)
