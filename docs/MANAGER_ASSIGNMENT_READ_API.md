# Management Employee assignment monitoring API - Batch 4 Stage 1

## Endpoint and authentication

`GET /api/v1/management/employees/{employee_id}/assignments/`

Use the existing JWT bearer authentication and mobile-account eligibility rules.
GET, HEAD and OPTIONS are supported. POST, PATCH, PUT and DELETE return 405 after
normal authentication/permission checks. No assignment creation or learning
mutation is provided by this endpoint.

## Authority and Employee scope

This endpoint reuses the existing reporting authority (`dashboard_role`) and
assignment scope; Employee directory visibility alone is insufficient.

- **Company:** effective `training.add_trainingassignment` preserves existing
  Administrator/Training Coordinator and explicit global-grant oversight.
  Management-only eligible accounts need no linked Employee. Company authority
  takes precedence over Manager membership, including for mixed-role accounts.
  Existing Employees, including inactive Employees and the actor's own Employee,
  remain visible for historical oversight.
- **Team:** existing Manager reporting authority requires Manager Group membership
  and an active linked Employee. Only active direct and indirect descendants are
  returned. The Manager's own Employee, peers, superiors, inactive Employees and
  unrelated hierarchies are excluded. Use existing personal learning endpoints
  for the Manager's own assignments.
- **Other accounts:** ordinary Employees, Trainers, Supervisors and directory-only
  users gain no new monitoring authority. Existing personal learning is unchanged.
- JWT authentication requires an active User. Mobile eligibility independently
  denies inactive linked Employees, even if they have company permissions.

Team monitoring is a read/report operation: it does **not** require or grant the
separate `training.assign_team_trainingassignment` write permission. No migration,
Group grant or new capability string is introduced. Existing `assignment_report`,
`team_workspace` and `company_dashboard` discovery remains unchanged; the backend
rechecks authority independently of any cached Flutter capability.

Recipient eligibility follows Employee activity, not availability of a login:
active in-scope Employees without a User, or with a disabled linked User, can
still have historical assignments monitored. Their disabled User cannot log in.

## Pagination and ordering

Optional `page` and `page_size` use the existing pagination convention: default
20, maximum 100 (larger page sizes are capped). Results are ordered by
`-assigned_at`, then `-pk`, providing deterministic newest-first ordering.
Authorization and Employee lookup happen before pagination. An authorized
Employee with no assignments returns 200 with an empty paginated list.
No new search/status filters or client-controlled scope selectors are introduced.

Response 200 uses the existing envelope. Illustrative values:

```json
{
  "count": 1,
  "next": null,
  "previous": null,
  "results": [
    {
      "id": 101,
      "training_id": 4,
      "training_version_id": 12,
      "training_title": "Workplace safety v2",
      "version_number": 2,
      "status": "IN_PROGRESS",
      "assigned_at": "2026-10-20T10:00:00Z",
      "due_at": "2026-10-30T23:59:59Z",
      "started_at": "2026-10-21T08:00:00Z",
      "completed_at": null,
      "is_overdue": false,
      "progress_summary": {
        "required_lessons_completed": 1,
        "required_lessons_total": 2
      }
    }
  ]
}
```

- `id` is the assignment ID, not an authorization grant for learner routes.
- `training_id` identifies the parent catalog record. `training_version_id` is
  the exact pinned TrainingVersion primary key; `version_number` is its version
  number. `training_title` is that version's title, matching the learner summary
  contract, not the mutable catalog title.
- `status` is the authoritative `ASSIGNED`, `IN_PROGRESS`, `COMPLETED` or
  `CANCELLED` value. Historical assignments on retired pinned versions remain
  included. The query does not filter history by current publication/catalog state.
- Dates are existing serializer ISO 8601 timestamps; `due_at`, `started_at` and
  `completed_at` may be null. Flutter may display them in device-local time.
- `is_overdue` reuses the existing backend rule: only open assignments with a due
  timestamp strictly before the request's reference time are overdue. Completed
  and cancelled assignments are not overdue.
- `progress_summary` reuses the learner list's distinct required-lesson counts.
  These are server-recorded lesson completions, not an overall completion
  percentage, assessment result or video watch percentage. Zero required lessons
  yields zero counts; do not interpret 0/0 as a passed or completed assignment.
  Preserve the assignment's authoritative status.

No lesson bodies, protected media URLs, question/answer content, watch-session
identifiers, scores, credentials or employee deactivation reasons are returned.

## Errors and isolation

Errors retain `{error: {code, message, fields}}`.

- **401:** missing/invalid/expired JWT or disabled actor User. A web session alone
  does not authenticate this API.
- **403:** missing reporting authority or mobile ineligibility. Checks occur before
  target lookup, so an unauthorized actor gets the same denial for own/foreign IDs.
- **404:** unknown or out-of-scope Employee. Team self/foreign/inactive targets and
  unknown IDs have the same generic response, including when pagination is invalid.
  Authorized requests for nonexistent pages also return the standard 404.
- **405:** unsupported mutation method after authentication and authorization.

Ordinary GET/HEAD/OPTIONS create no assignments, sessions, progress, certificates,
notifications or audit events. Scope precedes pagination; counts and pages cannot
include another Employee. Metadata and lesson counts are selected/aggregated in
bounded queries rather than fetching progress separately for each assignment.

## Flutter integration

Fetch using the selected directory Employee ID, but do not infer monitoring
permission from directory access or infer company authority from `change_employee`.
For standard Team accounts, hide self-monitoring and use personal Learning instead.
A 404 after hierarchy/activity changes must clear that target's monitoring data.
Preserve existing account-generation cancellation and stale-response isolation.
Keep this read-only screen separate from protected learner operations, and do not
route a Manager to another employee's lesson/assessment using an assignment ID.
Follow the existing recovery policy for 401/403; do not automatically refresh JWTs
or introduce mutation retries. The employee's own learner API contract is unchanged.

## Validation

Focused regressions live in `api/v1/test_assignment_monitoring.py`. They cover
scope/permission negatives, mixed grants, active-account gates, historical states,
pagination, shared summary compatibility, no write queries and stable query counts.
Tests use isolated fixtures only; development Assignments 96/97 are never used.
