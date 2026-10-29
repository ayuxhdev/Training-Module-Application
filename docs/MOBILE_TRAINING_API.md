# Mobile training catalog and version APIs

Batch 6 Stage 2. These management APIs use JWT bearer authentication and the
existing mobile-account eligibility gate. An inactive User or inactive linked
Employee cannot use them. Eligible management-only accounts need no Employee link.

## Permissions and scope

| Endpoint | Method | Required effective Django permission |
| --- | --- | --- |
| `/api/v1/management/trainings/` | GET | `training.view_training` |
| `/api/v1/management/trainings/` | POST | `training.add_training` |
| `/api/v1/management/trainings/{id}/` | GET | `training.view_training` |
| `/api/v1/management/trainings/{id}/` | PATCH | `training.change_training` |
| `/api/v1/management/trainings/{id}/versions/` | GET | `training.view_trainingversion` |
| `/api/v1/management/trainings/{id}/versions/` | POST | `training.add_trainingversion` |
| `/api/v1/management/versions/` | GET | `training.view_trainingversion` |
| `/api/v1/management/versions/{id}/` | GET | `training.view_trainingversion` |

Permissions are independent: an add/change grant does not imply GET access, and
a version-view grant does not imply catalog-view access. As on the website,
version viewing includes its module and lesson summaries. It does not grant
module/lesson mutation rights. HEAD uses the corresponding GET permission.

The existing catalog is company-wide; Training has no tenant, department or owner
scope field. Effective content permissions authorize access to the catalog,
including drafts and retired versions. Manager membership, directory visibility,
team assignment authority and personal learner access alone grant **no** catalog
management access. Administrator/Training Coordinator content grants continue to
work without role-name authorization in these endpoints. Permissions are checked
before object lookup, so unauthorized callers receive the same denial for real
and nonexistent IDs. Authorized callers receive 404 for missing objects.

## Catalog GET and course mutations

`GET /api/v1/management/trainings/` accepts:

- `search`: trimmed text, maximum 150 characters; case-insensitive code, catalog
  title or description search.
- `is_active`: optional boolean; omission includes active and inactive courses.
- `page`: positive integer, default 1.
- `page_size`: integer from 1 to 100, default 20.

Invalid supported filters/page sizes return 400. Out-of-range pages return 404.
Results are ordered by catalog title, code and ID. The standard envelope is
`count`, `next`, `previous`, `results`; navigation links are URLs or null.

Each list item and the detail response have this shape (illustrative values):

```json
{
  "id": 12,
  "code": "SAFETY",
  "catalog_title": "Workplace safety",
  "description": "Safety curriculum",
  "is_active": true,
  "latest_version_number": 3,
  "latest_version_status": "DRAFT",
  "created_at": "2026-10-28T09:00:00Z",
  "updated_at": "2026-10-28T09:00:00Z"
}
```

Latest means highest version number across all lifecycle states. Both latest
fields are null when there are no versions. Timestamps are ISO 8601.

POST accepts `code` (required, nonblank, maximum 40), `catalog_title` (required,
nonblank, maximum 200), `description` (optional, default empty string) and
`is_active` (optional, default true). Code uniqueness and validation reuse
`TrainingForm` and the model. The current website has no code regex or uppercase
requirement; this API does not add one. PATCH accepts the same writable fields
and preserves omitted values. Unknown fields, creator IDs and lifecycle data are
rejected. Successful POST returns 201 and PATCH returns 200 with the catalog
representation. No-op PATCH emits no change audit event.

## Version history and detail

`GET /api/v1/management/trainings/{id}/versions/` uses the same bounded pagination
and envelope, ordered by descending version number then ID. It includes DRAFT,
PUBLISHED and RETIRED versions. Each result contains the version fields below,
excluding `modules`.

`GET /api/v1/management/versions/{id}/` returns:

```json
{
  "id": 24,
  "training_id": 12,
  "version_number": 3,
  "title": "Workplace safety 2026",
  "description": "Safety curriculum",
  "learning_objectives": "Recognize hazards",
  "change_summary": "Updated guidance",
  "status": "DRAFT",
  "published_at": null,
  "created_at": "2026-10-28T09:00:00Z",
  "updated_at": "2026-10-28T09:00:00Z",
  "modules": [
    {
      "id": 31,
      "title": "Introduction",
      "description": "Getting started",
      "order": 1,
      "lessons": [
        {"id": 45, "title": "Overview", "lesson_type": "TEXT", "order": 1, "is_required": true}
      ]
    }
  ]
}
```

`order` maps to the existing `position` field. `lesson_type` maps to
`content_type` (`TEXT` or `VIDEO`). Modules and lessons are ordered by position,
then ID, using bounded-query prefetches rather than per-row fetches. Empty
curricula return empty arrays. These are summaries: no lesson body, video path,
storage URL, checksum, playback session, assessment, question or answer is
returned. No viewing operation creates progress, notifications or audit events.

## Draft creation

`POST /api/v1/management/trainings/{id}/versions/` accepts:

```json
{
  "title": "Workplace safety 2026",
  "description": "Safety curriculum",
  "learning_objectives": "Recognize hazards",
  "change_summary": "Updated guidance"
}
```

Only title is required (nonblank, maximum 200); other fields default to empty
strings. The server supplies the URL parent, creator, next version number and
DRAFT status. Reject client `version_number`, `status`, publication metadata,
creator, source-version/cloning identifiers and every other unknown field.

The transaction locks the Training row before allocating max(version number)
plus one, including the first version. API allocations serialize; the database
uniqueness constraint remains the final safeguard against independent website
authors choosing the same explicit number. Such a database uniqueness conflict
returns 409; ordinary form validation errors return 400. Nothing is overwritten.

Inactive courses still permit draft authoring, matching the current website.
They remain excluded from the assignment picker. Creation uses
`TrainingVersionForm` and model validation and returns 201 with the full version
detail representation (`modules: []`). Published/retired versions, assignments,
assessment history and certificate pins are unchanged.

## Errors, auditing and Flutter integration

Errors retain the standard `{ "error": { "code", "message", "fields" } }`
envelope. Field validation maps Django non-field errors to `non_field_errors`.
401 indicates authentication failure; 403 indicates eligibility/permission denial.
Do not blindly retry a write after an ambiguous network failure; refresh the
catalog/version history first because the write may already have committed.

Successful writes use the established commit-time audit events:
`training.training.created`, `training.training.updated`, and
`training.trainingversion.created`. Server-derived snapshots omit full training
content. Failed or rolled-back writes register no committed success event.

All four agreed GET paths and minimum field names are preserved. Flutter must
gate course and version screens independently using the exact server-issued
permission capabilities above. This is distinct from
`GET /api/v1/management/training-versions/`, which retains its existing published,
active-course, assignment-authority contract unchanged.

Module/text-lesson REST mutations are not included here. Video uploads,
assessment authoring, cloning, publication and retirement APIs are also outside
this implementation; their website behavior is unchanged.

## Version discovery (version-view-only navigation)

`GET /api/v1/management/versions/` requires `training.view_trainingversion`,
JWT authentication and the existing mobile eligibility checks. It does not require
or grant `training.view_training`. Manager/team assignment authority alone is
insufficient. GET, HEAD and OPTIONS are supported; mutations are not.

Optional query parameters: `search` (trimmed, maximum 150 characters), `page`
(positive integer, default 1), `page_size` (1 to 100, default 20). Search matches
version title, course catalog title or course code, case-insensitively. It does
not search private descriptions or lesson content. Invalid supported parameters
return the standard 400 error envelope; out-of-range pages return 404.

The response uses `count`, `next`, `previous`, `results`. Each result contains
exactly these fields:

```json
{
  "id": 21,
  "training_id": 12,
  "training_title": "Workplace safety",
  "version_number": 3,
  "title": "Workplace safety revision 3",
  "status": "DRAFT"
}
```

