from decimal import Decimal

from django.conf import settings
from django.core.validators import MinValueValidator, MaxValueValidator
from django.db import models
from django.db.models import F, Q
from django.utils import timezone

from config.model_utils import TimestampedModel, protect_delete, require


class Training(TimestampedModel):
    code = models.CharField(max_length=40, unique=True)
    catalog_title = models.CharField(max_length=200)
    description = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)
    created_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT,
                                   related_name="created_trainings")

    def delete(self, *args, **kwargs):
        protect_delete("Archive trainings instead of deleting them.")

    def __str__(self):
        return self.catalog_title


class TrainingVersion(TimestampedModel):
    class Status(models.TextChoices):
        DRAFT = "DRAFT", "Draft"
        PUBLISHED = "PUBLISHED", "Published"
        RETIRED = "RETIRED", "Retired"

    training = models.ForeignKey(Training, on_delete=models.PROTECT, related_name="versions")
    version_number = models.PositiveIntegerField(validators=[MinValueValidator(1)])
    title = models.CharField(max_length=200)
    description = models.TextField(blank=True)
    learning_objectives = models.TextField(blank=True)
    change_summary = models.TextField(blank=True)
    status = models.CharField(max_length=12, choices=Status, default=Status.DRAFT)
    published_at = models.DateTimeField(null=True, blank=True)
    published_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT,
                                     null=True, blank=True, related_name="published_training_versions")
    created_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT,
                                   related_name="created_training_versions")

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["training", "version_number"], name="unique_training_version"),
            models.CheckConstraint(condition=Q(version_number__gte=1), name="training_version_positive"),
            models.CheckConstraint(condition=(Q(status="DRAFT", published_at__isnull=True, published_by__isnull=True) |
                Q(status__in=["PUBLISHED", "RETIRED"], published_at__isnull=False, published_by__isnull=False)),
                name="training_publication_fields"),
        ]
        indexes = [models.Index(fields=["training", "status"], name="training_version_status_idx")]

    def clean(self):
        super().clean()
        old = self.original()
        self.require_unchanged(old, ["training_id", "version_number"])
        if old and old.status != self.Status.DRAFT:
            self.require_frozen(old, except_fields=["status"])
            require(self.status == old.status or (old.status == self.Status.PUBLISHED and self.status == self.Status.RETIRED),
                    "Published versions may only transition to retired.")
        elif self.status != self.Status.DRAFT:
            require(self.status == self.Status.PUBLISHED and self.pk, "Create a draft before publishing.")
            require(self.assessments.filter(kind="FINAL").count() == 1, "Publication requires exactly one final assessment.")
            require(self.modules.exists(), "Publication requires at least one module.")
            for module in self.modules.all():
                require(module.lessons.exists(), "Every published module must contain a lesson.")
                for lesson in module.lessons.all():
                    lesson.full_clean()
            for assessment in self.assessments.all():
                assessment.validate_for_publication()

    def validate_delete(self):
        require(self.original().status == self.Status.DRAFT, "Published training versions cannot be deleted.")

    def __str__(self):
        return f"{self.title} v{self.version_number}"


class VersionContent(TimestampedModel):
    """Children share the version lock used by publication."""
    class Meta:
        abstract = True

    def get_version_id(self):
        raise NotImplementedError

    def lock_parents(self, using):
        TrainingVersion.objects.using(using).select_for_update().get(pk=self.get_version_id())

    def clean(self):
        super().clean()
        version = TrainingVersion.objects.get(pk=self.get_version_id())
        require(version.status == TrainingVersion.Status.DRAFT, "Published curriculum is immutable; create a new version.")

    def validate_delete(self):
        require(TrainingVersion.objects.get(pk=self.get_version_id()).status == TrainingVersion.Status.DRAFT,
                "Published curriculum cannot be deleted.")


class Module(VersionContent):
    training_version = models.ForeignKey(TrainingVersion, on_delete=models.PROTECT, related_name="modules")
    title = models.CharField(max_length=200)
    description = models.TextField(blank=True)
    position = models.PositiveIntegerField(validators=[MinValueValidator(1)])

    class Meta:
        ordering = ["position"]
        constraints = [models.UniqueConstraint(fields=["training_version", "position"], name="unique_module_position"),
                       models.CheckConstraint(condition=Q(position__gte=1), name="module_position_positive")]

    def get_version_id(self):
        return self.training_version_id

    def clean(self):
        super().clean()
        self.require_unchanged(self.original(), ["training_version_id"])


