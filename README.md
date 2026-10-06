# Garden's Need Training Module Application

Internal employee training, assessment, certification, and workforce development platform for Garden's Need.

The application manages structured employee learning across departments and job roles while enforcing secure access, training versioning, assessment rules, progress tracking, certification, reporting, and auditability.

## Project Status

**Current development stage:** M12 complete, M13 Phases 1–3 complete

The current repository contains a substantially developed Django web application and a versioned REST API that is now being prepared for the employee mobile application.

### Confirmed current state

* M0–M12 completed
* M13 Phase 1: API Foundation + Versioning completed
* M13 Phase 2: Mobile Authentication + Security completed
* M13 Phase 3: Employee Profile + Dashboard API completed
* Versioned REST API available under `/api/v1/`
* JWT-based mobile authentication implemented
* Employee profile API implemented
* Employee dashboard API implemented
* Training, assessment, certificate, reporting, and audit workflows implemented in the backend/web application
* Video progress tracking and anti-skip protections implemented
* GitHub Actions CI configured
* **328 automated tests passing against MySQL**
* Android employee application is the next major development stage
* iOS development is intentionally deferred until Android has been completed, tested, piloted, and stabilized

The repository is not yet considered production-ready. Staging, production deployment configuration, observability, remaining mobile APIs, the Android application, real employee pilot testing, and final release hardening remain.

## Technology Stack

### Backend

* Python 3.14
* Django 5.2 LTS
* Django REST Framework 3.18.1
* MySQL 8
* Django built-in authentication system
* Django REST Framework SimpleJWT 5.5.1
* Server-rendered Django templates

### Frontend

* HTML
* CSS
* Basic JavaScript
* Django Templates

A separate SPA framework such as React or Vue is intentionally not used for V1.

### Development

* Visual Studio Code
* Git
* GitHub
* GitHub Actions
* MySQL
* Django test framework

Automated Playwright/browser E2E testing is planned, but is not currently part of the CI pipeline.

## Application Architecture

The project follows a Django monolith architecture.

```text
Garden's Need Training Module Application
│
├── Django Web Portal
│   ├── Administration
│   ├── Management
│   ├── Training
│   ├── Assessments
│   ├── Certificates
│   ├── Reports
│   └── Audit
│
└── Versioned REST API
    └── /api/v1/
        └── Employee Mobile Application
```

Major Django applications include:

```text
accounts/
organization/
training/
assessments/
certifications/
reports/
audit/
api/
config/
```

The backend remains the authoritative source for:

* permissions
* employee scope
* training assignments
* progress
* assessment scores
* completion
* certificates
* audit records

Client-side state is never trusted for security-sensitive decisions.

## Current API

The REST API is versioned under:

```text
/api/v1/
```

Currently implemented endpoints include:

```text
GET  /api/v1/status/

POST /api/v1/auth/login/
POST /api/v1/auth/refresh/
POST /api/v1/auth/logout/
GET  /api/v1/auth/me/

GET  /api/v1/dashboard/

GET  /api/v1/assignments/
GET  /api/v1/assignments/{assignment_id}/
GET  /api/v1/assignments/{assignment_id}/lessons/{lesson_id}/progress/
POST /api/v1/assignments/{assignment_id}/lessons/{lesson_id}/progress/
POST /api/v1/assignments/{assignment_id}/lessons/{lesson_id}/complete/
POST /api/v1/assignments/{assignment_id}/lessons/{lesson_id}/sessions/
GET  /api/v1/assignments/{assignment_id}/lessons/{lesson_id}/sessions/{session_id}/media/
POST /api/v1/assignments/{assignment_id}/lessons/{lesson_id}/sessions/{session_id}/end/
```

The API currently provides:

* JWT authentication
* refresh-token rotation and blacklisting
* logout protection against cross-user token invalidation
* active employee validation
* employee profile information
* employee-scoped dashboard data
* standardized API error responses
* throttling for authentication endpoints

Assignment and learning endpoints require a JWT bearer token and an active linked Employee. Assignment results are restricted to that Employee. Curriculum detail includes persisted lesson progress; playback and completion updates reuse the existing server-side validation and session rules. Assessment and certificate API endpoints are not included in this API surface.

## Core Features

### Authentication and Authorization

The application supports role-based access including:

* Administrator
* Training Coordinator
* Manager
* Trainer
* Supervisor
* Employee

Authorization is enforced on the backend.

