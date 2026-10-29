"""VIDEO-only draft authoring; playback authorization stays in learning APIs."""

from django.http import QueryDict
from django.db import OperationalError
from rest_framework import generics
from rest_framework.exceptions import APIException
from rest_framework.parsers import FormParser, JSONParser, MultiPartParser

from training.models import Lesson, TrainingVersion

from . import video_management_services as services
from .curriculum_management_views import CurriculumWriteMixin
from .training_management_serializers import VideoLessonAuthoringSerializer, VideoLessonInputSerializer


class UploadUnavailable(APIException):
    status_code = 503
    default_code = "upload_unavailable"
    default_detail = "Video storage is unavailable. Contact your administrator and try again."


class VideoEditConflict(APIException):
    status_code = 409
    default_code = "conflict"
    default_detail = "Another editor is changing this curriculum. Refresh before trying again."


class VideoWriteMixin(CurriculumWriteMixin):
    model = Lesson
    position_constraint = "unique_lesson_position"
    input_serializer_class = VideoLessonInputSerializer
    serializer_class = VideoLessonAuthoringSerializer
    parser_classes = [MultiPartParser, JSONParser, FormParser]

    def input_data(self, request):
        # Treat omitted multipart booleans exactly like omitted JSON fields;
        # HTML checkbox defaults must not silently change API defaults.
        data = request.data
        return dict(data.items()) if isinstance(data, QueryDict) else data

    def save_response(self, request, service, *parent_ids, creating=False):
        try:
            return super().save_response(request, service, *parent_ids, creating=creating)
        except services.VideoStorageUnavailable as exc:
            raise UploadUnavailable() from exc
        except OperationalError as exc:
            if exc.args and exc.args[0] in (1205, 1213):
                raise VideoEditConflict() from exc
            raise


class VideoLessonCreateView(VideoWriteMixin, generics.GenericAPIView):
    http_method_names = ["post", "options"]
    method_permissions = {method: "training.add_lesson" for method in ("POST", "OPTIONS")}

    def post(self, request, version_pk, module_pk):
        return self.save_response(request, services.create_video_lesson, version_pk, module_pk, creating=True)


class VideoLessonDetailView(VideoWriteMixin, generics.RetrieveAPIView):
    http_method_names = ["get", "patch", "head", "options"]
    method_permissions = {
        "GET": "training.view_lesson", "HEAD": "training.view_lesson",
        "OPTIONS": "training.view_lesson", "PATCH": "training.change_lesson",
    }

    def get_queryset(self):
        return Lesson.objects.select_related("module").filter(
            module_id=self.kwargs["module_pk"],
            module__training_version_id=self.kwargs["version_pk"],
            module__training_version__status=TrainingVersion.Status.DRAFT,
            content_type=Lesson.ContentType.VIDEO,
        )

    def patch(self, request, version_pk, module_pk, pk):
        return self.save_response(request, services.update_video_lesson, version_pk, module_pk, pk)
