# Garden's Need Training Module Application

Internal employee training, assessment, certification, and workforce development platform for Garden's Need.

The application manages structured employee learning across departments and job roles while enforcing secure access, training versioning, assignment rules, progress tracking, assessment scoring, certification, reporting, and auditability.

---

## Project Status

**Current stage: M15 complete, M16 next**

The project now consists of:

- Django web application
- Versioned REST API
- Flutter Android employee application
- MySQL-backed backend
- Protected training-media architecture
- Automated backend, mobile, and playback validation

### Completed milestones

- M0-M12: Core web platform
- M13: Mobile API Foundation & Versioning
- M14: Flutter / Android Foundation
- M15: Employee App Core

### Next milestones

- **M16:** Learning + Secure Video
- **M17:** Assessment + Certificates
- **M18:** Notifications + Resilience
- **M19:** Android Release Candidate
- **M20:** Production + Deployment Hardening
- **M21:** Final Bug Hunt + Security + Repository Review
- **M22:** Readability + Refactor + Garden's Need Visual Polish
- **M23:** Final Acceptance + Android V1 Release

`docs/ROADMAP.md` is the canonical milestone roadmap.

### Current validation baseline

```text
Django/MySQL:       348 / 348 passing
Flutter:             81 / 81 passing
Flutter analyze:      0 issues
JavaScript playback:  3 / 3 passing
Android debug APK:    successful
```

Additional checks currently passing include:

```text
Django system check
Migration drift check
pip check
git diff --check
```

The application is **not yet production-ready**.

---

# Technology Stack

## Backend

- Python
- Django
- Django REST Framework
- MySQL 8
- Django authentication
- SimpleJWT
- Server-rendered Django templates
- Protected training-media endpoints

## Web Frontend

- Django Templates
- HTML
- CSS
- JavaScript

The existing web application remains a supported product surface.

A separate React/Vue SPA is not required for V1.

## Mobile

- Flutter
- Android-first
- Flutter `video_player` for the planned V1 video experience
- Secure token storage
- REST API integration

The Android application uses the existing versioned backend rather than duplicating business rules locally.

iOS is intentionally deferred until Android has reached a stable release state.

## Development

- Visual Studio Code
- Git
- GitHub
- GitHub Actions
- MySQL
- Django test framework
- Flutter tooling

---

# Application Architecture

The current system has two client surfaces sharing one authoritative backend.

```text
                    Garden's Need Training Platform
                              │
                    ┌─────────┴─────────┐
                    │                   │
             Django Web Portal    Flutter Android App
                    │                   │
                    └─────────┬─────────┘
                              │
                       Django REST API
                           /api/v1/
                              │
                       Django Backend
                              │
                 ┌────────────┼────────────┐
                 │            │            │
              MySQL       Media Storage   Audit
```

Major backend applications include:

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

The backend remains authoritative for:

- authentication
- authorization
- employee scope
- Manager reporting scope
- training versions
- assignments
- progress
- playback sessions
- assessment scoring
- completion
- certificates
- audit records

Clients must not become authoritative for security-sensitive decisions.

---

# Training Version Lifecycle

Training follows:

```text
Training
└── Training Version
    └── Module
        └── Lesson
```

Training versions use:

```text
DRAFT
PUBLISHED
RETIRED
```

Rules:

- Draft versions may be edited.
- Published versions are immutable.
- Retired versions remain immutable.
- Anything that has been published cannot be deleted.
- New assignments use the latest published version.
- Existing assignments remain pinned to their assigned version.
- Retired versions cannot receive new assignments.
- Existing assignments may continue against a retired version.
- Published assessments and answer keys remain frozen with their version.
- Published media is immutable.

A corrected published training version requires a new version.

Employees are not automatically migrated to newer versions.

---

# Current REST API

The REST API is versioned under:

```text
/api/v1/
```

Current API areas include:

```text
Authentication
Dashboard
Assignments
Learning
Playback Sessions
Protected Media
```

### Authentication

```text
POST /api/v1/auth/login/
POST /api/v1/auth/refresh/
POST /api/v1/auth/logout/
GET  /api/v1/auth/me/
```

### Dashboard

```text
GET /api/v1/dashboard/
```

### Assignments

```text
GET /api/v1/assignments/
GET /api/v1/assignments/<assignment_id>/
```

### Learning

```text
GET  /api/v1/assignments/<assignment_id>/lessons/<lesson_id>/progress/
POST /api/v1/assignments/<assignment_id>/lessons/<lesson_id>/progress/

POST /api/v1/assignments/<assignment_id>/lessons/<lesson_id>/complete/
```

### Playback Sessions