`training_title` is the current course catalog title; `title` is the version's
own title. IDs and version numbers are integers; titles and status are strings.
Results sort by course catalog title, course ID, descending version number, then
version ID. Pagination is deterministic for an unchanged dataset, not a snapshot
across concurrent edits. As with existing version history/detail, authorized
readers can see DRAFT, PUBLISHED and RETIRED versions, including inactive courses.
There is no employee/team filter or tenant scope in this company-wide content
permission. Each result can open the existing `/management/versions/{id}/` API.

Flutter version-only navigation should use this list directly, without first
fetching the course catalog or course detail. This endpoint exposes no course
metadata beyond identification, curriculum content, media URLs or answers, and
performs no business-state/audit mutations. Existing catalog, history, detail and
published-only assignment-picker contracts are unchanged.

## Batch 6 Stage 5: draft modules and TEXT lessons

All routes below start with `/api/v1/management/`. They use the same JWT,
mobile-eligibility and standard error-envelope rules as the catalog APIs.
No Group name is used as authority. Effective permissions are independent:
an add/change grant does not require a course/version/view grant, does not grant
those permissions, and does not authorize GET. Manager membership alone is
insufficient. Content-authoring permissions remain company-wide, as on the
website; there is no separate owner/team/tenant field on curriculum records.

| Relative route | Method | Effective permission | Success |
| --- | --- | --- | --- |
| `versions/{version_id}/modules/` | POST | `training.add_module` | 201 |
| `versions/{version_id}/modules/{module_id}/` | GET | `training.view_module` | 200 |
| `versions/{version_id}/modules/{module_id}/` | PATCH | `training.change_module` | 200 |
| `versions/{version_id}/modules/{module_id}/text-lessons/` | POST | `training.add_lesson` | 201 |
| `versions/{version_id}/modules/{module_id}/text-lessons/{lesson_id}/` | GET | `training.view_lesson` | 200 |
| `versions/{version_id}/modules/{module_id}/text-lessons/{lesson_id}/` | PATCH | `training.change_lesson` | 200 |

Detail HEAD uses the corresponding GET permission. OPTIONS uses add permission
on create routes and view permission on detail routes. No DELETE, PUT, video
upload, content-type conversion, assessment-authoring or publication operation
is provided. These detail reads support loading draft edit forms; existing
version-detail summary responses are unchanged.

### Eligibility and parent isolation

Every route above requires a DRAFT version. An authorized caller receives 404
for a missing/non-DRAFT version, a module outside the specified version, or a
lesson outside the specified module. TEXT lesson details also return 404 for
VIDEO lessons. This matches the website's draft-only lookup behavior. Unauthorized
callers are denied before object lookup, independently of whether IDs exist.

Published and retired content cannot be changed. Existing assignment version
pins, learner progress, assessment results, certificates and stored videos are
not updated. A new version is required to change published content.

### Module input and response

POST accepts:

| Field | Rule |
| --- | --- |
| `title` | Required, nonblank string, maximum 200 characters |
| `description` | Optional string, blank allowed, default `""` |
| `position` | Required integer, 1 through 2147483647 |

PATCH accepts any subset of the same fields. Omitted fields retain their latest
stored values. Empty/no-change PATCH returns the current representation without
updating timestamps or recording a success audit event.

Example POST to `/api/v1/management/versions/42/modules/`:

```json
{"title": "Site safety", "description": "Before starting work", "position": 1}
```

Example 201 response (also the GET/PATCH response shape):

```json
{
  "id": 70,
  "training_version_id": 42,
  "title": "Site safety",
  "description": "Before starting work",
  "position": 1
}
```

Example PATCH to `/api/v1/management/versions/42/modules/70/`:

```json
{"title": "Site safety introduction", "position": 4}
```

### TEXT lesson input and response

POST accepts:

| Field | Rule |
| --- | --- |
| `title` | Required, nonblank string, maximum 200 characters |
| `body` | Required, nonblank plain text; follows existing LessonForm validation |
| `position` | Required integer, 1 through 2147483647 |
| `content_type` | Optional; only `"TEXT"` is accepted; default `"TEXT"` |
| `is_required` | Optional boolean, default `true` |

