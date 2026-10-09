# Product Requirements Document

## 1. Product Name

**Garden's Need Training Module Application**

## 2. Product Purpose

The Garden's Need Training Module Application is an internal employee training, assessment, certification, reporting, and workforce development platform.

Its purpose is to provide a controlled system for:

- assigning training
- delivering training content
- tracking learning progress
- assessing employee understanding
- certifying completed training
- reporting training status
- preserving audit history
- supporting future workforce skill development

The system is designed primarily for internal company use.

## 3. Business Problem

Employee training in a manufacturing environment can become difficult to manage when training records, job-role requirements, videos, assessments, certificates, and completion data are spread across different systems or handled manually.

The application centralizes these activities into one controlled system.

The platform should make it easier to answer:

- Which employees require a specific training?
- Which trainings apply to a job role?
- Has an employee completed the required training?
- Has the employee passed the required assessment?
- Which certificates have been issued?
- Which assignments are overdue?
- What important administrative actions occurred?
- What training version did an employee actually complete?
- Is a Manager attempting to access data outside their reporting hierarchy?

## 4. Product Goals

V1 should provide a secure and reliable internal training platform capable of managing the complete training lifecycle.

Primary goals:

1. Centralize employee training management.
2. Apply training requirements consistently across roles.
3. Preserve historical training data.
4. Track employee learning progress securely.
5. Prevent simple video-progress manipulation.
6. Provide quizzes and final assessments.
7. Automatically issue certificates after valid completion.
8. Provide role-aware dashboards and reports.
9. Preserve an audit history of important actions.
10. Maintain strong backend authorization boundaries.
11. Provide a usable web application and Android employee application.
12. Prepare the system for secure production deployment.

## 5. V1 Non-Goals

The following are not required for the first production release unless explicitly approved:

- full skill matrix
- practical skill assessment workflow
- supervisor practical verification
- machine certification workflow
- QR certificate verification
- advanced notification system
- multilingual content
- AI-generated training content
- AI knowledge assistant
- retrieval-augmented factory knowledge
- advanced workforce analytics
- iOS application
- unrestricted offline course completion
- complex third-party HR integration

These remain future-scope items and must not be represented as implemented V1 functionality.

## 6. Users and Roles

The system recognizes six primary roles.

### 6.1 Administrator

Administrators have the broadest application access, subject to the actual permission configuration.

Expected responsibilities may include:

- organization configuration
- employee administration
- training administration
- assignment management
- assessment management
- certificate management
- reporting
- audit review

### 6.2 Training Coordinator

Training Coordinators manage operational training activities according to their assigned permissions.

Expected responsibilities may include:

- training content
- employee training assignments
- assessments
- certificates
- reporting
- audit review

Privileged-account protections must remain enforced.

### 6.3 Manager

Managers operate within their authorized reporting hierarchy.

Managers must only access employees within their permitted recursive reporting subtree.

They must not broaden this scope through:

- crafted URLs
- report filters
- query parameters
- form values
- API payloads
- direct object identifiers

### 6.4 Trainer

Trainer is an application role.

Its capabilities must follow the permissions actually assigned in the application.

Do not invent additional capabilities merely because the role exists.

### 6.5 Supervisor

Supervisor is an application role.

Its capabilities must follow the permissions actually assigned in the application.

Future practical verification functionality may use this role, but practical verification is not part of the current V1 implementation.

### 6.6 Employee

Employees primarily consume assigned training.

Expected capabilities include:

- viewing their own training
- opening permitted lessons
- watching assigned training videos
- completing quizzes and assessments
- viewing their own results
- viewing their own certificates

Employees must not access other employees' training records, reports, certificates, or administrative data.

## 7. Organization Requirements

The application must support the organizational structure required by the training system.

Current requirements include:

- departments
- job roles
- employees
- reporting relationships
- employee status
- role-based permissions

Employee records must preserve historical relationships where required.

Employees should generally be deactivated instead of deleted when deletion would damage historical records.

Repeated deactivation must not overwrite historical information or create misleading duplicate audit events.

## 8. Authentication Requirements

The system must provide authenticated access.

