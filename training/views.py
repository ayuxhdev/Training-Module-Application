import json
import mimetypes
import re
from datetime import timedelta
from decimal import Decimal, InvalidOperation, ROUND_DOWN

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.contrib.auth.mixins import LoginRequiredMixin, PermissionRequiredMixin
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import IntegrityError, transaction
from django.db.models import BooleanField, Case, Prefetch, Value, When
from django.http import Http404, HttpResponse, JsonResponse, StreamingHttpResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse, reverse_lazy
from django.utils import timezone
from django.views.decorators.http import require_http_methods
from django.views.generic import CreateView, DetailView, FormView, ListView, UpdateView

from audit.mixins import AuditedFormMixin
from audit.services import audit_snapshot, record_event
from organization.models import Employee
from organization.views import employee_scope

from .forms import (LessonForm, ModuleForm, RoleTrainingAssignmentForm,
					RoleTrainingRequirementCreateForm, RoleTrainingRequirementUpdateForm,
					TrainingAssignmentForm, TrainingForm, TrainingVersionForm)
from .models import (Lesson, LessonProgress, Module, RoleTrainingRequirement, Training, TrainingAssignment,
						 TrainingVersion, VideoWatchSession, VIDEO_HEARTBEAT_TOLERANCE)


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


# Longer gaps cannot establish continuous playback; the next observation only
# resets the position baseline. Clients must report progress at least every 30s.
VIDEO_HEARTBEAT_MAX_GAP = Decimal("30.0")


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


def _bounded_position(position, duration):
	if position < 0 or position > duration:
		raise ValidationError("Position must be within the video duration.")
	return position.quantize(Decimal("0.001"), rounding=ROUND_DOWN)


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


@require_http_methods(["GET", "HEAD"])
@login_required
def video_media(request, assignment_pk, lesson_pk, session_pk):
	return _video_media_operation(request, assignment_pk, lesson_pk, session_pk)


def _video_media_operation(request, assignment_pk, lesson_pk, session_pk):
	assignment, lesson, error = _playback_context(request, assignment_pk, lesson_pk)
	if error:
		return error
	get_object_or_404(
		VideoWatchSession,
		pk=session_pk,
		assignment=assignment,
		lesson=lesson,
		ended_at__isnull=True,
		updated_at__gte=timezone.now() - timedelta(seconds=float(VIDEO_HEARTBEAT_MAX_GAP)),
	)
	if not lesson.video_file:
		raise Http404
	try:
		size = lesson.video_file.size
		media = lesson.video_file.open("rb")
	except (OSError, ValueError):
		raise Http404 from None
	if size <= 0:
		media.close()
		raise Http404

	start, end = 0, size - 1
	range_header = request.headers.get("Range")
	if range_header is not None:
		match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header) if len(range_header) <= 100 else None
		if match and (match.group(1) or match.group(2)):
			try:
				if match.group(1):
					start = int(match.group(1))
					end = min(int(match.group(2)), size - 1) if match.group(2) else size - 1
				else:
					start = max(0, size - int(match.group(2)))
			except ValueError:
				match = None
		if not match or start >= size or end < start:
			media.close()
			response = HttpResponse(status=416)
			response["Content-Range"] = f"bytes */{size}"
			response["Cache-Control"] = "private, no-store"
			return response

	content_type = mimetypes.guess_type(lesson.video_file.name)[0] or "application/octet-stream"
	if not content_type.startswith("video/"):
		content_type = "application/octet-stream"
	if request.method == "HEAD":
		media.close()
		response = HttpResponse(content_type=content_type, status=206 if range_header else 200)
	else:
		def chunks():
			try:
				media.seek(start)
				remaining = end - start + 1
				while remaining:
					chunk = media.read(min(64 * 1024, remaining))
					if not chunk:
						break
					remaining -= len(chunk)
					yield chunk
			finally:
				media.close()

		response = StreamingHttpResponse(chunks(), content_type=content_type, status=206 if range_header else 200)
		response._resource_closers.append(media.close)
	response["Accept-Ranges"] = "bytes"
	response["Content-Length"] = str(end - start + 1)
	response["Cache-Control"] = "private, no-store"
	if range_header:
		response["Content-Range"] = f"bytes {start}-{end}/{size}"
	return response


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
		"resume_position": float(_verified_resume_position(progress)),
		"watched_ranges": progress.watched_ranges,
		"watched_seconds": float(progress.watched_seconds),
		"progress_percent": float(progress.progress_percent),
		"completed": progress.completed_at is not None,
		"completed_at": progress.completed_at.isoformat() if progress.completed_at else None,
		"session_id": session.pk if session else None,
	}


