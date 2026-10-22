# Mobile organization management API — Batch 3A

Implemented backend contract. All paths below start with `/api/v1/management/`.
Authentication is `Authorization: Bearer <access token>` using the existing JWT
flow. Current mobile eligibility and effective Django permissions are checked on
every request; role names supplied by the client confer no permissions.

## Endpoints and capabilities

| Path | Method | Required existing capability/permission | Success |
|---|---|---|---|
| `departments/` | GET | `organization.view_department` | 200, paginated list |
| `departments/` | POST | `organization.add_department` | 201, created record |
| `departments/{id}/` | PATCH | `organization.change_department` | 200, updated record |
| `job-roles/` | GET | `organization.view_jobrole` | 200, paginated list |
| `job-roles/` | POST | `organization.add_jobrole` | 201, created record |
| `job-roles/{id}/` | PATCH | `organization.change_jobrole` | 200, updated record |

These permission strings already appear in `/api/v1/auth/me/`'s `capabilities`
array. No additional `can_*` booleans were added. A write permission does not
implicitly grant the corresponding view permission, and a write does not require
an additional view permission. Appropriately permissioned management accounts
can operate without a linked Employee. An inactive linked Employee remains
ineligible even if management permissions are present.

Department/Job Role records are company reference data, not employee-owned data.
The existing read rules include inactive records and order by `name`, then `id`.
Manager employee-directory/team scope is unchanged. Default Managers and Employees
have no reference write permissions; direct/group grants are evaluated normally.

## JSON request and response fields

| Field | POST | PATCH | Validation |
|---|---|---|---|
| `code` | Required | Optional | Nonblank string, up to 30 characters; unique per resource |
| `name` | Required | Optional | Nonblank string, up to 120 characters; duplicate names allowed |
| `description` | Optional, default `""` | Optional | String; blank allowed, null rejected |
| `is_active` | Optional, default `true` | Optional | Boolean; null rejected |

Strings are trimmed as in the existing Django forms. Code uniqueness follows the
database collation, including its existing case sensitivity rules. Codes may be
edited, matching the web portal. PATCH preserves omitted attributes; `{}` is an
accepted equivalent update. Editing/deactivating a referenced record preserves
Employee, assignment and training-requirement references and their states.

Example POST body:

```json
{"code":"MAINT","name":"Maintenance","description":"Maintenance team","is_active":true}
```

POST/PATCH return an unwrapped record with exactly these fields:

```json
{"id":42,"code":"MAINT","name":"Maintenance","description":"Maintenance team","is_active":true}
```

`id` is server-generated and not writable. Every other unexpected input field is
also rejected, including ownership, user, group/permission and timestamp fields.
No Employee mutation, deletion, or detail GET/PUT endpoint is introduced.

GET pagination is unchanged: `count`, `next`, `previous`, `results`. Use `page`
and optional `page_size` (default 20, maximum 100). Creation and editing do not
change the existing read response shape.

## Errors

Existing API envelope, for example a field validation failure:

```json
{"error":{"code":"validation_error","message":"Invalid input.","fields":{"code":["This code is already in use."]}}}
```

Field messages depend on the specific validator; Flutter should display returned
field messages rather than matching their text. Model-wide validation uses
`fields.non_field_errors`. Malformed JSON uses the existing `parse_error`
contract; authentication/permission errors normally have empty `fields`.

- **400:** missing/invalid fields, duplicate code, unexpected/read-only fields,
  non-object payload or malformed JSON.
- **401:** missing, invalid or expired JWT, or a disabled authenticated User.
- **403:** current account lacks mobile eligibility or the required permission.
- **404:** PATCH target does not exist, after authorization succeeds.
- **405:** unsupported method after normal authentication/permission checks.
  Collections support GET/HEAD/POST/OPTIONS; detail routes support PATCH/OPTIONS.
  DELETE is unsupported.

Writes use transactions and model `full_clean()`. Updates lock and reread the
target before applying supplied values. Expected duplicate-code races return a
field error; unrelated database integrity failures are not disguised as input
errors. There is no new automatic retry or idempotency-key protocol.

## Audit and Flutter integration

Successful changes reuse `organization.department.created/updated` and
`organization.jobrole.created/updated` audit events. Actor and snapshots are
server-derived; audit callbacks run after commit using the existing audit service.
Rolled-back/rejected writes schedule no successful event. Equivalent updates
produce no duplicate update event. Existing snapshots contain code/name/status;
`changed_fields` also identifies description edits without adding description
content to the shared audit snapshot contract.

Flutter gates create/edit affordances with the exact capability strings. POST
sends the complete writable representation; PATCH sends only fields changed
from the values loaded into the edit form, and the client does not submit an
unchanged form. The client retains field and non-field validation errors and
refreshes or invalidates the relevant reference list only after a confirmed
success.
After an uncertain POST timeout, refresh/reconcile by code instead of blindly
retrying creation; uniqueness prevents duplicate records but does not turn a
repeated POST into a successful response. Preserve the existing 401 recovery and
account-switch isolation. Employee mutations remain Batch 3B.
