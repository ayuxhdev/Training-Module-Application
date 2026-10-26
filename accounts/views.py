from django.contrib.auth.views import LoginView, LogoutView
from django.contrib.auth.mixins import LoginRequiredMixin
from django.views.generic import TemplateView

from organization.models import Employee


class SignInView(LoginView):
	template_name = "registration/login.html"
	redirect_authenticated_user = True


class SignOutView(LogoutView):
	next_page = "/accounts/login/"


class ProfileView(LoginRequiredMixin, TemplateView):
    template_name = "accounts/profile.html"
    http_method_names = ["get", "head", "options"]

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        context["profile_employee"] = (
            Employee.objects.filter(user=self.request.user)
            .select_related("department", "job_role")
            .first()
        )
        return context