def _verified_resume_position(progress):
	if progress.completed_at:
		return progress.last_position_seconds
	verified_end = Decimal("0")
	for start, end in progress.watched_ranges:
		if Decimal(str(start)) > verified_end:
			break
		verified_end = max(verified_end, Decimal(str(end)))
	return min(progress.last_position_seconds, verified_end)


def _apply_observed_position(progress, session, position, now):
	duration = Decimal(str(progress.lesson.video_duration_seconds))
	position = _bounded_position(position, duration)
	previous_position = Decimal(str(session.ending_position_seconds if session.ending_position_seconds is not None
		else session.starting_position_seconds))
	# updated_at is written after the observed position was captured.
	last_observed_at = min(session.updated_at, progress.last_accessed_at)
	elapsed = max(Decimal("0"), Decimal(str((now - last_observed_at).total_seconds())))
	session_elapsed = max(Decimal("0"), Decimal(str((now - session.started_at).total_seconds())))
	# Accepted movement spends the session's one-time jitter allowance, including replay.
	remaining_budget = max(Decimal("0"), session_elapsed + VIDEO_HEARTBEAT_TOLERANCE - session.active_watch_seconds)
	# Idle time must not replenish jitter credit on later rapid requests.
	session_tolerance = max(Decimal("0"), VIDEO_HEARTBEAT_TOLERANCE - session.active_watch_seconds)
	interval = None
	advance = position - previous_position
	if (elapsed <= VIDEO_HEARTBEAT_MAX_GAP
			and 0 < advance <= elapsed + session_tolerance
			and advance <= remaining_budget):
		candidate = _merge_ranges(progress.watched_ranges, (previous_position, position))
		candidate_seconds = sum((Decimal(str(end)) - Decimal(str(start)) for start, end in candidate), Decimal("0"))
		lesson_elapsed = max(Decimal("0"), Decimal(str((now - progress.started_at).total_seconds())))
		new_unique_seconds = candidate_seconds - progress.watched_seconds
		remaining_unique_budget = max(
			Decimal("0"), lesson_elapsed + VIDEO_HEARTBEAT_TOLERANCE - progress.watched_seconds
		)
		# Share the latest observation budget across sessions, so opening another
		# session cannot spend time or jitter already consumed by this lesson.
		observed_elapsed = max(Decimal("0"), Decimal(str((now - progress.last_accessed_at).total_seconds())))
		remaining_unique_budget = min(
			remaining_unique_budget,
			observed_elapsed + max(Decimal("0"), VIDEO_HEARTBEAT_TOLERANCE - progress.watched_seconds),
		)
		if new_unique_seconds <= remaining_unique_budget:
			interval = (previous_position, position)
			session.active_watch_seconds += min(advance, elapsed).quantize(
				Decimal("0.001"), rounding=ROUND_DOWN,
			)
	progress.watched_ranges = _merge_ranges(progress.watched_ranges, interval)
	progress.last_position_seconds = position
	progress.last_accessed_at = now
	# While open, this is the session's last observed position; on end, it is final.
	session.ending_position_seconds = position
	if progress.completed_at is None and progress.progress_percent >= progress.lesson.minimum_watch_percent:
		progress.completed_at = now


