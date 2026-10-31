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

## Batch 6 Stage 7: draft VIDEO lesson authoring

These routes start with `/api/v1/management/` and preserve all earlier catalog,
version, module, TEXT, assignment-picker and learner-playback contracts.

| Relative route | Method | Effective permission | Success |
| --- | --- | --- | --- |
| `versions/{version_id}/modules/{module_id}/video-lessons/` | POST | `training.add_lesson` | 201 |
| `versions/{version_id}/modules/{module_id}/video-lessons/{lesson_id}/` | GET | `training.view_lesson` | 200 |
| `versions/{version_id}/modules/{module_id}/video-lessons/{lesson_id}/` | PATCH | `training.change_lesson` | 200 |

JWT and existing mobile eligibility are required. Add/view/change permissions
are independent; no extra course, version or module grant is inferred or required.
Manager membership alone grants nothing. As with website content management,
explicit lesson permissions are company-wide. Parent IDs must match the complete
version/module/lesson chain, and the version must be DRAFT on every operation.
Published/retired versions and TEXT lessons return 404 through these routes.
Detail HEAD uses view permission. OPTIONS uses add permission on create and view
permission on detail. No delete, content-type conversion, preview/download or
publication operation is introduced.

### Requests

POST uses `multipart/form-data` with one `video_file`. PATCH accepts multipart
for attachment replacement, or JSON for metadata-only edits. File-name/path
strings are not accepted as attachment references. Query-string fields do not
select parents or override the submitted fields.

| Field | POST | PATCH |
| --- | --- | --- |
| `title` | Required, nonblank, maximum 200 characters | Optional |
| `position` | Required integer, 1 to 2147483647 | Optional |
| `video_file` | Required nonempty file | Optional replacement file |
| `content_type` | Optional, only `VIDEO`; defaults to `VIDEO` | Optional, only `VIDEO` |
| `is_required` | Optional boolean, default `true` | Optional; omission preserves the stored flag |
| `minimum_watch_percent` | Optional decimal, 0 to 100, up to 2 decimal places; default `90.00` | Optional |

Existing website minimum-watch rules remain authoritative. Multipart omissions
use the same defaults as JSON, rather than HTML checkbox behavior. Metadata PATCH
preserves the existing attachment, checksum and duration. An unchanged PATCH
returns the current data without an update timestamp or success audit event.

Unknown/protected fields are rejected, including `body`, parent IDs, actors,
timestamps, lifecycle state, `video_url`, `video_checksum` and
`video_duration_seconds`. The server derives the checksum and duration from the
actual uploaded bytes; ordinary administrators never supply them.

Example multipart POST fields (the file part contains actual binary bytes):

```text
title: Equipment inspection
position: 2
is_required: true
minimum_watch_percent: 80.00
video_file: <selected MP4 file bytes>
```

Example metadata PATCH:

```json
{"title":"Equipment inspection overview","position":4,"is_required":false}
```

Example POST/GET/PATCH response:

```json
{
  "id": 94,
  "module_id": 70,
  "training_version_id": 42,
  "title": "Equipment inspection",
  "content_type": "VIDEO",
  "position": 2,
  "is_required": true,
  "minimum_watch_percent": "80.00",
  "video_duration_seconds": 69,
  "has_video": true
}
```

Percentages serialize as decimal strings; IDs, positions and whole-second duration
are integers. `has_video` reports an attachment reference, not a fresh storage
health check. Responses expose no storage key, filesystem path, original filename,
public media URL, checksum, lesson body or assessment answers.

### Validation and private storage

The existing LessonForm/video-upload pipeline performs extension, size, signature,
actual byte-count and SHA-256 checks, then bounded ffprobe inspection of the
selected video stream and duration. Supported containers remain MP4, WebM and MOV,
with the existing 2 GB limit. Missing/empty, unreadable, incomplete, oversized or
unsupported files fail closed. A matching suffix/header alone is insufficient.
The existing ffprobe command restricts protocols/formats, disables external MOV
references and has a 15-second subprocess timeout. Missing processing capability,
invalid metadata, no video stream or inspection failure rejects the upload.
This is bounded structural/metadata inspection, not antivirus scanning or a full
frame-by-frame decode, transcoding or a guarantee of native decoder compatibility.

