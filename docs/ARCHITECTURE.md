# Architecture

## 1. Purpose

This document describes the current architecture of the Garden's Need Training Module Application, the boundaries between its major components, and the architectural principles that govern future development.

The application consists of:

- a Django web application
- a Django REST API under `/api/v1/`
- a Flutter Android employee application
- MySQL as the authoritative relational database
- protected training-media delivery
- server-side business rules and audit controls

The architecture is intentionally designed so that security-sensitive business logic remains on the backend.

---

## 2. Architectural Principles

The application follows these core principles:

1. **Backend authoritative**
   - The server owns security-sensitive business state.
   - Clients do not determine authoritative completion, scoring, ownership, or permissions.

2. **Server-side authorization**
   - Permissions and ownership are enforced by backend views, services, querysets, and model constraints.
   - UI visibility is never treated as authorization.

3. **Immutable published training**
   - Published TrainingVersions are immutable.
   - Corrections require a new version.

4. **Assignment version pinning**
   - An assignment remains attached to the TrainingVersion it was created against.
   - New assignments use the appropriate latest published version.

5. **Protected media**
   - Training video is not exposed through unrestricted public media URLs.
   - Playback uses the existing session-based protected media architecture.

6. **Explicit lifecycle**
   - Training versions follow Draft → Published → Retired.

7. **Narrow changes**
   - New features should build on existing architecture rather than introducing parallel systems unnecessarily.

8. **Auditability**
   - Security-sensitive business operations should leave an appropriate audit trail.

9. **Production-oriented validation**
   - MySQL is the authoritative backend test environment for full-suite validation.
   - Flutter and JavaScript validation are part of the repository validation workflow.

---

## 3. High-Level System

```text
                    Garden's Need Training System
                              |
              +---------------+---------------+
              |                               |
        Django Web App                    Flutter Android
              |                               |
              +---------------+---------------+
                              |
                       Django REST API
                           /api/v1/
                              |
                     +--------+--------+
                     |                 |
                  Services          Models
                     |                 |
                     +--------+--------+
                              |
                            MySQL
                              |
                  +-----------+-----------+
                  |                       |
             Audit Records          Training Media
                                          |
                                Protected Media Delivery
```

The Django application remains the central authority.

The Flutter application is a client of the API, not an independent business-rule engine.

---

## 4. Current Product Surfaces

The application currently has two primary client surfaces.

### 4.1 Django Web Application

The web application provides browser-based workflows for administrative, training, management, and learner operations.

It includes functionality for areas such as:

- authentication
- Employees
- organization hierarchy
- training management
- training versions
- modules and lessons
- assignments
- learning progress
- assessments
- certificates
- reporting
- audit access
- protected video playback

The web application uses Django's authentication, authorization, CSRF, ORM, templates, forms, and server-side business logic.

### 4.2 Flutter Android Application

The Flutter application is the employee-facing mobile client.

Current completed foundation includes:

- Android project foundation
- API networking
- secure credential storage
- authentication
- application shell
- dashboard
- profile
- assignment list
- assignment detail
- module navigation
- lesson navigation
- TEXT lesson completion
- learning progress
- previous/next navigation
- learning-flow integration handling

M16 extends this foundation with secure learning/video behavior.

Android is the V1 mobile target. iOS is deferred until Android is stable and released.

---

## 5. Backend Architecture

The backend is a Django application backed by MySQL.

Conceptually:

```text
HTTP Request
    |
    v
Django URL routing
    |
    +-------------------+
    |                   |
 Web Views           DRF API Views
    |                   |
    +---------+---------+
              |
       Authorization
              |
       Business Logic
              |
       Django Models
              |
            MySQL
```

The backend is responsible for:

- authentication
- authorization
- ownership
- lifecycle validation
- assignment state
- learning state
- progress validation
- assessment scoring
- certificate eligibility
- audit events
- protected media authorization
- concurrency controls

---

## 6. Django Application Structure

The project is organized around Django applications and supporting API/configuration modules.

Major conceptual areas include:

```text
config/
training/
api/
mobile/
```

The exact source-file organization may evolve, but architectural responsibilities should remain clear.

### 6.1 Training Domain

The training domain owns concepts including:

- Training
- TrainingVersion
- Module
- Lesson
- TrainingAssignment
- LessonProgress
- VideoWatchSession
- Assessment
- AssessmentQuestion
- QuestionRevision
- AssessmentAttempt
- Certificate
- audit-related records

Business rules should remain close to the domain they govern.

### 6.2 API Layer

The API layer exposes mobile-facing functionality through `/api/v1/`.

API views should:

- authenticate the request
- validate authorization
- resolve trusted backend relationships
- validate input
- invoke appropriate business logic
- return stable API responses

The API should not become a second implementation of the same business rules already enforced by the domain.

---

## 7. API Architecture

The mobile API is path-versioned:

```text
/api/v1/
```

