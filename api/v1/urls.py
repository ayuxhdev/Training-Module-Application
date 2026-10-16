from django.urls import path, re_path

from .views import APINotFoundView, APIStatusView
from .auth_views import EmployeeLoginView, EmployeeRefreshView, EmployeeLogoutView, EmployeeMeView
from .dashboard_views import EmployeeDashboardView
from .certificate_views import CertificateDetailView, CertificateListView
from .assessment_views import (
    AssessmentAttemptDetailView,
    AssessmentListView,
    AssessmentStartView,
    AssessmentSubmitView,
)
from .learning_views import (
	AssignmentDetailView,
	AssignmentListView,
	LessonProgressView,
	TextLessonCompletionView,
	VideoSessionEndView,
	VideoSessionMediaView,
    
	VideoSessionStartView,
	VideoReplayMediaView,
)

app_name = "v1"

urlpatterns = [
    path("status/", APIStatusView.as_view(), name="status"),
    path("auth/login/", EmployeeLoginView.as_view(), name="auth-login"),
    path("auth/refresh/", EmployeeRefreshView.as_view(), name="auth-refresh"),
    path("auth/logout/", EmployeeLogoutView.as_view(), name="auth-logout"),
    path("auth/me/", EmployeeMeView.as_view(), name="auth-me"),
    path("dashboard/", EmployeeDashboardView.as_view(), name="dashboard"),
    path("certificates/", CertificateListView.as_view(), name="certificate-list"),
    path("certificates/<int:certificate_id>/", CertificateDetailView.as_view(), name="certificate-detail"),
    path("assignments/", AssignmentListView.as_view(), name="assignment-list"),
    path("assignments/<int:assignment_id>/", AssignmentDetailView.as_view(), name="assignment-detail"),
    path(
        "assignments/<int:assignment_id>/assessments/",
        AssessmentListView.as_view(), name="assessment-list",
    ),
    path(
        "assignments/<int:assignment_id>/assessments/<int:assessment_id>/attempts/",
        AssessmentStartView.as_view(), name="assessment-start",
    ),
    path(
        "assessment-attempts/<int:attempt_id>/",
        AssessmentAttemptDetailView.as_view(), name="assessment-attempt-detail",
    ),
    path(
        "assessment-attempts/<int:attempt_id>/submit/",
        AssessmentSubmitView.as_view(), name="assessment-submit",
    ),
    path(
        "assignments/<int:assignment_id>/lessons/<int:lesson_id>/progress/",
        LessonProgressView.as_view(), name="lesson-progress",
    ),
    path(
        "assignments/<int:assignment_id>/lessons/<int:lesson_id>/complete/",
        TextLessonCompletionView.as_view(), name="lesson-complete",
    ),
    path(
        "assignments/<int:assignment_id>/lessons/<int:lesson_id>/replay/media/",
        VideoReplayMediaView.as_view(), name="video-replay-media",
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
