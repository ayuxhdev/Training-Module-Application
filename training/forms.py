from datetime import datetime, time

from django import forms
from django.core.exceptions import NON_FIELD_ERRORS
from django.db import transaction
from django.db.models import Max
from django.utils import timezone

from .video_uploads import video_upload_metadata

from notifications.models import Notification
from notifications.services import create_assignment_notification
from .models import Lesson, Module, RoleTrainingRequirement, Training, TrainingAssignment, TrainingVersion
from organization.models import Employee, JobRole


class TrainingForm(forms.ModelForm):
    class Meta:
        model = Training
        fields = ["code", "catalog_title", "description", "is_active"]


class TrainingVersionForm(forms.ModelForm):
    class Meta:
        model = TrainingVersion
        fields = ["version_number", "title", "description", "learning_objectives", "change_summary"]

    def clean_version_number(self):
        number = self.cleaned_data["version_number"]
        if self.instance.training_id and TrainingVersion.objects.filter(
            training_id=self.instance.training_id, version_number=number
        ).exclude(pk=self.instance.pk).exists():
            raise forms.ValidationError("This training already has that version number.")
        return number


class ModuleForm(forms.ModelForm):
    position = forms.IntegerField(min_value=1, widget=forms.NumberInput(attrs={"step": "1"}))

    class Meta:
        model = Module
        fields = ["title", "description", "position"]

    def clean_position(self):
        position = self.cleaned_data["position"]
        if self.instance.training_version_id and Module.objects.filter(
            training_version_id=self.instance.training_version_id, position=position
        ).exclude(pk=self.instance.pk).exists():
            raise forms.ValidationError("This version already has a module at that position.")
        return position


class LessonForm(forms.ModelForm):
    position = forms.IntegerField(label="Lesson order", min_value=1, widget=forms.NumberInput(attrs={"step": "1"}))

    class Meta:
        model = Lesson
        fields = ["title", "content_type", "video_file", "body", "position", "is_required", "minimum_watch_percent"]
        labels = {"content_type": "Lesson type", "video_file": "Video file", "body": "Written content", "minimum_watch_percent": "Minimum watched (%)"}
        help_texts = {
            "video_file": "Choose MP4, WebM or MOV, up to 2 GB. Video length and integrity information are calculated automatically.",
            "body": "Required for written lessons.",
            "minimum_watch_percent": "Percentage of the video a learner must watch, confirmed by the server.",
        }
        widgets = {"video_file": forms.FileInput(attrs={"accept": ".mp4,.webm,.mov"})}
        error_messages = {"video_file": {"empty": "The selected file is empty. Choose a video file.", "invalid": "Choose a readable MP4, WebM or MOV video file."}}

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        if not self.instance.pk:
            self.initial["content_type"] = Lesson.ContentType.VIDEO
        if not self.instance.pk and self.instance.module_id:
            last = Lesson.objects.filter(module_id=self.instance.module_id).aggregate(last=Max("position"))["last"]
            self.initial["position"] = (last or 0) + 1

    def clean_position(self):
        position = self.cleaned_data["position"]
        if self.instance.module_id and Lesson.objects.filter(
            module_id=self.instance.module_id, position=position
        ).exclude(pk=self.instance.pk).exists():
            raise forms.ValidationError("This module already has a lesson at that position.")
        return position

    def clean(self):
        cleaned = super().clean()
        if cleaned.get("content_type") == Lesson.ContentType.TEXT:
            if not cleaned.get("body", "").strip():
                self.add_error("body", "Enter the written lesson content.")
            cleaned["video_file"] = ""
            self.instance.video_duration_seconds = None
            self.instance.video_checksum = ""
        elif cleaned.get("content_type") == Lesson.ContentType.VIDEO:
            uploaded = cleaned.get("video_file") if "video_file" in self.files else None
            if uploaded and "video_file" not in self.errors:
                try:
                    checksum, duration = video_upload_metadata(uploaded)
                except forms.ValidationError as exc:
                    self.add_error("video_file", exc)
                else:
                    self.instance.video_checksum = checksum
                    self.instance.video_duration_seconds = duration
            elif not self.instance.video_file and "video_file" not in self.errors:
                self.add_error("video_file", "Choose a video file for this lesson.")
        return cleaned

    def _update_errors(self, errors):
        messages = {
            "Video checksum must be a lowercase SHA-256 digest.": "The saved video's integrity information is unavailable. Upload a replacement video.",
            "Video file size could not be determined.": "The saved video could not be read. Upload a replacement or contact your administrator.",
            "Video files cannot exceed 2GB.": "Choose a video no larger than 2 GB.",
            "Uploaded file must be a valid video format.": "The video could not be read as a supported format. Upload a new MP4, WebM or MOV video.",
            "Supported video formats are MP4, WebM, and MOV.": "Choose an MP4, WebM or MOV video file.",
        }
        error_dict = errors.error_dict if hasattr(errors, "error_dict") else {NON_FIELD_ERRORS: errors.error_list}
        remaining = {}
        for field, field_errors in error_dict.items():
            for error in field_errors:
                if field == NON_FIELD_ERRORS and error.message in messages:
                    self.add_error("video_file", messages[error.message])
                else:
                    remaining.setdefault(field, []).append(error)
        if remaining:
            super()._update_errors(forms.ValidationError(remaining))

    def _post_clean(self):
        # Invalid input already has field errors; don't add secondary constraint errors.
        if not self._errors:
            super()._post_clean()