PATCH accepts any subset. Omitted fields preserve the latest stored values,
including an existing `false` required flag. `content_type` cannot change to VIDEO.
The website form's whitespace normalization is retained. The body has no new
API-specific character limit beyond existing framework/request/storage limits,
matching the existing unbounded model/form text field. Titles retain the existing
200-character limit. Unknown fields and null values are rejected.

Text is stored/returned as text, not trusted HTML. Tags are literal text: existing
website rendering escapes them and native clients must use text widgets, not
interpret this field as HTML. No sanitizer or rich-text format is introduced.

Example POST to
`/api/v1/management/versions/42/modules/70/text-lessons/`:

```json
{
  "title": "Before work",
  "body": "Check your equipment.\nReport unsafe conditions.",
  "position": 1,
  "is_required": true
}
```

Example 201 response (also the GET/PATCH response shape):

```json
{
  "id": 90,
  "module_id": 70,
  "training_version_id": 42,
  "title": "Before work",
  "content_type": "TEXT",
  "body": "Check your equipment.\nReport unsafe conditions.",
  "position": 1,
  "is_required": true
}
```

Example PATCH to
`/api/v1/management/versions/42/modules/70/text-lessons/90/`:

```json
{"body": "Updated instructions.", "position": 3, "is_required": false}
```

Neither input accepts IDs, parent relationships, timestamps, actors, version
state, video files, checksums, durations or minimum-watch percentages. The existing
internal minimum-watch value is preserved and has no completion effect for TEXT.
VIDEO records cannot be converted or edited through these routes. No response
exposes a media path, playback URL or assessment answer key.

### Ordering, concurrency and audit behavior

`position` is the existing model/form field, not the read-summary alias `order`.
Positions are unique within a version (modules) or module (lessons). Gaps are
allowed. PATCH to an unused position changes ordering without renumbering other
records. An occupied position is rejected; these routes do not silently swap,
shift or batch-renumber siblings. To swap two positions, use a vacant temporary
positive position through separate PATCH requests, as in the existing website
workflow. That sequence consists of separate transactions, not one atomic swap.

Each write is atomic and locks the parent version before children; model saves
use the same version lock as publication. Parent eligibility is rechecked inside
the lock. Partial edits merge into fresh locked state. Duplicate positions
are validated by the existing forms/models and protected by database constraints.
Simultaneous requests cannot bypass draft eligibility or partially save a rejected
edit. This is serialized partial-update behavior, not an optimistic revision-token
contract: later edits to the same field can replace an earlier draft edit.

Successful creates/changes schedule the existing `training.module.created`,
`training.module.updated`, `training.lesson.created`, or `training.lesson.updated`
audit event after commit. Events contain approved metadata/changed field names,
not lesson bodies or full descriptions. Rejected/rolled-back writes and no-op
PATCH requests do not produce success events.

### Errors

- 400 `validation_error`: missing/invalid title, empty text, unknown/protected
  fields, invalid type/order, or a position already occupied during validation.
  Field errors appear under `error.fields`, for example
  `{"error":{"code":"validation_error","message":"Invalid input.","fields":{"position":["This version already has a module at that position."]}}}`.
  The standard envelope's summary message is generated by the existing handler.
- 401: missing, invalid or expired JWT, or inactive User.
- 403: missing effective permission or an ineligible mobile account (including
  an inactive linked Employee). No role-name exception is made for Managers.
- 404: nonexistent or non-DRAFT version, mismatched parent IDs, missing record,
  or a VIDEO record addressed through a text-only detail route.
- 409 `conflict`: a database uniqueness race specifically naming
  `unique_module_position` or `unique_lesson_position`. Refresh and choose a free
  position. Unrelated database errors are not mislabeled as ordering conflicts.
- 405: unsupported methods for an otherwise authorized caller.

Flutter integration must send the full nested parent chain, use the returned
IDs and authoritative positions, invalidate affected curriculum summaries after
success, render field/non-field errors, and handle 401/403/404/409 without blindly
retrying mutations. Full text edit loading uses its separate view permission;
version-view permission continues to authorize summaries only.
