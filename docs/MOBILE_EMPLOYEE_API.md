# Mobile Employee management API — Batch 3B

Implemented backend contract for Employee creation, profile editing and deactivation. Requests
use existing JWT bearer authentication and mobile-account eligibility checks.
There is no credential provisioning, Group/permission administration, Employee
reactivation or deletion API in this batch.

## Endpoints and authorization

| Endpoint | Method | Effective Django permission | Success |
|---|---|---|---|
| `/api/v1/management/employees/` | GET | `organization.view_employee` | 200, paginated directory |
| `/api/v1/management/employees/` | POST | `organization.add_employee` | 201, created Employee detail |
| `/api/v1/management/employees/{id}/` | GET | `organization.view_employee` | 200, Employee detail |
| `/api/v1/management/employees/{id}/` | PATCH | `organization.change_employee` | 200, Employee detail |
| `/api/v1/management/employees/{id}/deactivate/` | POST | `organization.change_employee` | 200, inactive Employee detail |

Permissions are checked server-side, not inferred from a client role label.
Existing read scope is unchanged: effective `change_employee` authority permits
company-wide Employee scope; otherwise Managers see themselves and recursive
reporting descendants, and other linked employees see only themselves. GET still
requires the separate view permission.

Ordinary Managers and Employees cannot POST or PATCH, including their own profiles.
As explicitly approved, an effective `change_employee` grant is company-wide even
on a Manager account. PATCH requires neither an additional view grant nor an
Employee link. An inactive linked Employee cannot bypass eligibility through
management grants.

POST independently requires `add_employee`, not view/change permission or an
Employee link. Like the existing web creation form, an effective add grant
authorizes creation with company reference data; it adds no team-only creation
policy and does not expand the actor's existing directory read scope.

## POST creation contract

POST accepts exactly the existing web form fields:

| Field | Required | Validation / behavior |
|---|---|---|
| `employee_code` | Yes | Trimmed nonblank string, maximum 30 characters; unique under database collation; immutable after creation |
| `display_name` | Yes | Trimmed nonblank string, maximum 150 characters |
| `department` | Yes | Existing Department ID |
| `job_role` | Yes | Existing Job Role ID |
| `date_joined` | Yes | Valid ISO date (`YYYY-MM-DD`) |
| `reporting_manager` | No | Existing Employee ID or null; defaults to no manager; existing cycle validation applies |
| `user` | No | Existing unlinked Django User ID or null; defaults to no login link |

Example (illustrative IDs only):

```json
{"employee_code":"EXAMPLE-042","display_name":"Example employee","department":2,"job_role":3,"date_joined":"2026-10-01"}
```

The new Employee is active by the existing model default. Clients cannot set
activation/deactivation fields. Without `user`, the response has
`login_status: "NOT_LINKED"`; Employee creation alone does not create a login.

Account linking reuses `may_manage_linked_user()` from the web form:

- An actor with add authority may link an existing ordinary, unlinked User.
- Linking an existing superuser requires a superuser actor. An ordinary
  Administrator-group actor cannot link a superuser.
- Linking an existing staff or Administrator-group User requires an
  Administrator-group or superuser actor, exactly as on the website. An
  add/change grant alone does not override these privileged-account rules.
- A User already linked to an Employee cannot be reassigned to the new record.
- No User passwords, usernames, active flags, Groups or permissions are created
  or modified. Linking an inactive User is allowed by the existing web rules but
  does not enable it; the response reports `login_status: "INACTIVE"`.
- Account existence/privilege is rechecked under a User row lock before linking.
  When a manager is supplied, hierarchy locks precede the User lock, matching the
  existing Employee lifecycle ordering. Database uniqueness prevents duplicate
  identity or login links; verified uniqueness races return field errors.

Unknown fields, nested account/credential payloads and technical ID aliases are
rejected. POST does not accept `id`, `username`, `password`, `groups`,
`permissions`, `is_staff`, `is_superuser`, `is_active`, timestamps or actor labels.
Existing inactive Department/Job Role references remain allowed, matching the
web form. No assignment, credential or role-provisioning workflow is introduced.