class TrainingAssignmentForm(forms.ModelForm):
    due_date = forms.DateField(
        required=False,
        widget=forms.DateInput(attrs={"type": "date"}),
        help_text="Optional. Due at the end of the selected day.",
    )

    class Meta:
        model = TrainingAssignment
        fields = ["employee", "training_version", "due_date"]

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["employee"].queryset = Employee.objects.filter(is_active=True).select_related("department", "job_role")
        self.fields["employee"].empty_label = "Select an employee"
        self.fields["training_version"].queryset = TrainingVersion.objects.filter(
            status=TrainingVersion.Status.PUBLISHED,
        ).select_related("training")
        self.fields["training_version"].empty_label = "Select a training version"
        self.fields["training_version"].label_from_instance = lambda version: (
            f"{version.training.catalog_title} — {version.title} "
            f"(v{version.version_number}, {version.get_status_display()})"
        )

    def _post_clean(self):
        if self._errors:
            return
        super()._post_clean()

    def clean(self):
        cleaned = super().clean()
        employee = cleaned.get("employee")
        version = cleaned.get("training_version")
        if employee and not employee.is_active:
            self.add_error("employee", "Inactive employees cannot receive assignments.")
        if version and version.status != TrainingVersion.Status.PUBLISHED:
            self.add_error("training_version", "Assignments require a published training version.")
        if employee and version and TrainingAssignment.objects.filter(employee=employee, training_version=version).exists():
            raise forms.ValidationError("This employee already has an assignment for that training version.")
        due_date = cleaned.get("due_date")
        if due_date:
            due_at = timezone.make_aware(datetime.combine(due_date, time.max))
            if due_at < timezone.now():
                self.add_error("due_date", "The due date cannot be in the past.")
        if employee:
            self.instance.department_at_assignment = employee.department
            self.instance.job_role_at_assignment = employee.job_role
        return cleaned

    def save(self, commit=True, *, assigned_by):
        assignment = super().save(commit=False)
        assignment.source = TrainingAssignment.Source.MANUAL
        assignment.assigned_by = assigned_by
        assignment.department_at_assignment = assignment.employee.department
        assignment.job_role_at_assignment = assignment.employee.job_role
        if self.cleaned_data.get("due_date"):
            assignment.due_at = timezone.make_aware(
                datetime.combine(self.cleaned_data["due_date"], time.max)
            )
        if commit:
            with transaction.atomic():
                creating = assignment._state.adding
                assignment.save()
                if creating:
                    create_assignment_notification(assignment.pk, Notification.EventType.ASSIGNED)
        return assignment


class RoleTrainingAssignmentForm(forms.Form):
    role_requirement = forms.ModelChoiceField(
        queryset=RoleTrainingRequirement.objects.none(),
        empty_label="Select a job-role requirement",
    )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["role_requirement"].queryset = RoleTrainingRequirement.objects.filter(
            is_active=True,
            training_version__status=TrainingVersion.Status.PUBLISHED,
        ).select_related("job_role", "training_version__training")
        self.fields["role_requirement"].label_from_instance = lambda requirement: (
            f"{requirement.job_role.name} → "
            f"{requirement.training_version.training.catalog_title} / "
            f"{requirement.training_version.title} (v{requirement.training_version.version_number}, "
            f"due in {requirement.due_in_days} days)"
        )


class RoleTrainingRequirementCreateForm(forms.ModelForm):
    class Meta:
        model = RoleTrainingRequirement
        fields = ["job_role", "training_version", "due_in_days", "is_active"]

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["job_role"].queryset = JobRole.objects.filter(is_active=True).order_by("name")
        self.fields["training_version"].queryset = TrainingVersion.objects.filter(
            status=TrainingVersion.Status.PUBLISHED,
        ).select_related("training").order_by("training__catalog_title", "version_number")
        self.fields["training_version"].label_from_instance = lambda version: (
            f"{version.training.catalog_title} — {version.title} (v{version.version_number})"
        )

    def _post_clean(self):
        if self._errors:
            return
        super()._post_clean()


class RoleTrainingRequirementUpdateForm(forms.ModelForm):
    class Meta:
        model = RoleTrainingRequirement
        fields = ["due_in_days", "is_active"]
