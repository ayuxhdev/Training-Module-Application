from django.urls import path, re_path

from .views import APINotFoundView, APIStatusView
from .auth_views import EmployeeLoginView, EmployeeRefreshView, EmployeeLogoutView, EmployeeMeView

app_name = "v1"

urlpatterns = [
    path("status/", APIStatusView.as_view(), name="status"),
    path("auth/login/", EmployeeLoginView.as_view(), name="auth-login"),
    path("auth/refresh/", EmployeeRefreshView.as_view(), name="auth-refresh"),
    path("auth/logout/", EmployeeLogoutView.as_view(), name="auth-logout"),
    path("auth/me/", EmployeeMeView.as_view(), name="auth-me"),
    re_path(r"^.*$", APINotFoundView.as_view(), name="not-found"),
]
