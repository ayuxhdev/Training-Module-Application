from django import forms

from .models import Lesson, Module, Training, TrainingVersion


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
    class Meta:
        model = Lesson
        fields = [
            "title", "position", "content_type", "body", "video_file",
            "video_duration_seconds", "video_checksum", "is_required", "minimum_watch_percent",
        ]
        widgets = {"video_file": forms.FileInput()}

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
            cleaned["video_file"] = ""
            cleaned["video_duration_seconds"] = None
            cleaned["video_checksum"] = ""
        return cleaned