The current API foundation includes authentication and employee learning workflows.

Representative endpoints include:

```text
POST /api/v1/auth/login/
POST /api/v1/auth/refresh/
POST /api/v1/auth/logout/
GET  /api/v1/auth/me/

GET  /api/v1/dashboard/

GET  /api/v1/assignments/
GET  /api/v1/assignments/<id>/

POST /api/v1/assignments/<id>/lessons/<lesson_id>/complete/
GET  /api/v1/assignments/<id>/lessons/<lesson_id>/progress/

POST /api/v1/assignments/<id>/lessons/<lesson_id>/sessions/
POST /api/v1/assignments/<id>/lessons/<lesson_id>/progress/
POST /api/v1/assignments/<id>/lessons/<lesson_id>/sessions/<session_id>/end/

Protected session-based media delivery
```

The exact endpoint set may expand as later milestones are implemented.

API versioning is currently URL-based rather than header-negotiated.

### M17 Phase 1: learner assessment API

All four endpoints require bearer JWT authentication and an active linked Employee.
Lookups are restricted to that Employee, including for staff or administrator users.
They reuse the website's eligibility, start/resume and submission operations in
`assessments/views.py`; grading is not implemented separately in the API.

| Method | `/api/v1/` path | Response |
|---|---|---|
| GET | `assignments/<assignment_id>/assessments/` | `assignment_id`, `training_version_id`, `assessments` |
| POST | `assignments/<assignment_id>/assessments/<assessment_id>/attempts/` | Attempt detail; 201 for a new attempt, 200 for resume |
| GET | `assessment-attempts/<attempt_id>/` | Attempt detail or persisted result |
| POST | `assessment-attempts/<attempt_id>/submit/` | Persisted result; 200 after successful submission, including an expired result |

Each overview entry contains `id`, `kind`, nullable `module_id`, `title`, `sequence`,
`is_required`, `pass_percentage`, nullable `time_limit_minutes`, `max_attempts`,
`attempts_used`, `attempts_remaining`, nullable `ongoing_attempt_id`, `passed`,
`completed`, `can_start`, `can_resume`, nullable `blocking_reason`, and `attempts`.
Here `completed` means this assessment has been passed, not that the assignment
is complete. Attempt summaries include ID, number, status, start/deadline/submission
timestamps, score, maximum points, passing-threshold snapshot and pass state.
`can_start` describes creation of a new attempt; `can_resume` describes the existing
one. Clients should display the server's blocking reason rather than recreate rules.
Overview entries are ordered with module quizzes first, by module position and
assessment sequence, then the final assessment; primary keys provide a stable tie-breaker.

Attempt detail adds `assignment_id`, `assessment_id`, `training_version_id`,
`assignment_status`, nullable `certificate_id`, `questions` and `answers` to the
summary. Scores and thresholds are Decimal strings; timestamps use ISO 8601.
An ongoing attempt returns ordered questions with `id` (the **AssessmentQuestion**
ID, not the question-bank ID), `position`, `points`, `prompt`, `type` (`SINGLE_CHOICE`
or `TRUE_FALSE`), and ordered
`options` containing only `id`, `text`, `position`. Its `answers` list is empty.
No correctness flags, explanations or answer-key IDs are returned. Closed attempts
return an empty `questions` list and recorded answers with `assessment_question_id`,
`presented_position`, `prompt`, nullable `selected_option_id`/`selected_option_text`,
`points_possible`, and `points_awarded`. No complete answer key is returned.

Submission accepts this JSON object only:

```json
{"answers": {"123": 456, "124": null}}
```

Keys identify the attempt's AssessmentQuestions; values identify options from the
exact frozen revisions. Missing/null answers score zero. Legacy integer strings
and empty-string unanswered values remain accepted by the shared answer parser.
Malformed/duplicate normalized IDs, foreign questions/options, and extra top-level
fields (including client-supplied score/pass/completion) are rejected. Results are
always calculated and stored server-side.

Expected errors use the existing `{"error":{"code":"...","message":"...","fields":{}}}` envelope:
400 for invalid input, 401 for missing/invalid/expired JWT, 403 for an inactive or
missing Employee, 404 for unavailable/foreign IDs, and 409 for state conflicts such
as prerequisites, exhausted attempts, restarting a passed assessment, or duplicate
submission. Method violations return 405 through the same handler. Inactive Users
are rejected by JWT authentication.

Approved assessment semantics:

- Assessments remain pinned to the assignment's published or retired version.
- Once passed for an assignment, no new attempt may be started through the API or
  website. History and persisted results remain readable.
- Starting again resumes the existing ongoing attempt, including after its stored
  deadline. GET/resume does not expire it. There is no answer-draft persistence.
- Submission at the deadline is allowed; submission strictly after it records an
  EXPIRED, zero-score, non-passing result with unanswered rows. Supplied option IDs
  must still belong to the frozen questions. There is no automatic expiry worker.
