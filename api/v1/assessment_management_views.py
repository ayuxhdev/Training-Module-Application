"""Permission-separated management endpoints; learner serializers are unchanged."""

from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import IntegrityError, OperationalError
from django.db.models import Prefetch, Q
from django.db.models.deletion import ProtectedError
from django.shortcuts import get_object_or_404
from rest_framework import generics
from rest_framework.exceptions import APIException
from rest_framework.parsers import JSONParser
from rest_framework.response import Response

from assessments.models import Assessment, AssessmentQuestion, Question, QuestionOption, QuestionRevision
from training.models import TrainingVersion

from . import assessment_management_services as services
from .assessment_management_serializers import (
    AssessmentAuthoringSerializer, AssessmentInputSerializer,
    AssessmentQuestionAuthoringSerializer, AssessmentQuestionInputSerializer,
    EmptyAuthoringInputSerializer, QuestionAuthoringSerializer, QuestionInputSerializer,
    RevisionAuthoringSerializer, RevisionEditInputSerializer, RevisionInputSerializer, RevisionSummarySerializer,
)
from .training_management_serializers import CatalogQuerySerializer, VersionQuerySerializer
from .training_management_views import TrainingManagementMixin, _is_unique_constraint_conflict, _validation_error


class AuthoringConflict(APIException):
    status_code = 409
    default_code = "conflict"
    default_detail = "Another edit conflicts with this operation. Refresh before trying again."


class AssessmentManagementMixin(TrainingManagementMixin):
    parser_classes = [JSONParser]

    def write(self, request, service, *ids, creating=False):
        serializer = self.input_serializer_class(data=request.data, partial=not creating)
        serializer.is_valid(raise_exception=True)
        try:
            instance = service(request.user, *ids, serializer.validated_data)
        except DjangoValidationError as exc:
            raise _validation_error(exc) from exc
        except ProtectedError as exc:
            raise AuthoringConflict("Referenced options cannot be removed.") from exc
        except IntegrityError as exc:
            constraints = (
                (Question, "code"), (QuestionRevision, "unique_question_revision"),
                (QuestionOption, "unique_question_option_order"), (Assessment, "unique_version_assessment_seq"),
                (AssessmentQuestion, "unique_assessment_question_pos"), (AssessmentQuestion, "unique_assessment_question_rev"),
            )
            if any(_is_unique_constraint_conflict(exc, model, name) for model, name in constraints):
                raise AuthoringConflict() from exc
            raise
        except OperationalError as exc:
            if exc.args and exc.args[0] in (1205, 1213):
                raise AuthoringConflict() from exc
            raise
        return Response(self.get_serializer(instance).data, status=201 if creating else 200)

    def page_query(self, query_class=VersionQuerySerializer):
        query = query_class(data=self.request.query_params)
        query.is_valid(raise_exception=True)
        return query.validated_data


class VersionAssessmentManagementView(AssessmentManagementMixin, generics.ListAPIView):
    method_permissions = {"GET": "assessments.view_assessment", "HEAD": "assessments.view_assessment", "OPTIONS": "assessments.view_assessment", "POST": "assessments.add_assessment"}
    serializer_class = AssessmentAuthoringSerializer
    input_serializer_class = AssessmentInputSerializer
    http_method_names = ["get", "head", "options", "post"]

    def get_queryset(self):
        self.page_query()
        get_object_or_404(TrainingVersion, pk=self.kwargs["version_pk"])
        return Assessment.objects.filter(training_version_id=self.kwargs["version_pk"]).order_by("kind", "sequence", "pk")

    def post(self, request, version_pk):
        return self.write(request, services.save_assessment, version_pk, creating=True)


class AssessmentManagementDetailView(AssessmentManagementMixin, generics.RetrieveAPIView):
    method_permissions = {"GET": "assessments.view_assessment", "HEAD": "assessments.view_assessment", "OPTIONS": "assessments.view_assessment", "PATCH": "assessments.change_assessment"}
    serializer_class = AssessmentAuthoringSerializer
    input_serializer_class = AssessmentInputSerializer
    http_method_names = ["get", "head", "options", "patch"]

    def get_queryset(self):
        return Assessment.objects.filter(training_version_id=self.kwargs["version_pk"])

    def patch(self, request, version_pk, pk):
        return self.write(request, lambda actor, version_id, values: services.save_assessment(actor, version_id, values, pk), version_pk)


class AssessmentQuestionManagementView(AssessmentManagementMixin, generics.ListAPIView):
    method_permissions = {"GET": "assessments.view_assessmentquestion", "HEAD": "assessments.view_assessmentquestion", "OPTIONS": "assessments.view_assessmentquestion", "POST": "assessments.add_assessmentquestion"}
    serializer_class = AssessmentQuestionAuthoringSerializer
    input_serializer_class = AssessmentQuestionInputSerializer
    http_method_names = ["get", "head", "options", "post"]

    def get_queryset(self):
        self.page_query()
        get_object_or_404(Assessment, pk=self.kwargs["assessment_pk"], training_version_id=self.kwargs["version_pk"])
        return AssessmentQuestion.objects.filter(assessment_id=self.kwargs["assessment_pk"]).order_by("position", "pk")

    def post(self, request, version_pk, assessment_pk):
        return self.write(request, services.save_assessment_question, version_pk, assessment_pk, creating=True)


