# Mobile Employee profile API — Batch 3B phase 1

Implemented contract for native Employee editing. Requests use existing JWT
bearer authentication and mobile-account eligibility checks. This phase adds no
Employee creation, activation/deactivation, deletion or account administration.

## Endpoints and authorization

| Endpoint | Method | Effective Django permission | Success |
|---|---|---|---|
| `/api/v1/management/employees/` | GET | `organization.view_employee` | 200, paginated directory |
| `/api/v1/management/employees/{id}/` | GET | `organization.view_employee` | 200, Employee detail |
| `/api/v1/management/employees/{id}/` | PATCH | `organization.change_employee` | 200, Employee detail |

Permissions are checked server-side, not inferred from a client role label.
Existing read scope is unchanged: effective `change_employee` authority permits
company-wide Employee scope; otherwise Managers see themselves and recursive
reporting descendants, and other linked employees see only themselves. GET still
requires the separate view permission.

Ordinary Managers and Employees cannot PATCH, including their own profiles.
As explicitly approved, an effective `change_employee` grant is company-wide even
on a Manager account. PATCH requires neither an additional view grant nor an
Employee link. An inactive linked Employee cannot bypass eligibility through
management grants.

## Detail response: GET and successful PATCH

Illustrative data only:

```json
{
  "id": 42,
  "employee_code": "EXAMPLE-042",
  "display_name": "Example employee",
  "department": {"id": 2, "code": "PROD", "name": "Production"},
  "job_role": {"id": 3, "code": "OP", "name": "Operator"},
  "reporting_manager": "Example manager",
  "reporting_manager_id": 7,
  "is_active": true,
  "date_joined": "2026-10-01",
  "login_status": "ACTIVE"
}
```

`reporting_manager` retains its existing display-name string, or `null` when no
manager is assigned. The additive, read-only `reporting_manager_id` is the
related Employee's integer ID, or `null` in the same case. Never infer IDs from
names. Receiving an ID does not authorize viewing that manager's record: every
lookup retains its existing scope checks.

Department and Job Role already expose stable IDs through `department.id` and
`job_role.id`; their nested representations are unchanged. `login_status` remains
`ACTIVE`, `INACTIVE` or `NOT_LINKED`, without exposing User credentials/account IDs.

Directory pagination remains `count`, `next`, `previous`, `results`, ordered by
display name then primary key. List rows are unchanged: they do not contain
`reporting_manager_id`, `date_joined` or `login_status`. Load detail before editing.

## PATCH fields and Flutter mapping

Only these five fields are writable. Omission preserves the existing value;
`{}` is a successful no-op.

| Value from detail | PATCH key | Request type / validation |
|---|---|---|
| `display_name` | `display_name` | Trimmed nonblank string, maximum 150 characters |
| `department.id` | `department` | Existing Department ID; null rejected |
| `job_role.id` | `job_role` | Existing Job Role ID; null rejected |
| `reporting_manager_id` | `reporting_manager` | Existing Employee ID, or null to clear; cycles rejected |
| `date_joined` | `date_joined` | Valid ISO date (`YYYY-MM-DD`); null rejected |

Example partial update:

```json
{"display_name":"Updated example employee","reporting_manager":7}
```

Clear the manager with `{"reporting_manager":null}`. Do not send its display name.
Do not send nested Department/Job Role objects or use `department_id`,
`job_role_id` or `reporting_manager_id` as request keys: those aliases are rejected.
Build the request from supported fields, rather than sending the entire GET
representation. Prefer sending changed fields only to preserve unrelated edits.

Unexpected fields are rejected even when their values are unchanged. These
include `id`, immutable `employee_code`, User/account links, credentials, Groups,
permissions, capability labels, activation/deactivation fields and timestamps.
Existing web/model validation is retained, including allowing existing inactive
Department/Job Role references. Profile transfers do not rewrite assignment
versions or historical department/job-role snapshots.

## Errors, audit and recovery

Errors retain the existing envelope:

```json
{"error":{"code":"validation_error","message":"Invalid input.","fields":{"display_name":["This field may not be blank."]}}}
```

- **400:** invalid fields/references/dates, reporting cycles, malformed/non-object
  JSON, or unsupported fields. Model-wide errors use `fields.non_field_errors`.
- **401:** missing, invalid or expired JWT, or disabled User.
- **403:** ineligible mobile account or missing effective permission.
- **404:** unknown Employee, or out-of-scope GET. Unauthorized PATCH returns 403
  before object lookup, without disclosing whether the ID exists.
- **405:** unsupported method after normal authentication/permission checks.
  Detail supports GET/HEAD/PATCH/OPTIONS; collection supports GET/HEAD/OPTIONS.
  POST, PUT and DELETE are unsupported.

Writes use transactions, model validation and the existing hierarchy lock order.
Actual changes schedule `organization.employee.updated` after commit through the
existing audit service, with server-derived actor, standard snapshots and
`changed_fields`. Rejected/rolled-back writes create no success event. Empty or
equivalent repeated updates neither save the record nor create duplicate events.

Refresh Employee detail and directory after confirmed success. After an uncertain
mutation timeout, refetch/reconcile before an explicit retry; do not blindly retry
or introduce automatic JWT refresh. Preserve account-switch cancellation and
stale-response isolation. Flutter Employee edit UI is outside this backend phase.
