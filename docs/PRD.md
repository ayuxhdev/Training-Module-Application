# Product Requirements Document

## 1. Product Name

**Garden's Need Training Module Application**

## 2. Product Purpose

The Garden's Need Training Module Application is an internal employee training, assessment, certification, and workforce development platform.

Its purpose is to provide a structured system for:

- assigning training
- delivering training content
- tracking learning progress
- assessing employee understanding
- certifying completed training
- reporting training status
- preserving audit history
- supporting future workforce skill development

The system is designed for internal company use.

## 3. Business Problem

Employee training in a manufacturing environment can become difficult to manage when training records, job-role requirements, videos, assessments, certificates, and completion data are spread across different systems or handled manually.

The application aims to centralize these activities into one controlled system.

The platform should make it easier to answer questions such as:

- Which employees require a specific training?
- Which trainings apply to a job role?
- Has an employee completed the required training?
- Has the employee passed the final assessment?
- Which certificates have been issued?
- Which assignments are overdue?
- What actions were performed by administrators or coordinators?
- What training version did an employee actually complete?
- Is a Manager attempting to access data outside their reporting hierarchy?

## 4. Product Goals

The V1 product should provide a secure and reliable internal training system capable of managing the complete training lifecycle.

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
11. Provide a usable frontend for daily internal operation.
12. Prepare the application for secure production deployment.

## 5. Non-Goals for V1

The following features are not required for the first production release unless explicitly added later:

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
- native mobile application
- native Android screen-capture blocking
- complex third-party HR integration

These are future-scope items and should not be treated as implemented V1 functionality.

## 6. Users and Roles

The system currently recognizes six primary roles.

### 6.1 Administrator

Administrators have the broadest application access.

Expected responsibilities may include:

- organization configuration
- employee administration
- training administration
- assignment management
- assessment management
- certificate management
- reporting
- audit review

Administrator permissions remain subject to the actual permission configuration in the application.

### 6.2 Training Coordinator

Training Coordinators manage operational training activities.

Expected responsibilities may include:

- training content
- employee training assignments
- assessments
- certificates
- reporting
- audit review

Training Coordinators must not be allowed to bypass privileged-account protections.

### 6.3 Manager

Managers operate within their authorized reporting hierarchy.

Managers must only be able to access employees in their permitted recursive reporting subtree.

They must not be able to broaden this scope through:

- crafted URLs
- report filters
- query parameters
- form values
- direct object identifiers

### 6.4 Trainer

Trainer exists as an application role.

Its final V1 user-interface responsibilities should follow the permissions actually assigned in the application.

No additional capabilities should be invented merely because the role exists.

### 6.5 Supervisor

Supervisor exists as an application role.

Its final V1 user-interface responsibilities should follow the permissions actually assigned in the application.

Future practical verification functionality may use this role, but practical verification is not currently part of implemented V1 backend functionality.

### 6.6 Employee

Employees primarily consume assigned training.

Expected Employee capabilities include:

- viewing their own training
- opening permitted lessons
- watching assigned training videos
- completing quizzes and assessments
- viewing their own results
- viewing their own certificates

Employees must not be able to access other employees' training records, reports, certificates, or administrative data.

## 7. Organization Requirements

The application must support organizational structure used by the training system.

Current requirements include:

- departments
- job roles
- employees
- reporting relationships
- employee status
- role-based permissions

Employee records should preserve historical relationships where required.

Employees should generally be deactivated instead of deleted when deletion would damage historical records.

Repeated employee deactivation should not overwrite historical deactivation information or create misleading duplicate success audit events.

## 8. Authentication Requirements

The application must provide authenticated access.

Requirements include:

- login
- logout
- Django-backed user authentication
- backend authorization enforcement
- access control for protected views
- protection against direct URL access

Authentication alone does not grant authorization.

Every protected feature must apply the appropriate permission and ownership rules.

## 9. Authorization Requirements

Authorization is a core product requirement.

The system must enforce permissions on the backend.

The application must not rely on:

- hidden navigation links
- hidden buttons
- disabled fields
- browser state
- JavaScript-only restrictions

The backend must validate:

- user permission
- employee ownership
- Manager hierarchy
- assignment ownership
- certificate ownership
- parent-child relationships
- access to reports
- access to audit history

Out-of-scope objects should return controlled authorization or not-found responses as appropriate.

## 10. Training Content Requirements

