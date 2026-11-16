"""Website report fields and filters, without curriculum or employee private data."""

from rest_framework import serializers

from training.models import TrainingAssignment


class AssignmentReportQuerySerializer(serializers.Serializer):
    status = serializers.ChoiceField(choices=TrainingAssignment.Status.choices, required=False)
    department = serializers.IntegerField(min_value=1, required=False)
    job_role = serializers.IntegerField(min_value=1, required=False)
    training = serializers.IntegerField(min_value=1, required=False)
    training_version = serializers.IntegerField(min_value=1, required=False)
    overdue_only = serializers.BooleanField(required=False)


class AssignmentReportSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    employee_name = serializers.CharField(source="employee.display_name")
    employee_code = serializers.CharField(source="employee.employee_code")
    department_name = serializers.CharField(source="department_at_assignment.name")
    job_role_name = serializers.CharField(source="job_role_at_assignment.name")
    training_title = serializers.CharField(source="training_version.training.catalog_title")
    version_title = serializers.CharField(source="training_version.title")
    version_number = serializers.IntegerField(source="training_version.version_number")
    status = serializers.CharField()
    status_display = serializers.CharField(source="get_status_display")
    is_overdue = serializers.BooleanField()
    assigned_at = serializers.DateTimeField()
    due_at = serializers.DateTimeField(allow_null=True)
    completed_at = serializers.DateTimeField(allow_null=True)
    certificate_id = serializers.SerializerMethodField()
    certificate_number = serializers.SerializerMethodField()
    is_certificate_revoked = serializers.SerializerMethodField()

    def can_view_certificate(self):
        # The report's issued/revoked indicator does not grant independent
        # certificate discovery or detail access.
        request = self.context.get("request")
        return request is not None and request.user.has_perm("certifications.view_certificate")

    def get_certificate_id(self, assignment):
        certificate = getattr(assignment, "certificate", None)
        return certificate.pk if certificate and self.can_view_certificate() else None

    def get_certificate_number(self, assignment):
        certificate = getattr(assignment, "certificate", None)
        return certificate.certificate_number if certificate and self.can_view_certificate() else None

    def get_is_certificate_revoked(self, assignment):
        certificate = getattr(assignment, "certificate", None)
        return certificate.revoked_at is not None if certificate else None


class ReportOptionSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    label = serializers.CharField()


class ReportVersionOptionSerializer(ReportOptionSerializer):
    training_id = serializers.IntegerField()
    version_number = serializers.IntegerField()
    title = serializers.CharField()
