"""Assignment-report download contract for Android.

GET /api/v1/management/reports/assignments/export/
Authentication: Bearer JWT, active mobile account, existing company/manager
report authority. Manager rows retain the authoritative recursive report scope.

Filters are identical to the paginated report: status (ASSIGNED, IN_PROGRESS,
COMPLETED, CANCELLED), positive integer department/job_role/training/
training_version, and Boolean overdue_only. Malformed known filters return 400
in the standard API error envelope. Valid nonexistent or out-of-scope IDs yield
an empty report; filters never grant scope. Pagination parameters do not limit
this download. The paginated JSON endpoint and its permissions are unchanged.

200: text/csv; charset=utf-8; attachment filename assignment-report-YYYY-MM-DD.csv;
Cache-Control: private, no-store; X-Content-Type-Options: nosniff.
Column order: Employee, Department, Job role, Training, Version, Assigned,
Deadline, Status, Overdue, Completed, Certificate. Values match the website:
historical department/job role and pinned version, ISO-8601 timestamps, blank
nullable dates, Yes/No overdue, and Issued/Revoked/Not issued certificate state.
No certificate number, certificate ID, answer key, private media or email is sent.
CSV quoting and spreadsheet-formula protection use the existing website writer.
An empty result is a header-only CSV. Ordering is -assigned_at, pk.

At most 10,000 rows: 10,001 observed matching IDs cause 413 with error code
export_too_large and guidance to narrow filters, before any CSV output.
The bounded ID selection excludes later inserts; it is not a transactional
snapshot of concurrently edited row values. Scope and filters are reapplied
when streaming. Only IDs are materialized; joined rows stream in chunks.
401/403 use the existing API authentication/permission errors.

Android should issue one authenticated GET with the current report filters,
consume response bytes as UTF-8 CSV, and honor the server download filename.
Handle JSON errors before saving/sharing a file; never fall back to a partial
paginated export after 413. No Flutter integration is implemented here.
"""

from django.http import StreamingHttpResponse
from django.utils import timezone
from rest_framework.exceptions import APIException

from reports.views import (
    ASSIGNMENT_REPORT_EXPORT_MAX_ROWS,
    _assignment_report_csv_stream,
)


class AssignmentReportExportTooLarge(APIException):
    status_code = 413
    default_code = "export_too_large"
    default_detail = (
        f"Reports are limited to {ASSIGNMENT_REPORT_EXPORT_MAX_ROWS:,} rows. "
        "Narrow the report filters and try again."
    )


def assignment_report_csv_response(assignments):
    # Bound the probe as well as the stream. Fix the ID set before sending a
    # header so concurrent inserts cannot silently truncate a larger report.
    assignment_ids = list(assignments.values_list("pk", flat=True)[
        :ASSIGNMENT_REPORT_EXPORT_MAX_ROWS + 1
    ])
    if len(assignment_ids) > ASSIGNMENT_REPORT_EXPORT_MAX_ROWS:
        raise AssignmentReportExportTooLarge()

    export_assignments = assignments.filter(pk__in=assignment_ids)
    response = StreamingHttpResponse(
        _assignment_report_csv_stream(export_assignments),
        content_type="text/csv; charset=utf-8",
    )
    response["Content-Disposition"] = (
        f'attachment; filename="assignment-report-{timezone.localdate().isoformat()}.csv"'
    )
    response["Cache-Control"] = "private, no-store"
    response["X-Content-Type-Options"] = "nosniff"
    return response
