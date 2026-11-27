from django.urls import path

from . import views


app_name = "reports"

urlpatterns = [
	path("", views.dashboard, name="dashboard"),
	path("reports/assignments/export/", views.assignment_report_export, name="assignment-report-export"),
	path("reports/assignments/", views.assignment_report, name="assignment-report"),
]