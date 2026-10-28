"""Website-only, read-only account oversight for active Django Superusers."""

from django import forms
from django.contrib.auth import get_user_model
from django.contrib.auth.mixins import LoginRequiredMixin
from django.contrib.auth.models import Group
from django.core.exceptions import PermissionDenied
from django.db.models import Count, Prefetch, Q, Value
from django.db.models.functions import Concat
from django.utils.decorators import method_decorator
from django.views.decorators.cache import never_cache
from django.views.generic import DetailView, ListView, TemplateView


class ActiveSuperuserRequiredMixin(LoginRequiredMixin):
    http_method_names = ["get", "head", "options"]

    @method_decorator(never_cache)
    def dispatch(self, request, *args, **kwargs):
        if not request.user.is_authenticated:
            return self.handle_no_permission()
        if not request.user.is_active or not request.user.is_superuser:
            raise PermissionDenied
        response = super().dispatch(request, *args, **kwargs)
        response["X-Robots-Tag"] = "noindex, nofollow"
        return response


def account_directory_queryset():
    # Explicit projection: no target password hashes, permissions or credentials
    # are fetched by the directory/detail queries.
    return get_user_model().objects.only(
        "id", "username", "first_name", "last_name", "email", "is_active",
        "is_staff", "is_superuser", "last_login", "date_joined",
        "employee__id", "employee__user_id", "employee__employee_code",
        "employee__display_name",
    ).select_related("employee").prefetch_related(
        Prefetch("groups", queryset=Group.objects.only("id", "name").order_by("name", "pk")),
    ).order_by("username", "pk")


class SystemDashboardView(ActiveSuperuserRequiredMixin, TemplateView):
    template_name = "accounts/system_admin/dashboard.html"

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        context["account_stats"] = get_user_model().objects.aggregate(
            total=Count("pk"),
            active=Count("pk", filter=Q(is_active=True)),
            inactive=Count("pk", filter=Q(is_active=False)),
            staff=Count("pk", filter=Q(is_staff=True)),
            superusers=Count("pk", filter=Q(is_superuser=True)),
            linked=Count("pk", filter=Q(employee__isnull=False)),
            unlinked=Count("pk", filter=Q(employee__isnull=True)),
        )
        return context


class UserDirectorySearchForm(forms.Form):
    q = forms.CharField(
        label="Search user accounts", required=False, max_length=150,
        help_text="Search username, name, email or linked Employee code/name.",
        widget=forms.TextInput(attrs={"type": "search", "autocomplete": "off"}),
    )


class SystemUserListView(ActiveSuperuserRequiredMixin, ListView):
    template_name = "accounts/system_admin/user_list.html"
    context_object_name = "accounts"
    paginate_by = 25

    def get_queryset(self):
        self.search_form = UserDirectorySearchForm(self.request.GET)
        queryset = account_directory_queryset()
        if not self.search_form.is_valid():
            return queryset.none()
        value = self.search_form.cleaned_data["q"]
        if value:
            queryset = queryset.alias(
                search_name=Concat("first_name", Value(" "), "last_name"),
            ).filter(
                Q(username__icontains=value) | Q(first_name__icontains=value)
                | Q(last_name__icontains=value) | Q(search_name__icontains=value)
                | Q(email__icontains=value)
                | Q(employee__employee_code__icontains=value)
                | Q(employee__display_name__icontains=value)
            )
        return queryset

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        context["search_form"] = self.search_form
        context["search_term"] = self.search_form.cleaned_data.get("q", "")
        return context

    def render_to_response(self, context, **response_kwargs):
        if self.search_form.errors:
            response_kwargs["status"] = 400
        return super().render_to_response(context, **response_kwargs)


class SystemUserDetailView(ActiveSuperuserRequiredMixin, DetailView):
    template_name = "accounts/system_admin/user_detail.html"
    context_object_name = "account"

    def get_queryset(self):
        return account_directory_queryset()
