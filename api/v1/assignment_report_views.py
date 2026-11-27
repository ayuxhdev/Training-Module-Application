"""Read-only report API. Filters narrow the website reporting scope, never expand it."""

from rest_framework import generics, serializers
from rest_framework.permissions import BasePermission, IsAuthenticated
from rest_framework.response import Response
from rest_framework.utils.urls import replace_query_param
from rest_framework_simplejwt.authentication import JWTAuthentication

from api.pagination import StandardResultsSetPagination
from api.permissions import IsMobileAccount
from reports.queries import dashboard_role
from training.models import TrainingAssignment

from .assignment_report_csv import assignment_report_csv_response
from .assignment_report_queries import assignment_report_options, assignment_report_queryset
from .assignment_report_serializers import (
    AssignmentReportQuerySerializer, AssignmentReportSerializer,
    ReportOptionSerializer, ReportVersionOptionSerializer,
)


class HasAssignmentReportAccess(BasePermission):
    def has_permission(self, request, view):
        return dashboard_role(request.user) in ("company", "manager")


class AssignmentReportMixin:
    authentication_classes = [JWTAuthentication]
    permission_classes = [IsAuthenticated, IsMobileAccount, HasAssignmentReportAccess]
    pagination_class = StandardResultsSetPagination
    http_method_names = ["get", "head", "options"]


class AssignmentReportView(AssignmentReportMixin, generics.ListAPIView):
    serializer_class = AssignmentReportSerializer

    def get_queryset(self):
        query = AssignmentReportQuerySerializer(data=dict(self.request.query_params.items()))
        query.is_valid(raise_exception=True)
        return assignment_report_queryset(self.request.user, query.validated_data)


class AssignmentReportExportView(AssignmentReportView):
    """Download all scoped matches, independent of JSON list pagination."""

    def get(self, request, *args, **kwargs):
        return assignment_report_csv_response(self.get_queryset())

    def finalize_response(self, request, response, *args, **kwargs):
        response = super().finalize_response(request, response, *args, **kwargs)
        # Errors must not be cached either; only successful responses are CSV.
        response["Cache-Control"] = "private, no-store"
        response["X-Content-Type-Options"] = "nosniff"
        return response


class AssignmentReportFiltersView(AssignmentReportMixin, generics.GenericAPIView):
    """Each option collection has its own count/next/previous in pagination.

    Without kind, return page one of every collection. Follow a collection's
    next link (kind plus page) to enumerate it completely; page_size is 20/100.
    """

    def get(self, request):
        choices = assignment_report_options(request.user)
        kind = request.query_params.get("kind")
        if kind is not None and kind not in choices:
            raise serializers.ValidationError({"kind": "Unknown filter collection."})
        if kind is None and request.query_params.get("page", "1") != "1":
            raise serializers.ValidationError({"kind": "Select a collection before paging."})
        result = {"statuses": [
            {"value": value, "label": label} for value, label in TrainingAssignment.Status.choices
        ], "pagination": {}}
        for name, queryset in choices.items():
            if kind is not None and kind != name:
                continue
            paginator = self.pagination_class()
            page = paginator.paginate_queryset(queryset, request, view=self)
            if name == "training_versions":
                rows = [{"id": obj.pk, "training_id": obj.training_id,
                         "version_number": obj.version_number, "title": obj.title,
                         "label": f"{obj.training.catalog_title} - {obj.title} (v{obj.version_number})"}
                        for obj in page]
                serializer = ReportVersionOptionSerializer(rows, many=True)
            else:
                rows = [{"id": obj.pk, "label": obj.catalog_title if name == "trainings" else obj.name}
                        for obj in page]
                serializer = ReportOptionSerializer(rows, many=True)
            result[name] = serializer.data
            next_link = paginator.get_next_link()
            previous_link = paginator.get_previous_link()
            result["pagination"][name] = {
                "count": paginator.page.paginator.count,
                "next": replace_query_param(next_link, "kind", name) if next_link else None,
                "previous": replace_query_param(previous_link, "kind", name) if previous_link else None,
            }
        return Response(result)
