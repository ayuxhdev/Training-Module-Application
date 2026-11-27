from django.contrib.auth.forms import PasswordChangeForm
from django.contrib.auth.hashers import check_password
from django.core.validators import MaxLengthValidator
from django.core.exceptions import ValidationError
from django.views.decorators.debug import sensitive_variables


class OwnPasswordChangeForm(PasswordChangeForm):
    """Use Django policy, preserving password whitespace and hiding bound values."""

    def __init__(self, user, *args, **kwargs):
        super().__init__(user, *args, **kwargs)
        self.fields["old_password"].label = "Current password"
        for field in self.fields.values():
            field.validators.append(MaxLengthValidator(4096))
            field.max_length = 4096
            field.widget.attrs["maxlength"] = 4096

    @sensitive_variables()
    def clean_old_password(self):
        password = self.cleaned_data["old_password"]
        # Form validation must never rehash/save an unlocked, stale User. The
        # service revalidates and saves only after acquiring the account lock.
        if not check_password(password, self.user.password):
            raise ValidationError(self.error_messages["password_incorrect"], code="password_incorrect")
        return password

    @sensitive_variables()
    def clean_new_password1(self):
        password = self.cleaned_data["new_password1"]
        if check_password(password, self.user.password):
            raise ValidationError("Choose a password different from your current password.", code="password_unchanged")
        return password
