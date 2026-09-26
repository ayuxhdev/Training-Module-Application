from django.urls import path

from .views import (
    AssessmentCreateView,
    AssessmentDetailView,
    AssessmentQuestionCreateView,
    AssessmentQuestionUpdateView,
    AssessmentUpdateView,
    QuestionCreateView,
    QuestionDetailView,
    QuestionListView,
    QuestionUpdateView,
    VersionAssessmentListView,
    attempt_detail,
    create_question_revision,
    edit_question_revision,
    freeze_question_revision,
    question_revision_detail,
    start_attempt,
    submit_attempt,
)

app_name = "assessments"

urlpatterns = [
    path("questions/", QuestionListView.as_view(), name="question-list"),
    path("questions/new/", QuestionCreateView.as_view(), name="question-create"),
    path("questions/<int:pk>/", QuestionDetailView.as_view(), name="question-detail"),
    path("questions/<int:pk>/edit/", QuestionUpdateView.as_view(), name="question-update"),
    path("questions/<int:pk>/revisions/new/", create_question_revision, name="revision-create"),
    path("revisions/<int:pk>/", question_revision_detail, name="revision-detail"),
    path("revisions/<int:pk>/edit/", edit_question_revision, name="revision-update"),
    path("revisions/<int:pk>/freeze/", freeze_question_revision, name="revision-freeze"),
    path("versions/<int:version_pk>/assessments/", VersionAssessmentListView.as_view(), name="assessment-list"),
    path("versions/<int:version_pk>/assessments/new/", AssessmentCreateView.as_view(), name="assessment-create"),
    path("assessments/<int:pk>/", AssessmentDetailView.as_view(), name="assessment-detail"),
    path("assessments/<int:pk>/edit/", AssessmentUpdateView.as_view(), name="assessment-update"),
    path("assessments/<int:assessment_pk>/questions/new/", AssessmentQuestionCreateView.as_view(), name="assessment-question-create"),
    path("assessment-questions/<int:pk>/edit/", AssessmentQuestionUpdateView.as_view(), name="assessment-question-update"),
    path("assignments/<int:assignment_pk>/assessments/<int:assessment_pk>/start/", start_attempt, name="attempt-start"),
    path("attempts/<int:pk>/", attempt_detail, name="attempt-detail"),
    path("attempts/<int:pk>/submit/", submit_attempt, name="attempt-submit"),
]