class Lesson(VersionContent):
    class ContentType(models.TextChoices):
        VIDEO = "VIDEO", "Video"
        TEXT = "TEXT", "Written lesson"

    module = models.ForeignKey(Module, on_delete=models.PROTECT, related_name="lessons")
    title = models.CharField(max_length=200)
    position = models.PositiveIntegerField(validators=[MinValueValidator(1)])
    content_type = models.CharField(max_length=5, choices=ContentType)
    body = models.TextField(blank=True)
    video_file = models.FileField(upload_to="training/videos/%Y/%m/", max_length=255, blank=True)
    video_duration_seconds = models.PositiveIntegerField(null=True, blank=True)
    video_checksum = models.CharField(max_length=64, blank=True)
    is_required = models.BooleanField(default=True)
    minimum_watch_percent = models.DecimalField(max_digits=5, decimal_places=2, default=Decimal("90.00"),
                                               validators=[MinValueValidator(0), MaxValueValidator(100)])

    class Meta:
        ordering = ["position"]
        constraints = [
            models.UniqueConstraint(fields=["module", "position"], name="unique_lesson_position"),
            models.CheckConstraint(condition=Q(position__gte=1), name="lesson_position_positive"),
            models.CheckConstraint(condition=Q(minimum_watch_percent__gte=0, minimum_watch_percent__lte=100), name="lesson_watch_percent_range"),
            models.CheckConstraint(condition=(
                (Q(content_type="TEXT", video_file="", video_duration_seconds__isnull=True, video_checksum="") & ~Q(body="")) |
                (Q(content_type="VIDEO", video_duration_seconds__isnull=False, video_duration_seconds__gt=0) & ~Q(video_file="") & ~Q(video_checksum=""))),
                name="lesson_content_fields"),
        ]

    def get_version_id(self):
        return Module.objects.values_list("training_version_id", flat=True).get(pk=self.module_id)

    def clean(self):
        super().clean()
        self.require_unchanged(self.original(), ["module_id"])
        if self.content_type == self.ContentType.TEXT:
            require(bool(self.body.strip()), "Written lessons need nonempty content.")
        elif self.content_type == self.ContentType.VIDEO:
            require(len(self.video_checksum) == 64 and all(c in "0123456789abcdef" for c in self.video_checksum),
                    "Video checksum must be a lowercase SHA-256 digest.")


class RoleTrainingRequirement(TimestampedModel):
    job_role = models.ForeignKey("organization.JobRole", on_delete=models.PROTECT, related_name="training_requirements")
    training_version = models.ForeignKey(TrainingVersion, on_delete=models.PROTECT, related_name="role_requirements")
    is_active = models.BooleanField(default=True)
    due_in_days = models.PositiveIntegerField(default=30)
    created_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name="created_role_requirements")

    class Meta:
        constraints = [models.UniqueConstraint(fields=["job_role", "training_version"], name="unique_role_training_version")]
        indexes = [models.Index(fields=["job_role", "is_active"], name="role_requirement_active_idx")]

    def clean(self):
        super().clean()
        self.require_unchanged(self.original(), ["job_role_id", "training_version_id"])
        if self.is_active:
            from organization.models import JobRole
            require(JobRole.objects.get(pk=self.job_role_id).is_active, "An active requirement needs an active job role.")
            require(TrainingVersion.objects.get(pk=self.training_version_id).status == TrainingVersion.Status.PUBLISHED,
                    "Requirements must target a published version.")

    def delete(self, *args, **kwargs):
        protect_delete("Deactivate training requirements instead of deleting them.")


