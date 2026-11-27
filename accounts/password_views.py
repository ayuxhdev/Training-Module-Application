from django.contrib import messages
from django.contrib.auth import update_session_auth_hash
from django.contrib.auth.mixins import LoginRequiredMixin
from django.core.exceptions import PermissionDenied, ValidationError
from django.urls import reverse_lazy
from django.utils.decorators import method_decorator
from django.views.decorators.cache import never_cache
from django.views.decorators.debug import sensitive_post_parameters
from django.views.generic import FormView

from .password_forms import OwnPasswordChangeForm
from .password_services import PasswordChangeThrottle, change_own_password, eligible_password_account


@method_decorator(never_cache, name="dispatch")
@method_decorator(sensitive_post_parameters(), name="dispatch")
class OwnPasswordChangeView(LoginRequiredMixin, FormView):
    template_name = "accounts/password_change.html"
    form_class = OwnPasswordChangeForm
    success_url = reverse_lazy("accounts:profile")
    http_method_names = ["get", "post", "head", "options"]

    def dispatch(self, request, *args, **kwargs):
        if request.user.is_authenticated and not eligible_password_account(request.user):
            raise PermissionDenied
        return super().dispatch(request, *args, **kwargs)

    def get_form_kwargs(self):
        return {**super().get_form_kwargs(), "user": self.request.user}

    def post(self, request, *args, **kwargs):
        throttle = PasswordChangeThrottle()
        if not throttle.allow_request(request, self):
            response = self.render_to_response(self.get_context_data(
                form=self.form_class(request.user),
                rate_limit_error="Too many password-change attempts. Wait a minute and try again.",
            ), status=429)
            response["Retry-After"] = str(max(1, int(throttle.wait() or 60)))
            return response
        return super().post(request, *args, **kwargs)

    def form_valid(self, form):
        try:
            user = change_own_password(self.request.user, form.data)
        except ValidationError as error:
            for field, errors in error.error_dict.items():
                form.add_error(field if field in form.fields else None, errors)
            return self.form_invalid(form)
        update_session_auth_hash(self.request, user)
        messages.success(self.request, "Password changed. Other sessions have ended; sign in again on Android.")
        return super().form_valid(form)
