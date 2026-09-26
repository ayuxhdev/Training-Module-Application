from django.contrib.auth.mixins import LoginRequiredMixin, PermissionRequiredMixin
from django.contrib.auth.decorators import login_required, permission_required
from django.core.exceptions import PermissionDenied
from django.http import Http404
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse_lazy
from django.views.generic import CreateView, DetailView, ListView, UpdateView

from audit.mixins import AuditedFormMixin
from audit.services import audit_snapshot, record_event
from .forms import DepartmentForm, EmployeeDeactivateForm, EmployeeForm, JobRoleForm, may_manage_linked_user
from .models import Department, Employee, JobRole


MANAGE_EMPLOYEES = "organization.change_employee"
VIEW_EMPLOYEES = "organization.view_employee"


def can_manage(user):
	return user.is_superuser or user.has_perm(MANAGE_EMPLOYEES)


def employee_scope(user):
	employee = Employee.objects.filter(user=user).first()
	if not employee:
		return Employee.objects.none()
	if not user.groups.filter(name="Manager").exists():
		return Employee.objects.filter(pk=employee.pk)
	ids = {employee.pk}
	pending = {employee.pk}
	while pending:
		child_ids = set(Employee.objects.filter(reporting_manager_id__in=pending).values_list("pk", flat=True)) - ids
		ids.update(child_ids)
		pending = child_ids
	return Employee.objects.filter(pk__in=ids)


class EmployeeListView(LoginRequiredMixin, ListView):
	model = Employee
	template_name = "organization/employee_list.html"
	context_object_name = "employees"

	def get_queryset(self):
		if not self.request.user.has_perm(VIEW_EMPLOYEES):
			return Employee.objects.none()
		queryset = Employee.objects.select_related("department", "job_role", "reporting_manager")
		if can_manage(self.request.user):
			return queryset
		return queryset.filter(pk__in=employee_scope(self.request.user).values("pk"))


class EmployeeDetailView(LoginRequiredMixin, DetailView):
	model = Employee
	template_name = "organization/employee_detail.html"
	context_object_name = "employee"

	def get_queryset(self):
		if not self.request.user.has_perm(VIEW_EMPLOYEES):
			return Employee.objects.none()
		queryset = Employee.objects.select_related("department", "job_role", "reporting_manager")
		return queryset if can_manage(self.request.user) else queryset.filter(
			pk__in=employee_scope(self.request.user).values("pk"))


class ManageEmployeeMixin(AuditedFormMixin, LoginRequiredMixin):
	permission_required = MANAGE_EMPLOYEES

	def dispatch(self, request, *args, **kwargs):
		if not (request.user.is_superuser or request.user.has_perm(self.permission_required)):
			raise Http404
		return super().dispatch(request, *args, **kwargs)

	def get_form_kwargs(self):
		kwargs = super().get_form_kwargs()
		if self.form_class is EmployeeForm:
			kwargs["actor"] = self.request.user
		return kwargs


class EmployeeCreateView(ManageEmployeeMixin, CreateView):
	permission_required = "organization.add_employee"
	model = Employee
	form_class = EmployeeForm
	template_name = "organization/employee_form.html"
	success_url = reverse_lazy("organization:employee-list")


class EmployeeUpdateView(ManageEmployeeMixin, UpdateView):
	model = Employee
	form_class = EmployeeForm
	template_name = "organization/employee_form.html"
	success_url = reverse_lazy("organization:employee-list")


@login_required
@permission_required(MANAGE_EMPLOYEES, raise_exception=True)
def deactivate_employee(request, pk):
	if request.method != "POST":
		raise Http404
	employee = get_object_or_404(Employee, pk=pk)
	if employee.user_id and not may_manage_linked_user(request.user, employee.user):
		raise PermissionDenied
	form = EmployeeDeactivateForm(request.POST)
	if not form.is_valid():
		return render(
			request,
			"organization/employee_detail.html",
			{"employee": employee, "form": form},
			status=400,
		)
	before = audit_snapshot(employee)
	employee.is_active = False
	employee.deactivation_reason = form.cleaned_data["reason"]
	employee.save()
	record_event(
		request.user,
		"organization.employee.deactivated",
		employee,
		before=before,
		after=audit_snapshot(employee),
	)
	return redirect("organization:employee-detail", pk=employee.pk)


class DepartmentListView(LoginRequiredMixin, PermissionRequiredMixin, ListView):
	permission_required = "organization.view_department"
	model = Department
	template_name = "organization/reference_list.html"
	context_object_name = "items"
	extra_context = {"title": "Departments", "create_url": "organization:department-create"}


class JobRoleListView(LoginRequiredMixin, PermissionRequiredMixin, ListView):
	permission_required = "organization.view_jobrole"
	model = JobRole
	template_name = "organization/reference_list.html"
	context_object_name = "items"
	extra_context = {"title": "Job roles", "create_url": "organization:job-role-create"}


class ManageDepartmentMixin(ManageEmployeeMixin):
	permission_required = "organization.change_department"


class DepartmentCreateView(ManageDepartmentMixin, CreateView):
	permission_required = "organization.add_department"
	model = Department
	form_class = DepartmentForm
	template_name = "organization/reference_form.html"
	success_url = reverse_lazy("organization:department-list")


class DepartmentUpdateView(ManageDepartmentMixin, UpdateView):
	model = Department
	form_class = DepartmentForm
	template_name = "organization/reference_form.html"
	success_url = reverse_lazy("organization:department-list")


class JobRoleCreateView(ManageDepartmentMixin, CreateView):
	permission_required = "organization.add_jobrole"
	model = JobRole
	form_class = JobRoleForm
	template_name = "organization/reference_form.html"
	success_url = reverse_lazy("organization:job-role-list")


class JobRoleUpdateView(ManageDepartmentMixin, UpdateView):
	model = JobRole
	form_class = JobRoleForm
	template_name = "organization/reference_form.html"
	success_url = reverse_lazy("organization:job-role-list")