- Required module lessons (including authoritative VIDEO completion) gate quizzes;
  required lessons and quizzes gate the final assessment. A passed quiz is recorded
  as an AssessmentAttempt, not a LessonProgress row.
- Mutations preserve Employee → TrainingVersion → Assignment → Attempt lock order.
  Concurrent starts resume one attempt; concurrent submissions grade once and
  reject the duplicate. Passing invokes existing assignment completion and
  idempotent certificate issuance in the same transaction.
- `certificate_id` references an already-issued certificate; GET never issues one.
  Phase 1 initially covered assessment endpoints; subsequent M17 certificate APIs
  and Flutter integration are implemented below. Autosave, offline queues,
  abandonment and new expiry mechanisms are not implemented.

### M17 certificate APIs and Flutter integration

`GET /api/v1/certificates/` and `GET /api/v1/certificates/<certificate_id>/`
require JWT authentication, an active linked Employee and ownership through the
certificate's assignment. The list is paginated, ordered newest-first with a primary-key
tie-breaker. Detail returns historical employee/training/version snapshots, issue
date and revocation state. Revoked certificates remain readable by their owner.
These read-only endpoints do not issue/revoke certificates or expose document downloads.

Flutter assessment models, repository and Riverpod controllers consume the overview,
start/resume, attempt-detail and submission contracts. Implemented screens cover
eligibility/blocking reasons, question selection/navigation, submission confirmation,
server-confirmed results, retry eligibility and history. Deadline displays do not
determine expiry or grades. Uncertain submissions are reconciled through a read,
not an automatic resubmission; unsubmitted selections are not represented as saved drafts.
Account/generation guards prevent stale responses from showing another learner's state.

Flutter certificate models, repository, controllers and list/detail screens consume
the paginated API and display authoritative historical data, including revoked states.
Profile, Dashboard and completed-training certificate links, and assignment/module
assessment entry points, reuse the existing router and Dashboard/Learning/Profile tabs.
`MyApp` supplies both themes with `ThemeMode.system`; shared typography/layout is
preserved, and theme changes retain selected answers and certificate state.

Separate validation checkpoints: foundation validation passed **436/436 Django/MySQL**
tests; after theme integration, **316/316 Flutter** tests passed, the analyzer was clean
and a debug APK built successfully. Android core M17 end-to-end flows passed;
revoked-certificate runtime QA was blocked by a missing fixture, not passed.
Automated revoked-state tests exist. These records do not imply a combined rerun,
commit, merge or release.
The subsequent ordering-review run passed **59/59 focused assessment/certificate API
tests** and **438/438 full Django/MySQL tests**, plus system and migration-drift checks.
Flutter was not rerun for that backend/documentation change.

---

## 8. Authentication Architecture

### Web

The Django web application uses:

- Django authentication
- session middleware
- CSRF protection
- permission/group authorization

### Mobile API

The mobile API uses Simple JWT.

The authentication flow is conceptually:

```text
Flutter
   |
   | credentials
   v
POST /api/v1/auth/login/
   |
   v
Django authentication
   |
   v
Active Employee validation
   |
   v
Access + Refresh tokens
```

Refresh tokens are rotated and blacklisted according to the configured Simple JWT policy.

API logout blacklists the supplied refresh token after validating ownership.

Already-issued access tokens are not immediately revoked by logout. Active Employee validation remains an additional server-side protection.

---

## 9. Flutter Architecture

The Flutter application follows a layered client architecture.

Conceptually:

```text
Screens / Widgets
       |
Providers / State
       |
Repositories
       |
API Client
       |
Secure Storage / HTTP
       |
Django REST API
```

### Presentation Layer

Responsible for:

- rendering screens
- user interaction
- navigation
- loading/error states
- temporary UI state

It must not become the authority for business security rules.

### State Layer

Responsible for:

- holding server-backed state
- coordinating screen updates
- invalidating stale data
- managing loading and mutation states

### Repository Layer

Responsible for:

- API operations
- translating API responses into application models
- keeping network concerns out of widgets

### API Client

Responsible for:

- HTTP requests
- authentication headers
- token handling
- API error interpretation
- common network behavior

### Secure Storage

Sensitive authentication material is stored using the appropriate secure storage mechanism rather than ordinary application preferences.

---

## 10. Flutter Navigation

The employee application uses a structured navigation flow.

Conceptually:

```text
Dashboard
   |
   +--> Assignments
           |
           +--> Assignment Detail
                    |
                    +--> Module
                           |
                           +--> Lesson
                                  |
                                  +--> Learning / Completion
```

Navigation should derive available actions from server-backed state.

The client must not use navigation restrictions as the only authorization mechanism.

---

## 11. Backend and Flutter Responsibility Boundary

The responsibility boundary is deliberate.

### Backend owns

