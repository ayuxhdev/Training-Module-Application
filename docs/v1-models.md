# V1 Database Models

The Garden's Need Training Module Application uses one factory, Django's existing `auth.User`, and the domain model layer described below.

The current application architecture includes:

- Django web application
- Django REST API under `/api/v1/`
- Flutter Android application
- MySQL 8
- Protected, session-based training media
- JWT authentication for mobile API access
- Django session authentication for the web application

The database remains the authoritative source for employees, training versions, assignments, learning progress, assessments, certificates, permissions, and audit records.

All user relationships use `settings.AUTH_USER_MODEL`.

## Domain Models

| App | Models |
| --- | --- |
| organization | Department, JobRole, Employee |
| training | Training, TrainingVersion, Module, Lesson, RoleTrainingRequirement, TrainingAssignment, LessonProgress, VideoWatchSession |
| assessments | Question, QuestionRevision, QuestionOption, Assessment, AssessmentQuestion, AssessmentAttempt, AttemptAnswer |
| certifications | Certificate |
| audit | AuditLog |

The `accounts` and `reports` applications do not introduce database tables.

The mobile application, REST API, notifications, and future workforce-development features do not introduce separate duplicate domain models. They operate against the existing authoritative model layer.

---

## Factory and Organizational Structure

The application currently models **one factory**.

Employees belong to departments and job roles. Manager relationships define reporting hierarchy and are validated to prevent self-reference and recursive cycles.

Employees and linked Django users are deactivated rather than deleted.

Historical employee identity is preserved:

- employee codes cannot be repurposed
- linked user identities cannot be repurposed
- inactive employees cannot authenticate
- reactivating an employee does not automatically re-enable login access
- existing historical assignments, progress, assessments, certificates, and audit records remain associated with their original employee

Historical relationships use `PROTECT` where deleting the referenced record would invalidate historical data.

---

# Training Versioning and Lifecycle

Training content follows:

**Draft → Published → Retired**

A `TrainingVersion` begins as a draft.

Publication validates the complete version, including:

- modules
- lessons
- lesson ordering
- frozen assessment questions
- final assessment
- required curriculum structure

Published versions are immutable.

After publication:

- modules cannot be moved or structurally changed
- lessons cannot be edited
- assessment composition cannot be changed
- referenced question revisions remain frozen
- media associated with the published version must remain immutable
- retirement is the only subsequent lifecycle transition

A new release is represented by a new `TrainingVersion` and new mutable curriculum rows where required.

Existing assignments remain pinned to their assigned version.

New assignments use the latest eligible published version.

Retired versions cannot receive new assignments, but existing assignments may continue through completion.

---

# Historical Data Rules

Historical entities are preserved rather than rewritten.

Examples include:

- employee placement at assignment time
- assigned training version
- assessment question revisions
- assessment attempts
- certificate issuance data
- audit history

Assignments store department and role snapshots representing the employee's placement when the assignment was created.

The current `Employee` record represents the employee's current placement.

Changing an employee's department or role does not rewrite historical assignments.

Role-training requirements reference exact published training versions.

Creating or changing a role requirement does not itself create assignments. Future orchestration must apply active requirements idempotently while preserving an existing assignment's original source.

---

# Assignment and Learning State

A training assignment is unique per employee and training version.

The uniqueness rule applies across all assignment statuses and sources.

Retakes are represented by additional assessment attempts on the same assignment. Recurring recertification of the same version is intentionally outside the current model.

An assignment can only become complete when all required learning and assessment conditions have been satisfied.

The backend remains authoritative for:

- lesson completion
- video progress
- assessment results
- assignment completion
- certificate eligibility

The Flutter client must not independently declare an assignment complete.

---

# Lesson Progress

`LessonProgress` stores persistent learning state for an assignment and lesson.

For video lessons, `watched_ranges` stores sorted and merged intervals:

```text
[start, end]
```

Intervals are measured in seconds.

Previously recorded coverage cannot be removed.

`resume_position` is independent from coverage.

`watched_seconds` and `progress_percent` are derived values rather than independently stored totals, preventing contradictory aggregate values.

Playback progress must be based on observed playback intervals rather than trusting arbitrary client-reported totals.

The API and Flutter application must use the existing backend learning-progress contract rather than introducing a parallel client-side progress system.

---

# Video Watch Sessions

`VideoWatchSession` represents an individual playback session.

A session may contain:

- assignment
- lesson
- optional session identifier
- optional device identifier
- start position
- latest position
- active playback information
- session start/end timestamps
- session completion state

Session identifiers and device identifiers are not assumed to be globally unique.