class TrainingAssignment(TimestampedModel):
    class Status(models.TextChoices):
        ASSIGNED = "ASSIGNED", "Assigned"
        IN_PROGRESS = "IN_PROGRESS", "In progress"
        COMPLETED = "COMPLETED", "Completed"
        CANCELLED = "CANCELLED", "Cancelled"

    class Source(models.TextChoices):
        MANUAL = "MANUAL", "Manual"
        ROLE = "ROLE", "Job role"

    employee = models.ForeignKey("organization.Employee", on_delete=models.PROTECT, related_name="training_assignments")
    training_version = models.ForeignKey(TrainingVersion, on_delete=models.PROTECT, related_name="assignments")
    status = models.CharField(max_length=12, choices=Status, default=Status.ASSIGNED)
    source = models.CharField(max_length=6, choices=Source, default=Source.MANUAL)
    role_requirement = models.ForeignKey(RoleTrainingRequirement, on_delete=models.PROTECT, null=True, blank=True, related_name="assignments")
    department_at_assignment = models.ForeignKey("organization.Department", on_delete=models.PROTECT, related_name="historical_assignments")
    job_role_at_assignment = models.ForeignKey("organization.JobRole", on_delete=models.PROTECT, related_name="historical_assignments")
    assigned_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, null=True, blank=True, related_name="assigned_trainings")
    assigned_at = models.DateTimeField(default=timezone.now)
    due_at = models.DateTimeField(null=True, blank=True)
    started_at = models.DateTimeField(null=True, blank=True)
    completed_at = models.DateTimeField(null=True, blank=True)
    cancelled_at = models.DateTimeField(null=True, blank=True)
    cancellation_reason = models.TextField(blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["employee", "training_version"], name="unique_employee_version"),
            models.CheckConstraint(condition=(Q(source="MANUAL", role_requirement__isnull=True) | Q(source="ROLE", role_requirement__isnull=False)), name="assignment_source_fields"),
            models.CheckConstraint(condition=Q(due_at__isnull=True) | Q(due_at__gte=F("assigned_at")), name="assignment_due_order"),
            models.CheckConstraint(condition=Q(started_at__isnull=True) | Q(started_at__gte=F("assigned_at")), name="assignment_start_order"),
            models.CheckConstraint(condition=(Q(status="COMPLETED", started_at__isnull=False, completed_at__isnull=False, cancelled_at__isnull=True) |
                Q(status="CANCELLED", cancelled_at__isnull=False, completed_at__isnull=True) |
                Q(status__in=["ASSIGNED", "IN_PROGRESS"], completed_at__isnull=True, cancelled_at__isnull=True)), name="assignment_status_dates"),
            models.CheckConstraint(condition=Q(completed_at__isnull=True) | Q(completed_at__gte=F("started_at")), name="assignment_completion_order"),
            models.CheckConstraint(condition=Q(cancelled_at__isnull=True) | Q(cancelled_at__gte=F("assigned_at")), name="assignment_cancel_order"),
        ]
        indexes = [models.Index(fields=["employee", "status"], name="assignment_employee_status_idx"),
                   models.Index(fields=["status", "due_at"], name="assignment_due_idx"),
                   models.Index(fields=["training_version", "status"], name="assignment_version_status_idx")]

    def lock_parents(self, using):
        from organization.models import Employee
        Employee.objects.using(using).select_for_update().get(pk=self.employee_id)
        TrainingVersion.objects.using(using).select_for_update().get(pk=self.training_version_id)

    def clean(self):
        super().clean()
        old = self.original()
        if self.role_requirement_id:
            self.role_requirement = RoleTrainingRequirement.objects.get(pk=self.role_requirement_id)
        self.require_unchanged(old, ["employee_id", "training_version_id", "source", "role_requirement_id",
                                     "department_at_assignment_id", "job_role_at_assignment_id", "assigned_at", "assigned_by_id"])
        if old and old.status == self.Status.COMPLETED:
            self.require_frozen(old)
        if not old or (old.status == self.Status.CANCELLED and self.status != self.Status.CANCELLED):
            from organization.models import Employee
            employee = Employee.objects.get(pk=self.employee_id)
            require(employee.is_active, "Inactive employees cannot receive assignments.")
            require(TrainingVersion.objects.get(pk=self.training_version_id).status == TrainingVersion.Status.PUBLISHED,
                    "New or reopened assignments require a published version.")
            if not old:
                require(self.department_at_assignment_id == employee.department_id and self.job_role_at_assignment_id == employee.job_role_id,
                        "Assignment snapshots must match the employee's current department and role.")
            if self.role_requirement_id:
                require(self.role_requirement.is_active and self.role_requirement.job_role_id == employee.job_role_id,
                        "Role assignment requires an active requirement matching the employee's role.")
        if self.role_requirement_id:
            require(self.role_requirement.training_version_id == self.training_version_id, "Requirement and assignment versions must match.")
        if self.status == self.Status.CANCELLED:
            require(bool(self.cancellation_reason.strip()), "Cancellation requires a reason.")
        if self.status == self.Status.IN_PROGRESS:
            require(self.started_at is not None, "In-progress assignments need a start time.")
        if self.status == self.Status.COMPLETED:
            require(self.pk is not None, "Save an assignment before completing it.")
            required = Lesson.objects.filter(module__training_version_id=self.training_version_id, is_required=True)
            require(not required.exclude(pk__in=self.lesson_progress.filter(completed_at__isnull=False).values("lesson_id")).exists(),
                    "All required lessons must be completed.")
            assessments = self.training_version.assessments.filter(is_required=True)
            require(not assessments.exclude(pk__in=self.attempts.filter(status="SUBMITTED", passed=True).values("assessment_id")).exists(),
                    "All required assessments must be passed.")

    def delete(self, *args, **kwargs):
        protect_delete("Cancel assignments instead of deleting history.")


