# Architecture

## 1. Purpose

This document describes the current architecture of the Garden's Need Training Module Application.

The application is intentionally implemented as a Django monolith rather than as separate frontend and backend services.

The architecture prioritizes:

- secure backend authorization
- maintainable business logic
- strong data integrity
- clear ownership boundaries
- historical record preservation
- predictable deployment
- minimal unnecessary complexity

## 2. Technology Architecture

Current stack:

- Python 3.14
- Django 5.2 LTS
- MySQL 8
- Django built-in User model
- Django Templates
- HTML
- CSS
- basic JavaScript
- Git
- GitHub
- GitHub Actions
- Playwright for later browser and E2E testing

The V1 application does not use:

- React
- a separate SPA
- a separate REST frontend/backend architecture
- microservices

## 3. High-Level Structure

The project is organized into Django applications with separate business responsibilities.

```text
config/
accounts/
organization/
training/
assessments/
certifications/
reports/
audit/
```

At a high level:

```text
Browser
   |
   v
Django Views
   |
   +--> Forms / Validation
   |
   +--> Permission / Scope Logic
   |
   +--> Models / Business Rules
   |
   +--> Audit Logging
   |
   v
MySQL
```

Django templates render the user interface.

The backend remains authoritative for all security-sensitive state.

## 4. Application Responsibilities

### 4.1 `config`

The `config` package contains project-level Django configuration.

Responsibilities include:

- settings
- root URL configuration
- environment-based settings
- database configuration
- security configuration
- application registration

Production settings are designed to fail closed when required security configuration is missing.

### 4.2 `accounts`

The accounts application handles authentication-related concerns.

Responsibilities include:

- login
- logout
- user-facing authentication behavior
- authentication tests
- role-aware entry behavior

The project uses Django's built-in User model rather than a custom user model.

### 4.3 `organization`

The organization application manages the company structure used by training and authorization logic.

Core models include:

- Department
- JobRole
- Employee

Responsibilities include:

- departments
- job roles
- employees
- reporting relationships
- employee activation status
- manager hierarchy
- organization permissions

Employee records are preserved historically rather than casually deleted.

### 4.4 `training`

The training application contains the core learning-domain models and workflows.

Core models include:

- Training
- TrainingVersion
- Module
- Lesson
- RoleTrainingRequirement
- TrainingAssignment
- LessonProgress
- VideoWatchSession

Responsibilities include:

- training creation
- training versioning
- module ordering
- lesson ordering
- lesson content
- publishing
- retirement
- assignments
- role-based assignment requirements
- video progress
- watched ranges
- anti-skip logic
- training completion integration

### 4.5 `assessments`

The assessments application contains question and assessment functionality.

Core models include:

- Question
- QuestionRevision
- QuestionOption
- Assessment
- AssessmentQuestion
- AssessmentAttempt
- AttemptAnswer

Responsibilities include:

- question bank
- question revisions
- answer options
- lesson quizzes
- final assessments
- attempt creation
- attempt limits
- prerequisites
- answer submission
- server-side scoring
- pass/fail evaluation
- training completion integration

### 4.6 `certifications`

The certifications application manages training certificates.

Core model:

- Certificate

Responsibilities include:

- automatic certificate issuance
- unique certificate identifiers
- historical snapshots
- employee certificate access
- certificate revocation
- idempotent issuance

### 4.7 `reports`

The reports application contains dashboard and reporting behavior.

Responsibilities include:

- role-aware dashboards
- assignment reports
- overdue reporting
- completion percentages
- filtering
- manager scope enforcement
- employee-specific dashboard information

Report filtering must never broaden the user's authorized scope.

### 4.8 `audit`

The audit application records important application actions.

Core model:

- AuditLog

Responsibilities include:

- audit-event creation
- controlled metadata
- server-derived actors
- server-derived targets
- transaction-aware logging
- read-only audit history
- audit permissions

Audit records are not intended to be edited or deleted through normal application workflows.

## 5. Core Data Model

The main business relationships can be viewed as:

```text
User
 |
 v
Employee
 |
 +--> Department
 |
 +--> JobRole
 |
 +--> Manager / Reporting Relationship
 |
 +--> TrainingAssignment
        |
        v
   TrainingVersion
        |
        +--> Training
        |
        +--> Module
              |
              v
            Lesson
```

Assessment relationships:

```text
TrainingVersion / Lesson
        |
        v
    Assessment
        |
        +--> AssessmentQuestion
        |       |
        |       v
        |    QuestionRevision
        |
        v
AssessmentAttempt
        |
        v
AttemptAnswer
```

Certificate relationship:

```text
TrainingAssignment
        |
        v
   Completion
        |
        v
   Certificate
```

Audit relationship:

```text
Authenticated User
        |
        v
    Business Action
        |
        v
      AuditLog
```

## 6. Training Versioning Architecture

Training uses explicit versioning.

```text
Training
   |
   +--> TrainingVersion 1
   |
   +--> TrainingVersion 2
   |
   +--> TrainingVersion N
```

This allows:

- historical assignments to remain attached to the version actually completed
- new content to be introduced without rewriting history
- published content to remain stable
- retired content to remain available for historical records

Training version states are:

```text
DRAFT
PUBLISHED
RETIRED
```

### Draft

Draft versions may be edited according to permission rules.

### Published

Published versions represent released training content.

Published versions are protected from unsafe modification.

### Retired

Retired versions are no longer intended for new normal usage but remain preserved for historical consistency.

## 7. Training Content Hierarchy

Content follows:

```text
Training
└── TrainingVersion
    └── Module
        └── Lesson
```

Modules and lessons have defined ordering.

The parent-child relationship is derived and validated by the backend.

Clients must not be trusted to assign arbitrary parents.

## 8. Assignment Architecture

Training assignments connect employees with a specific published training version.

Assignments may originate from:

- manual assignment
- job-role requirement

Conceptually:

```text
Employee
   |
   v
TrainingAssignment
   |
   v
TrainingVersion
```

Assignment records preserve important historical context.

Assignment creation validates:

- employee status
- training-version eligibility
- duplicate assignment
- due date
- source
- authorization scope

Role-based assignment operations also account for concurrent duplicate creation.

## 9. Role Training Requirements

Role training requirements associate job roles with required training.

Conceptually:

```text
JobRole
   |
   v
RoleTrainingRequirement
   |
   v
TrainingVersion
```

These requirements can be used to create employee assignments for employees belonging to the relevant role.

Stored due-period configuration is validated before assignment creation.

## 10. Authorization Architecture

Authorization is layered.

The system does not depend on only one permission mechanism.

Typical checks may include:

1. authentication
2. Django permission
3. role/group permission
4. object ownership
5. organizational scope
6. object lifecycle state
7. parent-child validity

Example:

```text
Request
  |
  v
Authenticated?
  |
  v
Required permission?
  |
  v
Object inside allowed scope?
  |
  v
Requested action valid for current state?
  |
  v
Proceed
```

## 11. Manager Scope

Manager access is based on the reporting hierarchy.

Managers are limited to their recursive reporting subtree.

Conceptually:

```text
Manager
 |
 +--> Direct Report A
 |      |
 |      +--> Report A1
 |
 +--> Direct Report B
        |
        +--> Report B1
```

The authorized scope may include descendants, not only direct reports.

This scope is enforced by backend queries.

Filters must be applied inside the already-authorized queryset.

A filter must never be allowed to enlarge the queryset.

## 12. Employee Scope

Employees operate primarily on their own records.

Employee authorization is conceptually:

```text
Authenticated User
        |
        v
     Employee
        |
        v
Own assignments / progress / attempts / certificates
```

The browser must not be trusted to provide the employee identity for sensitive actions.

Where possible, ownership should be derived from the authenticated user and trusted backend relationships.

## 13. Video Progress Architecture

Video progress is designed to be server authoritative.

Main components:

- LessonProgress
- VideoWatchSession
- watched ranges
- heartbeat endpoint
- start endpoint
- resume endpoint
- end endpoint

Conceptually:

```text
Video Player
   |
   | start
   v
VideoWatchSession
   |
   | heartbeat
   v
Observed Playback Position
   |
   v
Server Validation
   |
   +--> watched ranges
   |
   +--> resume position
   |
   +--> completion state
```

## 14. Video Anti-Skip Design

The browser cannot directly declare that the video is complete.

The backend evaluates observed playback progression.

Protections include:

- controlled watch-session creation
- validated session ownership
- position validation
- watched-range merging
- tolerance limits
- idle-gap limits
- cross-session allowance controls
- assignment validation
- lesson validation

Long periods without valid heartbeats must not generate watch credit.

A previously identified issue allowed idle time to contribute excessive playback credit. The backend now rejects credit across excessive idle gaps and controls tolerance across sessions.

## 15. Assessment Architecture

Assessments are separated from individual attempts.

Conceptually:

```text
Assessment
   |
   +--> AssessmentQuestion
           |
           v
     QuestionRevision
```

A Question may have multiple revisions.

Using a revision allows historical assessments to reference stable question content rather than silently changing when a question is edited later.

## 16. Assessment Attempts

Attempts represent employee execution of an assessment.

```text
Employee
   |
   v
AssessmentAttempt
   |
   +--> AttemptAnswer
   |
   v
Server-side Score
```

The backend controls:

- eligibility
- attempt count
- prerequisite status
- answers used for scoring
- correct answers
- score
- pass/fail
- completion effects

The client is never authoritative for the final score.

## 17. Training Completion Flow

A simplified completion flow is:

```text
Assigned Employee
        |
        v
Completes required learning
        |
        v
Meets assessment requirements
        |
        v
Passes required final assessment
        |
        v
TrainingAssignment completed
        |
        v
Certificate issuance evaluated
```

Completion must be based on trusted persisted state.

## 18. Certificate Architecture

Certificates are tied to authoritative completion.

Conceptually:

```text
Completed TrainingAssignment
        |
        v
Certificate Service / Logic
        |
        +--> existing certificate?
        |        |
        |        +--> return existing
        |
        +--> otherwise create
```

Certificate issuance is idempotent.

This prevents repeated completion handling from generating duplicate certificates.

Certificates preserve historical snapshots such as:

- employee information
- training-version information

Revocation changes certificate state but does not erase the historical record.

## 19. Audit Architecture

Audit logging is designed around server-controlled events.

Conceptually:

```text
Business Operation
       |
       v
Database Transaction
       |
       v
Successful Commit
       |
       v
Audit Event
```

Where appropriate, audit logging uses `transaction.on_commit`.

This prevents a failed business transaction from leaving behind a misleading success audit event.

Audit logging is configured to be robust so that an audit-write problem does not necessarily undo an otherwise valid business operation.

## 20. Audit Event Content

Audit events should contain controlled information such as:

- event type
- actor
- target
- timestamp
- approved metadata

The application intentionally avoids storing unnecessary sensitive information.

Examples that should not be placed into audit metadata include:

- passwords
- authentication tokens
- secrets
- assessment answers
- unnecessary training body content

## 21. Dashboard Architecture

The application uses role-aware dashboard behavior.

The root application flow is conceptually:

```text
/
 |
 +--> anonymous --> login
 |
 +--> authenticated --> role-aware dashboard
```

Dashboard querysets are constrained before metrics are calculated.

Examples:

```text
Administrator
    -> company-level permitted data

Manager
    -> recursive reporting subtree

Employee
    -> own data only
```

## 22. Reporting Architecture

Reports are based on scoped querysets.

Correct flow:

```text
All records
   |
   v
Apply authorization scope
   |
   v
Apply user-selected filters
   |
   v
Calculate report output
```

Incorrect flow:

```text
All records
   |
   v
Apply arbitrary user filter
   |
   v
Attempt permission check afterward
```

Authorization scope must come first.

## 23. Form and Validation Architecture

Django Forms are used where appropriate for validation.

Validation may occur at multiple levels:

- form validation
- model validation
- database constraints
- view/service logic

Save-time failures are still possible due to concurrency.

For expected conflicts, the application should convert those failures into controlled user-facing errors.

It must not assume that successful form validation guarantees that a later database save cannot fail.

## 24. Concurrency Strategy

Concurrency-sensitive operations are handled through combinations of:

- `transaction.atomic`
- `select_for_update`
- database uniqueness
- validation
- narrow exception handling
- post-conflict existence checks

Examples include:

- employee deactivation
- assignment creation
- assessment attempts
- video progress
- certificate issuance

The application must not broadly swallow database or validation errors.

Only expected conflicts should be converted into normal application behavior.

## 25. Database Strategy

The project uses MySQL 8 for development and automated backend testing.

This is deliberate.

The project should not switch tests to SQLite merely because SQLite is easier to configure.

Reasons include:

- locking behavior
- date/time behavior
- constraints
- uniqueness
- transaction behavior
- MySQL-specific integration confidence

Current test baseline:

```text
189 full tests passing on MySQL
```

## 26. Environment Configuration

Runtime configuration is environment based.

Local development uses a `.env` file.

The `.env` file is excluded from Git.

Important configuration includes:

- DEBUG
- Django secret key
- database name
- database user
- database password
- database host
- database port
- allowed hosts
- HTTPS/security options

Production uses fail-closed security behavior.

For example, missing required production secret configuration should prevent unsafe startup rather than silently using a committed fallback.

## 27. Security Settings Strategy

Development and production settings have different requirements.

Development may use:

```text
DEBUG=True
```

Production must use:

```text
DEBUG=False
```

Production configuration should enable or configure:

- secure session cookies
- secure CSRF cookies
- HTTPS redirect as appropriate
- HSTS
- explicit allowed hosts
- strong secret key

These settings should be environment configurable without weakening secure defaults.

## 28. Frontend Architecture

The V1 frontend remains server rendered.

```text
Django View
    |
    v
Django Template
    |
    +--> HTML
    +--> CSS
    +--> Basic JavaScript
```

JavaScript may improve usability but must not become the authority for security-sensitive state.