Open sessions may be updated.

Ended sessions are immutable.

Ending positions may move backwards because a learner may seek backwards before closing a session.

Active watch seconds represent active elapsed playback time. They do not represent unique content coverage.

`completed_normally` describes how a playback session was closed. It does not itself mean that the lesson was completed.

Session records do not automatically update aggregate lesson coverage.

Playback ingestion must:

1. validate the authenticated employee and assignment
2. validate the lesson/version relationship
3. observe the actual playback interval
4. merge the interval into `LessonProgress.watched_ranges`
5. update the playback session
6. persist the related state transactionally

Session endpoints alone cannot reconstruct complete watched intervals across arbitrary seeks.

---

# Protected Training Media

V1 video is streaming-only.

The application does not expose training media as unrestricted public files.

The existing protected media flow is reused by the mobile application. M16 must not introduce a parallel media API.

The protected media route verifies the authenticated learner's authorization for the specific assignment and lesson before serving media.

Published media is treated as immutable.

Media storage is abstracted so the current local/development storage can later be replaced by object storage without changing the domain model or authorization contract.

The model layer cannot prevent a person with direct filesystem access from overwriting a file. Operational storage permissions and deployment controls therefore remain part of the security boundary.

---

# Assessments

Questions support:

- single-choice questions
- true/false questions

Question revisions provide historical answer-key stability.

Freezing a question validates the answer key.

Assessments store explicit question revisions, ordering, and marks.

An assessment attempt is tied to the applicable assessment/version.

Closed attempts and their answers are immutable, including:

- passed attempts
- failed attempts
- expired attempts
- abandoned attempts

The backend is authoritative for assessment initialization, grading, submission, pass/fail state, and attempt limits.

---

# Assessment Attempt Transaction

Attempt creation and grading must be performed transactionally.

The required workflow is:

1. Lock the assignment.
2. Allocate the next attempt number within the same transaction.
3. Create the attempt.
4. Create a row for every presented question, including unanswered questions.
5. Grade the submitted answers.
6. Submit and close the attempt.
7. Persist the resulting business state.
8. Record corresponding audit entries within the caller's shared transaction.

Concurrent requests must not create duplicate attempt numbers or inconsistent attempt state.

---

# Certificates

A certificate references:

- the employee
- the completed assignment
- the exact training version
- the qualifying final assessment attempt

Certificate issuance stores immutable snapshots required for historical rendering.

Certificate issuance is idempotent.

Revocation is one-way and does not modify the underlying training version, assignment, or assessment attempt.

A certificate therefore remains a historical record of what the learner earned and under which published version.

---

# Audit Logging

`AuditLog` records business changes requiring historical traceability.

Audit entries should be created in the same transaction as the business change.

Audit snapshots must not contain:

- passwords
- JWTs
- refresh tokens
- session secrets
- unnecessary personal information

Generic JSON fields do not automatically sanitize sensitive payloads. Callers are responsible for supplying appropriate audit data.

The audit model records the result of business operations. Automatic audit-event generation remains a workflow/service responsibility rather than a responsibility of every individual model save.

---

# Persistence Contract

`config/model_utils.py` contains reusable abstract model behavior.

Model persistence follows these principles:

- `save()` performs model validation
- lifecycle-sensitive mutations occur inside transactions
- appropriate rows are locked before mutation
- model validation enforces cross-table business rules where required
- database constraints enforce local uniqueness and integrity rules where possible
- deletion policies preserve historical data

Save validated objects individually.

Bulk create/update operations and queryset updates are not supported mutation interfaces because they bypass model lifecycle validation.

Where supported by the model layer, queryset deletion follows the model's deletion policy.

`update_fields` must not allow callers to bypass validation of the complete persisted state.

Direct SQL, `save_base()`, and Django's internal base-manager mutation paths are not supported application mutation interfaces.

There are no database triggers responsible for application-level immutability.

---

# Validation and Database Constraints

Business rules are divided between application validation and database constraints.

Model validation handles rules such as:

- reporting hierarchy cycles
- lifecycle transitions
- cross-table relationships
- version consistency
- assessment state
- assignment state
- historical immutability

Database constraints handle rules such as:

- unique employee identities
- unique assignment per employee/version
- local timestamp relationships
- valid result-state combinations
- other database-enforceable integrity rules

Manager hierarchy cycle validation remains in model validation because MySQL does not support the required self-referential validation through a normal database CHECK constraint.

Concurrency-sensitive workflows must use transactions and row locking rather than relying only on validation.

---

# Authentication and API Boundary