class AssessmentQuestionManagementDetailView(AssessmentManagementMixin, generics.RetrieveAPIView):
    method_permissions = {"GET": "assessments.view_assessmentquestion", "HEAD": "assessments.view_assessmentquestion", "OPTIONS": "assessments.view_assessmentquestion", "PATCH": "assessments.change_assessmentquestion"}
    serializer_class = AssessmentQuestionAuthoringSerializer
    input_serializer_class = AssessmentQuestionInputSerializer
    http_method_names = ["get", "head", "options", "patch"]

    def get_queryset(self):
        return AssessmentQuestion.objects.filter(assessment_id=self.kwargs["assessment_pk"], assessment__training_version_id=self.kwargs["version_pk"])

    def patch(self, request, version_pk, assessment_pk, pk):
        return self.write(request, lambda actor, version_id, assessment_id, values: services.save_assessment_question(actor, version_id, assessment_id, values, pk), version_pk, assessment_pk)


class QuestionManagementView(AssessmentManagementMixin, generics.ListAPIView):
    method_permissions = {"GET": "assessments.view_question", "HEAD": "assessments.view_question", "OPTIONS": "assessments.view_question", "POST": "assessments.add_question"}
    serializer_class = QuestionAuthoringSerializer
    input_serializer_class = QuestionInputSerializer
    http_method_names = ["get", "head", "options", "post"]

    def get_queryset(self):
        query = self.page_query(CatalogQuerySerializer)
        qs = Question.objects.order_by("code", "pk")
        if query.get("search"):
            qs = qs.filter(Q(code__icontains=query["search"]) | Q(topic__icontains=query["search"]))
        if "is_active" in query:
            qs = qs.filter(is_active=query["is_active"])
        return qs

    def post(self, request):
        return self.write(request, services.create_question, creating=True)


class QuestionManagementDetailView(AssessmentManagementMixin, generics.RetrieveAPIView):
    method_permissions = {"GET": "assessments.view_question", "HEAD": "assessments.view_question", "OPTIONS": "assessments.view_question", "PATCH": "assessments.change_question"}
    queryset = Question.objects.all()
    serializer_class = QuestionAuthoringSerializer
    input_serializer_class = QuestionInputSerializer
    http_method_names = ["get", "head", "options", "patch"]

    def patch(self, request, pk):
        return self.write(request, services.update_question, pk)


class QuestionRevisionManagementView(AssessmentManagementMixin, generics.ListAPIView):
    method_permissions = {"GET": "assessments.view_questionrevision", "HEAD": "assessments.view_questionrevision", "OPTIONS": "assessments.view_questionrevision", "POST": "assessments.add_questionrevision"}
    serializer_class = RevisionSummarySerializer
    input_serializer_class = RevisionInputSerializer
    http_method_names = ["get", "head", "options", "post"]

    def get_queryset(self):
        self.page_query()
        get_object_or_404(Question, pk=self.kwargs["question_pk"])
        return QuestionRevision.objects.filter(question_id=self.kwargs["question_pk"]).order_by("revision_number", "pk")

    def post(self, request, question_pk):
        return self.write(request, services.create_revision, question_pk, creating=True)


class QuestionRevisionManagementDetailView(AssessmentManagementMixin, generics.RetrieveAPIView):
    method_permissions = {"GET": "assessments.view_questionrevision", "HEAD": "assessments.view_questionrevision", "OPTIONS": "assessments.view_questionrevision", "PATCH": "assessments.change_questionrevision"}
    serializer_class = RevisionAuthoringSerializer
    input_serializer_class = RevisionEditInputSerializer
    http_method_names = ["get", "head", "options", "patch"]

    def get_queryset(self):
        return QuestionRevision.objects.filter(question_id=self.kwargs["question_pk"]).prefetch_related(
            Prefetch("options", queryset=QuestionOption.objects.order_by("position", "pk")),
        )

    def patch(self, request, question_pk, pk):
        return self.write(request, services.update_revision, question_pk, pk)


class QuestionRevisionFreezeView(AssessmentManagementMixin, generics.GenericAPIView):
    method_permissions = {method: "assessments.change_questionrevision" for method in ("POST", "OPTIONS")}
    serializer_class = RevisionAuthoringSerializer
    input_serializer_class = EmptyAuthoringInputSerializer
    http_method_names = ["post", "options"]

    def post(self, request, question_pk, pk):
        return self.write(request, services.freeze_revision, question_pk, pk)