class AssignmentLessonRecord(TimestampedModel):
    class Meta:
        abstract = True

    def lock_parents(self, using):
        TrainingAssignment.objects.using(using).select_for_update().get(pk=self.assignment_id)

    def clean(self):
        super().clean()
        self.require_unchanged(self.original(), ["assignment_id", "lesson_id"])
        self.lesson = Lesson.objects.select_related("module").get(pk=self.lesson_id)
        assignment = TrainingAssignment.objects.select_related("employee").get(pk=self.assignment_id)
        require(self.lesson.module.training_version_id == assignment.training_version_id, "Lesson must belong to the assigned training version.")
        require(assignment.employee.is_active, "Inactive employees cannot record new progress.")
        require(assignment.status in [TrainingAssignment.Status.ASSIGNED, TrainingAssignment.Status.IN_PROGRESS],
                "Progress requires an open assignment.")

    def delete(self, *args, **kwargs):
        protect_delete("Learning history cannot be deleted.")


class LessonProgress(AssignmentLessonRecord):
    assignment = models.ForeignKey(TrainingAssignment, on_delete=models.PROTECT, related_name="lesson_progress")
    lesson = models.ForeignKey(Lesson, on_delete=models.PROTECT, related_name="employee_progress")
    started_at = models.DateTimeField(default=timezone.now)
    last_accessed_at = models.DateTimeField(default=timezone.now)
    last_position_seconds = models.DecimalField(max_digits=12, decimal_places=3, default=0, validators=[MinValueValidator(0)])
    watched_ranges = models.JSONField(default=list, blank=True)
    completed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["assignment", "lesson"], name="unique_assignment_lesson"),
                       models.CheckConstraint(condition=Q(last_position_seconds__gte=0), name="progress_position_nonnegative"),
                       models.CheckConstraint(condition=Q(last_accessed_at__gte=F("started_at")), name="progress_access_order"),
                       models.CheckConstraint(condition=Q(completed_at__isnull=True) | Q(completed_at__gte=F("started_at")), name="progress_completion_order")]
        indexes = [models.Index(fields=["assignment", "completed_at"], name="progress_completion_idx")]

    @property
    def watched_seconds(self):
        return sum((Decimal(str(end)) - Decimal(str(start)) for start, end in self.watched_ranges), Decimal(0))

    @property
    def progress_percent(self):
        if self.lesson.content_type == Lesson.ContentType.TEXT:
            return Decimal(100 if self.completed_at else 0)
        return min(Decimal(100), self.watched_seconds * 100 / self.lesson.video_duration_seconds)

    def clean(self):
        super().clean()
        old = self.original()
        self.require_unchanged(old, ["started_at"])
        if old:
            require(self.last_accessed_at >= old.last_accessed_at, "Last access time cannot move backwards.")
        if old and old.completed_at:
            self.require_unchanged(old, ["completed_at"])
        require(isinstance(self.watched_ranges, list), "Watched ranges must be a list of [start, end] intervals.")
        if self.lesson.content_type == Lesson.ContentType.TEXT:
            require(not self.watched_ranges and self.last_position_seconds == 0, "Written lessons cannot have video progress.")
            return
        duration = self.lesson.video_duration_seconds
        require(0 <= self.last_position_seconds <= duration, "Resume position must fall within the video.")
        previous_end = None
        for interval in self.watched_ranges:
            require(isinstance(interval, list) and len(interval) == 2 and
                    all(type(value) in (int, float) for value in interval), "Each watched interval must contain two numbers.")
            start, end = interval
            require(0 <= start < end <= duration, "Watched intervals must fall within the video.")
            require(previous_end is None or start > previous_end, "Watched intervals must be ordered and merged, without overlaps or touching endpoints.")
            previous_end = end
        if old:
            for old_start, old_end in old.watched_ranges:
                require(any(start <= old_start and end >= old_end for start, end in self.watched_ranges),
                        "Previously recorded video coverage cannot be discarded.")
        if self.completed_at:
            require(self.progress_percent >= self.lesson.minimum_watch_percent, "Video coverage is below the completion threshold.")


