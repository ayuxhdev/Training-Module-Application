from uuid import uuid4

from django.db import transaction
from django.utils import timezone

from assessments.models import Assessment, AssessmentAttempt
from audit.services import record_event
from organization.models import Employee
from training.models import TrainingAssignment, TrainingVersion

from .models import Certificate


@transaction.atomic
def issue_completed_assignment_certificate(assignment_id, actor=None):
    assignment_ref = TrainingAssignment.objects.values("employee_id", "training_version_id").get(pk=assignment_id)
    employee = Employee.objects.select_for_update().get(pk=assignment_ref["employee_id"])
    TrainingVersion.objects.select_for_update().get(pk=assignment_ref["training_version_id"])
    assignment = TrainingAssignment.objects.select_for_update().get(pk=assignment_id)
    if assignment.status != TrainingAssignment.Status.COMPLETED or not employee.is_active:
        return None

    existing = Certificate.objects.filter(assignment=assignment).first()
    if existing:
        return existing

    final_attempt = AssessmentAttempt.objects.filter(
        assignment=assignment,
        assessment__training_version_id=assignment.training_version_id,
        assessment__kind=Assessment.Kind.FINAL,
        status=AssessmentAttempt.Status.SUBMITTED,
        passed=True,
    ).order_by("-submitted_at", "-pk").first()
    if final_attempt is None:
        return None

    version = TrainingVersion.objects.get(pk=assignment.training_version_id)
    certificate = Certificate.objects.create(
        certificate_number=f"GN-{uuid4().hex.upper()}",
        assignment=assignment,
        training_version=version,
        qualifying_final_attempt=final_attempt,
        issued_at=timezone.now(),
        employee_code_snapshot=employee.employee_code,
        employee_name_snapshot=employee.display_name,
        training_title_snapshot=version.title,
        version_number_snapshot=version.version_number,
        issued_by=actor if getattr(actor, "is_authenticated", False) else None,
    )
    record_event(
        actor,
        "certifications.certificate.issued",
        certificate,
        after={
            "certificate_number": certificate.certificate_number,
            "assignment_id": assignment.pk,
            "training_version_id": version.pk,
        },
    )
    return certificate