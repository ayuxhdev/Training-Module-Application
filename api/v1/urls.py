from django.urls import path, re_path

from .views import APINotFoundView, APIStatusView
from .auth_views import EmployeeLoginView, EmployeeRefreshView, EmployeeLogoutView, EmployeeMeView
from .dashboard_views import EmployeeDashboardView
from .learning_views import (
	AssignmentDetailView,
	AssignmentListView,
	LessonProgressView,
	TextLessonCompletionView,
	VideoSessionEndView,
	VideoSessionMediaView,
	VideoSessionStartView,
)

app_name = "v1"

urlpatterns = [
    path("status/", APIStatusView.as_view(), name="status"),
    path("auth/login/", EmployeeLoginView.as_view(), name="auth-login"),
    path("auth/refresh/", EmployeeRefreshView.as_view(), name="auth-refresh"),
    path("auth/logout/", EmployeeLogoutView.as_view(), name="auth-logout"),
    path("auth/me/", EmployeeMeView.as_view(), name="auth-me"),
    path("dashboard/", EmployeeDashboardView.as_view(), name="dashboard"),
    path("assignments/", AssignmentListView.as_view(), name="assignment-list"),
    path("assignments/<int:assignment_id>/", AssignmentDetailView.as_view(), name="assignment-detail"),
    path(
        "assignments/<int:assignment_id>/lessons/<int:lesson_id>/progress/",
        LessonProgressView.as_view(), name="lesson-progress",
    ),
    path(
        "assignments/<int:assignment_id>/lessons/<int:lesson_id>/complete/",
        TextLessonCompletionView.as_view(), name="lesson-complete",
    ),
    path(
        "assignments/<int:assignment_id>/lessons/<int:lesson_id>/sessions/",
        VideoSessionStartView.as_view(), name="video-session-start",
    ),
    path(
        "assignments/<int:assignment_id>/lessons/<int:lesson_id>/sessions/<int:session_id>/media/",
        VideoSessionMediaView.as_view(), name="video-session-media",
    ),
    path(
        "assignments/<int:assignment_id>/lessons/<int:lesson_id>/sessions/<int:session_id>/end/",
        VideoSessionEndView.as_view(), name="video-session-end",
    ),
    re_path(r"^.*$", APINotFoundView.as_view(), name="not-found"),
]