```text
POST /api/v1/assignments/<assignment_id>/lessons/<lesson_id>/sessions/

POST /api/v1/assignments/<assignment_id>/lessons/<lesson_id>/sessions/<session_id>/end/
```

### Protected Media

```text
GET /api/v1/assignments/<assignment_id>/lessons/<lesson_id>/sessions/<session_id>/media/
```

The existing session-based media endpoint is the authoritative V1 protected-media route.

Assessment and certificate APIs are planned for later milestones rather than being treated as complete mobile functionality today.

---

# Authentication and Authorization

The application supports:

- Administrator
- Training Coordinator
- Manager
- Trainer
- Supervisor
- Employee

Authorization is enforced on the backend.

## Employee scope

Employees access only their own permitted records.

For the mobile API, the authenticated user and linked Employee record determine ownership.

Clients must not select arbitrary employee IDs to obtain another employee's data.

## Manager scope

Managers are restricted to their recursive reporting hierarchy.

Filters cannot broaden this scope.

The same principle applies to:

- dashboards
- reports
- assignments
- direct URLs
- API resources

---

# Core Features

## Organization Management

The system supports:

- departments
- job roles
- employees
- reporting relationships
- recursive Manager hierarchy
- employee activation/deactivation
- historical relationship preservation

Employee records are deactivated rather than destructively deleted when historical preservation is required.

---

## Training Management

Training supports:

- training versions
- modules
- lessons
- text lessons
- video lessons
- publishing
- retirement
- version pinning
- historical preservation

Published content is protected from unsafe modification.

---

## Training Assignments

Assignments support:

- manual assignment
- job-role requirements
- version pinning
- due dates
- assignment status
- assignment source
- historical snapshots
- ownership validation
- Manager-scope validation

Assignment states include:

```text
ASSIGNED
IN_PROGRESS
COMPLETED
CANCELLED
```

---

## Learning Progress

The backend tracks learning state.

For text lessons, completion is persisted through the API.

For video lessons, the backend will remain authoritative for:

- playback sessions
- watched ranges
- progress
- completion
- anti-skip validation
- idle-time protection

The mobile client must not manufacture completion locally.

---

## Secure Video Architecture

V1 video is:

```text
Streaming only
No unrestricted downloads
Server-authoritative progress
Session-based media access
```

The existing media route is tied to:

- authenticated employee
- authorized assignment
- exact lesson
- playback session

The architecture supports byte-range requests for seeking.

Published media is immutable.

Replacing published media requires a new training version.

Android-specific capture protection such as `FLAG_SECURE` may be used where appropriate, but no client platform can guarantee prevention of screenshots or external recording.

---

## Assessments

The assessment system supports:

- question banks
- question revisions
- answer options
- lesson quizzes
- final assessments
- attempt tracking
- attempt limits
- prerequisites
- server-side scoring
- pass/fail handling
- assessment history

The backend determines authoritative scores and completion.

The mobile client must never decide whether an answer is correct or whether an employee has passed.

Assessment and certificate mobile integration is planned for M17.

---

## Certificates

Certificates support:

- unique certificate numbers
- issue timestamps
- employee information
- training-version references
- revocation
- historical preservation
- idempotent issuance

Certificate revocation does not delete the historical certificate.

---

## Dashboards and Reports

Role-aware dashboards and reporting support information such as:

- assignments
- completion
- overdue work
- departments
- job roles
- training
- training versions
- certificates

Manager results remain limited to the authorized reporting hierarchy.

Employees receive employee-scoped dashboard information.

---

## Audit Logging

Important actions are recorded through the audit system.

Examples include:

- employee changes
- organization changes
- training changes
- training publishing
- training retirement
- assignments
- question changes
- assessment attempts
- assessment results
- lesson completion
- training completion
- certificate issuance
- certificate revocation

Audit records avoid unnecessary sensitive information.

---

# Security Principles

The application follows these core principles:

- backend authorization is authoritative
- hidden UI controls are not security controls
- direct URLs are protected
- ownership is derived from trusted backend state
- Manager scope is enforced server-side
- client-supplied progress is not trusted
- client-supplied assessment scores are not trusted
- client-supplied employee IDs do not override ownership
- state-changing actions use appropriate HTTP methods
- CSRF protection remains enabled
- malformed input receives controlled errors
- transactions and locking are used where correctness requires them
- published content is immutable
- historical records are preserved where required
- secrets are never committed
- production security configuration fails closed where required
- authentication tokens are securely handled
- inactive employees cannot use protected functionality
- audit metadata avoids unnecessary sensitive data

Security-sensitive testing includes:

- IDOR
- ownership isolation
- Manager scope
- JWT behavior
- logout/token invalidation
- inactive employee handling
- playback security
- progress validation
- protected media access

The final broad security and repository review is scheduled for M21.

---

# Web Application

The Django web application remains a complete product surface.

Current workflows include:

- authentication
- dashboards
- employee management
- organization management
- reporting hierarchy
- training management
- training versioning
- assignments
- text learning
- video learning
- assessments
- certificates
- reporting
- audit viewing

The existing Django web application will be refined rather than replaced.

Final Garden's Need visual polish is intentionally scheduled for M22 after the major functional work is complete.

---

# Android Employee Application

The Flutter Android application is now an active part of the repository.

M14 established:

- Flutter Android project
- networking
- secure storage
- authentication
- application shell
- base UI
- dashboard integration
- profile integration

M15 added:

- assignment list
- assignment status
- assignment detail
- training entry
- module navigation
- lesson navigation
- text lesson completion
- learning progress
- previous/next navigation
- learning-flow integration QA

Current mobile baseline:

```text
81 / 81 Flutter tests passing
flutter analyze: 0 issues
Android debug APK: successful
```

---

# Mobile Architecture Direction

The Flutter application consumes the existing API.

The mobile client must not duplicate backend rules for:

- authorization
- assignment eligibility
- versioning
- playback security
- completion
- assessment scoring
- certificate issuance

The server remains authoritative.

The application is Android-first.

iOS development is deferred until Android has been released and stabilized.

---

# Offline Boundary

V1 does not provide unrestricted offline course completion.

The server remains authoritative for:

- playback progress
- lesson completion
- assessments
- certificates

Offline caching may improve usability where safe, but it must not create a second authoritative completion system.

---

# Testing

The project uses risk-based testing.

### Current baseline

```text
Django/MySQL:       348 / 348
Flutter:             81 / 81
Flutter analyze:      0 issues
JavaScript playback:  3 / 3
```

### Backend checks

```powershell
python manage.py test
python manage.py check
python manage.py makemigrations --check --dry-run
python -m pip check
git diff --check
```

### Flutter checks

```powershell
flutter analyze
flutter test
```

### JavaScript

Playback tests should be run whenever web playback code changes.

---

# CI

GitHub Actions validates the major automated surfaces.

Current CI direction includes:

```text
Django/MySQL tests
Django system checks
Migration consistency
pip check
Flutter analyze
Flutter tests
JavaScript playback tests
```

CI uses disposable credentials and must never contain production secrets.

The Flutter CI version must remain compatible with the Dart SDK required by `mobile/pubspec.yaml`.

---

# Development Setup

## 1. Clone the repository

```powershell
git clone https://github.com/ayuxhdev/Training-Module-Application.git

cd Training-Module-Application
```

## 2. Create the Python environment

```powershell
python -m venv .venv
```

Windows PowerShell:

```powershell
.venv\Scripts\Activate.ps1
```

## 3. Install backend dependencies

```powershell
python -m pip install --upgrade pip
pip install -r requirements.txt
```

## 4. Configure MySQL

The project uses MySQL 8 for normal backend development and automated testing.

Create the development database and application user according to the configuration expected by `config/settings.py`.

Do not use SQLite as the normal backend test database.

## 5. Configure environment variables

Create a local `.env` file.

The `.env` file must not be committed.

Local development may use:

```env
DEBUG=true
```

Production must use:

```env
DEBUG=false
DJANGO_SECRET_KEY=<secure-random-secret>
```

Database credentials and other configuration must use the variable names expected by the current settings implementation.

Never commit:

- database passwords
- production secrets
- API keys
- authentication tokens
- private credentials

## 6. Apply migrations

```powershell
python manage.py migrate
```

## 7. Create a superuser if required

```powershell
python manage.py createsuperuser
```

## 8. Start Django

```powershell
python manage.py runserver
```

Default development address:

```text
http://127.0.0.1:8000/
```

---

# Mobile Development

From the mobile directory:

```powershell
cd mobile
```

Install dependencies:

```powershell
flutter pub get
```

Analyze:

```powershell
flutter analyze
```

Run tests:

```powershell
flutter test
```

Build a debug APK:

```powershell
flutter build apk --debug
```

The Android application package identity is:

```text
com.gardensneed.training
```

Do not change the package identity casually. It is part of the Android release identity.

---

# Development Rules

Read:

```text
AGENTS.md
```

before making significant changes.

Important rules:

- inspect existing code first
- reuse established architecture
- prefer the simplest correct solution
- keep backend authority centralized
- do not duplicate business rules in Flutter
- avoid unrelated refactoring
- avoid unnecessary migrations
- preserve historical data
- add regression tests for confirmed bugs
- validate focused behavior first
- validate the broader suite afterward
- do not commit or push unless explicitly instructed
- do not introduce production infrastructure prematurely

