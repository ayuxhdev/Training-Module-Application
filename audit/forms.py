from django import forms
from django.contrib.auth import get_user_model


class AuditLogFilterForm(forms.Form):
    actor = forms.ModelChoiceField(
        queryset=get_user_model().objects.none(),
        required=False,
        label="Performed By",
    )
    action = forms.CharField(
        required=False,
        max_length=80,
    )
    start_date = forms.DateField(
        required=False,
        widget=forms.DateInput(attrs={"type": "date"}),
    )
    end_date = forms.DateField(
        required=False,
        widget=forms.DateInput(attrs={"type": "date"}),
    )
    target_type = forms.CharField(
        required=False,
        max_length=100,
    )

    def __init__(self, *args, actors, **kwargs):
        super().__init__(*args, **kwargs)

        user_model = get_user_model()
        self.fields["actor"].queryset = actors.order_by(
            user_model.USERNAME_FIELD
        )

    def clean(self):
        cleaned = super().clean()

        start_date = cleaned.get("start_date")
        end_date = cleaned.get("end_date")

        if start_date and end_date and start_date > end_date:
            self.add_error(
                "end_date",
                "End date must not precede start date.",
            )

        return cleaned