Training content follows this hierarchy:

```text
Training
└── Training Version
    └── Module
        └── Lesson
```

### 10.1 Training

A Training represents the overall training subject.

### 10.2 Training Version

Training content is versioned.

Supported states:

```text
DRAFT
PUBLISHED
RETIRED
```

Requirements:

- Draft content may be edited according to current permissions.
- Published versions must be protected from unsafe modification.
- Retired versions must remain preserved for historical purposes.
- Publishing must require valid training structure.
- Publishing must require the expected final assessment configuration.
- Publish and retire operations must use state-changing requests such as POST.

### 10.3 Modules

Training versions may contain ordered modules.

Modules must remain associated with their trusted parent training version.

### 10.4 Lessons

Modules may contain ordered lessons.

Current lesson types include:

- text
- video

Lesson validation must prevent unsafe or inconsistent content configuration.

## 11. Training Assignment Requirements

Training assignments connect employees to published training versions.

Assignments may be created:

- manually
- through role-based training requirements

Requirements include:

- only valid employees may be assigned
- assignment scope must respect authorization
- assignments should target permitted training versions
- duplicate assignments must be prevented
- concurrency must not produce uncontrolled server errors
- due dates must be valid
- assignment source must be preserved
- historical snapshots should be preserved where implemented

Role-based assignment creation must handle concurrent duplicates safely.

If another request creates the same assignment during a batch operation, the operation should only treat it as a duplicate when the exact expected assignment now exists.

Unexpected validation failures must not be silently ignored.

## 12. Video Training Requirements

Video lessons require server-authoritative progress tracking.

Required behavior includes:

- resume position
- watch session creation
- heartbeat tracking
- watched-range tracking
- progress persistence
- assignment validation
- lesson validation
- completion calculation

The browser must not be allowed to declare authoritative completion.

The system must protect against simple progress manipulation such as:

- skipping large unwatched sections
- manufacturing credit through idle time
- reusing playback tolerance repeatedly
- using malformed session identifiers
- combining sessions to improperly increase watch credit

Long inactive gaps must not generate watch credit.

## 13. Assessment Requirements

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
- pass/fail result
- training completion integration

### 13.1 Question History

Questions may use revision records so historical assessment behavior remains stable.

### 13.2 Scoring

Scores must be calculated by the backend.

The browser must never be authoritative for:

- correct answers
- score
- pass/fail
- completion

### 13.3 Final Assessment

Published training must have the required final assessment configuration.

Passing the required final assessment may complete the associated training assignment when all authoritative conditions are met.

### 13.4 Concurrency

Assessment creation and attempts must safely handle duplicate or concurrent activity.

Save-time uniqueness failures must return controlled validation behavior rather than HTTP 500 where the conflict is expected.

## 14. Certificate Requirements

Certificates represent successful completion of required training.

Requirements include:

- automatic issuance after authoritative completion
- unique certificate identifier
- issue timestamp
- employee snapshot
- training version snapshot
- idempotent issuance
- employee access to their own certificates
- authorized administrative management
- revocation support

Revocation must preserve the certificate record.

Repeated completion processing must not create duplicate certificates.

## 15. Dashboard Requirements

The application should provide role-aware dashboards.

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

## 16. Reporting Requirements

The reporting system currently supports assignment-focused reporting.

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

Report filters must never broaden a user's authorized scope.

A Manager selecting a crafted department, role, training, version, or employee identifier must remain inside the Manager's allowed reporting hierarchy.

Employees must not have access to administrative assignment reports.

## 17. Audit Requirements

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

Requirements:

- actor must be server-derived
- target must be server-derived
- timestamp must be server-derived
- event metadata must be controlled
- failed transactions must not create misleading success events
- audit failures should not undo successful business operations where the existing design intentionally uses robust post-commit logging
- sensitive assessment answers must not be stored in audit metadata
- secrets and credentials must never be stored in audit metadata

Audit records are read-only through the normal application interface.

## 18. Security Requirements

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
- incorrect client-authoritative scoring
- incorrect client-authoritative progress

Production should require:

- `DEBUG=False`
- strong secret key
- explicit allowed hosts
- HTTPS
- secure cookies
- appropriate HSTS
- secure static/media strategy
- database backups
- operational logging

The release target is:

- no known exploitable critical or high-severity security issue
- no known important reproducible bug left unresolved

This target does not imply that software can be guaranteed to be invulnerable.

