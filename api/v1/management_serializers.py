from collections.abc import Mapping

from rest_framework import serializers

from organization.forms import may_manage_linked_user
from organization.models import Department, Employee, JobRole


class ReferenceSummarySerializer(serializers.Serializer):
    id = serializers.IntegerField()
    code = serializers.CharField()
    name = serializers.CharField()


class OrganizationReferenceSerializer(ReferenceSummarySerializer):
    description = serializers.CharField()
    is_active = serializers.BooleanField()


class OrganizationReferenceWriteSerializer(serializers.ModelSerializer):
    class Meta:
        fields = ("id", "code", "name", "description", "is_active")
        read_only_fields = ("id",)

    def to_internal_value(self, data):
        if isinstance(data, Mapping):
            unexpected = set(data) - {"code", "name", "description", "is_active"}
            if unexpected:
                raise serializers.ValidationError({field: ["This field is not writable."] for field in sorted(unexpected)})
        return super().to_internal_value(data)


class DepartmentWriteSerializer(OrganizationReferenceWriteSerializer):
    class Meta(OrganizationReferenceWriteSerializer.Meta):
        model = Department


class JobRoleWriteSerializer(OrganizationReferenceWriteSerializer):
    class Meta(OrganizationReferenceWriteSerializer.Meta):
        model = JobRole


class EmployeeDirectorySerializer(serializers.Serializer):
    id = serializers.IntegerField()
    employee_code = serializers.CharField()
    display_name = serializers.CharField()
    department = ReferenceSummarySerializer()
    job_role = ReferenceSummarySerializer()
    # The portal shows this relationship's name, not access to the manager's record.
    reporting_manager = serializers.CharField(source="reporting_manager.display_name", default=None)
    is_active = serializers.BooleanField()


class EmployeeDirectoryDetailSerializer(EmployeeDirectorySerializer):
    reporting_manager_id = serializers.IntegerField(read_only=True, allow_null=True)
    date_joined = serializers.DateField()
    login_status = serializers.SerializerMethodField()

    def get_login_status(self, employee):
        if employee.user_id is None:
            return "NOT_LINKED"
        return "ACTIVE" if employee.user.is_active else "INACTIVE"


class EmployeeProfileWriteSerializer(serializers.ModelSerializer):
    class Meta:
        model = Employee
        fields = ("display_name", "department", "job_role", "reporting_manager", "date_joined")

    def to_internal_value(self, data):
        if isinstance(data, Mapping):
            unexpected = set(data) - set(self.Meta.fields)
            if unexpected:
                raise serializers.ValidationError({field: ["This field is not writable."] for field in sorted(unexpected)})
        return super().to_internal_value(data)


class EmployeeCreateSerializer(EmployeeProfileWriteSerializer):
    class Meta(EmployeeProfileWriteSerializer.Meta):
        fields = ("employee_code", "display_name", "user", "department", "job_role", "reporting_manager", "date_joined")

    def validate_user(self, user):
        actor = getattr(self.context.get("request"), "user", None)
        if not may_manage_linked_user(actor, user):
            raise serializers.ValidationError("You cannot link a privileged login account.")
        return user


class EmployeeDeactivationSerializer(serializers.Serializer):
    reason = serializers.CharField(max_length=1000, trim_whitespace=True)

    def to_internal_value(self, data):
        if isinstance(data, Mapping):
            unexpected = set(data) - {"reason"}
            if unexpected:
                raise serializers.ValidationError({field: ["This field is not writable."] for field in sorted(unexpected)})
            if "reason" in data and not isinstance(data["reason"], str):
                raise serializers.ValidationError({"reason": ["Enter a deactivation reason."]})
        return super().to_internal_value(data)


class ManagementMetricsSerializer(serializers.Serializer):
    total = serializers.IntegerField()
    assigned = serializers.IntegerField()
    in_progress = serializers.IntegerField()
    completed = serializers.IntegerField()
    cancelled = serializers.IntegerField()
    overdue = serializers.IntegerField()
    eligible = serializers.IntegerField()
    completion_percent = serializers.FloatField()


class RecentFailureSerializer(serializers.Serializer):
    assessment_title = serializers.CharField(source="assessment.title")
    employee_name = serializers.CharField(source="assignment.employee.display_name")
    score_points = serializers.DecimalField(max_digits=12, decimal_places=2)
    maximum_points = serializers.DecimalField(max_digits=12, decimal_places=2)
    submitted_at = serializers.DateTimeField()


class IncompleteEmployeeSerializer(serializers.Serializer):
    employee_id = serializers.IntegerField(source="pk")
    employee_name = serializers.CharField(source="display_name")
    incomplete_assignment_count = serializers.IntegerField()
    overdue_assignment_count = serializers.IntegerField()


class ManagementDashboardSerializer(serializers.Serializer):
    scope = serializers.ChoiceField(choices=("company", "team"))
    metrics = ManagementMetricsSerializer()
    summary = serializers.DictField(child=serializers.IntegerField())
    recent_failures = RecentFailureSerializer(many=True)
    incomplete_employees = IncompleteEmployeeSerializer(many=True)