Requirements include:

- login
- logout
- JWT-based mobile authentication
- Django-backed authentication for the web application
- protected API access
- backend authorization enforcement
- session restoration where supported
- protection against direct unauthorized access

Authentication alone does not grant authorization.

Every protected feature must apply the appropriate permission and ownership rules.

## 9. Authorization Requirements

Authorization is a core product requirement.

The backend must enforce authorization.

The application must not rely on:

- hidden navigation links
- hidden buttons
- disabled fields
- browser state
- JavaScript-only restrictions
- client-supplied ownership

The backend must validate:

- user permission
- employee ownership
- Manager hierarchy
- assignment ownership
- certificate ownership
- parent-child relationships
- report scope
- audit access
- media access
- playback session ownership

Out-of-scope objects must return controlled authorization or not-found responses as appropriate.

## 10. System Architecture

The application consists of two primary client surfaces backed by one authoritative Django system.

### 10.1 Backend

The backend is built around:

- Python
- Django
- MySQL 8
- Django templates
- HTML/CSS/JavaScript
- REST API under `/api/v1/`

The backend remains authoritative for security-sensitive business state.

### 10.2 Web Application

The web application provides the administrative and operational interface for authorized users.

It supports areas such as:

- authentication
- organization management
- training management
- assignments
- assessments
- certificates
- dashboards
- reports
- audit review

### 10.3 Android Application

The V1 employee mobile application is Android-first and built with:

- Flutter
- Dart
- Riverpod
- GoRouter
- Dio
- secure token storage

The Android application consumes the existing backend REST APIs.

The mobile client must not replace backend authorization, scoring, progress validation, versioning, or completion rules.

### 10.4 iOS

iOS is deferred until Android V1 is stable and released unless explicitly approved earlier.

## 11. Training Content Requirements

Training content follows:

```text
Training
└── Training Version
    └── Module
        └── Lesson
```

### 11.1 Training

A Training represents the overall training subject.

### 11.2 Training Version

Training content is versioned.

Supported lifecycle:

```text
DRAFT → PUBLISHED → RETIRED
```

Rules:

- Draft versions may be edited according to permissions.
- Draft versions may be deleted when safe.
- Published versions are immutable.
- Retired versions remain preserved for historical purposes.
- Published versions cannot be deleted.
- Retired versions cannot receive new assignments.
- Existing assignments remain pinned to their assigned version.
- Existing learners may continue working on a retired version.
- New assignments use the latest published version.
- Publishing requires valid training structure.
- Publishing requires the expected final assessment configuration.
- Publishing and retirement are state-changing operations.
- Assessment questions and answer keys are frozen with the assigned version.

If published content requires correction, a new version should be created rather than mutating the published version.

### 11.3 Modules

Training versions may contain ordered modules.

Modules must remain associated with their trusted parent training version.

### 11.4 Lessons

Modules may contain ordered lessons.

Current lesson types include:

- text
- video

Lesson validation must prevent unsafe or inconsistent configurations.

## 12. Training Assignment Requirements

Training assignments connect employees to specific training versions.

Assignments may be created:

- manually
- through role-based training requirements

Requirements include:

- only valid employees may be assigned
- assignment scope must respect authorization
- assignments must target permitted versions
- duplicate assignments must be prevented
- due dates must be valid
- assignment source must be preserved
- historical snapshots must be preserved where implemented
- assignments remain pinned to their assigned version

New assignments use the latest published version unless an explicit permitted version is selected.

Employees are not automatically migrated to newer versions.

Role-based assignment creation must handle concurrent duplicates safely.

Unexpected validation failures must not be silently ignored.

## 13. Video Training Requirements

Video lessons require server-authoritative progress tracking.

Required behavior includes:

- resume position
- playback session creation
- heartbeat tracking
- watched-range tracking
- progress persistence
- assignment validation
- lesson validation
- completion calculation
- protected media access

The client must not be allowed to declare authoritative completion.

The system must protect against simple progress manipulation such as:

- skipping large unwatched sections
- manufacturing credit through idle time
- reusing playback tolerance improperly
- using malformed session identifiers
- combining sessions to improperly increase watch credit

