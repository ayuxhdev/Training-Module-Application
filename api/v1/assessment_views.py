from decimal import InvalidOperation

from django.core.exceptions import ValidationError
from django.db import IntegrityError
from django.shortcuts import get_object_or_404
from rest_framework import serializers
from rest_framework.response import Response

from assessments.models import Assessment, AssessmentAttempt
from assessments.views import (
	AssessmentConflict,
	_assessment_state,
	_start_attempt_operation,
	_submit_attempt_operation,
)
from training.models import TrainingAssignment, TrainingVersion

from .assessment_serializers import (
	AssessmentOverviewSerializer,
	AssessmentSubmissionSerializer,
	AttemptDetailSerializer,
)
from .learning_views import JWTActiveEmployeeAPIView, LearningConflict


def _employee_attempt(request, attempt_id):
	return get_object_or_404(
		AssessmentAttempt.objects.select_related("assessment", "assignment__certificate"),
		pk=attempt_id, assignment__employee=request.user.employee,
	)


class AssessmentListView(JWTActiveEmployeeAPIView):
	def get(self, request, assignment_id):
		assignment = get_object_or_404(
			TrainingAssignment.objects.select_related("training_version"),
			pk=assignment_id, employee=request.user.employee,
			training_version__status__in=(TrainingVersion.Status.PUBLISHED, TrainingVersion.Status.RETIRED),
		)
		assessments = (
			Assessment.objects.filter(training_version_id=assignment.training_version_id)
			.select_related("module").order_by("-kind", "module__position", "sequence", "pk")
		)
		states = [_assessment_state(assignment, assessment) for assessment in assessments]
		return Response({
			"assignment_id": assignment.pk,
			"training_version_id": assignment.training_version_id,
			"assessments": AssessmentOverviewSerializer(states, many=True).data,
		})


class AssessmentStartView(JWTActiveEmployeeAPIView):
	def post(self, request, assignment_id, assessment_id):
		try:
			attempt, created = _start_attempt_operation(request, assignment_id, assessment_id)
		except AssessmentConflict as exc:
			raise LearningConflict(str(exc)) from exc
		except ValidationError as exc:
			raise LearningConflict(" ".join(exc.messages)) from exc
		except IntegrityError as exc:
			raise LearningConflict("The attempt could not be started. Reload the assessment before retrying.") from exc
		return Response(
			AttemptDetailSerializer(_employee_attempt(request, attempt.pk)).data,
			status=201 if created else 200,
		)


class AssessmentAttemptDetailView(JWTActiveEmployeeAPIView):
	def get(self, request, attempt_id):
		return Response(AttemptDetailSerializer(_employee_attempt(request, attempt_id)).data)


class AssessmentSubmitView(JWTActiveEmployeeAPIView):
	def post(self, request, attempt_id):
		# Resolve ownership even when the payload is malformed.
		_employee_attempt(request, attempt_id)
		serializer = AssessmentSubmissionSerializer(data=request.data)
		serializer.is_valid(raise_exception=True)
		try:
			attempt = _submit_attempt_operation(request, attempt_id, serializer.validated_data["answers"])
		except AssessmentConflict as exc:
			raise LearningConflict(str(exc)) from exc
		except ValidationError as exc:
			raise serializers.ValidationError({"answers": exc.messages}) from exc
		except IntegrityError as exc:
			raise LearningConflict("The attempt could not be submitted. Reload its result before retrying.") from exc
		except (InvalidOperation, ValueError) as exc:
			raise serializers.ValidationError("Invalid assessment answers.") from exc
		return Response(AttemptDetailSerializer(_employee_attempt(request, attempt.pk)).data)
