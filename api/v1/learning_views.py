import json

from django.core.exceptions import ValidationError
from django.db import IntegrityError
from django.db.models import BooleanField, Case, Count, Q, Value, When
from django.http import JsonResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import generics, serializers
from rest_framework.exceptions import APIException
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework_simplejwt.authentication import JWTAuthentication
from rest_framework.views import APIView

from api.permissions import IsActiveEmployee
from reports.queries import overdue_condition
from training.models import Lesson, LessonProgress, Module, TrainingAssignment, TrainingVersion
from training.views import (
	AssignmentLearningConflict,
	_complete_text_lesson_operation,
	_end_video_session_operation,
	_progress_response,
	_start_video_session_operation,
	_video_media_operation,
	_video_progress_operation,
)

from .learning_serializers import AssignmentDetailSerializer, AssignmentListSerializer


class LearningConflict(APIException):
	status_code = 409
	default_detail = "This learning operation conflicts with the current assignment state."
	default_code = "conflict"


class JWTActiveEmployeeAPIView(APIView):
	authentication_classes = [JWTAuthentication]
	permission_classes = [IsAuthenticated, IsActiveEmployee]


class AssignmentListView(generics.ListAPIView):
	authentication_classes = [JWTAuthentication]
	permission_classes = [IsAuthenticated, IsActiveEmployee]
	serializer_class = AssignmentListSerializer

	def get_queryset(self):
		now = timezone.now()
		return TrainingAssignment.objects.filter(employee=self.request.user.employee).select_related(
			"training_version",
		).annotate(
			is_overdue=Case(
				When(overdue_condition(now), then=Value(True)),
				default=Value(False),
				output_field=BooleanField(),
			),
			required_lessons_total=Count(
				"training_version__modules__lessons",
				filter=Q(training_version__modules__lessons__is_required=True),
				distinct=True,
			),
			required_lessons_completed=Count(
				"lesson_progress__lesson_id",
				filter=Q(
					lesson_progress__completed_at__isnull=False,
					lesson_progress__lesson__is_required=True,
				),
				distinct=True,
			),
		).order_by("due_at", "pk")


class AssignmentDetailView(JWTActiveEmployeeAPIView):
	def get(self, request, assignment_id):
		now = timezone.now()
		assignment = get_object_or_404(
			TrainingAssignment.objects.filter(employee=request.user.employee).select_related(
				"training_version__training",
			).annotate(
				is_overdue=Case(
					When(overdue_condition(now), then=Value(True)),
					default=Value(False),
					output_field=BooleanField(),
				),
			),
			pk=assignment_id,
		)
		learning_available = (
			assignment.status != TrainingAssignment.Status.CANCELLED
			and assignment.training_version.status in (
				TrainingVersion.Status.PUBLISHED, TrainingVersion.Status.RETIRED,
			)
		)
		modules = list(
			Module.objects.filter(training_version=assignment.training_version).prefetch_related("lessons")
		) if learning_available else []
		lesson_ids = [lesson.pk for module in modules for lesson in module.lessons.all()]
		progress_by_lesson = {
			progress.lesson_id: progress
			for progress in LessonProgress.objects.filter(
				assignment=assignment,
				lesson_id__in=lesson_ids,
			).select_related("lesson")
		}
		serializer = AssignmentDetailSerializer(
			assignment,
			context={"modules": modules, "progress_by_lesson": progress_by_lesson},
		)
		return Response(serializer.data)


def _adapt_learning_response(response):
	if not isinstance(response, JsonResponse):
		return response
	data = json.loads(response.content.decode("utf-8"))
	if response.status_code == 409:
		raise LearningConflict(data.get("error", LearningConflict.default_detail))
	if response.status_code >= 400:
		raise serializers.ValidationError(data.get("error", "Invalid learning request."))
	return Response(data, status=response.status_code)


def _adapt_media_response(response):
	if isinstance(response, JsonResponse):
		return _adapt_learning_response(response)
	if response.status_code == 416:
		adapted = Response({
			"error": {
				"code": "range_not_satisfiable",
				"message": "The requested byte range is not satisfiable.",
				"fields": {},
			}
		}, status=416)
		for header in ("Content-Range", "Cache-Control"):
			if header in response:
				adapted[header] = response[header]
		return adapted
	return response


class LessonProgressView(JWTActiveEmployeeAPIView):
	def get(self, request, assignment_id, lesson_id):
		return _adapt_learning_response(
			_video_progress_operation(request, assignment_id, lesson_id),
		)

	def post(self, request, assignment_id, lesson_id):
		return _adapt_learning_response(
			_video_progress_operation(request, assignment_id, lesson_id),
		)


class TextLessonCompletionView(JWTActiveEmployeeAPIView):
	def post(self, request, assignment_id, lesson_id):
		try:
			progress = _complete_text_lesson_operation(request, assignment_id, lesson_id)
		except AssignmentLearningConflict as exc:
			raise LearningConflict(str(exc)) from exc
		except (ValidationError, IntegrityError, ValueError) as exc:
			raise serializers.ValidationError(str(exc)) from exc
		return Response(_progress_response(progress))


class VideoSessionStartView(JWTActiveEmployeeAPIView):
	def post(self, request, assignment_id, lesson_id):
		return _adapt_learning_response(
			_start_video_session_operation(request, assignment_id, lesson_id),
		)


class VideoSessionMediaView(JWTActiveEmployeeAPIView):
	def get(self, request, assignment_id, lesson_id, session_id):
		return _adapt_media_response(
			_video_media_operation(request, assignment_id, lesson_id, session_id),
		)

	def head(self, request, assignment_id, lesson_id, session_id):
		return _adapt_media_response(
			_video_media_operation(request, assignment_id, lesson_id, session_id),
		)


class VideoSessionEndView(JWTActiveEmployeeAPIView):
	def post(self, request, assignment_id, lesson_id, session_id):
		return _adapt_learning_response(
			_end_video_session_operation(request, assignment_id, lesson_id, session_id),
		)
