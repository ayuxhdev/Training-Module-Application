from django.urls import path

from .views import (
    LessonCreateView,
    LessonUpdateView,
    ModuleCreateView,
    ModuleUpdateView,
    TrainingCreateView,
    TrainingDetailView,
    TrainingListView,
    TrainingUpdateView,
    TrainingVersionCreateView,
    TrainingVersionDetailView,
    TrainingVersionListView,
    TrainingVersionUpdateView,
    RoleTrainingAssignmentCreateView,
    TrainingAssignmentCreateView,
    TrainingAssignmentDetailView,
    TrainingAssignmentListView,
    publish_version,
    retire_version,
)

app_name = "training"

urlpatterns = [
    path("assignments/", TrainingAssignmentListView.as_view(), name="assignment-list"),
    path("assignments/new/", TrainingAssignmentCreateView.as_view(), name="assignment-create"),
    path("assignments/role/new/", RoleTrainingAssignmentCreateView.as_view(), name="role-assignment-create"),
    path("assignments/<int:pk>/", TrainingAssignmentDetailView.as_view(), name="assignment-detail"),
    path("trainings/", TrainingListView.as_view(), name="training-list"),
    path("trainings/new/", TrainingCreateView.as_view(), name="training-create"),
    path("trainings/<int:pk>/", TrainingDetailView.as_view(), name="training-detail"),
    path("trainings/<int:pk>/edit/", TrainingUpdateView.as_view(), name="training-update"),
    path("trainings/<int:training_pk>/versions/", TrainingVersionListView.as_view(), name="version-list"),
    path("trainings/<int:training_pk>/versions/new/", TrainingVersionCreateView.as_view(), name="version-create"),
    path("versions/<int:pk>/", TrainingVersionDetailView.as_view(), name="version-detail"),
    path("versions/<int:pk>/edit/", TrainingVersionUpdateView.as_view(), name="version-update"),
    path("versions/<int:pk>/publish/", publish_version, name="version-publish"),
    path("versions/<int:pk>/retire/", retire_version, name="version-retire"),
    path("versions/<int:version_pk>/modules/new/", ModuleCreateView.as_view(), name="module-create"),
    path("modules/<int:pk>/edit/", ModuleUpdateView.as_view(), name="module-update"),
    path("modules/<int:module_pk>/lessons/new/", LessonCreateView.as_view(), name="lesson-create"),
    path("lessons/<int:pk>/edit/", LessonUpdateView.as_view(), name="lesson-update"),
]
