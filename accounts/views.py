from django.contrib.auth.views import LoginView, LogoutView


class SignInView(LoginView):
	template_name = "registration/login.html"
	redirect_authenticated_user = True


class SignOutView(LogoutView):
	next_page = "/accounts/login/"
