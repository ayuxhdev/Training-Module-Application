from datetime import timedelta

from django.contrib import messages
from django.contrib.auth.mixins import LoginRequiredMixin, PermissionRequiredMixin
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import IntegrityError, transaction
from django.http import Http404
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse, reverse_lazy
from django.utils import timezone
from django.views.generic import CreateView, DetailView, FormView, ListView, UpdateView

from organization.models import Employee
from organization.views import employee_scope

from .forms import (LessonForm, ModuleForm, RoleTrainingAssignmentForm, TrainingAssignmentForm,
					TrainingForm, TrainingVersionForm)
from .models import Lesson, Module, RoleTrainingRequirement, Training, TrainingAssignment, TrainingVersion


class ContentPermissionMixin(LoginRequiredMixin, PermissionRequiredMixin):
	raise_exception = True


ASSIGNMENT_MANAGE_PERMISSION = "training.add_trainingassignment"


def can_manage_assignments(user):
	return user.is_superuser or user.has_perm(ASSIGNMENT_MANAGE_PERMISSION)


class AssignmentAccessMixin(LoginRequiredMixin):
	raise_exception = True

	def dispatch(self, request, *args, **kwargs):
		if not (can_manage_assignments(request.user) or request.user.groups.filter(name__in=["Manager", "Employee"]).exists()):
			raise PermissionDenied
		return super().dispatch(request, *args, **kwargs)


def assignment_scope(user):
	if can_manage_assignments(user):
		return Employee.objects.all()
	return employee_scope(user)


class TrainingAssignmentListView(AssignmentAccessMixin, ListView):
	model = TrainingAssignment
	template_name = "training/assignment_list.html"
	context_object_name = "assignments"

	def get_queryset(self):
		return TrainingAssignment.objects.select_related(
			"employee", "training_version__training", "department_at_assignment", "job_role_at_assignment"
		).filter(employee__in=assignment_scope(self.request.user)).order_by("due_at", "pk")


class TrainingAssignmentDetailView(AssignmentAccessMixin, DetailView):
	model = TrainingAssignment
	template_name = "training/assignment_detail.html"
	context_object_name = "assignment"

	def get_queryset(self):
		return TrainingAssignment.objects.select_related(
			"employee", "training_version__training", "department_at_assignment", "job_role_at_assignment",
			"role_requirement", "assigned_by"
		).filter(employee__in=assignment_scope(self.request.user))


class TrainingAssignmentCreateView(LoginRequiredMixin, PermissionRequiredMixin, CreateView):
	permission_required = ASSIGNMENT_MANAGE_PERMISSION
	raise_exception = True
	form_class = TrainingAssignmentForm
	template_name = "training/assignment_form.html"

	def form_valid(self, form):
		try:
			self.object = form.save(assigned_by=self.request.user)
		except (ValidationError, IntegrityError) as exc:
			form.add_error(None, "This assignment could not be created: " + str(exc))
			return self.form_invalid(form)
		return redirect("training:assignment-detail", pk=self.object.pk)


class RoleTrainingAssignmentCreateView(LoginRequiredMixin, PermissionRequiredMixin, FormView):
	permission_required = ASSIGNMENT_MANAGE_PERMISSION
	raise_exception = True
	form_class = RoleTrainingAssignmentForm
	template_name = "training/role_assignment_form.html"

	def form_valid(self, form):
		requirement = form.cleaned_data["role_requirement"]
		matching_employees = Employee.objects.filter(job_role=requirement.job_role)
		employees = matching_employees.filter(is_active=True).select_related("department", "job_role")
		existing_ids = set(TrainingAssignment.objects.filter(
			employee__in=matching_employees, training_version=requirement.training_version
		).values_list("employee_id", flat=True))
		created = 0
		for employee in employees:
			if employee.pk in existing_ids:
				continue
			try:
				with transaction.atomic():
					TrainingAssignment.objects.create(
						employee=employee,
						training_version=requirement.training_version,
						source=TrainingAssignment.Source.ROLE,
						role_requirement=requirement,
						department_at_assignment=employee.department,
						job_role_at_assignment=employee.job_role,
						assigned_by=self.request.user,
						due_at=timezone.now() + timedelta(days=requirement.due_in_days),
					)
				created += 1
			except IntegrityError:
				existing_ids.add(employee.pk)
		skipped = matching_employees.count() - created
		messages.success(self.request, f"Created {created} assignment(s); skipped {skipped} existing or inactive employee(s).")
		return redirect("training:assignment-list")


class TrainingListView(ContentPermissionMixin, ListView):
	permission_required = "training.view_training"
	model = Training
	template_name = "training/training_list.html"
	context_object_name = "trainings"


class TrainingDetailView(ContentPermissionMixin, DetailView):
	permission_required = "training.view_training"
	model = Training
	template_name = "training/training_detail.html"
	context_object_name = "training"


class TrainingCreateView(ContentPermissionMixin, CreateView):
	permission_required = "training.add_training"
	model = Training
	form_class = TrainingForm
	template_name = "training/training_form.html"
	success_url = reverse_lazy("training:training-list")

	def form_valid(self, form):
		form.instance.created_by = self.request.user
		return super().form_valid(form)


class TrainingUpdateView(ContentPermissionMixin, UpdateView):
	permission_required = "training.change_training"
	model = Training
	form_class = TrainingForm
	template_name = "training/training_form.html"
	success_url = reverse_lazy("training:training-list")


