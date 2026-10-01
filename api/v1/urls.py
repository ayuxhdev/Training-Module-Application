from django.urls import path, re_path

from .views import APINotFoundView, APIStatusView

app_name = "v1"

urlpatterns = [
    path("status/", APIStatusView.as_view(), name="status"),
    re_path(r"^.*$", APINotFoundView.as_view(), name="not-found"),
]