The REST API does not introduce a second domain-data layer.

Mobile authentication uses JWT access and refresh tokens.

The API verifies:

- authenticated user
- active linked Employee
- assignment ownership
- lesson/version relationship
- applicable authorization scope

The Django web application continues to use its existing session-authenticated flow.

The same database records are authoritative for both web and mobile clients.

The Flutter application must never maintain an independent authoritative copy of:

- assignment completion
- assessment score
- certificate status
- backend learning progress

---

# Offline Boundary

V1 does not provide unrestricted offline learning completion.

Local mobile storage may support appropriate temporary state such as:

- authentication/session information through secure storage
- UI state
- temporary resilience data where explicitly supported

Offline behavior must never allow the client to manufacture authoritative completion, assessment results, or certificates.

Any future offline capability must preserve backend authority and be introduced as an explicit architecture decision.

---

# Workflow Services

The model layer validates persisted state but does not itself implement every business workflow.

Workflow/service responsibilities include:

- training publication
- training cloning/version creation
- role-based assignment orchestration
- playback ingestion
- assessment initialization
- assessment grading/submission
- certificate rendering
- automatic audit-event generation
- notification workflows
- future assignment orchestration

These services must use the existing model invariants and transactional rules rather than bypassing them.

---

# Current Architecture Status

The current product is no longer Django-only.

### Completed

- M0-M12: core Django training platform
- M13: Mobile API Foundation and Versioning
- M14: Flutter/Android Foundation
- M15: Employee App Core

Current validated baseline:

- Django/MySQL: **348 tests**
- Flutter: **81 tests**
- JavaScript: **3 tests**

Android application package:

```text
com.gardensneed.training
```

### Current milestone

**M16: Learning + Secure Video**

M16 extends the existing model and API contracts to support secure mobile video learning.

M16 must not introduce:

- a parallel media API
- unrestricted media URLs
- client-authoritative completion
- unrestricted offline completion
- unnecessary model duplication
- unrelated architecture refactors

### Planned after M16

- M17: Assessment + Certificates
- M18: Notifications + Resilience
- M19: Android Release Candidate
- M20: Production + Deployment Hardening
- M21: Final Bug Hunt + Security + Repository Review
- M22: Readability + Refactor + Garden's Need Visual Polish
- M23: Final Acceptance + Android V1 Release

---

# Migrations and Verification

The database uses MySQL 8 for normal development and integration testing.

Migration files exist for the domain applications and use Django's configured user model.

Normal Windows development commands use the project's virtual environment:

```powershell
& .\.venv\Scripts\python.exe manage.py makemigrations
& .\.venv\Scripts\python.exe manage.py migrate
& .\.venv\Scripts\python.exe manage.py check
& .\.venv\Scripts\python.exe manage.py test organization training assessments certifications audit
```

The full backend validation baseline is currently:

```powershell
& .\.venv\Scripts\python.exe manage.py test
& .\.venv\Scripts\python.exe manage.py check
& .\.venv\Scripts\python.exe manage.py makemigrations --check --dry-run
& .\.venv\Scripts\python.exe -m pip check
& .\.venv\Scripts\python.exe manage.py test --settings=config.test_settings
```

The application also validates the Flutter and JavaScript layers separately.

The CI pipeline covers the current backend, Flutter, and JavaScript validation paths.

For concurrency-sensitive database behavior, MySQL integration testing remains authoritative. SQLite-based fallback tests are useful for isolated model validation but do not prove MySQL row-locking or concurrency semantics.

Never redirect application data into a disposable test database.

Production credentials, database grants, and deployment infrastructure are outside this document and must be managed through deployment configuration and operational controls.

---

# Model Design Principles

The model layer follows these principles:

1. **Backend authority**
   The server and database determine authoritative business state.

2. **Historical integrity**
   Published training, assignments, attempts, certificates, and audit history remain reproducible.

3. **Immutable published content**
   Published versions are never edited in place.

4. **Explicit version pinning**
   Assignments reference the exact training version they were created for.

5. **Transactional state changes**
   Concurrency-sensitive operations use transactions and row locking.

6. **Defense in depth**
   Business rules are enforced through model validation, database constraints, authorization, and workflow services.

7. **No duplicate domain state**
   Web, API, and Flutter clients use the same authoritative model layer.

8. **Streaming-only V1 media**
   Training videos are protected and served through the existing authorization boundary.

9. **Controlled offline behavior**
   Mobile clients cannot create authoritative learning results while disconnected.

10. **Risk-based evolution**
    New models and schema changes are introduced only when a real product requirement requires them.