- authentication validity
- authorization
- Employee ownership
- Manager scope
- assignment ownership
- TrainingVersion selection
- lifecycle state
- lesson completion authority
- video progress authority
- assessment scoring
- pass/fail
- certificate eligibility
- audit actor and target
- security-sensitive validation

### Flutter owns

- presentation
- navigation
- local UI state
- loading indicators
- optimistic usability behavior where safe
- API communication
- local caching where appropriate
- playback UI
- temporary playback state

Flutter must never turn a locally calculated value into authoritative business state.

---

## 12. Training Domain Model

The primary training structure is:

```text
Training
└── TrainingVersion
    └── Module
        └── Lesson
```

A TrainingVersion represents a concrete version of training content.

Published versions are immutable.

---

## 13. Training Version Lifecycle

TrainingVersion follows:

```text
DRAFT
   |
   v
PUBLISHED
   |
   v
RETIRED
```

### Draft

Draft versions may be edited according to authorization rules.

### Published

Published versions are frozen.

Content, assessment structure, answer keys, and published media associated with the version must not be modified in place.

### Retired

Retired versions remain available for historical integrity and existing assignments but cannot receive normal new assignments.

---

## 14. Assignment Version Pinning

Assignments are pinned to the TrainingVersion selected when the assignment is created.

Conceptually:

```text
Employee
   |
   v
TrainingAssignment
   |
   +----> TrainingVersion
              |
              +----> Modules
              |
              +----> Lessons
              |
              +----> Assessment
```

If a newer TrainingVersion is published later:

```text
Old Assignment ----> Old Version
New Assignment ----> New Version
```

Existing assignments are not automatically migrated.

This preserves historical training integrity and makes completion reproducible.

---

## 15. Training Content Immutability

Anything that has been published must be treated as historical content.

This includes:

- lesson content
- training structure
- assessment questions
- answer keys
- relevant question revisions
- published media

If a published training requires correction, the preferred architecture is:

```text
Published V1
     |
     | correction
     v
Draft V2
     |
     v
Published V2
```

The old published version remains unchanged.

---

## 16. Learning State

Learning state is associated with the assignment and its exact TrainingVersion.

Conceptually:

```text
TrainingAssignment
       |
       +---- LessonProgress
       |
       +---- VideoWatchSession
       |
       +---- AssessmentAttempt
       |
       +---- Certificate
```

This prevents progress from one training version from silently becoming progress for another.

---

## 17. Lesson Architecture

Lessons may contain different content types.

Current learning flow supports TEXT lessons and is being extended for VIDEO learning.

The client should determine presentation from the server-provided lesson type.

The backend remains responsible for determining whether the lesson is actually complete.

---

## 18. Text Lesson Completion

TEXT lesson completion is a server-authorized mutation.

Conceptually:

```text
Flutter
   |
   | complete lesson
   v
API
   |
   +--> authenticated?
   |
   +--> active Employee?
   |
   +--> owns assignment?
   |
   +--> lesson belongs to assignment/version?
   |
   +--> state permits completion?
   |
   v
Persist completion
```

The client may update its local presentation after successful server confirmation, but the server remains authoritative.

---

## 19. Video Architecture

Video is designed as protected streaming rather than downloadable training content.

The V1 architecture reuses the existing M13 session-based protected media endpoint.

Conceptually:

```text
Flutter Video Player
        |
        v
Playback Session API
        |
        v
Open Watch Session
        |
        v
Protected Media Endpoint
        |
        +--> Employee authorization
        +--> Assignment authorization
        +--> Lesson/version validation
        +--> Session validation
        |
        v
Video bytes
```

No unrestricted public media route should be introduced.

---

## 20. Video Watch Sessions

A VideoWatchSession represents an authorized playback context.

It provides a server-side boundary around media access and playback progress.

A session is associated with the relevant:

- Employee
- assignment
- lesson
- TrainingVersion

The backend validates session state before serving protected media or accepting relevant playback mutations.

Closed or stale sessions must not continue to provide unrestricted access.

---

## 21. Video Progress

The backend records observed playback coverage.

The architecture does not trust the client to submit:

- total watched seconds
- arbitrary watched ranges
- completion state

The backend instead derives progress from validated observations.

Conceptually:

```text
Playback observation
        |
        v
Server validation
        |
        v
Position / elapsed-time checks
        |
        v
Watched interval
        |
        v
Interval merge
        |
        v
Authoritative coverage
```

---

## 22. Anti-Skip Model

The existing playback system protects against simple forged progress.

Forward movement is constrained by server-observed playback progression and elapsed time.

Already-watched areas may be replayed without creating additional unique coverage.

A large heartbeat gap resets the position baseline rather than awarding continuous playback credit.

The backend also validates:

- session state
- ownership
- lesson
- TrainingVersion
- assignment state
- position bounds
- progress history

The system is not DRM.

It cannot prevent:

- screen recording
- external cameras
- determined local capture

---

## 23. Video Completion