Long inactive gaps must not generate watch credit.

### 13.1 Media Access

V1 media is streaming-only.

The existing M13 session-based protected media endpoint is the authoritative media access mechanism.

Do not create an unrestricted parallel media route when the existing session architecture can be reused.

Media access must validate:

- authenticated user
- assignment
- lesson
- training version
- playback session

### 13.2 Published Media

Published media is immutable.

Replacing published media requires a new training version.

### 13.3 Media Validation

Media uploads must be validated before being accepted.

Validation should include, where applicable:

- file size
- file type
- extension
- actual file content
- checksum

Validation must fail closed when required metadata or content cannot be safely verified.

### 13.4 V1 Video Format

Preferred V1 format:

- MP4
- H.264 video
- AAC audio
- HTTP range streaming

The existing Flutter `video_player` approach should be reused unless a demonstrated requirement requires a different playback implementation.

### 13.5 Screen Capture

Android screen-capture protection should be applied where appropriate using supported platform mechanisms such as `FLAG_SECURE`.

This is intended to reduce ordinary capture paths. It must not be represented as making screen recording impossible.

## 14. Learning Progress Requirements

Learning progress must remain authoritative on the server.

The mobile and web clients may display local UI state, but authoritative completion must come from the backend.

Progress must remain associated with:

- assignment
- training version
- module
- lesson
- playback session where applicable

The learning flow must support:

- ordered module navigation
- lesson navigation
- text lesson completion
- video lesson playback
- previous/next lesson navigation
- resume behavior
- progress refresh

Client navigation must not bypass completion requirements.

## 15. Assessment Requirements

The system must support structured assessments.

Current functionality includes:

- question bank
- question revisions
- answer options
- lesson quizzes
- final assessments
- assessment attempts
- attempt limits
- prerequisites
- server-side scoring
- pass/fail results
- training completion integration

### 15.1 Question History

Question revisions must preserve historical assessment behavior.

Published training versions must retain the questions and answer configuration associated with that version.

### 15.2 Scoring

Scores must be calculated by the backend.

The client must never be authoritative for:

- correct answers
- score
- pass/fail
- completion

### 15.3 Final Assessment

Published training must have the required final assessment configuration.

Passing the required final assessment may complete the associated assignment when all authoritative conditions are satisfied.

### 15.4 Concurrency

Assessment creation and attempts must safely handle duplicate or concurrent activity.

Expected uniqueness conflicts must return controlled behavior rather than HTTP 500.

## 16. Certificate Requirements

Certificates represent successful completion of required training.

Requirements include:

- automatic issuance after authoritative completion
- unique certificate identifier
- issue timestamp
- employee snapshot
- training version reference
- idempotent issuance
- employee access to permitted certificates
- authorized administrative management
- revocation support

Revocation must preserve the certificate record.

Repeated completion processing must not create duplicate certificates.

Certificates must reference the version actually earned.

## 17. Dashboard Requirements

The application provides role-aware dashboards.

### Administrator and Training Coordinator

May receive company-level training information according to permissions.

### Manager

May receive metrics limited to the Manager's authorized reporting subtree.

### Employee

May receive information related to their own:

- assignments
- training status
- assessment results
- certificates

Dashboards must not leak data outside authorized scope.

The Android employee dashboard consumes the backend dashboard API rather than maintaining an independent source of truth.

## 18. Reporting Requirements

The reporting system supports assignment-focused reporting.

Filters may include:

- assignment status
- department
- job role
- training
- training version
- overdue state

Derived data may include:

- overdue status
- completion percentage

Report filters must never broaden authorized scope.

A Manager selecting a crafted department, role, training, version, or employee identifier must remain inside the Manager's authorized hierarchy.

Employees must not gain administrative reporting access.

## 19. Audit Requirements

The application must preserve an audit history for important state changes.

Audit events may include:

- organization changes
- employee changes
- training changes
- training publishing
- training retirement
- assignments
- question changes
- assessment attempts
- assessment results
- lesson completion
- assignment completion
- certificate issuance
- certificate revocation
- security-sensitive playback events

Requirements:

- actor must be server-derived
- target must be server-derived
- timestamp must be server-derived
- event metadata must be controlled
- failed transactions must not create misleading success events
- sensitive assessment answers must not be stored in audit metadata
- secrets and credentials must never be stored in audit metadata
- media and playback lifecycle events should remain auditable where applicable

## 20. Security Requirements

Security is a release requirement.

The application must protect against:

- unauthorized object access
- IDOR-style access
- privilege escalation
- forged ownership
- forged Manager scope
- CSRF on state-changing actions
- malformed input
- insecure production configuration
- accidental secret exposure
- client-authoritative scoring
- client-authoritative progress
- unauthorized media access
- invalid playback sessions

Production requires:

- `DEBUG=False`
- strong secret key
- explicit allowed hosts
- HTTPS
- secure cookies
- appropriate HSTS
- protected static/media strategy
- database backups
- operational logging
- rollback planning

The release target is:

- no known exploitable critical or high-severity security issue
- no known important reproducible release-blocking bug

This target does not imply that software can be guaranteed invulnerable.

## 21. Offline Requirements

V1 does not support unrestricted offline course completion.

The server remains authoritative for:

- completion
- progress
- assessment results
- certificates
- assignment state

Offline UI behavior must not create an authoritative completion claim that can bypass server validation.

Any future synchronization system requires an explicit design before implementation.

## 22. Testing Requirements

Backend testing must continue to use MySQL.

Current baseline:

```text
Django/MySQL: 348 tests
Flutter: 81 tests
JavaScript playback: 3 tests
```

These numbers are a current baseline, not permanent requirements. Future milestone work may change the test count.

Testing should include:

- happy paths
- permission failures
- ownership failures
- malformed requests
- duplicate requests
- repeated state transitions
- exact date/time boundaries
- exact score boundaries
- concurrency-sensitive paths
- playback-session failures
- media authorization failures
- regression tests for confirmed defects

Important backend checks include:

```powershell
python manage.py test
python manage.py check
python manage.py makemigrations --check --dry-run
python -m pip check
git diff --check
```

Mobile milestone validation should include:

```powershell
flutter analyze
flutter test
flutter build apk --debug
```

The exact repository workflow should be followed where commands or paths differ.

Existing JavaScript playback tests must continue to pass when playback-related functionality changes.

## 23. Risk-Based Testing

Testing effort should match change risk.

### Low risk

Examples:

- documentation
- isolated copy changes
- minor UI layout changes

Use focused validation.

### Medium risk

Examples:

- API behavior
- Flutter navigation
- repository changes
- assignment state
- lesson state
- media integration

Use focused tests plus relevant runtime/build validation.

### High risk

Examples:

- authentication
- authorization
- media access
- playback sessions
- progress/completion
- assessments
- certificates
- versioning/lifecycle
- security-sensitive database changes

Use focused tests, negative testing, broader regression coverage, and the relevant full suite.

Do not add large quantities of redundant tests merely to increase test count.

## 24. Accessibility Requirements

The frontend should support:

- keyboard navigation where applicable
- visible focus states
- readable typography
- adequate contrast
- clear labels
- meaningful validation messages
- logical heading structure
- accessible forms
- usable responsive layouts
- accessible mobile controls

Accessibility improvements should be incorporated throughout development and receive deliberate attention during the later UX/polish stages.

## 25. Performance Requirements

V1 should perform reliably for internal company usage.

Performance work should focus on measured bottlenecks rather than premature optimization.

Database queries must preserve secure scoping while remaining reasonably efficient.

Mobile screens should avoid unnecessary repeated API requests and unnecessary rebuilds where practical.

## 26. Data Integrity Requirements

The system must preserve historical information where business records depend on it.

Examples include:

- training versions
- assignments
- assessment history
- certificates
- audit records
- published media

The application should use:

- immutability
- snapshots
- retirement
- deactivation
- revocation

where these patterns are part of the established design.

Destructive schema changes require explicit approval.

## 27. UI and Visual Direction

The current functional milestones prioritize correctness and usability over final visual polish.

Do not prematurely lock:

- final color palette
- final animation system
- final interaction language
- final visual identity

The final Garden's Need premium visual direction will be deliberately designed during M22.

When M22 begins, UI/UX direction should be reviewed before implementation.

The intended final interface should be:

- professional
- premium
- calm
- accessible
- interactive
- visually polished
- suitable for internal business software

## 28. Production Deployment Requirements

Before production release, the project must have documented procedures for:

- environment configuration
- database configuration
- migrations
- static files
- media files
- HTTPS
- secure cookies
- backups
- application startup
- logging
- smoke testing
- rollback

Production deployment and hardening are dedicated later milestones.

## 29. V1 Acceptance Criteria

V1 is ready for release only when the required end-to-end product flow works.

At minimum:

1. Users can authenticate.
2. Authorization boundaries are enforced.
3. Organization data can be managed by authorized users.
4. Training can be created and versioned.
5. Valid training versions can be published.
6. Published versions remain immutable.
7. Employees can receive assignments.
8. Assignments remain pinned to their assigned versions.
9. Employees can consume training lessons.
10. Text lessons can be completed.
11. Video lessons can be played through protected media access.
12. Video progress is validated server-side.
13. Anti-skip and session protections remain effective.
14. Quizzes and final assessments work.
15. Scores are calculated server-side.
16. Training completion works.
17. Certificates are issued correctly and idempotently.
18. Dashboards and reports respect permissions.
19. Important actions are audited.
20. Web workflows remain functional.
21. Android employee workflows remain functional.
22. Automated backend, Flutter, and relevant JavaScript tests pass.
23. Relevant E2E/integration tests pass.
24. Production configuration is secure.
25. Documentation is accurate.
26. Final security review is complete.
27. No known important reproducible release-blocking bug remains unresolved.

## 30. Current Development Roadmap

### Completed

```text
M0  - Project Foundation
M1  - Authentication & Organization
M2  - Training Content & Versioning
M3  - Training Assignments
M4  - Video Progress & Anti-Skip
M5  - Assessments & Scoring
M6  - Certificates
M7  - Dashboards & Reports
M8  - Audit Logging & Backend Hardening
M9  - Backend Cleanup & Simplification
M10 - Security Hardening & Vulnerability Testing
M11 - Documentation + Project Structure + CI
M12 - Functional Backend / Web Platform Completion
M13 - Mobile API Foundation + Versioning
M14 - Flutter / Android Foundation
M15 - Employee App Core
```

### Current

```text
M16 - Learning + Secure Video
```

### Planned

```text
M17 - Assessment + Certificates
M18 - Notifications + Resilience
M19 - Android Release Candidate
M20 - Production + Deployment Hardening
M21 - Final Bug Hunt + Security + Repository Review
M22 - Readability + Refactor + Garden's Need Visual Polish
M23 - Final Acceptance + Android V1 Release
```

Milestone scope should not be silently skipped or expanded without an explicit decision.

## 31. M16 Requirements

M16 builds on the completed M13-M15 foundation.

M16 must:

- integrate secure video playback into the existing employee learning flow
- reuse the existing session-based protected media endpoint
- preserve server-authoritative progress
- preserve anti-skip behavior
- preserve playback session validation
- support resume behavior
- handle playback failures safely
- apply appropriate Android screen-capture protection
- remain streaming-only
- avoid unrestricted downloads
- avoid duplicating backend playback rules
- preserve existing assignment/version relationships

M16 must not silently redesign:

- training version lifecycle
- assignment version pinning
- assessment architecture
- certificate architecture
- media authorization
- backend business rules

If an existing business rule is ambiguous, resolve the ambiguity before implementing conflicting behavior.

## 32. Future Product Direction

After V1 is stable and real usage has been observed, future versions may extend the platform into broader workforce capability management.

Potential areas include:

- skill matrix
- practical assessments
- supervisor verification
- machine certifications
- QR verification
- training notifications
- multilingual learning
- richer analytics
- AI-assisted factory knowledge
- retrieval-augmented internal knowledge
- additional native mobile workflows
- iOS support

Future functionality should be prioritized based on actual operational needs rather than automatically added to V1.