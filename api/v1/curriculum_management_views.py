"""Draft-only curriculum adapters; website forms and models own validation."""

from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import IntegrityError
from rest_framework import generics
from rest_framework.exceptions import APIException
from rest_framework.response import Response

from training.models import Lesson, Module, TrainingVersion

from . import training_management_services as services
from .training_management_serializers import (
    ModuleAuthoringSerializer, ModuleInputSerializer,
    TextLessonAuthoringSerializer, TextLessonInputSerializer,
)
from .training_management_views import (
    TrainingManagementMixin, _is_unique_constraint_conflict, _validation_error,
)


class CurriculumPositionConflict(APIException):
    status_code = 409
    default_code = "conflict"
    default_detail = "That position was taken by another edit. Refresh and choose an unused position."


class CurriculumWriteMixin(TrainingManagementMixin):
    def input_data(self, request):
        return request.data

    def save_response(self, request, service, *parent_ids, creating=False):
        serializer = self.input_serializer_class(data=self.input_data(request), partial=not creating)
        serializer.is_valid(raise_exception=True)
        try:
            instance = service(request.user, *parent_ids, serializer.validated_data)
        except DjangoValidationError as exc:
            raise _validation_error(exc) from exc
        except IntegrityError as exc:
            if _is_unique_constraint_conflict(exc, self.model, self.position_constraint):
                raise CurriculumPositionConflict() from exc
            raise
        return Response(self.get_serializer(instance).data, status=201 if creating else 200)


class ModuleCreateView(CurriculumWriteMixin, generics.GenericAPIView):
    http_method_names = ["post", "options"]
    method_permissions = {method: "training.add_module" for method in ("POST", "OPTIONS")}
    model = Module
    position_constraint = "unique_module_position"
    input_serializer_class = ModuleInputSerializer
    serializer_class = ModuleAuthoringSerializer

    def post(self, request, version_pk):
        return self.save_response(request, services.create_module, version_pk, creating=True)


class ModuleDetailView(CurriculumWriteMixin, generics.RetrieveAPIView):
    http_method_names = ["get", "patch", "head", "options"]
    method_permissions = {
        "GET": "training.view_module", "HEAD": "training.view_module",
        "OPTIONS": "training.view_module", "PATCH": "training.change_module",
    }
    model = Module
    position_constraint = "unique_module_position"
    input_serializer_class = ModuleInputSerializer
    serializer_class = ModuleAuthoringSerializer

    def get_queryset(self):
        return Module.objects.filter(
            training_version_id=self.kwargs["version_pk"],
            training_version__status=TrainingVersion.Status.DRAFT,
        )

    def patch(self, request, version_pk, pk):
        return self.save_response(request, services.update_module, version_pk, pk)


class TextLessonCreateView(CurriculumWriteMixin, generics.GenericAPIView):
    http_method_names = ["post", "options"]
    method_permissions = {method: "training.add_lesson" for method in ("POST", "OPTIONS")}
    model = Lesson
    position_constraint = "unique_lesson_position"
    input_serializer_class = TextLessonInputSerializer
    serializer_class = TextLessonAuthoringSerializer

    def post(self, request, version_pk, module_pk):
        return self.save_response(
            request, services.create_text_lesson, version_pk, module_pk, creating=True,
        )


class TextLessonDetailView(CurriculumWriteMixin, generics.RetrieveAPIView):
    http_method_names = ["get", "patch", "head", "options"]
    method_permissions = {
        "GET": "training.view_lesson", "HEAD": "training.view_lesson",
        "OPTIONS": "training.view_lesson", "PATCH": "training.change_lesson",
    }
    model = Lesson
    position_constraint = "unique_lesson_position"
    input_serializer_class = TextLessonInputSerializer
    serializer_class = TextLessonAuthoringSerializer

    def get_queryset(self):
        return Lesson.objects.select_related("module").filter(
            module_id=self.kwargs["module_pk"],
            module__training_version_id=self.kwargs["version_pk"],
            module__training_version__status=TrainingVersion.Status.DRAFT,
            content_type=Lesson.ContentType.TEXT,
        )

    def patch(self, request, version_pk, module_pk, pk):
        return self.save_response(request, services.update_text_lesson, version_pk, module_pk, pk)