Video completion is calculated by the backend using validated watched coverage and the lesson's configured completion threshold.

The Flutter client may display progress and completion status, but it cannot directly set authoritative completion.

This is important because a mobile client can be modified or manipulated outside the application's normal UI.

---

## 24. Media Storage Boundary

Development/local media storage may use the existing application storage architecture.

The storage implementation should remain behind a clear boundary so that production storage can later move to object storage or another infrastructure service.

The authorization rule must not depend on the storage implementation.

The architectural requirement is:

```text
Authorized application request
          |
          v
Authorization boundary
          |
          v
Storage implementation
```

Not:

```text
Public object URL
      |
      v
Training video
```

---

## 25. Assessments

Assessments are tied to the relevant TrainingVersion.

The structure is conceptually:

```text
Assessment
└── AssessmentQuestion
    └── QuestionRevision
```

Assessment attempts are associated with the Employee's assignment and the exact assessment/version context.

The backend calculates:

- correctness
- points
- score
- pass/fail

The client does not provide authoritative scoring.

---

## 26. Assessment Immutability

Published assessment content is frozen with the TrainingVersion.

Attempts retain the question/revision context required to reproduce what the learner was assessed against.

Later changes to future training versions must not rewrite the historical meaning of an existing attempt.

---

## 27. Certificates

Certificates are generated by backend rules.

Conceptually:

```text
Assignment
    |
    +--> Required learning complete
    |
    +--> FINAL assessment passed
    |
    +--> Same TrainingVersion
    |
    v
Certificate
```

A certificate references the earned TrainingVersion.

Certificate issuance does not modify the underlying TrainingVersion.

Revocation preserves the certificate record and records the revocation event.

---

## 28. Authorization Architecture

Authorization uses multiple layers.

Conceptually:

```text
Authentication
      |
      v
Permission
      |
      v
Object ownership
      |
      v
Manager/reporting scope
      |
      v
Lifecycle/state
      |
      v
Business validation
```

No single UI role check should be treated as sufficient.

---

## 29. Manager Scope

Manager access is based on the Manager's actual Employee relationship and reporting hierarchy.

The backend computes the authorized employee scope and applies it before additional filters.

Conceptually:

```text
Manager
   |
   v
Own Employee record
   |
   v
Reporting descendants
   |
   v
Authorized queryset
   |
   v
User filters
```

Filters cannot expand the underlying authorization scope.

---

## 30. Audit Architecture

Security-sensitive business operations may generate audit events.

Audit data uses server-derived:

- actor
- target
- timestamp
- action
- controlled before/after information

Audit writes are transaction-aware where required so that rolled-back business operations do not create false success history.

Audit records are application-protected but are not intended to be tamper-proof against privileged database access.

---

## 31. Concurrency Architecture

Concurrency-sensitive operations use database-backed integrity controls.

Depending on the operation, this may include:

- `transaction.atomic`
- `select_for_update`
- uniqueness constraints
- model validation
- narrow integrity-error handling

The system must not rely on a check-then-save sequence alone when concurrent requests can modify the same logical state.

---

## 32. Database Architecture

MySQL is the authoritative relational database.

Conceptually:

```text
Django ORM
    |
    v
MySQL
    |
    +--> Users / Employees
    +--> Training
    +--> Assignments
    +--> Progress
    +--> Sessions
    +--> Assessments
    +--> Certificates
    +--> Audit records
```

Database constraints are used as the final integrity layer where appropriate.

Full backend validation is performed against MySQL rather than relying only on SQLite-style development behavior.

---

## 33. Transaction Boundaries

Transactions are used around operations where multiple writes must remain consistent.

Examples include:

- assignment creation
- Employee deactivation
- assessment attempt operations
- playback progress/session mutations
- certificate issuance
- lifecycle transitions

Lock ordering should remain consistent within related operations to reduce race conditions and deadlock risk.

---

## 34. API Error Architecture

API errors use the project's structured error response model.

Conceptually:

```json
{
  "error": {
    "code": "...",
    "message": "...",
    "fields": {}
  }
}
```

HTTP status remains meaningful.

Typical statuses include:

- 400 for invalid input
- 401 for unauthenticated requests
- 403 for forbidden actions
- 404 for unavailable/out-of-scope resources
- 409 for conflicts
- 429 for throttling

Unexpected server failures remain server errors and must not be disguised as successful responses.

### M18 first batch: learner read recovery

Assignment list/detail and Dashboard read providers depend on the active authenticated
employee identity. Dio cancellation tokens are cancelled on provider disposal/rebuild;
assignment pagination checks cancellation before continuing and never follows an
external `next` URL. Obsolete responses do not become current learner data; consumers
hide prior content during reload/recovery.

Assignment reads disable Riverpod's implicit retry, matching the existing Dashboard
policy. Explicit retries invalidate the read provider. Pull-refresh failures remain
visible provider errors without a second unhandled future. No generic Dio retry,
automatic JWT refresh or POST replay is added. M16 playback and M17 assessment
reconciliation retain their unchanged mutation lifecycles.

