from django.contrib.auth.mixins import LoginRequiredMixin, PermissionRequiredMixin
from django.contrib.auth.decorators import login_required, permission_required
from django.core.exceptions import PermissionDenied
from django.db import transaction
from django.http import Http404, HttpResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse_lazy
from django.views.generic import CreateView, DetailView, ListView, UpdateView

from audit.mixins import AuditedFormMixin
from audit.services import audit_snapshot, record_event
from .forms import DepartmentForm, EmployeeDeactivateForm, EmployeeForm, JobRoleForm, may_manage_linked_user
from .models import Department, Employee, JobRole
from .scopes import employee_scope


MANAGE_EMPLOYEES = "organization.change_employee"
VIEW_EMPLOYEES = "organization.view_employee"


def can_manage(user):
	return user.is_superuser or user.has_perm(MANAGE_EMPLOYEES)


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

	def post(self, request, *args, **kwargs):
		with transaction.atomic():
			if request.POST.get("reporting_manager"):
				# Match Employee.lock_parents(): hierarchy before target, before User.
				list(Employee.objects.order_by("pk").select_for_update().values_list("pk", flat=True))
			return super().post(request, *args, **kwargs)

	def get_queryset(self):
		queryset = super().get_queryset()
		# Build and validate the form from the current locked state, not a stale
		# instance that could overwrite a concurrent deactivation or profile edit.
		return queryset.select_for_update() if self.request.method == "POST" else queryset


@login_required
@permission_required(MANAGE_EMPLOYEES, raise_exception=True)
def deactivate_employee(request, pk):
	if request.method != "POST":
		raise Http404
	with transaction.atomic():
		employee = get_object_or_404(Employee.objects.select_for_update(), pk=pk)
		if employee.user_id and employee.user_id == request.user.pk:
			raise PermissionDenied
		if employee.user_id and not may_manage_linked_user(request.user, employee.user):
			raise PermissionDenied
		if not employee.is_active:
			return HttpResponse("This employee is already inactive.", status=409)
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

	def get_context_data(self, **kwargs):
		context = super().get_context_data(**kwargs)
		if self.model is Department:
			context.update(reference_name="department", reference_list_url="organization:department-list")
		else:
			context.update(reference_name="job role", reference_list_url="organization:job-role-list")
		context["reference_edit"] = self.object is not None
		return context


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