## 19. Testing Requirements

Backend testing must continue to use MySQL.

Current baseline:

```text
189 full tests passing on MySQL
```

Testing should include:

- happy paths
- permission failures
- ownership failures
- malformed requests
- duplicate requests
- state retries
- exact date/time boundaries
- exact score boundaries
- concurrency-sensitive paths
- regression tests for confirmed defects

Important verification commands include:

```powershell
python manage.py test
python manage.py check
python manage.py makemigrations --check --dry-run
python -m pip check
git diff --check
```

Frontend and complete workflow testing will later use browser automation and Playwright.

## 20. Frontend Requirements

V1 frontend architecture remains:

- Django templates
- HTML
- CSS
- basic JavaScript

The project does not currently require a React or separate SPA architecture.

Frontend requirements include:

- usable navigation
- role-appropriate pages
- clear forms
- useful validation messages
- training progress visibility
- usable video experience
- usable assessment experience
- certificate access
- report usability
- responsive layouts
- accessibility improvements

Frontend controls must not replace backend authorization.

## 21. Design Direction

The intended visual identity includes:

- deep forest green
- ivory or white
- charcoal
- restrained brass accents

The interface should feel:

- professional
- calm
- premium
- practical
- suitable for internal business software

Functionality and usability take priority over decorative styling.

The final premium visual pass is intentionally scheduled near the end of V1 development.

## 22. Accessibility Requirements

The frontend should aim to support:

- keyboard navigation
- visible focus states
- readable typography
- adequate contrast
- clear labels
- meaningful validation messages
- logical heading structure
- accessible forms
- usable responsive layouts

Accessibility will receive focused attention during the UX and responsive milestone.

## 23. Performance Expectations

V1 should perform reliably for internal company usage.

The architecture should avoid unnecessary complexity.

Performance work should focus on measured bottlenecks rather than premature optimization.

Database queries should preserve secure scoping while remaining reasonably efficient.

## 24. Data Integrity Requirements

The system should preserve historical information where business records depend on it.

Examples include:

- training versions
- assignments
- assessment history
- certificates
- audit records

The application should use:

- immutability
- snapshots
- retirement
- deactivation
- revocation

where these patterns are already part of the established design.

## 25. Deployment Requirements

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

Production deployment work is scheduled for a later dedicated milestone.

## 26. V1 Acceptance Criteria

V1 is ready for release only when the required product flow works end-to-end.

At minimum:

1. Users can authenticate.
2. Authorization boundaries are enforced.
3. Organization data can be managed by authorized users.
4. Training can be created and versioned.
5. Valid training versions can be published.
6. Employees can receive assignments.
7. Employees can consume training lessons.
8. Video progress is tracked securely enough for V1.
9. Quizzes and final assessments work.
10. Scores are calculated server-side.
11. Training completion works.
12. Certificates are issued correctly.
13. Dashboards and reports respect permissions.
14. Important actions are audited.
15. Automated tests pass.
16. E2E browser tests pass.
17. Production configuration is secure.
18. Documentation is accurate.
19. Final security review is complete.
20. No known important reproducible release-blocking bug remains unresolved.

## 27. Current Development Roadmap

Completed:

```text
Milestone 0  - Project Setup & Foundation
Milestone 1  - Authentication & Organization
Milestone 2  - Training Content & Versioning
Milestone 3  - Training Assignments
Milestone 4  - Video Progress & Anti-Skip
Milestone 5  - Assessments & Scoring
Milestone 6  - Certificates
Milestone 7  - Dashboards & Reports
Milestone 8  - Audit Logging & Backend Hardening
Milestone 9  - Backend Cleanup & Simplification
Milestone 10 - Security Hardening & Vulnerability Testing
```

Current:

```text
Milestone 11 - Documentation + Project Structure + CI
```

Remaining:

```text
Milestone 12 - Functional Frontend
Milestone 13 - UX + Responsive + Accessibility
Milestone 14 - Full E2E + Integration Testing
Milestone 15 - Production + Deployment Hardening
Milestone 16 - Final Bug Hunt + Security + Repository Review
Milestone 17 - Final Readability + Refactor Pass
Milestone 18 - Premium Visual Polish
Milestone 19 - Final Acceptance + V1 Release
```

## 28. Future Product Direction

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
- native mobile workflows

Future functionality should be prioritized based on actual operational needs rather than added automatically to V1.