def _video_progress_operation(request, assignment_pk, lesson_pk):
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


@login_required
def video_progress(request, assignment_pk, lesson_pk):
	return _video_progress_operation(request, assignment_pk, lesson_pk)


@require_http_methods(["POST"])
@login_required
def start_video_session(request, assignment_pk, lesson_pk):
	return _start_video_session_operation(request, assignment_pk, lesson_pk)


def _start_video_session_operation(request, assignment_pk, lesson_pk):
	assignment, lesson, error = _playback_context(request, assignment_pk, lesson_pk)
	if error:
		return error
	try:
		body = _json_body(request)
		requested_position = body.get("position")
		session_identifier = body.get("session_identifier", "")
		device_identifier = body.get("device_identifier", "")
		for field_name, value in (
			("session_identifier", session_identifier),
			("device_identifier", device_identifier),
		):
			if not isinstance(value, str) or len(value) > 128:
				raise ValidationError(f"{field_name} must be a string of at most 128 characters.")
		with transaction.atomic():
			assignment = _lock_playback_assignment(assignment)
			if assignment.status not in (TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS):
				return JsonResponse({"error": "This assignment does not accept progress."}, status=409)
			progress = LessonProgress.objects.select_for_update().filter(
				assignment=assignment, lesson=lesson).first()
			if requested_position is None:
				requested_position = _verified_resume_position(progress) if progress else 0
			position = _position(requested_position, "position")
			duration = Decimal(str(lesson.video_duration_seconds))
			position = _bounded_position(position, duration)
			now = timezone.now()
			session = VideoWatchSession(
				assignment=assignment,
				lesson=lesson,
				started_at=now,
				starting_position_seconds=position,
				ending_position_seconds=position,
				session_identifier=session_identifier,
				device_identifier=device_identifier,
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
	return _end_video_session_operation(request, assignment_pk, lesson_pk, session_pk)


def _end_video_session_operation(request, assignment_pk, lesson_pk, session_pk):
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
			session.completed_normally = completed_normally
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


@require_http_methods(["POST"])
@login_required
def complete_text_lesson(request, assignment_pk, lesson_pk):
	try:
		_complete_text_lesson_operation(request, assignment_pk, lesson_pk)
	except AssignmentLearningConflict as exc:
		return HttpResponse(str(exc), status=409)
	except (ValidationError, IntegrityError, ValueError) as exc:
		return HttpResponse(str(exc), status=400)
	return redirect(reverse("training:assignment-detail", kwargs={"pk": assignment_pk}) + f"?lesson={lesson_pk}")


class AssignmentLearningConflict(Exception):
	pass


def _complete_text_lesson_operation(request, assignment_pk, lesson_pk):
	assignment = get_object_or_404(
		TrainingAssignment.objects.select_related("employee", "training_version"),
		pk=assignment_pk,
		employee__user=request.user,
	)
	lesson = get_object_or_404(
		Lesson,
		pk=lesson_pk,
		module__training_version_id=assignment.training_version_id,
		content_type=Lesson.ContentType.TEXT,
	)
	with transaction.atomic():
		assignment = _lock_playback_assignment(assignment)
		progress = LessonProgress.objects.select_for_update().filter(
			assignment=assignment, lesson=lesson,
		).first()
		if assignment.status == TrainingAssignment.Status.COMPLETED and progress and progress.completed_at:
			return progress
		if assignment.status not in (TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS):
			raise AssignmentLearningConflict("This assignment does not accept progress.")
		if not progress or not progress.completed_at:
			now = timezone.now()
			if progress is None:
				progress = LessonProgress(
					assignment=assignment, lesson=lesson,
					started_at=now, last_accessed_at=now, completed_at=now,
				)
			else:
				progress.last_accessed_at = now
				progress.completed_at = now
			progress.save()
			record_event(
				request.user, "training.lessonprogress.completed", progress,
				after={"assignment_id": assignment.pk, "lesson_id": lesson.pk,
					"completed_at": progress.completed_at.isoformat()},
			)
		if assignment.status == TrainingAssignment.Status.ASSIGNED:
			assignment.status = TrainingAssignment.Status.IN_PROGRESS
			assignment.started_at = timezone.now()
			assignment.save()
		from assessments.views import _try_complete_assignment
		_try_complete_assignment(assignment, actor=request.user)
	return progress


def _with_assignment_overdue(queryset):
	from reports.queries import overdue_condition

	return queryset.annotate(is_overdue=Case(
		When(overdue_condition(timezone.now()), then=Value(True)),
		default=Value(False),
		output_field=BooleanField(),
	))


class TrainingAssignmentListView(AssignmentAccessMixin, ListView):
	model = TrainingAssignment
	template_name = "training/assignment_list.html"
	context_object_name = "assignments"

	def get_queryset(self):
		queryset = TrainingAssignment.objects.select_related(
			"employee", "training_version__training", "department_at_assignment", "job_role_at_assignment"
		).filter(employee__in=assignment_scope(self.request.user)).order_by("due_at", "pk")
		return _with_assignment_overdue(queryset)


class TrainingAssignmentDetailView(AssignmentAccessMixin, DetailView):
	model = TrainingAssignment
	template_name = "training/assignment_detail.html"
	context_object_name = "assignment"

	def get_queryset(self):
		queryset = TrainingAssignment.objects.select_related(
			"employee", "training_version__training", "department_at_assignment", "job_role_at_assignment",
			"role_requirement", "assigned_by"
		).filter(employee__in=assignment_scope(self.request.user))
		return _with_assignment_overdue(queryset)

	def get_context_data(self, **kwargs):
		context = super().get_context_data(**kwargs)
		assignment = self.object
		lesson_id = self.request.GET.get("lesson")
		can_learn = (
			assignment.employee.user_id == self.request.user.pk
			and assignment.employee.is_active
			and assignment.training_version.status == TrainingVersion.Status.PUBLISHED
			and assignment.status != TrainingAssignment.Status.CANCELLED
		)
		if not can_learn:
			if lesson_id is not None:
				raise Http404
			return context
		context["can_learn"] = True

		modules = list(Module.objects.filter(training_version=assignment.training_version).prefetch_related("lessons"))
		lessons = [lesson for module in modules for lesson in module.lessons.all()]
		progress_by_lesson = {
			progress.lesson_id: progress
			for progress in LessonProgress.objects.filter(assignment=assignment).select_related("lesson")
		}
		if lesson_id is not None:
			try:
				selected_id = int(lesson_id)
			except (TypeError, ValueError):
				raise Http404 from None
			if not any(lesson.pk == selected_id for lesson in lessons):
				raise Http404
		else:
			selected_id = lessons[0].pk if lessons else None

		module_items = []
		selected_lesson = None
		previous_lesson = None
		next_lesson = None
		for module in modules:
			items = []
			for lesson in module.lessons.all():
				progress = progress_by_lesson.get(lesson.pk)
				items.append({"lesson": lesson, "progress": progress})
				if lesson.pk == selected_id:
					selected_lesson = lesson
					context["selected_progress"] = progress
			module_items.append({"module": module, "lessons": items})
		if selected_lesson:
			index = next(index for index, lesson in enumerate(lessons) if lesson.pk == selected_lesson.pk)
			previous_lesson = lessons[index - 1] if index else None
			next_lesson = lessons[index + 1] if index + 1 < len(lessons) else None
		context.update({
			"module_items": module_items,
			"selected_lesson": selected_lesson,
			"previous_lesson": previous_lesson,
			"next_lesson": next_lesson,
			"can_record_progress": assignment.status in (
				TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS,
			),
		})
		return context


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


class RoleTrainingRequirementListView(ContentPermissionMixin, ListView):
	permission_required = ASSIGNMENT_MANAGE_PERMISSION
	model = RoleTrainingRequirement
	template_name = "training/role_requirement_list.html"
	context_object_name = "requirements"

	def get_queryset(self):
		return RoleTrainingRequirement.objects.select_related(
			"job_role", "training_version__training",
		).order_by("job_role__name", "training_version__training__catalog_title", "training_version__version_number")


class RoleTrainingRequirementCreateView(ContentPermissionMixin, CreateView):
	permission_required = ASSIGNMENT_MANAGE_PERMISSION
	model = RoleTrainingRequirement
	form_class = RoleTrainingRequirementCreateForm
	template_name = "training/role_requirement_form.html"

	def get_initial(self):
		return {"is_active": True}

	def get_context_data(self, **kwargs):
		context = super().get_context_data(**kwargs)
		form = context["form"]
		context["can_create_requirement"] = (
			form.fields["job_role"].queryset.exists()
			and form.fields["training_version"].queryset.exists()
		)
		return context

	def form_valid(self, form):
		form.instance.created_by = self.request.user
		return super().form_valid(form)

	def get_success_url(self):
		return reverse("training:role-requirement-list")


class RoleTrainingRequirementUpdateView(ContentPermissionMixin, UpdateView):
	permission_required = ASSIGNMENT_MANAGE_PERMISSION
	model = RoleTrainingRequirement
	form_class = RoleTrainingRequirementUpdateForm
	template_name = "training/role_requirement_form.html"

	def get_success_url(self):
		return reverse("training:role-requirement-list")


class RoleTrainingAssignmentCreateView(LoginRequiredMixin, PermissionRequiredMixin, FormView):
	permission_required = ASSIGNMENT_MANAGE_PERMISSION
	raise_exception = True
	form_class = RoleTrainingAssignmentForm
	template_name = "training/role_assignment_form.html"

	def get_context_data(self, **kwargs):
		context = super().get_context_data(**kwargs)
		context["has_role_requirements"] = context["form"].fields["role_requirement"].queryset.exists()
		return context

	def form_valid(self, form):
		requirement = form.cleaned_data["role_requirement"]
		try:
			assigned_at = timezone.now()
			due_at = assigned_at + timedelta(days=requirement.due_in_days)
		except OverflowError:
			form.add_error("role_requirement", "The due period is outside the supported date range.")
			return self.form_invalid(form)
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
						assigned_at=assigned_at,
						due_at=due_at,
					)
					created += 1
				except (IntegrityError, ValidationError):
					if TrainingAssignment.objects.filter(
						employee=employee, training_version=requirement.training_version,
					).exists():
						existing_ids.add(employee.pk)
					else:
						raise
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

	def get_queryset(self):
		return Training.objects.order_by("catalog_title", "code", "pk")


class TrainingDetailView(ContentPermissionMixin, DetailView):
	permission_required = "training.view_training"
	model = Training
	template_name = "training/training_detail.html"
	context_object_name = "training"

	def get_queryset(self):
		versions = TrainingVersion.objects.order_by("-version_number", "pk")
		return Training.objects.prefetch_related(Prefetch("versions", queryset=versions))


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
		return TrainingVersion.objects.filter(
			training_id=self.kwargs["training_pk"],
		).order_by("-version_number", "pk")

	def get_context_data(self, **kwargs):
		context = super().get_context_data(**kwargs)
		context["training"] = get_object_or_404(Training, pk=self.kwargs["training_pk"])
		return context


class TrainingVersionDetailView(ContentPermissionMixin, DetailView):
	permission_required = "training.view_trainingversion"
	model = TrainingVersion
	template_name = "training/version_detail.html"
	context_object_name = "version"

	def get_queryset(self):
		return TrainingVersion.objects.select_related("training").prefetch_related(
			"modules__lessons",
		)


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
