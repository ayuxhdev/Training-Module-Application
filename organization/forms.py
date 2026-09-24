from django import forms

from .models import Department, Employee, JobRole


def may_manage_linked_user(actor, target):
    if target is None or not (
        target.is_superuser or target.is_staff or target.groups.filter(name="Administrator").exists()
    ):
        return True
    return bool(actor and (actor.is_superuser or actor.groups.filter(name="Administrator").exists()))


class EmployeeForm(forms.ModelForm):
    def __init__(self, *args, **kwargs):
        self.actor = kwargs.pop("actor", None)
        super().__init__(*args, **kwargs)

    def clean_user(self):
        user = self.cleaned_data["user"]
        if user and self.instance.pk and self.instance.user_id == user.pk:
            return user
        if not may_manage_linked_user(self.actor, user):
            raise forms.ValidationError("You cannot link a privileged login account.")
        return user

    class Meta:
        model = Employee
        fields = [
            "employee_code", "display_name", "user", "department", "job_role",
            "reporting_manager", "date_joined",
        ]
        widgets = {"date_joined": forms.DateInput(attrs={"type": "date"})}


class EmployeeDeactivateForm(forms.Form):
    reason = forms.CharField(
        max_length=1000,
        required=True,
        strip=True,
        widget=forms.Textarea,
    )


class DepartmentForm(forms.ModelForm):
    class Meta:
        model = Department
        fields = ["code", "name", "description", "is_active"]


class JobRoleForm(forms.ModelForm):
    class Meta:
        model = JobRole
        fields = ["code", "name", "description", "is_active"]