Managers are restricted to employees within their authorized reporting hierarchy.

Employees can access only their own permitted training-related information.

For the mobile API, access is derived from the authenticated user and linked employee rather than arbitrary employee IDs supplied by the client.

### Organization Management

The system supports:

* departments
* job roles
* employees
* reporting relationships
* recursive manager hierarchy
* employee activation and deactivation
* preservation of historical employee relationships

Employee records are deactivated rather than deleted when historical information must be preserved.

Employee hierarchy validation includes protection against invalid reporting cycles.

### Training Management

Training content follows this hierarchy:

```text
Training
└── Training Version
    └── Module
        └── Lesson
```

Lessons currently support:

* text content
* video content

Training versions use the lifecycle:

```text
DRAFT
PUBLISHED
RETIRED
```

Published training versions and their protected child content cannot be modified unsafely.

Publishing requires the configured training requirements to be satisfied, including the required final assessment structure.

### Training Assignments

Training can be assigned through supported assignment workflows, including:

* manual assignment
* job-role requirements

Assignments preserve historical information such as assignment source and relevant snapshots.

The backend validates:

* employee eligibility
* training version state
* duplicate assignments
* due dates
* ownership
* reporting scope

Assignments use explicit lifecycle states including:

```text
ASSIGNED
IN_PROGRESS
COMPLETED
CANCELLED
```

### Video Progress Tracking

Video lessons support:

* resume position
* watch sessions
* heartbeat tracking
* watched-range tracking
* progress persistence
* anti-skip protections
* idle-time protections
* controlled completion logic

Video progress is validated and calculated by the backend.

Browser or mobile clients must not be able to claim arbitrary watched time or completion simply by sending manipulated progress values.

### Assessments

The assessment system includes:

* question bank
* question revisions
* answer options
* lesson quizzes
* final assessments
* attempt tracking
* attempt limits
* prerequisites
* server-side scoring
* pass/fail handling
* assessment result tracking

Assessment scores and training completion are determined by trusted backend logic.

Successful completion of the required final assessment can complete the related training assignment when all other completion conditions are satisfied.

### Certificates

Certificates are issued after authoritative training completion when all required conditions are satisfied.

Certificates include information such as:

* unique certificate number
* issue timestamp
* employee snapshot
* training version snapshot
* revocation support

Certificate issuance is designed to be idempotent.

Revocation preserves the historical certificate record rather than deleting it.

### Dashboards and Reports

Role-aware dashboards provide information based on the authenticated user's permissions and scope.

Reporting supports information such as:

* assignments
* assignment status
* completion
* overdue assignments
* departments
* job roles
* training
* training versions

Managers remain restricted to their authorized reporting hierarchy.

Employees cannot access administrative reporting functionality.

The employee dashboard API provides:

* assignment metrics
* action-required assignments
* overdue state
* recent certificates

Dashboard data is scoped to the authenticated employee.

### Audit Logging

Important application actions are recorded through the audit system.

Examples include:

* employee changes
* department changes
* job-role changes
* training changes
* training publishing
* training retirement
* assignments
* question changes
* assessment attempts
* assessment results
* lesson completion
* training completion
* certificate issuance
* certificate revocation

Audit records preserve accountability while avoiding unnecessary sensitive information such as assessment answers or training content.

## Security Principles

The application follows these security principles:

* authorization is enforced server-side
* permissions are never based only on hidden UI controls
* direct URL access is protected
* ownership is derived from trusted backend state
* manager scope is calculated on the backend
* client-supplied progress and scores are not trusted
* client-supplied employee IDs are not trusted for employee-scoped mobile resources
* state-changing actions use appropriate HTTP methods
* CSRF protection remains enabled
* malformed input should return controlled errors rather than unexpected HTTP 500 responses
* important operations use database transactions and locking when required
* historical records are preserved where necessary
* secrets are never committed to Git
* production configuration fails closed when required security configuration is missing
* secure cookies are enabled for production configuration
* authentication refresh tokens are rotated and blacklisted
* cross-user logout attempts are rejected
* inactive employees cannot authenticate or continue using protected API functionality
* audit metadata avoids unnecessary sensitive data

Security testing has specifically covered areas such as:

* IDOR and employee-scope isolation
* JWT ownership
* cross-user logout
* inactive-user handling
* token refresh behavior
* sensitive serializer fields
* playback anti-skip behavior

A comprehensive release-time security and repository audit remains planned before V1 release.

## Web Application