Examples:

JavaScript may:

- update visual progress
- submit playback heartbeats
- improve forms
- provide client-side feedback

JavaScript must not become authoritative for:

- authorization
- score
- completion
- ownership
- certificate eligibility

## 29. URL and Request Design

State-changing operations should use POST or another appropriate mutation method.

Examples include:

- employee deactivation
- training publishing
- training retirement
- certificate revocation
- assignment creation

GET should remain safe and non-mutating.

Directly entering a URL must not bypass backend authorization.

## 30. Error Handling Strategy

Expected invalid input should produce controlled responses.

Typical responses include:

```text
400 - malformed or invalid request
403 - authenticated but not authorized
404 - object unavailable or outside allowed scope
409 - conflicting state
```

Unexpected programming failures may still produce HTTP 500, but known invalid user actions should not.

Regression tests should be added when an uncontrolled 500 is reproduced and fixed.

## 31. Historical Integrity

The architecture prioritizes preserving business history.

Examples include:

- versioned training
- assignment snapshots
- question revisions
- certificate snapshots
- certificate revocation
- employee deactivation
- training retirement
- immutable audit history

Historical facts should not be silently rewritten because current data later changes.

## 32. Testing Architecture

Tests are currently implemented using Django's test framework.

Testing covers areas such as:

- authentication
- authorization
- organization scope
- training lifecycle
- assignments
- playback
- assessments
- certificates
- dashboards
- reports
- audit logging
- malformed requests
- concurrency-sensitive behavior
- regressions

Current baseline:

```text
189 / 189 tests passing on MySQL
```

Future browser and workflow testing will use Playwright.

## 33. Continuous Integration

GitHub Actions is planned as part of Milestone 11.

CI should eventually run at minimum:

```text
dependency installation
Django system check
migration consistency check
MySQL-backed automated tests
dependency consistency check
```

CI should use disposable credentials.

Real local or production credentials must never be committed into workflow files.

## 34. Deployment Architecture

The initial deployment should remain straightforward.

Conceptually:

```text
Browser
   |
 HTTPS
   |
   v
Web Server / Reverse Proxy
   |
   v
Django Application
   |
   v
MySQL
```

Exact infrastructure will be decided during the deployment milestone.

Production architecture must also account for:

- static files
- protected media
- backups
- logging
- HTTPS
- secrets
- rollback

## 35. Architectural Principles

The current project follows these architectural principles:

### Backend Authority

The backend is authoritative for all sensitive state.

### Least Privilege

Users should receive only the access needed for their role and scope.

### Preserve History

Historical training and certification information should not be casually rewritten or deleted.

### Simple Before Complex

Prefer straightforward Django solutions over additional frameworks and abstractions.

### Database Integrity

Use database constraints, transactions, validation, and locking together where appropriate.

### Explicit Lifecycle

Training content and certificates use explicit lifecycle concepts rather than destructive replacement.

### Test Real Behavior

Important backend behavior is tested against MySQL rather than a simplified database substitute.

## 36. Known Architectural Boundaries

The current system intentionally does not yet provide:

- REST API architecture
- React frontend
- microservices
- native mobile application
- full skill matrix
- practical-assessment workflow
- machine-certification workflow
- AI knowledge layer

These should not be added casually during unrelated V1 work.

## 37. Future Architectural Extensions

Later versions may introduce additional domains such as:

```text
Skill
EmployeeSkill
PracticalAssessment
PracticalVerification
MachineCertification
Notification
KnowledgeDocument
```

Potential long-term hierarchy:

```text
Company
└── Department
    └── Role
        └── Training Path
            └── Training
                └── Training Version
                    └── Module
                        └── Lesson
                            └── Quiz
                                └── Final Assessment
                                    └── Practical Assessment
                                        └── Certification
                                            └── Skill Level
```

This hierarchy represents product direction, not the current implemented database schema.

## 38. Architecture Change Policy

Major architectural changes should not be introduced silently.

Examples requiring explicit consideration include:

- replacing Django authentication
- replacing MySQL
- adding a separate API layer
- introducing React
- introducing microservices
- replacing current permission architecture
- removing historical versioning
- changing certificate ownership semantics
- weakening video progress validation

If an architecture change becomes necessary, document:

1. current problem
2. proposed change
3. security implications
4. migration implications
5. testing implications
6. deployment implications
7. rollback plan

## 39. Current Architecture Status

Core backend architecture is implemented and tested.

Current backend baseline:

```text
189 full tests passing on MySQL
```

The next architectural work is primarily:

- documenting the implemented system
- adding CI
- completing the frontend
- adding browser/E2E testing
- preparing production deployment
- performing the final whole-application security review

The current monolithic Django architecture remains the intended V1 architecture.