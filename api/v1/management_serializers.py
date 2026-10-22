from rest_framework import serializers


class ReferenceSummarySerializer(serializers.Serializer):
    id = serializers.IntegerField()
    code = serializers.CharField()
    name = serializers.CharField()


class OrganizationReferenceSerializer(ReferenceSummarySerializer):
    description = serializers.CharField()
    is_active = serializers.BooleanField()


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
    date_joined = serializers.DateField()
    login_status = serializers.SerializerMethodField()

    def get_login_status(self, employee):
        if employee.user_id is None:
            return "NOT_LINKED"
        return "ACTIVE" if employee.user.is_active else "INACTIVE"


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
