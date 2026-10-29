"""Private local uploads with an owned cleanup boundary around the DB commit."""

import logging
import shutil
import tempfile
from pathlib import Path, PurePosixPath

from django.core.exceptions import ValidationError
from django.core.files.storage import FileSystemStorage
from django.db import transaction
from django.shortcuts import get_object_or_404

from audit.services import audit_snapshot, record_event
from training.forms import LessonForm
from training.models import Lesson, Module

from .training_management_services import _locked_draft


logger = logging.getLogger(__name__)


class VideoStorageUnavailable(Exception):
    pass


class _OwnedUpload:
    """Own an exclusive new directory, including any partial storage writes.

    No existing file is ever a cleanup candidate. Other storage backends need
    their own reviewed ownership/rollback contract rather than a guessed path.
    """

    def __init__(self, instance, uploaded):
        self.storage = instance.video_file.storage
        if not isinstance(self.storage, FileSystemStorage):
            raise VideoStorageUnavailable
        self.root = Path(self.storage.path("")).resolve()
        extension = uploaded.name.rsplit(".", 1)[-1].lower()
        field = instance._meta.get_field("video_file")
        generated = field.generate_filename(instance, "video." + extension).replace("\\", "/")
        self.parent = Path(self.storage.path(str(PurePosixPath(generated).parent))).resolve()
        if not self.parent.is_relative_to(self.root) or self.parent == self.root:
            raise VideoStorageUnavailable
        self.extension = extension
        self.directory = None

    def save(self, uploaded, max_length):
        self.parent.mkdir(parents=True, exist_ok=True)
        for _ in range(3):
            self.directory = Path(tempfile.mkdtemp(prefix="upload-", dir=self.parent)).resolve()
            self.prefix = self.directory.relative_to(self.root).as_posix() + "/"
            # A historical row may reference a missing directory. Never reuse
            # that key namespace and accidentally replace its missing media.
            if not Lesson.objects.filter(video_file__startswith=self.prefix).exists():
                break
            self.directory.rmdir()
            self.directory = None
        else:
            raise VideoStorageUnavailable
        self.key = self.prefix + "video." + self.extension
        name = self.storage.save(self.key, uploaded, max_length=max_length)
        if not name.startswith(self.prefix):
            raise VideoStorageUnavailable
        return name

    def cleanup_if_unreferenced(self):
        if self.directory is None:
            return
        try:
            # A commit failure can have an uncertain outcome. Never remove
            # media still referenced by a committed row; retain it if DB state
            # cannot be checked safely and request operational investigation.
            if Lesson.objects.filter(video_file__startswith=self.prefix).exists():
                return
            resolved = self.directory.resolve()
            if resolved != self.directory or resolved.parent != self.parent or not resolved.is_relative_to(self.root):
                raise VideoStorageUnavailable
            shutil.rmtree(resolved)
        except Exception:
            logger.error("Video upload cleanup requires investigation: operation %s", self.directory.name)


def _save_video(actor, version_id, module_id, values, lesson_id=None):
    owned = None
    try:
        # Finish the actual DB commit before reporting upload success. Reject
        # enclosing application transactions before any file can be created.
        with transaction.atomic(durable=True):
            _locked_draft(version_id)
            module = get_object_or_404(
                Module.objects.select_for_update(), pk=module_id, training_version_id=version_id,
            )
            creating = lesson_id is None
            if creating:
                instance = Lesson(module=module, content_type=Lesson.ContentType.VIDEO)
            else:
                instance = get_object_or_404(
                    Lesson.objects.select_for_update(), pk=lesson_id, module=module,
                    content_type=Lesson.ContentType.VIDEO,
                )
            before = {} if creating else audit_snapshot(instance)
            data = {field: getattr(instance, field) for field in LessonForm.Meta.fields}
            data.update({key: value for key, value in values.items() if key != "video_file"})
            data["content_type"] = Lesson.ContentType.VIDEO
            files = {"video_file": values["video_file"]} if "video_file" in values else None
            form = LessonForm(data=data, files=files, instance=instance)
            # Reuse the website's checksum, size/header and bounded ffprobe
            # inspection. It owns stream restoration and metadata validation.
            if not form.is_valid():
                raise ValidationError(dict(form.errors))
            changed = list(form.changed_data)
            if not creating and not changed:
                return instance
            instance = form.save(commit=False)
            if files:
                uploaded = form.cleaned_data["video_file"]
                try:
                    owned = _OwnedUpload(instance, uploaded)
                    name = owned.save(uploaded, instance._meta.get_field("video_file").max_length)
                    # Already stored through the configured storage abstraction;
                    # prevent FileField.pre_save() from writing a second copy.
                    instance.video_file = name
                except OSError as exc:
                    raise VideoStorageUnavailable from exc
            instance.save()
            record_event(
                actor, "training.lesson.created" if creating else "training.lesson.updated", instance,
                before=before, after={**audit_snapshot(instance), "changed_fields": changed},
            )
        return instance
    except BaseException:
        if owned is not None:
            owned.cleanup_if_unreferenced()
        raise


def create_video_lesson(actor, version_id, module_id, values):
    return _save_video(actor, version_id, module_id, values)


def update_video_lesson(actor, version_id, module_id, lesson_id, values):
    return _save_video(actor, version_id, module_id, values, lesson_id=lesson_id)
