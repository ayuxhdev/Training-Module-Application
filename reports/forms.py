from django import forms

from organization.models import Department, JobRole
from training.models import Training, TrainingAssignment, TrainingVersion


class AssignmentReportFilterForm(forms.Form):
	status = forms.ChoiceField(required=False)
	department = forms.ModelChoiceField(queryset=Department.objects.none(), required=False)
	job_role = forms.ModelChoiceField(queryset=JobRole.objects.none(), required=False)
	training = forms.ModelChoiceField(queryset=Training.objects.none(), required=False)
	training_version = forms.ModelChoiceField(queryset=TrainingVersion.objects.none(), required=False)
	overdue_only = forms.BooleanField(required=False)

	def __init__(self, *args, assignment_queryset, **kwargs):
		super().__init__(*args, **kwargs)
		self.fields["status"].choices = [("", "All statuses"), *TrainingAssignment.Status.choices]
		scoped_assignments = assignment_queryset.order_by()
		self.fields["department"].queryset = Department.objects.filter(
			pk__in=scoped_assignments.values("department_at_assignment_id"),
		).order_by("name", "pk")
		self.fields["job_role"].queryset = JobRole.objects.filter(
			pk__in=scoped_assignments.values("job_role_at_assignment_id"),
		).order_by("name", "pk")
		self.fields["training"].queryset = Training.objects.filter(
			pk__in=scoped_assignments.values("training_version__training_id"),
		).order_by("catalog_title", "pk")
		self.fields["training_version"].queryset = TrainingVersion.objects.filter(
			pk__in=scoped_assignments.values("training_version_id"),
		).select_related("training").order_by("training__catalog_title", "version_number")