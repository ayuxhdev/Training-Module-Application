# Garden's Need Training Module Application

Internal employee training, assessment, certification, and workforce development platform for Garden's Need.

The application is designed to manage structured employee learning across departments and job roles while enforcing secure access, training versioning, assessment rules, progress tracking, certification, reporting, and auditability.

## Project Status

**Current phase:** Milestone 11 - Documentation, Project Structure, and CI

Core backend functionality is complete.

Current automated test baseline:

**189 full tests passing on MySQL**

The application is now moving toward frontend completion, end-to-end testing, deployment hardening, final security review, and visual polish.

## Technology Stack

### Backend

- Python 3.14
- Django 5.2 LTS
- MySQL 8
- Django built-in authentication system
- Server-rendered Django templates

### Frontend

- HTML
- CSS
- Basic JavaScript
- Django Templates

A separate SPA framework such as React is intentionally not used for V1.

### Development

- Visual Studio Code
- Git
- GitHub
- GitHub Actions
- Playwright for browser and end-to-end testing

## Application Architecture

The project follows a Django monolith architecture.

Major Django applications include:

```text
accounts/
organization/
training/
assessments/
certifications/
reports/
audit/
config/
```

The backend remains the authoritative source for:

- permissions
- employee scope
- training assignments
- progress
- assessment scores
- completion
- certificates
- audit records

Client-side state is never trusted for security-sensitive decisions.

## Core Features

### Authentication and Authorization

The application supports these roles:

- Administrator
- Training Coordinator
- Manager
- Trainer
- Supervisor
- Employee

Authorization is enforced on the backend.

Managers are restricted to employees within their authorized reporting hierarchy.

Employees can access only their own permitted training-related information.

### Organization Management

The system supports:

- departments
- job roles
- employees
- reporting relationships
- recursive manager hierarchy
- employee activation and deactivation
- preservation of historical employee relationships

Employee records are deactivated rather than deleted when historical information must be preserved.

### Training Management

Training content follows this hierarchy:

```text
Training
└── Training Version
    └── Module
        └── Lesson
```

Lessons currently support:

- text content
- video content

Training versions use the lifecycle:

```text
DRAFT
PUBLISHED
RETIRED
```

Published and retired training versions are protected from unsafe modification.

Publishing requires the configured training requirements to be valid, including the required final assessment structure.

### Training Assignments

Training can be assigned:

- manually
- through job-role requirements

Assignments preserve historical information including assignment source and snapshots.

The backend validates:

- active employee eligibility
- training version state
- duplicate assignments
- due dates
- ownership and reporting scope

### Video Progress Tracking

Video lessons support:

- resume position
- watch sessions
- heartbeat tracking
- watched-range tracking
- progress persistence
- anti-skip protections
- idle-time protections
- controlled completion logic

Video progress and completion are calculated by the backend rather than trusted from browser-supplied state.

### Assessments

The assessment system includes:

- question bank
- question revisions
- answer options
- lesson quizzes
- final assessments
- attempt tracking
- attempt limits
- prerequisites
- server-side scoring
- pass/fail handling

Assessment scores and training completion are determined by trusted backend logic.

Successful completion of the required final assessment can complete the related training assignment.

### Certificates

Certificates are automatically issued after authoritative training completion when all required conditions are satisfied.

Certificates include:

- unique certificate number
- issue timestamp
- employee snapshot
- training version snapshot
- revocation support

Certificate issuance is idempotent.

Revocation preserves the historical certificate record rather than deleting it.

### Dashboards and Reports

Role-aware dashboards provide information based on the authenticated user's permissions and scope.

Reporting currently supports information such as:

- assignments
- assignment status
- completion
- overdue assignments
- departments
- job roles
- training
- training versions

Managers remain restricted to their authorized reporting hierarchy.

Employees cannot access administrative reporting functionality.

### Audit Logging

Important application actions are recorded through the audit system.

Examples include:

- employee changes
- department changes
- job-role changes
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

Audit records preserve accountability while avoiding unnecessary sensitive information such as assessment answers or training content.

## Security Principles

The application follows these security principles:

- authorization is enforced server-side
- permissions are never based only on hidden UI controls
- direct URL access is protected
- ownership is derived from trusted backend state
- manager scope is calculated on the backend
- client-supplied progress and scores are not trusted
- state-changing actions use appropriate HTTP methods
- CSRF protection remains enabled
- malformed input should return controlled errors rather than HTTP 500 responses
- important operations use database transactions and locking when required
- historical records are preserved where necessary
- secrets are never committed to Git
- production configuration fails closed when required security configuration is missing
- secure cookies are enabled for production configuration
- audit metadata avoids unnecessary sensitive data

