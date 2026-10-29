"""Permission-separated company catalog authoring, independent of assignments."""

import re

from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import IntegrityError
from django.db.models import OuterRef, Prefetch, Q, Subquery
from django.shortcuts import get_object_or_404
from rest_framework import generics, serializers
from rest_framework.exceptions import APIException
from rest_framework.permissions import BasePermission, IsAuthenticated
from rest_framework.response import Response
from rest_framework_simplejwt.authentication import JWTAuthentication

from api.pagination import StandardResultsSetPagination
from api.permissions import IsMobileAccount
from training.models import Lesson, Module, Training, TrainingVersion

from . import training_management_services as services
from .training_management_serializers import (
    CatalogQuerySerializer, DraftVersionInputSerializer, TrainingCatalogSerializer,
    TrainingInputSerializer, TrainingVersionDetailSerializer,
    TrainingVersionSummarySerializer, VersionQuerySerializer,
    TrainingVersionDiscoverySerializer, VersionDiscoveryQuerySerializer,
)


class HasTrainingManagementPermission(BasePermission):
    def has_permission(self, request, view):
        # Authorized readers receive DRF's 405 for unsupported verbs; write
        # methods that do exist always require their independent permission.
        permission = view.method_permissions.get(
            request.method, view.method_permissions.get("GET"),
        )
        return bool(permission and request.user.has_perm(permission))


class TrainingManagementMixin:
    authentication_classes = [JWTAuthentication]
    permission_classes = [IsAuthenticated, IsMobileAccount, HasTrainingManagementPermission]
    pagination_class = StandardResultsSetPagination


class VersionNumberConflict(APIException):
    status_code = 409
    default_code = "conflict"
    default_detail = "Another author created that version. Refresh the version history and try again."


# Verified against model metadata and the real MySQL index in the API tests.
VERSION_NUMBER_CONSTRAINT = "unique_training_version"


def _is_unique_constraint_conflict(exc, model, constraint):
    if len(exc.args) < 2 or exc.args[0] != 1062 or not isinstance(exc.args[1], str):
        return False
    # MySQL reports the key separately from the duplicated value. Match the
    # entire quoted key, including its table when supplied, not arbitrary text.
    match = re.search(r"\bfor key (['`])([^'`]+)\1\Z", exc.args[1])
    return bool(match and match.group(2) in {
        constraint, f"{model._meta.db_table}.{constraint}",
    })


def _is_version_number_conflict(exc):
    return _is_unique_constraint_conflict(exc, TrainingVersion, VERSION_NUMBER_CONSTRAINT)


def _validation_error(exc):
    fields = exc.message_dict if hasattr(exc, "message_dict") else {"__all__": exc.messages}
    return serializers.ValidationError({
        "non_field_errors" if key == "__all__" else key: values for key, values in fields.items()
    })


def _duplicate_code(exc, code, *, exclude_id=None):
    if not exc.args or exc.args[0] != 1062:
        return False
    return Training.objects.filter(code=code).exclude(pk=exclude_id).exists()


def catalog_queryset():
    latest = TrainingVersion.objects.filter(training_id=OuterRef("pk")).order_by(
        "-version_number", "pk",
    )
    return Training.objects.annotate(
        latest_version_number=Subquery(latest.values("version_number")[:1]),
        latest_version_status=Subquery(latest.values("status")[:1]),
    ).order_by("catalog_title", "code", "pk")


def version_detail_queryset():
    lessons = Lesson.objects.only(
        "id", "module_id", "title", "content_type", "position", "is_required",
    ).order_by("position", "pk")
    modules = Module.objects.only(
        "id", "training_version_id", "title", "description", "position",
    ).order_by("position", "pk")
    modules = modules.prefetch_related(Prefetch("lessons", queryset=lessons))
    return TrainingVersion.objects.prefetch_related(Prefetch("modules", queryset=modules))


