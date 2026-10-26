from django.urls import path

from .views import ProfileView, SignInView, SignOutView

app_name = "accounts"

urlpatterns = [
    path("profile/", ProfileView.as_view(), name="profile"),
    path("login/", SignInView.as_view(), name="login"),
    path("logout/", SignOutView.as_view(), name="logout"),
]