class TrainingVersionListView(ContentPermissionMixin, ListView):
	permission_required = "training.view_trainingversion"
	model = TrainingVersion
	template_name = "training/version_list.html"
	context_object_name = "versions"

	def get_queryset(self):
		return TrainingVersion.objects.filter(training_id=self.kwargs["training_pk"]).order_by("-version_number")

	def get_context_data(self, **kwargs):
		context = super().get_context_data(**kwargs)
		context["training"] = get_object_or_404(Training, pk=self.kwargs["training_pk"])
		return context


class TrainingVersionDetailView(ContentPermissionMixin, DetailView):
	permission_required = "training.view_trainingversion"
	model = TrainingVersion
	template_name = "training/version_detail.html"
	context_object_name = "version"


class TrainingVersionCreateView(ContentPermissionMixin, CreateView):
	permission_required = "training.add_trainingversion"
	model = TrainingVersion
	form_class = TrainingVersionForm
	template_name = "training/version_form.html"

	def dispatch(self, request, *args, **kwargs):
		self.training = get_object_or_404(Training, pk=kwargs["training_pk"])
		return super().dispatch(request, *args, **kwargs)

	def get_form_kwargs(self):
		kwargs = super().get_form_kwargs()
		kwargs["instance"] = TrainingVersion(training=self.training)
		return kwargs

	def form_valid(self, form):
		form.instance.created_by = self.request.user
		return super().form_valid(form)

	def get_success_url(self):
		return reverse("training:version-detail", kwargs={"pk": self.object.pk})


class DraftVersionMixin(ContentPermissionMixin):
	def get_queryset(self):
		return super().get_queryset().filter(status=TrainingVersion.Status.DRAFT)


class TrainingVersionUpdateView(DraftVersionMixin, UpdateView):
	permission_required = "training.change_trainingversion"
	model = TrainingVersion
	form_class = TrainingVersionForm
	template_name = "training/version_form.html"

	def get_success_url(self):
		return reverse("training:version-detail", kwargs={"pk": self.object.pk})


class DraftModuleMixin(DraftVersionMixin):
	def get_version(self):
		return get_object_or_404(TrainingVersion, pk=self.kwargs["version_pk"], status=TrainingVersion.Status.DRAFT)

	def get_queryset(self):
		return Module.objects.filter(training_version=self.get_version())


class ModuleCreateView(DraftModuleMixin, CreateView):
	permission_required = "training.add_module"
	model = Module
	form_class = ModuleForm
	template_name = "training/module_form.html"

	def get_form_kwargs(self):
		kwargs = super().get_form_kwargs()
		kwargs["instance"] = Module(training_version=self.get_version())
		return kwargs

	def get_success_url(self):
		return reverse("training:version-detail", kwargs={"pk": self.object.training_version_id})


class ModuleUpdateView(DraftModuleMixin, UpdateView):
	permission_required = "training.change_module"
	model = Module
	form_class = ModuleForm
	template_name = "training/module_form.html"

	def get_queryset(self):
		return Module.objects.filter(training_version__status=TrainingVersion.Status.DRAFT)

	def get_success_url(self):
		return reverse("training:version-detail", kwargs={"pk": self.object.training_version_id})


class DraftLessonMixin(DraftVersionMixin):
	def get_module(self):
		return get_object_or_404(Module, pk=self.kwargs["module_pk"], training_version__status=TrainingVersion.Status.DRAFT)

	def get_queryset(self):
		return Lesson.objects.filter(module=self.get_module())


class LessonCreateView(DraftLessonMixin, CreateView):
	permission_required = "training.add_lesson"
	model = Lesson
	form_class = LessonForm
	template_name = "training/lesson_form.html"

	def get_form_kwargs(self):
		kwargs = super().get_form_kwargs()
		kwargs["instance"] = Lesson(module=self.get_module())
		return kwargs

	def get_success_url(self):
		return reverse("training:version-detail", kwargs={"pk": self.object.module.training_version_id})


class LessonUpdateView(DraftLessonMixin, UpdateView):
	permission_required = "training.change_lesson"
	model = Lesson
	form_class = LessonForm
	template_name = "training/lesson_form.html"

	def get_queryset(self):
		return Lesson.objects.filter(module__training_version__status=TrainingVersion.Status.DRAFT)

	def get_success_url(self):
		return reverse("training:version-detail", kwargs={"pk": self.object.module.training_version_id})


def publish_version(request, pk):
	if not request.user.is_authenticated or not request.user.has_perm("training.change_trainingversion"):
		raise PermissionDenied
	if request.method != "POST":
		raise Http404
	version = get_object_or_404(TrainingVersion, pk=pk, status=TrainingVersion.Status.DRAFT)
	version.status = TrainingVersion.Status.PUBLISHED
	version.published_at = timezone.now()
	version.published_by = request.user
	try:
		version.save()
	except ValidationError as exc:
		version.refresh_from_db()
		return render(request, "training/version_detail.html", {"version": version, "errors": exc}, status=400)
	return redirect("training:version-detail", pk=version.pk)


def retire_version(request, pk):
	if not request.user.is_authenticated or not request.user.has_perm("training.change_trainingversion"):
		raise PermissionDenied
	if request.method != "POST":
		raise Http404
	version = get_object_or_404(TrainingVersion, pk=pk, status=TrainingVersion.Status.PUBLISHED)
	version.status = TrainingVersion.Status.RETIRED
	version.save()
	return redirect("training:version-detail", pk=version.pk)
