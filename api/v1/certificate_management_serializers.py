"""Management certificate metadata only; never expose storage paths or answers."""

from rest_framework import serializers

from .certificate_serializers import CertificateListSerializer
from .certificate_management_services import MAX_REASON_LENGTH
from .training_management_serializers import ExplicitInputSerializer, VersionDiscoveryQuerySerializer


class CertificateManagementQuerySerializer(VersionDiscoveryQuerySerializer):
    is_revoked = serializers.BooleanField(required=False)


class CertificateManagementSerializer(CertificateListSerializer):
    employee_name = serializers.CharField(source="employee_name_snapshot", read_only=True)
    employee_code = serializers.CharField(source="employee_code_snapshot", read_only=True)

    class Meta(CertificateListSerializer.Meta):
        fields = [*CertificateListSerializer.Meta.fields, "employee_name", "employee_code", "revoked_at"]


class CertificateManagementDetailSerializer(CertificateManagementSerializer):
    class Meta(CertificateManagementSerializer.Meta):
        fields = [*CertificateManagementSerializer.Meta.fields, "revocation_reason"]


class RevocationReasonField(serializers.CharField):
    def to_internal_value(self, data):
        if not isinstance(data, str):
            self.fail("invalid")
        return super().to_internal_value(data)


class CertificateRevocationSerializer(ExplicitInputSerializer):
    reason = RevocationReasonField(max_length=MAX_REASON_LENGTH)


class CertificateRevocationResultSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    is_revoked = serializers.SerializerMethodField()
    revoked_at = serializers.DateTimeField()

    def get_is_revoked(self, certificate):
        return certificate.revoked_at is not None
