# Mobile manual training assignments — Batch 3 Stage 3

These endpoints use the existing JWT authentication, mobile-account eligibility,
and server assignment-authority helpers. No Flutter implementation is included.

## Authority and scope

- Company authority: effective `training.add_trainingassignment`, preserving
  Administrator/Training Coordinator and existing explicit global grants.
- Team authority: effective `training.assign_team_trainingassignment`, Manager
  membership, active User and active linked Employee. Only active direct/indirect
  reports are assignable; self, peers, superiors and foreign hierarchies are not.
- Mobile eligibility is also required; inactive linked Employees cannot bypass it
  through management grants. Management-only authorized global accounts work.
- `team_assignment` does not grant company dashboards or curriculum/role setup.

## GET `/api/v1/management/training-versions/`

Published versions of active catalog entries only. Returns metadata, never lesson
content, assessment questions/answer keys or media URLs.

Optional query parameters:

- `search`: trimmed, case-insensitive catalog code/title or version title, max 150.
- `page`, `page_size`: existing pagination, default 20 and maximum 100.

Ordering: catalog title, Training ID, version number, version primary key.
Response 200: `{count, next, previous, results}`. Each result contains:

```json
{
  "id": 12,
  "training_id": 4,
  "training_code": "SAFETY",
  "training_title": "Workplace safety",
  "title": "Workplace safety v2",
  "version_number": 2,
  "published_at": "2026-10-27T10:00:00Z"
}
```

`id` is the TrainingVersion ID to send on creation. Example data is illustrative.

## POST `/api/v1/management/assignments/`

```json
{"employee_id": 42, "training_version_id": 12, "due_date": "2026-11-30"}
```

Only these fields are accepted. IDs are positive integers. `due_date` may be
omitted or null; otherwise use an ISO calendar date, not a datetime. It is due at
the end of that day in the server's configured/current timezone, matching the
website. Past local dates are rejected. No client timezone parameter is accepted.

Response 201 is an unwrapped record with:

- `id`, `employee_id`, `training_version_id`
- `status` (`ASSIGNED`), `source` (`MANUAL`), `assigned_by_id`
- `department_at_assignment_id`, `job_role_at_assignment_id`
- `assigned_at`, nullable `due_at` (ISO 8601 timestamps)

The existing Employee directory endpoint can provide choices, but read access is
not proof of assignment eligibility. It includes Manager self/inactive records;
explicit Employee-management grants can also make it company-wide while assignment
authority stays team-scoped. The selection UI must account for those differences
and handle scope-validation errors. This POST independently enforces authoritative
assignable scope. No directory filter contract or read scope is changed here.

## Errors and recovery

Existing envelope: `{error: {code, message, fields}}`.

- 401: missing/invalid/expired JWT or inactive login.
- 403: mobile-ineligible account or insufficient assignment authority.
- 400 `validation_error`: invalid fields/references, inaccessible/inactive employee,
  ineligible version, past deadline, duplicate assignment or expected concurrent
  assignment uniqueness collision. Form errors use `employee_id`,
  `training_version_id`, `due_date`, and/or `non_field_errors`.
- Unknown and foreign employee IDs return the same generic employee-field error.
- 404: nonexistent pagination page. 405: unsupported methods.

Do not automatically retry an uncertain POST. A duplicate response does not grant
access to the learner's lesson/progress endpoints or return protected content.

## Transactions and policy boundary

Creation reuses `TrainingAssignmentForm`: full ordered Employee hierarchy locks
for team authority, recipient Employee, version, then actor User; fresh scope and
activity checks; locked recipient snapshots; model validation/unique constraint;
transactional ASSIGNED notification and successful-commit audit event.

Stage 3 explicitly excludes inactive parent Training records. The reviewed website
currently checks published version status without this parent-active condition.
An API-only `require_active_training=True` form option filters the choices and
locks/checks Training between version and User; its default is false, preserving
website behavior. No model, permission, migration or website policy is changed.

The API's outer transaction includes creation, notification and audit scheduling.
Failures roll back new records. Only a verified MySQL 1062 collision on
`unique_employee_version` with the exact employee/version pair is translated;
unrelated integrity failures are not mislabeled as duplicates.