class TrainingCatalogView(TrainingManagementMixin, generics.ListAPIView):
    http_method_names = ["get", "post", "head", "options"]
    method_permissions = {
        "GET": "training.view_training", "HEAD": "training.view_training",
        "OPTIONS": "training.view_training", "POST": "training.add_training",
    }
    serializer_class = TrainingCatalogSerializer

    def get_queryset(self):
        # A QueryDict triggers HTML-checkbox semantics in DRF: an omitted
        # optional boolean becomes False. Query filters must stay optional.
        query = CatalogQuerySerializer(data=dict(self.request.query_params.items()))
        query.is_valid(raise_exception=True)
        values = query.validated_data
        courses = catalog_queryset()
        if values.get("search"):
            search = values["search"]
            courses = courses.filter(
                Q(code__icontains=search) | Q(catalog_title__icontains=search)
                | Q(description__icontains=search)
            )
        if "is_active" in values:
            courses = courses.filter(is_active=values["is_active"])
        return courses

    def post(self, request, *args, **kwargs):
        serializer = TrainingInputSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            training = services.create_training(request.user, serializer.validated_data)
        except DjangoValidationError as exc:
            raise _validation_error(exc) from exc
        except IntegrityError as exc:
            if _duplicate_code(exc, serializer.validated_data["code"]):
                raise serializers.ValidationError({
                    "code": ["Training with this Code already exists."],
                }) from exc
            raise
        training = catalog_queryset().get(pk=training.pk)
        return Response(TrainingCatalogSerializer(training).data, status=201)


class TrainingCatalogDetailView(TrainingManagementMixin, generics.RetrieveAPIView):
    http_method_names = ["get", "patch", "head", "options"]
    method_permissions = {
        "GET": "training.view_training", "HEAD": "training.view_training",
        "OPTIONS": "training.view_training", "PATCH": "training.change_training",
    }
    serializer_class = TrainingCatalogSerializer

    def get_queryset(self):
        return catalog_queryset()

    def patch(self, request, *args, **kwargs):
        serializer = TrainingInputSerializer(data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        try:
            training = services.update_training(
                request.user, self.kwargs["pk"], serializer.validated_data,
            )
        except DjangoValidationError as exc:
            raise _validation_error(exc) from exc
        except IntegrityError as exc:
            if "code" in serializer.validated_data and _duplicate_code(
                exc, serializer.validated_data["code"], exclude_id=self.kwargs["pk"],
            ):
                raise serializers.ValidationError({
                    "code": ["Training with this Code already exists."],
                }) from exc
            raise
        return Response(TrainingCatalogSerializer(catalog_queryset().get(pk=training.pk)).data)


class TrainingVersionHistoryView(TrainingManagementMixin, generics.ListAPIView):
    http_method_names = ["get", "post", "head", "options"]
    method_permissions = {
        "GET": "training.view_trainingversion", "HEAD": "training.view_trainingversion",
        "OPTIONS": "training.view_trainingversion", "POST": "training.add_trainingversion",
    }
    serializer_class = TrainingVersionSummarySerializer

    def get_queryset(self):
        query = VersionQuerySerializer(data=self.request.query_params)
        query.is_valid(raise_exception=True)
        training = get_object_or_404(Training, pk=self.kwargs["pk"])
        return training.versions.order_by("-version_number", "pk")

    def post(self, request, *args, **kwargs):
        serializer = DraftVersionInputSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            version = services.create_draft_version(
                request.user, self.kwargs["pk"], serializer.validated_data,
            )
        except DjangoValidationError as exc:
            raise _validation_error(exc) from exc
        except IntegrityError as exc:
            if _is_version_number_conflict(exc):
                raise VersionNumberConflict() from exc
            raise
        version = version_detail_queryset().get(pk=version.pk)
        return Response(TrainingVersionDetailSerializer(version).data, status=201)


class TrainingVersionDiscoveryView(TrainingManagementMixin, generics.ListAPIView):
    http_method_names = ["get", "head", "options"]
    method_permissions = {
        method: "training.view_trainingversion" for method in ("GET", "HEAD", "OPTIONS")
    }
    serializer_class = TrainingVersionDiscoverySerializer

    def get_queryset(self):
        query = VersionDiscoveryQuerySerializer(data=dict(self.request.query_params.items()))
        query.is_valid(raise_exception=True)
        # Match version history/detail: effective version-view permission grants
        # company-wide summaries across lifecycle states, not course permissions.
        versions = TrainingVersion.objects.select_related("training").only(
            "id", "training_id", "version_number", "title", "status",
            "training__id", "training__catalog_title",
        )
        search = query.validated_data.get("search")
        if search:
            versions = versions.filter(
                Q(title__icontains=search) | Q(training__catalog_title__icontains=search)
                | Q(training__code__icontains=search)
            )
        return versions.order_by("training__catalog_title", "training_id", "-version_number", "pk")


class TrainingVersionDetailView(TrainingManagementMixin, generics.RetrieveAPIView):
    http_method_names = ["get", "head", "options"]
    method_permissions = {
        method: "training.view_trainingversion" for method in ("GET", "HEAD", "OPTIONS")
    }
    serializer_class = TrainingVersionDetailSerializer

    def get_queryset(self):
        return version_detail_queryset()