No media processor is installed or storage backend changed by these endpoints.
They reuse the currently configured private FileSystemStorage and generated
`training/videos/...` namespace. Each new attachment gets an exclusively reserved
private operation directory and server-chosen basename. Client filenames never
choose the stored path. A namespace referenced by an older row is not reused,
even if its directory is missing. New uploads to other storage backends fail closed with 503
until their ownership/rollback semantics receive a separate review.

Replacement never deletes the old file. On a rejected or rolled-back write,
cleanup removes only the new operation's exclusively owned, unreferenced directory,
including partial storage writes. Paths are resolved and bounded to the storage
root before removal. If a commit outcome cannot be determined, or cleanup fails,
the new directory is retained and an operation identifier is logged for controlled
operational investigation. A directory referenced by a committed row is never
removed as failure cleanup. Such exceptional artifacts remain private; they do
not gain a media-serving route. No background garbage collector is introduced.

Media remains accessible only through existing authorized playback/replay routes.
This management endpoint provides metadata, not video bytes. Published files,
learner watch sessions, heartbeat/anti-skip rules, progress, assignments,
assessment results and certificates are unchanged.

### Transactions, ordering and audit

Mutations lock the DRAFT version, then the matching module/VIDEO lesson, and merge
PATCH fields into fresh state. Validation and storage completion occur while the
version lock is held. The database transaction commits before upload success is
returned. This service uses a durable outer transaction and must not be called
inside another application `atomic()` block; nesting is rejected before writing
files. The current database configuration does not enable `ATOMIC_REQUESTS`.
Enabling request-wide transactions later requires an explicitly non-atomic view
boundary for these upload routes; do not silently wrap this service.

Position semantics match Stage 5: explicit positive values, gaps permitted,
occupied positions rejected, no sibling shifts or automatic renumbering. Later
authorized draft edits to the same field can replace earlier edits; there is no
optimistic revision-token contract.

Committed meaningful changes use existing `training.lesson.created` or
`training.lesson.updated` events, with server actor and approved metadata only.
No success event is recorded for rejected, unchanged or rolled-back writes.
Private file contents, storage keys and JWTs are not included in the events.

### Errors and Flutter integration

- 400: required/invalid fields, occupied positions, missing/rejected video,
  inspection failure or client-supplied protected metadata. Errors use the
  standard envelope and `error.fields`, commonly under `video_file`.
- 401: missing/invalid/expired JWT or inactive User.
- 403: missing effective permission or ineligible mobile identity.
- 404: missing/mismatched parent IDs, non-DRAFT version, or a TEXT record.
- 409: the exact lesson-position uniqueness race, MySQL lock-wait timeout or
  deadlock. Refresh authoritative state before retrying; unrelated database
  errors are not mislabeled as position conflicts.
- 503 `upload_unavailable`: private storage is unavailable or the configured
  backend has no supported ownership/cleanup contract. Internal paths are omitted.

Flutter VIDEO authoring is a later stage. It must upload bytes as multipart,
omit server-derived checksum/duration, prepopulate through authorized GET, preserve
independent capabilities, display field errors, invalidate curriculum caches after
success, and handle uncertain/cancelled uploads without blindly repeating writes.
Retries after a lost response must first inspect authoritative lesson state.

## Batch 6 Stage 9: assessment and question authoring

All routes below start with `/api/v1/management/`, require JWT authentication,
an active mobile-eligible identity, and the effective Django permission listed.
Business-role labels alone grant no access. These grants are company-wide content
permissions, matching website authoring; Manager team membership does not grant
them. No new permissions, models, migrations or learner endpoints are introduced.

### Routes and independent permissions