Learner entry screens use `ApiErrorView`: network/timeout messages offer explicit
retry, 401/403 offer explicit existing logout/sign-in recovery, and permanent read
failures offer no retry loop. Unexpected local exceptions show a generic message.
The shared error panel has live-region semantics and a scrollable large-text/narrow
landscape layout using the existing Light/Dark themes.

Batch 1 added no notification channel, credential, offline queue or client-authoritative
completion. The existing authenticated status endpoint is a connectivity check, not a
full readiness service. Notification persistence/APIs were added in the batches below.

### M18 in-app notifications (Batches 2A-2D)

`notifications.Notification` stores the Employee owner, assignment, event type,
server-derived text, timestamps and a deterministic unique key. ASSIGNED/COMPLETED
events share the assignment/completion transaction; rollback removes the event.
Batch 2D implements APPROACHING/OVERDUE generation through the same validated event
insertion path, without changing assignment/completion event behavior.

JWT-only APIs require `IsAuthenticated` and `IsActiveEmployee`:

- `GET /api/v1/notifications/`: owned list, newest `created_at` then PK descending;
  standard page-number pagination (20 default, 100 maximum).
- `GET /api/v1/notifications/unread-count/`: `{"unread_count": n}`, without writes.
- `POST /api/v1/notifications/<id>/read/`: returns the read-only notification fields;
  foreign/missing IDs return 404. Fields are id, type, title, message, assignment_id,
  created_at, is_read and read_at. Owner/internal deduplication fields are not exposed.
- `POST /api/v1/notifications/read-all/`: `{"updated_count": n}`, current owner only.

Read POSTs accept an empty payload only. A conditional owner/unread-filtered SQL
update changes only `read_at`/`updated_at`, preserving the first timestamp under
concurrent/repeated requests. The timestamp is clamped to creation time if the clock
moves backwards. Generic validated-queryset updates remain prohibited; immutable
event content and database checks remain in place. These read actions add no parent locks.

Batch 2C subsequently added the Flutter Notification Center and Dashboard bell.
The notification migration has been applied to authorized local development;
automated backend validation still uses only the isolated MySQL test database.

#### Deadline reminder command (Batch 2D)

Run once with an explicitly selected rollout timestamp:

```text
python manage.py generate_training_notifications --activation-cutoff <FIXED_ACTIVATION_ISO8601>
```

The cutoff must be a timezone-aware ISO-8601 timestamp no later than server time.
There is deliberately no implicit cutoff or automatic activation write. M20 must
record it once as `NOTIFICATIONS_ACTIVATED_AT` in persistent deployment configuration
and explicitly pass it as `--activation-cutoff` on every
hourly invocation, and retain it across restarts/redeployments. Do not compute a
fresh cutoff per run. Deadlines strictly before the cutoff are never backfilled;
deadlines at/after activation remain eligible on subsequent runs.

Candidates require an active Employee, an ASSIGNED/IN_PROGRESS assignment, a
deadline, and its pinned PUBLISHED/RETIRED version. APPROACHING is `now < due_at <=
now + 24 hours`; OVERDUE reuses `reports.queries.overdue_condition` (`due_at < now`).
At exact equality no event is due until time advances. The service locks Employee,
TrainingVersion, then Assignment and rechecks current deadline/state/activity under
one per-assignment transaction before generating an event. Concurrent completion,
cancellation, rescheduling and deactivation therefore cannot bypass the recheck.

Database-unique assignment/type/canonical-UTC-deadline keys deduplicate repeated or
concurrent runs. A changed deadline creates a distinct context; historical event
text and ownership remain immutable. The shared insertion path handles only the
expected uniqueness race and propagates unrelated validation/database errors.
Rollback removes an uncommitted reminder. Transactions are per assignment: an error
may leave earlier committed reminders intact; rerunning safely deduplicates them.
No assignment, lesson progress, attempt,
certificate or version is saved by the command. Messages contain only server-derived
training title/version/deadline, never answers, scores, tokens or media links.

No scheduler, retention cleanup, historical backfill or push/email/SMS integration
is installed. Hourly scheduling and production activation are M20 dependencies.
M18 implementation is complete and uncommitted; final acceptance/review is pending.

#### M18 acceptance evidence and operational boundary

The Flutter Notification Center and Dashboard bell are complete. Core populated
Android QA verified all four types, read/count synchronization, first-read timestamp
preservation, owned-assignment navigation, offline Retry and account switching.
System Light/Dark contrast and singular/plural count copy are fixed; app-theme tests
cover counts 0, 1 and 2, semantics and contrast. Latest separate checkpoints are
**494/494 Django/MySQL** (Batch 2D) and **392/392 Flutter**, clean analyzer and successful
debug APK (count-copy fix). These are historical run results, not simultaneous or
documentation-task reruns.