class VideoWatchSession(AssignmentLessonRecord):
    assignment = models.ForeignKey(TrainingAssignment, on_delete=models.PROTECT, related_name="video_watch_sessions")
    lesson = models.ForeignKey(Lesson, on_delete=models.PROTECT, related_name="watch_sessions")
    started_at = models.DateTimeField(default=timezone.now)
    ended_at = models.DateTimeField(null=True, blank=True)
    starting_position_seconds = models.DecimalField(max_digits=12, decimal_places=3, default=0, validators=[MinValueValidator(0)])
    ending_position_seconds = models.DecimalField(max_digits=12, decimal_places=3, null=True, blank=True, validators=[MinValueValidator(0)])
    active_watch_seconds = models.DecimalField(max_digits=12, decimal_places=3, default=0, validators=[MinValueValidator(0)])
    completed_normally = models.BooleanField(default=False)
    session_identifier = models.CharField(max_length=128, blank=True)
    device_identifier = models.CharField(max_length=128, blank=True)

    class Meta:
        constraints = [
            models.CheckConstraint(condition=Q(starting_position_seconds__gte=0, active_watch_seconds__gte=0), name="watch_session_nonnegative"),
            models.CheckConstraint(condition=Q(ending_position_seconds__isnull=True) | Q(ending_position_seconds__gte=0), name="watch_session_end_position"),
            models.CheckConstraint(condition=Q(ended_at__isnull=True) | Q(ended_at__gte=F("started_at")), name="watch_session_time_order"),
            models.CheckConstraint(condition=Q(completed_normally=False) | Q(ended_at__isnull=False), name="watch_session_normal_end"),
            models.CheckConstraint(condition=Q(ended_at__isnull=True) | Q(ending_position_seconds__isnull=False), name="watch_session_end_required"),
        ]
        indexes = [models.Index(fields=["assignment", "lesson", "started_at"], name="watch_session_history_idx"),
                   models.Index(fields=["session_identifier"], name="watch_session_identifier_idx")]

    def clean(self):
        super().clean()
        old = self.original()
        self.require_unchanged(old, ["started_at", "starting_position_seconds", "session_identifier", "device_identifier"])
        if old and old.ended_at:
            self.require_frozen(old)
        if old:
            require(self.active_watch_seconds >= old.active_watch_seconds, "Active watch time cannot decrease.")
        require(self.lesson.content_type == Lesson.ContentType.VIDEO, "Watch sessions require a video lesson.")
        duration = self.lesson.video_duration_seconds
        require(0 <= self.starting_position_seconds <= duration, "Starting position must fall within the video.")
        if self.ending_position_seconds is not None:
            require(0 <= self.ending_position_seconds <= duration, "Ending position must fall within the video.")
        if self.ended_at:
            elapsed = Decimal(str((self.ended_at - self.started_at).total_seconds()))
            require(0 <= self.active_watch_seconds <= elapsed, "Active watch time cannot exceed elapsed session time.")
        # Seeking backwards is allowed. Session duration is not unique content coverage.