| Relative route | GET / HEAD | POST | PATCH |
| --- | --- | --- | --- |
| `versions/{version_id}/assessments/` | `assessments.view_assessment` | `assessments.add_assessment` | — |
| `versions/{version_id}/assessments/{assessment_id}/` | `assessments.view_assessment` | — | `assessments.change_assessment` |
| `versions/{version_id}/assessments/{assessment_id}/questions/` | `assessments.view_assessmentquestion` | `assessments.add_assessmentquestion` | — |
| `versions/{version_id}/assessments/{assessment_id}/questions/{item_id}/` | `assessments.view_assessmentquestion` | — | `assessments.change_assessmentquestion` |
| `questions/` | `assessments.view_question` | `assessments.add_question` | — |
| `questions/{question_id}/` | `assessments.view_question` | — | `assessments.change_question` |
| `questions/{question_id}/revisions/` | `assessments.view_questionrevision` | `assessments.add_questionrevision` | — |
| `questions/{question_id}/revisions/{revision_id}/` | `assessments.view_questionrevision` | — | `assessments.change_questionrevision` |
| `questions/{question_id}/revisions/{revision_id}/freeze/` | — | `assessments.change_questionrevision` | — |

Create returns 201; GET, PATCH and freeze return 200. OPTIONS uses the route's
read permission, or change permission on freeze. Add/view/change remain
independent: receiving a mutation response grants no subsequent GET authority.
All mutations accept JSON objects only (`Content-Type: application/json`).
Unsupported content types return 415, avoiding HTML checkbox defaults.

List responses use `{count,next,previous,results}`, with default page size 20 and
maximum 100; `page` and `page_size` are validated. Question-bank lists additionally
support `search` (trimmed, maximum 150 characters; code/topic) and `is_active`.
Ordering is deterministic: assessments by kind/sequence/ID, attachments by
position/ID, questions by code/ID, revisions by revision number/ID. Revision lists
contain summaries, not prompts, explanations or answer options.

### Assessment settings and ordered attachments

Assessment POST fields are `kind` (`QUIZ` or `FINAL`) and nonblank `title`
(maximum 200 characters), plus these optional settings:

| Field | Default / rule |
| --- | --- |
| `module_id` | null; required for QUIZ, and must belong to the URL's version |
| `sequence` | 1; positive integer, maximum 4294967295 |
| `pass_percentage` | `80.00`; decimal 0–100, up to 2 decimal places |
| `max_attempts` | 3; positive integer, maximum 4294967295 |
| `time_limit_minutes` | null (untimed), otherwise positive integer, maximum 4294967295 |
| `is_required` | true |

PATCH accepts subsets; null is supported only for `module_id` and
`time_limit_minutes`. The existing AssessmentForm normalizes FINAL to
`module_id=null`, `sequence=1`, `is_required=true`. QUIZ sequences are unique
within the entire version/kind, not independently per module. Existing form and
model validation is authoritative; no new assessment type or grading rule exists.

Example assessment response:

```json
{"id":81,"training_version_id":42,"module_id":70,"kind":"QUIZ","title":"Module review","sequence":1,"pass_percentage":"80.00","max_attempts":3,"time_limit_minutes":null,"is_required":true}
```

Attachment POST fields are `question_revision_id`, positive `position`
(maximum 4294967295), and optional `points` (default `1.00`, minimum `0.01`,
maximum `999999.99`, up to 2 decimal places). PATCH accepts subsets, including a
different eligible revision. The website form permits only FROZEN revisions of
active questions. An assessment cannot contain multiple revisions of one question
or duplicate positions/revision IDs. Gaps are allowed; no automatic renumbering
or atomic position swapping is added. Use a vacant position for staged reordering.

```json
{"id":93,"assessment_id":81,"question_revision_id":65,"position":3,"points":"2.50"}
```

These response types contain metadata only: no prompts, explanations, option
text, correctness flags, attempt data or answer keys. Percentages and points are
decimal strings; IDs, sequence, position and time/attempt limits are integers.

Assessment and attachment reads permit existing DRAFT/PUBLISHED/RETIRED content,
as on the website. Mutations lock and recheck a DRAFT version, then its matching
assessment/item. Every nested version/assessment/item relationship is checked;
wrong parents and frozen curriculum mutations return 404. No explicit version
view grant is inferred or required by these authoring permissions.

### Global question bank and revisions

Questions are global reusable bank records, not direct children of a training
version. Question POST accepts `code` (unique, nonblank, maximum 40), optional
`topic` (blank permitted, maximum 120), and `is_active` (default true). PATCH
accepts subsets. The response is `{id,code,topic,is_active}`. As on the website,
creation atomically creates revision 1 with prompt `Draft question` and DRAFT
status, even for an add-question-only account. Authorized revision readers can
discover it through the separate revision list. Later revisions require their
independent add permission. Question metadata/deactivation remains editable as
on the website; it never edits a frozen revision's prompt or answer key.