All five disposable notifications were removed; QA Assignment **95** remains
cancelled with explicit retention authorization. Existing completion/progress,
assessment and certificate history was preserved. The 2026-10-17 focused lifecycle
pass verified background/resume, explicit offline recovery, post-resume logout/account
switching, existing expired-session recovery and both system themes. A still-pending
request at backgrounding and exact expiry occurring in the background were not
established; no forced token/clock change or new fixture was used. `docs/TASKS.md`
records the exact runtime outcomes and specialized live-QA limitations. Direct
authenticated pagination/IDOR/repeated-mutation checks, inaccessible-assignment
navigation and full TalkBack remain
live verification limits, with existing automated coverage where applicable.

Production rollout must persist one operator-selected activation cutoff and pass it
unchanged to hourly reminder runs. Scheduling, monitoring and deployment health
checks are M20 work. The existing authenticated status API proves connectivity;
it does not claim database/storage readiness or production monitoring. No additional
notification channel, automatic JWT refresh or offline mutation queue is implied.

---

## 35. Security Boundary

The security boundary is primarily the backend.

```text
                 UNTRUSTED CLIENT
                        |
          +-------------+-------------+
          |                           |
       Browser                    Flutter
          |                           |
          +-------------+-------------+
                        |
                        v
                 Django Backend
                        |
             +----------+----------+
             |                     |
       Authorization          Validation
             |                     |
             +----------+----------+
                        |
                        v
                     MySQL
```

The clients are treated as untrusted execution environments.

---

## 36. Offline Boundary

V1 does not make the Flutter application an authoritative offline training engine.

Offline behavior may support usability such as:

- retaining non-sensitive UI state
- caching appropriate read data
- handling temporary connectivity loss

However, authoritative completion and security-sensitive state remain server-controlled.

The architecture must not introduce a client-only offline completion path that bypasses backend validation.

---

## 37. Secure Storage

The Flutter application uses secure storage for sensitive authentication material.

Ordinary preferences/local state must not be treated as a secure credential vault.

Local storage does not become authoritative for:

- permissions
- Employee identity
- completion
- assessment score
- certificate eligibility

---

## 38. Android Security Boundary

Android-specific protections may supplement backend controls.

Where appropriate, the application may use platform protections such as `FLAG_SECURE` for sensitive screens or video playback.

These protections are defense-in-depth.

They do not replace:

- backend authorization
- protected media delivery
- session validation
- server-side progress calculation

They also cannot guarantee prevention of all forms of capture.

---

## 39. CI Architecture

Repository validation includes multiple technology surfaces.

The CI workflow should validate at least:

### Backend

- Django checks
- MySQL-backed test suite
- migration consistency
- dependency consistency where configured

### Flutter

- dependency resolution
- static analysis
- Flutter tests
- Android build validation where configured

### JavaScript Playback

- existing playback-related JavaScript tests

CI should use versions compatible with the project's declared SDK requirements.

The current workflow uses a Flutter release compatible with the project's Dart SDK requirement and modern Node setup.

---

## 40. Testing Architecture

Testing is risk-based.

### Backend

The Django test suite validates:

- authentication
- authorization
- ownership
- lifecycle
- assignments
- progress
- playback
- assessments
- certificates
- reporting
- audit behavior
- concurrency-sensitive paths

### Flutter

Flutter tests validate:

- state behavior
- repositories
- models
- screens
- learning flow
- integration behavior

### JavaScript

Existing playback JavaScript tests validate browser playback behavior where applicable.

### Runtime QA

High-risk features receive runtime validation in addition to automated tests.

The testing strategy should favor meaningful coverage over indiscriminate test volume.

---

## 41. Historical M15 Validation Baseline

The historical M15 snapshot includes:

- Django/MySQL full suite: 348 tests
- Flutter suite: 81 tests
- JavaScript playback tests: 3 tests
- Django checks passing
- migration consistency validated
- dependency compatibility validated
- Flutter analysis passing
- Android debug build validated
- repository diff checks passing

These counts are a snapshot and will increase as later milestones add functionality.

The latest CI/local output is authoritative if these numbers change.

---

## 42. Current Milestone State

Completed:

```text
M0-M12  Core web/backend platform
M13     Mobile API Foundation & Versioning
M14     Flutter / Android Foundation
M15     Employee App Core
M16     Learning + Secure Video
M17     Assessment + Certificates (afdadb4; pushed checkpoint)
```

Active:

```text
M18     Notifications + Resilience (learner recovery and in-app notifications)
```

Planned:

```text
M19     Android Release Candidate
M20     Production + Deployment Hardening
M21     Final Bug Hunt + Security + Repository Review
M22     Readability + Refactor + Garden's Need Visual Polish
M23     Final Acceptance + Android V1 Release
```

The roadmap document is the canonical source for milestone sequencing.

---

## 43. M16 Architectural Direction

