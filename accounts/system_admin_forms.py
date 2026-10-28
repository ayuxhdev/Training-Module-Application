"""Explicit, allowlisted forms for website-only Superuser provisioning."""

from django import forms
from django.contrib.auth import get_user_model
from django.contrib.auth.forms import UsernameField
from django.contrib.auth.models import Group

from organization.models import Employee


BUSINESS_GROUP_NAMES = (
    "Administrator", "Training Coordinator", "Manager", "Employee", "Trainer", "Supervisor",
)


def approved_groups():
    return Group.objects.filter(name__in=BUSINESS_GROUP_NAMES).order_by("name", "pk")


def unlinked_employees():
    return Employee.objects.filter(user__isnull=True).order_by("employee_code", "pk")


class ExplicitFieldsMixin:
    def clean(self):
        cleaned = super().clean()
        unexpected = set(self.data) - set(self.fields) - {"csrfmiddlewaretoken"}
        if unexpected:
            raise forms.ValidationError("This form contains unsupported fields. Reload the page and try again.")
        if hasattr(self.data, "getlist"):
            for name, field in self.fields.items():
                if not isinstance(field, forms.ModelMultipleChoiceField) and len(self.data.getlist(name)) > 1:
                    raise forms.ValidationError("Submit only one value for each account field.")
        return cleaned


class CreateSystemUserForm(ExplicitFieldsMixin, forms.ModelForm):
    username = UsernameField(
        max_length=150,
        help_text="Required. Use letters, digits and @/./+/-/_ only.",
    )
    groups = forms.ModelMultipleChoiceField(
        label="Business Groups", queryset=Group.objects.none(), required=False,
        help_text="Optional. Hold Ctrl (Command on macOS) to select multiple Groups. No technical access is granted.",
    )
    employee = forms.ModelChoiceField(
        label="Existing Employee", queryset=Employee.objects.none(), required=False,
        help_text="Optional. Only Employees without an account link are available. Existing links cannot be replaced.",
    )
    confirm = forms.BooleanField(label="I confirm creation of an inactive account with password sign-in disabled.")

    class Meta:
        model = get_user_model()
        fields = ["username", "first_name", "last_name", "email", "groups", "employee", "confirm"]

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["groups"].queryset = approved_groups()
        self.fields["employee"].queryset = unlinked_employees()


class SystemUserGroupsForm(ExplicitFieldsMixin, forms.Form):
    groups = forms.ModelMultipleChoiceField(
        label="Business Groups", queryset=Group.objects.none(), required=False,
        help_text="Select the business Groups to retain. An empty selection removes these business memberships only. Other memberships and direct permissions are preserved.",
    )
    confirm = forms.BooleanField(label="I confirm these business Group changes.")

    def __init__(self, *args, target, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["groups"].queryset = approved_groups()
        self.initial["groups"] = list(target.groups.filter(name__in=BUSINESS_GROUP_NAMES).values_list("pk", flat=True))


class SystemUserEmployeeLinkForm(ExplicitFieldsMixin, forms.Form):
    employee = forms.ModelChoiceField(
        label="Existing Employee", queryset=Employee.objects.none(),
        help_text="This creates a permanent account link. Existing links cannot be replaced or removed here.",
    )
    confirm = forms.BooleanField(label="I confirm this Employee and account should be permanently linked.")

    def __init__(self, *args, target, **kwargs):
        super().__init__(*args, **kwargs)
        choices = unlinked_employees()
        if target.is_active:
            choices = choices.filter(is_active=True)
        self.fields["employee"].queryset = choices