The web application is implemented using Django templates, CSS, and JavaScript.

Current workflows include:

* authentication
* role-aware navigation
* dashboards
* employee management
* reporting hierarchy management
* training management
* training versioning
* assignments
* video learning
* assessment taking
* assessment results
* certificates
* certificate revocation
* reporting
* audit viewing

The current web application is functionally mature for the completed training workflows but still requires additional visual refinement to reach the intended polished enterprise-application experience.

The UI modernization direction is to improve the existing Django application rather than replace it with a separate SPA framework.

## Mobile Application Direction

The mobile employee application has not yet been started in the repository.

There are currently no Android, Flutter, iOS, Kotlin, Java, or Dart application files in the project.

The immediate mobile strategy is:

```text
Complete required mobile APIs
        ↓
Build Android employee application
        ↓
Android testing and stabilization
        ↓
Comprehensive Android release-candidate audit
        ↓
Employee pilot
        ↓
Android release
        ↓
Revisit iOS
```

Flutter is the leading candidate for the mobile application because it can support a shared codebase for Android and future iOS development, but the toolchain should be validated before the framework is treated as permanently locked.

The Android application will use the versioned REST API and keep the backend authoritative for:

* authentication
* authorization
* assignment state
* progress
* assessment scoring
* completion
* certificates

## Current Testing Status

The project uses Django's test framework with MySQL.

### Current automated baseline

```text
328 tests passing on MySQL
0 failures
0 errors
```

The current suite covers areas including:

* authentication
* organization
* training
* video playback
* assessments
* certificates
* reporting
* audit logging
* API behavior
* mobile authentication
* employee profile API
* dashboard API
* security/ownership boundaries

### Useful verification commands

Run the complete automated test suite:

```powershell
python manage.py test
```

Run Django system checks:

```powershell
python manage.py check
```

Check for missing model migrations:

```powershell
python manage.py makemigrations --check --dry-run
```

Check installed Python package consistency:

```powershell
python -m pip check
```

Check the Git diff for whitespace errors:

```powershell
git diff --check
```

Confirmed bugs should receive regression tests whenever practical.

Testing strategy is risk-based:

* low-risk changes receive lightweight validation
* medium-risk changes receive focused tests and targeted runtime QA
* high-risk changes such as authentication, playback, progress, assessment, permissions, and data integrity receive immediate focused regression/security testing
* the Android release candidate will receive a comprehensive final audit followed by full regression and real-employee pilot testing

## CI

GitHub Actions is configured to run the backend validation pipeline.

The CI environment uses:

* Ubuntu runner
* MySQL 8 service
* Python 3.14

Current CI checks include:

```text
python -m pip check
python manage.py check
python manage.py makemigrations --check --dry-run
python manage.py test
```

The current CI pipeline does not yet include:

* automated Playwright/browser E2E tests
* deployment
* production release automation
* Android build/release validation

These may be added as the corresponding project phases are implemented.

## Local Development Setup

### 1. Clone the Repository

```bash
git clone https://github.com/ayuxhdev/Training-Module-Application.git

cd Training-Module-Application
```

### 2. Create a Virtual Environment

On Windows PowerShell:

```powershell
python -m venv .venv

.venv\Scripts\Activate.ps1
```

### 3. Install Dependencies

```powershell
python -m pip install --upgrade pip

pip install -r requirements.txt
```

### 4. Configure MySQL

The project uses MySQL rather than SQLite for normal development and automated backend testing.

Create the required development database and application database user according to the environment configuration used by the project.

### 5. Configure Environment Variables

Create a local `.env` file.

The `.env` file must not be committed to Git.

For local development:

```env
DEBUG=true
```

Production must use:

```env
DEBUG=false

DJANGO_SECRET_KEY=<secure-random-secret>
```

Database credentials and other required configuration must use the environment variable names expected by `config/settings.py`.

Never commit:

* database passwords
* production secrets
* API keys
* authentication tokens
* private credentials

### 6. Apply Migrations

```powershell
python manage.py migrate
```

### 7. Create a Superuser if Required

```powershell
python manage.py createsuperuser
```

### 8. Start the Development Server

```powershell
python manage.py runserver
```

Default development address:

```text
http://127.0.0.1:8000/
```

## Development Rules

Project development rules are documented in:

```text
AGENTS.md
```

Developers and coding agents should review that file before modifying the application.

Important principles include:

* inspect the existing implementation before editing
* prefer the simplest correct solution
* reuse existing models, helpers, permission logic, and established patterns
* enforce authorization on the backend
* never trust client state for permissions, progress, scores, completion, ownership, or parent relationships
* validate input safely
* preserve historical and security-sensitive data
* avoid unrelated refactoring
* avoid destructive schema or permission changes unless explicitly approved
* add regression tests for reproduced bugs
* run focused tests after changes
* run the complete test suite before considering important work complete
* do not commit or push unstable changes
* AI coding agents must not commit or push unless explicitly instructed by the user

## Project Documentation

Detailed documentation is stored under:

```text
docs/

├── PRD.md
├── ARCHITECTURE.md
├── DESIGN.md
├── TASKS.md
├── MEMORY.md
├── SECURITY.md
├── TESTING.md
└── DEPLOYMENT.md
```

Additional root-level documentation includes:

```text
README.md
AGENTS.md
CHANGELOG.md
```

### Documentation Purpose

`README.md`

* project introduction
* current status
* setup
* technology stack
* high-level architecture
* development entry point

`AGENTS.md`

* coding and agent rules
* security constraints
* project-specific implementation rules

`docs/PRD.md`

* product requirements
* users
* V1 scope
* exclusions
* future scope

`docs/ARCHITECTURE.md`

* Django applications
* data model relationships
* authorization architecture
* training lifecycle
* assignment flow
* video progress
* assessments
* certificates
* audit system

`docs/DESIGN.md`

* UI direction
* Garden's Need visual system
* layout rules
* components
* responsive behavior
* accessibility

`docs/TASKS.md`

* development roadmap
* current milestones
* future tasks
* known blockers

`docs/MEMORY.md`

* durable technical decisions
* important bug history
* implementation lessons
* architectural rationale

`docs/SECURITY.md`

* permission model
* authorization boundaries
* security decisions
* CSRF and session protection
* playback security
* assessment security
* audit considerations
* production requirements

`docs/TESTING.md`

* testing strategy
* MySQL test setup
* regression testing
* security testing
* browser testing
* Playwright strategy

`docs/DEPLOYMENT.md`

* production environment configuration
* secret handling
* HTTPS
* static and media files
* backups
* deployment checks
* rollback considerations

`CHANGELOG.md`

* meaningful project and release changes

## Current Development Direction

The next development stages are focused on making the existing backend fully consumable by the employee mobile application and then building the Android experience.

The expected dependency direction is:

```text
Mobile API Completion
        ↓
Android Foundation
        ↓
Employee Core Experience
        ↓
Learning + Secure Playback
        ↓
Assessment + Completion + Certificates
        ↓
Resilience + Operational Readiness
        ↓
Android Release Candidate
        ↓
Comprehensive Audit
        ↓
Employee Pilot
        ↓
Android Release
```

iOS is intentionally deferred until the Android application has reached a stable release state.

The detailed milestone roadmap will be maintained separately and should not be treated as final until the Android-first execution plan has been formally finalized.

## Production and Staging Readiness

The application is not yet production-ready.

Remaining infrastructure work includes areas such as:

* staging environment
* representative seed/demo data
* explicit production static-file configuration
* isolated media/video storage
* structured production logging
* production web server/deployment configuration
* deployment health checks
* database backup verification
* rollback procedures
* production observability

These will be implemented at the appropriate stage rather than prematurely complicating local development.

## V1 Release Standard

V1 should not be considered ready for release until:

* required functionality works end-to-end
* automated tests pass
* appropriate runtime testing passes
* high-risk security boundaries have been tested
* no known exploitable critical or high-severity security issue remains unresolved
* important reproducible defects have been resolved or formally accepted
* production configuration is secure
* documentation reflects the actual system
* deployment has been verified
* Android real-device testing has passed
* employee pilot testing has passed
* final regression has passed

## Future Scope

Potential future functionality includes:

* iOS employee application
* employee skill matrix
* practical skill assessments
* supervisor verification
* machine certifications
* QR-based certification verification
* shared-device workflows
* multilingual training
* AI-assisted factory knowledge
* retrieval-augmented knowledge access
* advanced workforce analytics
* stronger platform-specific mobile content protection where justified

These features are future scope and must not be treated as implemented functionality until they are explicitly developed and tested.

## Repository

GitHub repository:

```text
https://github.com/ayuxhdev/Training-Module-Application
```

## Product

**Garden's Need Internal Training Module Application**

This application is intended for internal organizational use.
