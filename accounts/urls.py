from django.urls import path

from .views import ProfileView, SignInView, SignOutView
from .system_admin import SystemDashboardView, SystemUserDetailView, SystemUserListView

app_name = "accounts"

urlpatterns = [
    path("system/", SystemDashboardView.as_view(), name="system-dashboard"),
    path("system/users/", SystemUserListView.as_view(), name="system-user-list"),
    path("system/users/<int:pk>/", SystemUserDetailView.as_view(), name="system-user-detail"),
    path("profile/", ProfileView.as_view(), name="profile"),
    path("login/", SignInView.as_view(), name="login"),
    path("logout/", SignOutView.as_view(), name="logout"),
]
