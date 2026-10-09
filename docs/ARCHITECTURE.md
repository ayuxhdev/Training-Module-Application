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

## 41. Current Validation Baseline

The current project baseline includes:

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
```

Next:

```text
M16     Learning + Secure Video
```

Planned:

```text
M17     Assessment + Certificates
M18     Notifications + Resilience
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

The current architecture is stable enough to proceed into M16.

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

The next architectural focus is secure video learning in M16.

The project should continue to favor incremental development over architectural replacement.

The final Garden's Need visual design, animation system, and broader UI polish are intentionally deferred until the dedicated M22 readability/refactor/visual-polish phase unless an earlier feature requires a functional UI treatment.

The architecture should therefore remain flexible enough to support that later visual layer without prematurely locking the final design system.