Revision POST accepts nonblank `prompt`, optional `question_type` (default
`SINGLE_CHOICE`) and `explanation` (default empty). Only `SINGLE_CHOICE` and
`TRUE_FALSE` exist; neither supports multiple selected answers. The server
allocates the next revision number under the Question row lock. POST and list
responses contain `{id,question_id,revision_number,question_type,status,frozen_at}`.
GET detail and successful PATCH/freeze additionally contain `prompt`,
`explanation`, and ordered `options`.

```json
{"id":65,"question_id":38,"revision_number":2,"question_type":"SINGLE_CHOICE","status":"DRAFT","frozen_at":null,"prompt":"Wear protective equipment?","explanation":"Follow the site procedure.","options":[{"id":110,"text":"Yes","position":1,"is_correct":true},{"id":111,"text":"No","position":2,"is_correct":false}]}
```

Only DRAFT revisions can be PATCHed. Frozen revisions return 404 for editing or
repeated freeze. PATCH accepts the revision fields above and optional `options`
(at most 1000 entries per request). This delegates to the existing website inline
formset in one transaction, with the following JSON adaptation:

- A new option has nonblank `text`, positive `position` (maximum 4294967295),
  and optional `is_correct` (default false).
- An existing option supplies its `id` and changed fields. IDs must belong to the
  URL's revision and appear only once. Foreign/missing IDs return 404.
- Omitted options/fields are preserved. `options: []` does not clear the key.
- Explicit `{"id":111,"delete":true}` removes only that existing DRAFT option,
  using the website's validated deletion path; there is no revision/question
  deletion endpoint or implicit whole-key replacement.
- Duplicate positions are invalid. Position gaps and existing website rules for
  option text are preserved; no new text-uniqueness rule is invented.
- Prompt/options/explanation changes commit together or all roll back. Omitted
  prompt/explanation retain their exact stored formatting; explicit text values
  retain normal form validation and whitespace normalization.

Like the website, drafts may be incomplete while being authored. Freeze is a
separate POST with `{}` and reuses the model's final validation: at least two
options, exactly one correct option, and for TRUE_FALSE exactly two options
labelled True and False (case-insensitive). Freeze assigns the server timestamp.
Only frozen active-question revisions can then be attached to a draft assessment.
Published training still requires frozen question revisions and all existing
publication validation. No training publication endpoint is added here.

### Answer visibility, atomicity and failures

Answer configuration is available only through authorized revision detail or
revision-edit/freeze responses. `view_questionrevision` grants the existing
website detail authority; `change_questionrevision` grants the existing website
edit/formset authority, including editing options without separate QuestionOption
grants. QuestionOption permission labels alone grant no revision access.
Assessment/attachment/question metadata permissions do not reveal answer keys.
The existing learner/public APIs and their serializers remain unchanged.

Version-bound writes lock version → assessment → item. Question-bank revision
writes lock Question → revision, the same revision aggregate used by option
model writes. Concurrent numbering and freeze/edit conflicts are serialized.
Meaningful committed writes use the existing assessment/question/revision audit
events. Option edits use the revision event, with metadata/boolean change flags,
never option text, explanations, correct-answer configuration or prompt contents.
Rejected, no-op and rolled-back writes produce no success event.

Errors use the standard API envelope: 400 for malformed/unknown fields, form/model
validation, occupied positions/sequences, or invalid references; 401 for invalid
authentication; 403 for missing permissions/mobile eligibility; 404 for nested
parent mismatches or immutable mutations; 409 for verified named unique-index
conflicts, MySQL lock timeouts/deadlocks, or protected option references. Unrelated
database failures are not mislabeled. Field errors preserve existing form field
names (for example `module` and `question_revision`); nested option errors appear
under `options`. Clients must map them to the corresponding `_id` inputs.

Flutter assessment authoring is future work. Forms must respect independent
permissions, load answer configuration only through authorized revision reads,
invalidate metadata/revision caches after successful writes, and handle 401,
403, 404 and 409 without blindly replaying mutations. No learner attempt, score,
completion, certificate, assignment pin or private media state is changed by
these authoring APIs.
