from django.urls import path, re_path

from .views import APINotFoundView, APIStatusView
from .auth_views import EmployeeLoginView, EmployeeRefreshView, EmployeeLogoutView, EmployeeMeView
from .dashboard_views import EmployeeDashboardView
from .management_views import (
    DepartmentReferenceUpdateView, DepartmentReferenceView, EmployeeDeactivationView,
    EmployeeDirectoryDetailView, EmployeeDirectoryView,
    JobRoleReferenceUpdateView, JobRoleReferenceView, ManagementDashboardView,
)
from .certificate_views import CertificateDetailView, CertificateListView
from .notification_views import (
    NotificationListView,
    NotificationReadAllView,
    NotificationReadView,
    NotificationUnreadCountView,
)
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
    path("management/dashboard/", ManagementDashboardView.as_view(), name="management-dashboard"),
    path("management/employees/", EmployeeDirectoryView.as_view(), name="management-employees"),
    path("management/employees/<int:pk>/", EmployeeDirectoryDetailView.as_view(), name="management-employee-detail"),
    path("management/employees/<int:pk>/deactivate/", EmployeeDeactivationView.as_view(), name="management-employee-deactivate"),
    path("management/departments/", DepartmentReferenceView.as_view(), name="management-departments"),
    path("management/departments/<int:pk>/", DepartmentReferenceUpdateView.as_view(), name="management-department-update"),
    path("management/job-roles/", JobRoleReferenceView.as_view(), name="management-job-roles"),
    path("management/job-roles/<int:pk>/", JobRoleReferenceUpdateView.as_view(), name="management-job-role-update"),
    path("notifications/", NotificationListView.as_view(), name="notification-list"),
    path("notifications/unread-count/", NotificationUnreadCountView.as_view(), name="notification-unread-count"),
    path("notifications/read-all/", NotificationReadAllView.as_view(), name="notification-read-all"),
    path("notifications/<int:notification_id>/read/", NotificationReadView.as_view(), name="notification-read"),
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
