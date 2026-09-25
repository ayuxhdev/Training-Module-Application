from django.contrib.auth.mixins import LoginRequiredMixin, PermissionRequiredMixin
from django.core.exceptions import PermissionDenied, ValidationError
from django.http import Http404
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse, reverse_lazy
from django.utils import timezone
from django.views.generic import CreateView, DetailView, ListView, UpdateView

from .forms import LessonForm, ModuleForm, TrainingForm, TrainingVersionForm
from .models import Lesson, Module, Training, TrainingVersion


class ContentPermissionMixin(LoginRequiredMixin, PermissionRequiredMixin):
	raise_exception = True


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
