from django import forms
from django.contrib.auth import get_user_model


class AuditLogFilterForm(forms.Form):
    actor = forms.ModelChoiceField(
        queryset=get_user_model().objects.none(),
        required=False,
        label="Performed by",
        help_text="Limit results to events attributed to this account. System events are not included.",
    )
    action = forms.CharField(
        required=False,
        max_length=80,
        label="Action",
        help_text="Show events whose recorded action contains this text.",
    )
    start_date = forms.DateField(
        required=False,
        widget=forms.DateInput(attrs={"type": "date"}),
        label="From date",
        help_text="Include events recorded on or after this date.",
    )
    end_date = forms.DateField(
        required=False,
        widget=forms.DateInput(attrs={"type": "date"}),
        label="Through date",
        help_text="Include events recorded on or before this date.",
    )
    target_type = forms.CharField(
        required=False,
        max_length=100,
        label="Record type",
        help_text="Match the exact record type shown in an event's full details, for example training.trainingversion.",
    )

    def __init__(self, *args, actors, **kwargs):
        super().__init__(*args, **kwargs)

        user_model = get_user_model()
        self.fields["actor"].queryset = actors.order_by(
            user_model.USERNAME_FIELD
        )
        for name, field in self.fields.items():
            if field.help_text:
                field.widget.attrs["aria-describedby"] = f"id_{name}_help"

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