Flutter can omit the optional User link. There is currently no mobile User lookup
or account-provisioning endpoint; an authorized User selector would need separate
scope approval. Do not invent usernames/passwords, guess account IDs or infer
them from Employee IDs. API support for linking a known existing User does not
implement that future UI workflow. PATCH still cannot add or change a User link.

POST is not an upsert or an idempotent success protocol. A repeated code/account
link returns 400 rather than creating a second Employee or duplicate audit event.

## POST deactivation contract

`POST /api/v1/management/employees/{id}/deactivate/` accepts exactly:

```json
{"reason":"Employee left the organization"}
```

`reason` is a required string, trimmed, nonblank and at most 1000 characters,
matching the existing web form. Unknown fields are rejected. The server derives
the target from the route and the actor from the JWT; clients cannot supply
activation flags, timestamps, account IDs or audit metadata.

Authorization requires mobile eligibility and effective `change_employee`,
independently of `view_employee` or a linked Employee. The approved company-wide
effective-permission policy also applies to Managers explicitly granted change
authority. Ordinary Managers and Employees cannot deactivate any record.

- Self-deactivation is forbidden, including for superusers.
- A superuser target requires a superuser actor. Administrator-group membership
  alone cannot bypass this rule.
- Staff and Administrator-group targets require an Administrator-group or
  superuser actor, reusing the web privileged-account protection.
- Existing inactive targets return **409** with code `employee_inactive`.
  Repeated requests preserve the original reason/timestamp and create no new audit.
- **403** covers missing permission, mobile ineligibility, self-deactivation or
  protected-account denial. Permission checks precede target lookup; authorized
  unknown IDs return **404**. JWT failures return **401**. Invalid payloads return
  **400**, normally with `fields.reason` for reason errors. Errors use the standard
  envelope. Only POST and OPTIONS are supported on this action route.

The transaction locks the Employee before its linked User, consistent with the
existing hierarchy/lifecycle lock order. It reads current state and privileges
under these locks. `Employee.save()` supplies the deactivation timestamp and
disables the linked login. A record without a login is also supported. Successful
commit schedules `organization.employee.deactivated` through the existing audit
service, with the server actor, before/after snapshots and validated reason.
Rejected or rolled-back writes create no success event.

Success returns the same Employee detail shape below, with `is_active: false`
and `login_status: "INACTIVE"` (or `"NOT_LINKED"`). It does not delete or rewrite
assignments, progress, assessment history, certificates or reporting relationships,
and does not reassign or deactivate subordinates. PATCH still rejects deactivation
fields. Reactivation is not implemented.

After an uncertain timeout, reconcile using authorized GET before an explicit
retry; 409 on retry means already inactive, not a new successful transition.
Do not automatically retry this mutation. No Flutter/device behavior is added
by this backend phase.

## Detail response: GET and successful POST/PATCH

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

- **400:** invalid fields/references/dates, duplicate Employee codes or account
  links, disallowed privileged-account links, reporting cycles, malformed/non-object
  JSON, or unsupported fields. Model-wide errors use `fields.non_field_errors`.
- **401:** missing, invalid or expired JWT, or disabled User.
- **403:** ineligible mobile account or missing effective permission.
- **404:** unknown Employee, or out-of-scope GET. Unauthorized PATCH returns 403
  before object lookup, without disclosing whether the ID exists.
- **405:** unsupported method after normal authentication/permission checks.
  Detail supports GET/HEAD/PATCH/OPTIONS; collection supports GET/HEAD/POST/OPTIONS.
  Detail POST, collection PATCH, PUT and DELETE are unsupported.

Writes use transactions, model validation and the existing hierarchy lock order.
Creation and actual profile changes schedule `organization.employee.created` or
`organization.employee.updated` after commit through the existing audit service,
with server-derived actor, standard snapshots and `changed_fields`.
Rejected/rolled-back writes create no success event. Empty or equivalent repeated
PATCH updates neither save the record nor create duplicate events.

Refresh Employee detail/directory after confirmed success only where GET is
authorized. Add authority does not imply view authority. After an uncertain
mutation timeout, refetch/reconcile where permitted before an explicit retry; an
add-only account may need an authorized administrator to verify the result.
Do not blindly retry or introduce automatic JWT refresh. Preserve account-switch
cancellation and stale-response isolation. Flutter creation/edit UI is outside
this backend phase.