---

# Documentation

Primary documentation:

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

Root documentation:

```text
README.md
AGENTS.md
CHANGELOG.md
```

### Documentation roles

`README.md`

- project introduction
- current status
- setup
- technology stack
- high-level architecture

`AGENTS.md`

- implementation rules
- agent workflow
- project constraints

`docs/PRD.md`

- product requirements
- V1 scope
- exclusions
- future scope

`docs/ARCHITECTURE.md`

- system architecture
- API architecture
- mobile architecture
- data and authorization boundaries
- media architecture

`docs/DESIGN.md`

- UI direction
- visual system
- responsive behavior
- accessibility
- final product polish

`docs/TASKS.md`

- milestone execution
- current tasks
- future tasks
- exit criteria

`docs/MEMORY.md`

- durable technical decisions
- important bugs
- implementation lessons
- architectural rationale

`docs/SECURITY.md`

- security model
- authorization
- media security
- authentication
- production security requirements

`docs/TESTING.md`

- test strategy
- regression strategy
- security testing
- mobile testing
- browser testing
- release testing

`docs/DEPLOYMENT.md`

- production configuration
- HTTPS
- secrets
- media
- backups
- deployment
- rollback
- release gates

`CHANGELOG.md`

- meaningful project changes
- milestone history

---

# Roadmap

```text
M0-M12  Core Platform                         COMPLETE
M13     Mobile API Foundation & Versioning    COMPLETE
M14     Flutter / Android Foundation          COMPLETE
M15     Employee App Core                     COMPLETE
M16     Learning + Secure Video               NEXT
M17     Assessment + Certificates             PLANNED
M18     Notifications + Resilience            PLANNED
M19     Android Release Candidate             PLANNED
M20     Production + Deployment Hardening     PLANNED
M21     Final Bug + Security Review            PLANNED
M22     Refactor + Visual Polish              PLANNED
M23     Final Acceptance + Android V1         PLANNED
```

---

# Immediate Development Direction

The immediate next milestone is:

## M16: Learning + Secure Video

M16 builds on the completed M13 API and M15 learning flow.

The primary goals are:

- Flutter video lesson experience
- protected playback session integration
- secure media streaming
- playback progress synchronization
- pause/resume behavior
- seeking behavior
- heartbeat handling
- server-authoritative completion
- Android capture protection where appropriate
- focused playback regression testing
- runtime Android QA

M16 must reuse the existing session-based protected media architecture.

It must not introduce a parallel unrestricted media endpoint.

---

# Release Direction

The intended release sequence is:

```text
M16
Learning + Secure Video
        ↓
M17
Assessment + Certificates
        ↓
M18
Notifications + Resilience
        ↓
M19
Android Release Candidate
        ↓
M20
Production + Deployment Hardening
        ↓
M21
Final Bug Hunt + Security + Repository Review
        ↓
M22
Readability + Refactor + Garden's Need Visual Polish
        ↓
M23
Final Acceptance + Android V1 Release
```

---

# Production Readiness

The application is not yet production-ready.

Remaining work includes:

- secure video completion
- mobile assessments and certificates
- resilience and operational features
- Android release-candidate validation
- production infrastructure
- staging/production-like validation
- backup and restore verification
- deployment hardening
- final security review
- final bug hunt
- visual polish
- employee pilot
- final acceptance

Do not represent these as completed until they have actually been implemented and validated.

---

# V1 Release Standard

V1 should not be released until:

- core workflows work end-to-end
- backend and mobile integration is stable
- automated tests pass
- high-risk security boundaries have been tested
- protected media works correctly
- Android real-device testing passes
- production configuration is secure
- backup and restore procedures are verified
- final bug hunt is complete
- final security/repository review is complete
- documentation matches the actual implementation
- employee pilot testing passes
- final acceptance passes

---

# Future Scope

Potential future capabilities include:

- iOS employee application
- skill matrices
- practical skill assessments
- supervisor verification
- machine certifications
- QR certificate verification
- shared-device workflows
- multilingual training
- advanced workforce analytics
- AI-assisted factory knowledge
- retrieval-augmented internal knowledge access
- additional mobile content-protection capabilities

These are future possibilities and are not considered implemented V1 functionality unless explicitly completed.

---

# Repository

GitHub:

```text
https://github.com/ayuxhdev/Training-Module-Application
```

---

# Product

**Garden's Need Internal Training Module Application**

An internal platform for structured employee learning, secure training delivery, assessment, certification, and workforce development.