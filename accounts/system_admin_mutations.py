"""CSRF-protected website forms for controlled, inactive account provisioning."""

from django.contrib import messages
from django.core.exceptions import ValidationError
from django.shortcuts import get_object_or_404
from django.urls import reverse
from django.views.generic import FormView

from .system_admin import ActiveSuperuserRequiredMixin, account_directory_queryset
from .system_admin_forms import (
    CreateSystemUserForm, SystemUserEmployeeLinkForm, SystemUserGroupsForm,
)
from .system_admin_services import (
    create_system_user, ensure_editable_target, link_system_user_employee,
    update_system_user_groups,
)


class SystemAccountFormView(ActiveSuperuserRequiredMixin, FormView):
    # GET only displays a form; only POST can save.
    http_method_names = ["get", "post", "head", "options"]
    template_name = "accounts/system_admin/form.html"

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        context["screen_title"] = self.screen_title
        context["submit_label"] = self.submit_label
        return context

    def invalid_operation(self, form, error):
        if hasattr(error, "message_dict"):
            for field, errors in error.message_dict.items():
                form.add_error(field if field in form.fields else None, errors)
        else:
            form.add_error(None, error.messages)
        return self.form_invalid(form)

    def form_invalid(self, form):
        return self.render_to_response(self.get_context_data(form=form), status=400)

    def get_success_url(self):
        return reverse("accounts:system-user-detail", args=[self.target.pk])


class SystemUserCreateView(SystemAccountFormView):
    form_class = CreateSystemUserForm
    screen_title = "Create user account"
    submit_label = "Create inactive account"

    def form_valid(self, form):
        try:
            self.target = create_system_user(self.request.user, form.cleaned_data)
        except ValidationError as error:
            return self.invalid_operation(form, error)
        messages.success(
            self.request,
            "Account created inactive, with password sign-in disabled. Credential setup and activation are not available in this stage.",
        )
        return super().form_valid(form)


class SystemTargetFormView(SystemAccountFormView):
    def get_form_kwargs(self):
        self.target = get_object_or_404(account_directory_queryset(), pk=self.kwargs["pk"])
        ensure_editable_target(self.request.user, self.target)
        return {**super().get_form_kwargs(), "target": self.target}

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        context["account"] = self.target
        return context


class SystemUserGroupsView(SystemTargetFormView):
    form_class = SystemUserGroupsForm
    screen_title = "Edit business Groups"
    submit_label = "Save business Groups"

    def form_valid(self, form):
        try:
            changed = update_system_user_groups(self.request.user, self.target.pk, form.cleaned_data["groups"])
        except ValidationError as error:
            return self.invalid_operation(form, error)
        if changed:
            messages.success(self.request, "Business Group memberships updated. Other memberships and direct permissions were preserved.")
        else:
            messages.info(self.request, "No business Group memberships changed.")
        return super().form_valid(form)


class SystemUserEmployeeLinkView(SystemTargetFormView):
    form_class = SystemUserEmployeeLinkForm
    screen_title = "Link existing Employee"
    submit_label = "Confirm Employee link"

    def form_valid(self, form):
        try:
            link_system_user_employee(self.request.user, self.target.pk, form.cleaned_data["employee"].pk)
        except ValidationError as error:
            return self.invalid_operation(form, error)
        messages.success(self.request, "Employee linked. Account status, reporting hierarchy and business Groups were preserved.")
        return super().form_valid(form)
