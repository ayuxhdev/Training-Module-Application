from django.urls import path

from . import views

app_name = "notifications"

urlpatterns = [
    path("", views.inbox, name="inbox"),
    path("read-all/", views.mark_all_read, name="mark-all-read"),
    path("<int:pk>/read/", views.mark_read, name="mark-read"),
]