A dedicated final bug hunt, security review, dependency review, and repository review is planned before the V1 release.

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

- database passwords
- production secrets
- API keys
- authentication tokens
- private credentials

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

## Testing

The project uses Django's test framework with MySQL.

Run the complete automated test suite:

```powershell
python manage.py test
```

Current backend baseline:

```text
189 tests passing on MySQL
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

Browser and end-to-end testing with Playwright is planned during the frontend and integration milestones.

## Development Rules

Project development rules are documented in:

```text
AGENTS.md
```

Developers and coding agents should review that file before modifying the application.

Important principles include:

- inspect the existing implementation before editing
- prefer the simplest correct solution
- reuse existing models, helpers, permission logic, and patterns
- enforce authorization on the backend
- never trust client state for permissions, progress, scores, completion, ownership, or parent relationships
- validate input safely
- preserve historical and security-sensitive data
- avoid unrelated refactoring
- avoid destructive schema or permission changes unless explicitly approved
- add regression tests for reproduced bugs
- run focused tests after changes
- run the complete test suite before considering important work complete
- do not commit or push unstable changes

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
- project introduction
- setup
- technology stack
- high-level architecture
- development entry point

`AGENTS.md`
- coding and agent rules
- security constraints
- project-specific implementation rules

`docs/PRD.md`
- product requirements
- users
- V1 scope
- exclusions
- future scope

`docs/ARCHITECTURE.md`
- Django applications
- data model relationships
- authorization architecture
- training lifecycle
- assignment flow
- video progress
- assessments
- certificates
- audit system

`docs/DESIGN.md`
- UI direction
- Garden's Need visual system
- layout rules
- components
- responsive behavior
- accessibility

`docs/TASKS.md`
- development roadmap
- current milestone
- future tasks
- known blockers

`docs/MEMORY.md`
- important durable technical decisions
- important bug history
- implementation lessons
- architectural rationale

`docs/SECURITY.md`
- permission model
- authorization boundaries
- security decisions
- CSRF and session protection
- playback security
- assessment security
- audit considerations
- production requirements

`docs/TESTING.md`
- testing strategy
- MySQL test setup
- regression testing
- security testing
- browser testing
- Playwright strategy

`docs/DEPLOYMENT.md`
- production environment configuration
- secret handling
- HTTPS
- static and media files
- backups
- deployment checks
- rollback considerations

`CHANGELOG.md`
- meaningful project and release changes

## V1 Roadmap

Completed backend milestones:

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

An interim backend bug-hunt after Milestone 10 increased the automated test baseline from 173 to:

```text
189 passing MySQL tests
```

Remaining V1 milestones:

```text
Milestone 11 - Documentation + Project Structure + CI
Milestone 12 - Functional Frontend
Milestone 13 - UX + Responsive + Accessibility
Milestone 14 - Full E2E + Integration Testing
Milestone 15 - Production + Deployment Hardening
Milestone 16 - Final Bug Hunt + Security + Repository Review
Milestone 17 - Final Readability + Refactor Pass
Milestone 18 - Premium Visual Polish
Milestone 19 - Final Acceptance + V1 Release
```

## V1 Release Standard

V1 should not be considered ready for release until:

- required functionality works end-to-end
- automated tests pass
- browser and integration testing passes
- no known exploitable critical or high-severity security issue remains
- no known important reproducible bug remains unresolved
- production configuration is secure
- documentation is accurate
- deployment has been verified
- final acceptance testing has passed

## Future Scope

Potential future functionality includes:

- employee skill matrix
- practical skill assessments
- supervisor verification
- machine certifications
- QR-based certification verification
- shared-device workflows
- notifications
- multilingual training
- AI-assisted factory knowledge
- retrieval-augmented knowledge access
- advanced workforce analytics
- native mobile functionality
- stronger mobile screen-capture protection where platform capabilities allow

These features are future scope and must not be treated as implemented functionality until they are explicitly developed and tested.

## Repository

GitHub repository:

```text
https://github.com/ayuxhdev/Training-Module-Application
```

## Product

**Garden's Need Internal Training Module Application**

This application is intended for internal organizational use.