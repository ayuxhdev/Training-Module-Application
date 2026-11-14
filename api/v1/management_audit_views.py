"""Company-wide audit metadata for effective audit readers; GET never writes."""

from django.contrib.auth import get_user_model
from rest_framework import generics, serializers
from rest_framework.response import Response
from rest_framework.utils.urls import replace_query_param

from audit.models import AuditLog
from audit.templatetags.audit_presentation import ENTITY_LABELS

from .management_audit_serializers import AuditLogQuerySerializer, AuditLogSerializer
from .training_management_views import TrainingManagementMixin


def audit_queryset():
    return AuditLog.objects.select_related("actor").only(
        "id", "occurred_at", "actor_id", "actor_label_snapshot", "actor__id", "actor__username",
        "action", "entity_type", "entity_id", "before_data", "after_data",
    )


class AuditLogMixin(TrainingManagementMixin):
    method_permissions = {method: "audit.view_auditlog" for method in ("GET", "HEAD", "OPTIONS")}
    http_method_names = ["get", "head", "options"]


class AuditLogListView(AuditLogMixin, generics.ListAPIView):
    serializer_class = AuditLogSerializer

    def get_queryset(self):
        query = AuditLogQuerySerializer(data=dict(self.request.query_params.items()))
        query.is_valid(raise_exception=True)
        values = query.validated_data
        logs = audit_queryset()
        for parameter, lookup in (
            ("actor", "actor_id"), ("action", "action__icontains"),
            ("target_type", "entity_type__iexact"),
            ("start_date", "occurred_at__date__gte"), ("end_date", "occurred_at__date__lte"),
        ):
            if parameter in values:
                logs = logs.filter(**{lookup: values[parameter]})
        return logs.order_by("-occurred_at", "-pk")


class AuditLogDetailView(AuditLogMixin, generics.RetrieveAPIView):
    serializer_class = AuditLogSerializer
    queryset = audit_queryset()


class AuditLogFiltersView(AuditLogMixin, generics.GenericAPIView):
    """Paginated recorded actors; static known record types contain no payload data."""

    def get(self, request):
        if request.query_params.get("kind", "actors") != "actors":
            raise serializers.ValidationError({"kind": "Unknown filter collection."})
        actor_ids = AuditLog.objects.filter(actor__isnull=False).values("actor_id")
        actors = get_user_model().objects.filter(pk__in=actor_ids).only("pk", "username").order_by("username", "pk")
        paginator = self.pagination_class()
        page = paginator.paginate_queryset(actors, request, view=self)
        next_link = paginator.get_next_link()
        previous_link = paginator.get_previous_link()
        return Response({
            "actors": [{"id": actor.pk, "username": actor.get_username(),
                        "display_name": actor.get_username()} for actor in page],
            "entity_types": [{"value": value, "label": label}
                             for value, label in sorted(ENTITY_LABELS.items())],
            "pagination": {"actors": {
                "count": paginator.page.paginator.count,
                "next": replace_query_param(next_link, "kind", "actors") if next_link else None,
                "previous": replace_query_param(previous_link, "kind", "actors") if previous_link else None,
            }},
        })
