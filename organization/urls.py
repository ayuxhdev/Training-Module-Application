from django.urls import path

from .views import (
    DepartmentCreateView,
    DepartmentListView,
    DepartmentUpdateView,
    EmployeeCreateView,
    EmployeeDetailView,
    EmployeeListView,
    EmployeeUpdateView,
    JobRoleCreateView,
    JobRoleListView,
    JobRoleUpdateView,
    deactivate_employee,
)

app_name = "organization"

urlpatterns = [
    path("employees/", EmployeeListView.as_view(), name="employee-list"),
    path("employees/new/", EmployeeCreateView.as_view(), name="employee-create"),
    path("employees/<int:pk>/", EmployeeDetailView.as_view(), name="employee-detail"),
    path("employees/<int:pk>/edit/", EmployeeUpdateView.as_view(), name="employee-update"),
    path("employees/<int:pk>/deactivate/", deactivate_employee, name="employee-deactivate"),
    path("departments/", DepartmentListView.as_view(), name="department-list"),
    path("departments/new/", DepartmentCreateView.as_view(), name="department-create"),
    path("departments/<int:pk>/edit/", DepartmentUpdateView.as_view(), name="department-update"),
    path("job-roles/", JobRoleListView.as_view(), name="job-role-list"),
    path("job-roles/new/", JobRoleCreateView.as_view(), name="job-role-create"),
    path("job-roles/<int:pk>/edit/", JobRoleUpdateView.as_view(), name="job-role-update"),
]
