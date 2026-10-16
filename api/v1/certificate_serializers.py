from rest_framework import serializers

from certifications.models import Certificate


class CertificateListSerializer(serializers.ModelSerializer):
    """Serializer for the employee certificate list endpoint."""

    training_title = serializers.CharField(source="training_title_snapshot", read_only=True)
    version_number = serializers.IntegerField(source="version_number_snapshot", read_only=True)
    is_revoked = serializers.SerializerMethodField()

    class Meta:
        model = Certificate
        fields = [
            "id",
            "certificate_number",
            "training_title",
            "version_number",
            "issued_at",
            "is_revoked",
        ]

    def get_is_revoked(self, obj):
        return obj.revoked_at is not None


class CertificateDetailSerializer(serializers.ModelSerializer):
    """Serializer for the employee certificate detail endpoint."""

    training_title = serializers.CharField(source="training_title_snapshot", read_only=True)
    version_number = serializers.IntegerField(source="version_number_snapshot", read_only=True)
    employee_name = serializers.CharField(source="employee_name_snapshot", read_only=True)
    employee_code = serializers.CharField(source="employee_code_snapshot", read_only=True)
    is_revoked = serializers.SerializerMethodField()
    has_document = serializers.SerializerMethodField()

    class Meta:
        model = Certificate
        fields = [
            "id",
            "certificate_number",
            "training_title",
            "version_number",
            "employee_name",
            "employee_code",
            "issued_at",
            "is_revoked",
            "revoked_at",
            "assignment_id",
            "has_document",
        ]

    def get_is_revoked(self, obj):
        return obj.revoked_at is not None

    def get_has_document(self, obj):
        return bool(obj.document_file)