M16 should extend the existing architecture rather than introduce a parallel media system.

The intended flow is:

```text
Flutter
   |
   +--> assignment/lesson API
   |
   +--> start watch session
   |
   +--> protected media request
   |
   +--> playback observations
   |
   +--> progress/session updates
   |
   v
Django backend
   |
   +--> authorization
   +--> session validation
   +--> progress calculation
   +--> completion calculation
   |
   v
MySQL + protected media storage
```

M16 should reuse the existing M13 session-based protected media endpoint.

It should not create an unrestricted `/media/...` playback route or duplicate the backend's existing playback rules in Flutter.

---

## 44. M16 Media Rules

M16 follows these rules:

- V1 media is streaming-only.
- Published media is immutable.
- Replacing published media requires a new TrainingVersion.
- Upload validation must reject unsupported/unsafe media.
- Media access remains authenticated and authorized.
- Watch sessions remain part of the media authorization boundary.
- Progress remains server-authoritative.
- Completion remains server-authoritative.
- Android playback protections are defense-in-depth.
- Storage remains replaceable behind an abstraction where practical.

---

## 45. Future Production Architecture

The production architecture may eventually separate infrastructure concerns such as:

```text
                    Internet
                       |
                 Reverse Proxy
                       |
              +--------+--------+
              |                 |
          Django Web        Django API
              |                 |
              +--------+--------+
                       |
                     MySQL
                       |
              Protected Storage
```

A CDN or object-storage layer may be introduced later.

If it is introduced, it must preserve the authorization boundary established by the application.

A storage optimization must never silently turn protected training media into publicly accessible objects.

---

## 46. Deployment Configuration

Production configuration is environment-driven.

Sensitive configuration includes:

- Django secret key
- database credentials
- allowed hosts
- HTTPS settings
- secure cookies
- HSTS
- proxy behavior
- storage configuration
- API/infrastructure limits

Development defaults must not be treated as production configuration.

Production deployment must explicitly verify Django deployment checks and the complete HTTPS/proxy topology.

---

## 47. Dependency Boundaries

Dependencies should be introduced only when they provide meaningful functionality that is not already available through the platform or existing project stack.

New dependencies should be evaluated for:

- security
- maintenance
- compatibility
- licensing where applicable
- bundle/build impact
- operational impact

M16 should continue using the existing Flutter video architecture unless actual requirements demonstrate that the current implementation cannot satisfy the required playback behavior.

A new playback library should not be introduced merely for convenience.

---

## 48. Architectural Change Policy

Architecture-sensitive changes require focused review.

Examples include:

- authentication
- authorization
- API versioning
- TrainingVersion lifecycle
- assignment versioning
- playback
- media delivery
- assessment scoring
- certificate issuance
- audit behavior
- database locking
- storage architecture
- production security settings

The preferred process is:

1. inspect current implementation
2. identify the affected boundary
3. determine whether existing architecture already solves the problem
4. make the narrowest correct change
5. add or update focused tests
6. run the relevant full validation
7. review the final diff
8. run automated review where applicable

Do not introduce a second implementation of an existing business rule without a concrete architectural reason.

---

## 49. Documentation Architecture

Documentation must reflect the actual repository state.

`ROADMAP.md` is the canonical milestone roadmap.

Other documentation should remain consistent with it.

When architecture or product decisions change, update the relevant documentation rather than leaving contradictory historical instructions in active sections.

Historical information may remain where useful, but it must be clearly historical and must not be presented as the current architecture.

---

## 50. Current Architectural Status

M16 secure cross-platform playback is complete. M17 assessment/eligibility and
certificate list/detail APIs, Flutter data/state/screens, navigation and system
Light/Dark integration are implemented using the existing authoritative backend.

The major foundations are in place:

- Django web application
- MySQL-backed domain model
- versioned REST API
- JWT mobile authentication
- Flutter Android client
- assignment/learning flow
- server-authoritative business rules
- protected playback/session architecture
- assessment and certificate backend
- audit architecture
- CI validation across backend, Flutter, and playback JavaScript

M17 is complete at committed/pushed checkpoint `afdadb4`, with green CI confirmed by
the user. Its previously blocked revoked-certificate runtime fixture remains a recorded
QA limitation. M18 learner recovery, notification persistence/APIs, Flutter Notification
Center and deadline generation are implemented. Core populated Android QA passed;
consolidated review and recorded lifecycle/specialized live-QA limitations are
the current checkpoint. Production reminder rollout/scheduling and operational
configuration belong to M20. M18 is uncommitted; no push, CI or release is implied.

The project should continue to favor incremental development over architectural replacement.

The final Garden's Need visual design, animation system, and broader UI polish are intentionally deferred until the dedicated M22 readability/refactor/visual-polish phase unless an earlier feature requires a functional UI treatment.

The architecture should therefore remain flexible enough to support that later visual layer without prematurely locking the final design system.
