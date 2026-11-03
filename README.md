# Garden's Need Training Module Application

**Internal Employee Training, Assessment & Certification Platform**

A cross-platform employee training management system developed for **Garden's Need Pvt. Ltd.**, supporting structured learning, training administration, assessments, certifications, workforce management and reporting.

The application consists of a Django web portal and a Flutter Android application, both connected to a centralized Django REST API and MySQL database.

**Current status:** Advanced V1 development, integration and release-readiness testing.

**Last updated:** 3 November 2026

> **Release status:** Not yet production-ready. Core functionality is substantially implemented, but final QA, security checks, UI/UX corrections and deployment validation remain in progress.

---

## 1. Technology Stack

| Component | Technology |
|---|---|
| Backend | Python, Django 5.2 LTS |
| REST API | Django REST Framework |
| Authentication | Django Authentication, SimpleJWT |
| Database | MySQL 8 |
| Web frontend | Django Templates, HTML, CSS, JavaScript |
| Android application | Flutter / Dart |
| Media playback | Protected video playback with server-authoritative progress |
| Video validation | FFprobe |
| CI/CD | GitHub Actions |
| Version control | Git / GitHub |
| Development environment | Visual Studio Code, Windows |
| Android package | `com.gardensneed.training` |

The Django backend remains the authoritative source for authentication, authorization, training versions, assignments, progress, assessment scoring, completion and certificate issuance.

The Flutter application consumes versioned APIs rather than duplicating security-sensitive business rules.

---

## 2. Application Architecture

```text
Garden's Need Training Platform
│
├── Django Web Portal
│   ├── Administration
│   ├── Organization Management
│   ├── Training Management
│   ├── Assessments
│   ├── Assignments
│   ├── Certificates
│   └── Reports
│
├── Flutter Android Application
│   ├── Authentication
│   ├── Employee Learning
│   ├── Video Playback
│   ├── Assessments
│   ├── Certificates
│   ├── Notifications
│   └── Authorized Management
│
└── Django REST API (/api/v1/)
    ├── Authentication & Permissions
    ├── Organization & Employees
    ├── Training & Versioning
    ├── Assignments & Requirements
    ├── Protected Media
    ├── Assessments & Question Bank
    ├── Completion & Certificates
    ├── Notifications
    └── Audit & Reporting
         │
         └── MySQL Database
```

Both applications share backend records and business rules. Platform-specific interfaces must preserve the same authorization and data-integrity guarantees.

---

## 3. Core Features

### Authentication and Authorization

- Role-based access for Administrator, Training Coordinator, Manager, Trainer, Supervisor and Employee.
- Django session authentication for the website.
- JWT authentication for the mobile API.
- Secure mobile token storage.
- Automatic access-token renewal and refresh coordination.
- Logout and token invalidation handling.
- Employee-specific data isolation.
- Recursive Manager reporting-hierarchy restrictions.
- Protection against unauthorized direct API access.

Current JWT configuration:

| Setting | Value |
|---|---|
| Access-token lifetime | 30 minutes |
| Refresh-token lifetime | 7 days |

The Flutter client includes automatic renewal, session-recovery handling and authentication checks before uploads.

Longer-lived revocable session policies remain a separate backend decision.

### Organization and Employee Management

- Department management.
- Job-role management.
- Employee records and account status.
- Reporting relationships.
- Manager hierarchy.
- Role-based access permissions.
- Historical record preservation.

### Training Management

Training is structured as:

```text
Training Course
└── Training Version
    ├── Module
    │   ├── Text Lesson
    │   └── Video Lesson
    └── Assessment
```

Supported workflows include:

- Training-course creation and management.
- Draft training versions.
- Module creation and editing.
- Text lesson authoring.
- Video lesson authoring and uploading.
- Version history.
- Assessment and question-bank authoring.
- Version publication and retirement through supported management workflows.

**Version integrity rules:**

- Draft versions may be edited.
- Published versions are immutable.
- Retired versions remain immutable.
- Published content cannot be destructively deleted.
- Existing assignments remain pinned to their assigned versions.
- Retired versions cannot receive new assignments.
- Employees already assigned to retired versions may continue their training.

Some web management actions, including version publication and retirement, still require mobile/API parity work.

### Protected Video Learning

The application includes:

- Protected training-video access.
- Authenticated playback sessions.
- Server-controlled watched coverage.
- Forward-seek restrictions before completion.
- Replay of previously watched portions.
- Completed-video replay.
- Free seeking after completion.
- Playback progress synchronization.
- Secure video upload and validation.
- Android capture deterrence using `FLAG_SECURE` where applicable.

Client-side protections do not guarantee absolute prevention of external recording or copying.

The backend remains authoritative for watched progress and completion.

### Assessments and Question Bank

- Question bank creation and management.
- Single-choice and True/False questions.
- Answer-option management.
- Draft question revisions.
- Permanent revision freezing.
- Assessment authoring.
- Attempt tracking and limits.
- Server-side scoring.
- Pass/Fail evaluation.
- Assessment history and prerequisites.

Frozen question revisions and published assessment answer keys must remain immutable.

Client-side validation improves usability, but backend validation must independently enforce correctness.

### Certificates

- Certificate issuance after eligible completion.
- Unique certificate identification.
- Employee and training-version information.
- Completion and issuance details.
- Revocation and historical preservation.
- Certificate access through the website and Android application.

Certificate presentation and website print formatting are undergoing refinement. The underlying certificate records remain authoritative.

### Assignments and Reporting

- Manual training assignments.
- Job-role training requirements.
- Manager-scoped assignments.
- Assignment version pinning.
- Assignment status and progress.
- Training dashboards.
- Completion and certificate reporting.
- Audit records for important operations.

---

## 4. Android Application

The Flutter Android application supports employee learning and authorized management workflows.

Major implemented areas include:

- Login and account access.
- Dashboard and profile.
- Assigned training.
- Text and video lessons.
- Protected playback and progress tracking.
- Assessments and results.
- Certificates.
- Notifications.
- Training catalogue.
- Draft training versions and modules.
- Text/video lesson authoring.
- Native video selection and uploading.
- Question-bank and assessment authoring.
- Role-aware management operations.

### Authentication Reliability

The mobile networking layer includes:

- Serialized token refresh.
- Coordinated token persistence.
- Authentication recovery for supported requests.
- Pre-upload authentication checks.
- Longer upload-specific timeouts.
- Preservation of active lesson drafts during recoverable session expiry.
- Protection against automatic replay of non-idempotent lesson creation or uploads.
- Same-account recovery restrictions.

Explicit logout, account switching and unrecoverable authentication states must not expose another user's draft.

### Physical-Device Testing

Testing has been performed on a **Realme Narzo 70 Turbo 5G** using private Tailscale HTTPS connectivity.

Reported successful checks include:

- Wireless authentication over mobile data.
- Dashboard and training access.
- Video anti-skip restrictions.
- Completed-video replay.
- Learner assessment submission.
- Question-bank creation, revisions and freezing.
- Module and text-lesson authoring.
- Video uploads of approximately 2.5 MB and 45 MB.
- Video attachment persistence.
- Authentication continuity after the access-token lifetime.

These checks do not replace complete production-device acceptance testing.

---

## 5. Development Setup

### Backend Requirements

- Python compatible with the project's dependency requirements.
- MySQL 8.
- FFprobe available for video validation.
- Dependencies from `requirements.txt`.
- A locally configured development environment.

### Clone Repository

```powershell
git clone https://github.com/ayuxhdev/Training-Module-Application.git
cd Training-Module-Application
```

### Create Python Environment

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
```

### Configure Environment

Configure the database, Django secret key, allowed hosts and other required settings using the project's current configuration.

Do not commit `.env`, passwords, database credentials or authentication tokens.

### Apply Database Migrations

```powershell
python manage.py migrate
```

Review pending migrations before applying them to any database containing valuable records.

### Start the Local Django Website

```powershell
python manage.py runserver 127.0.0.1:8000
```

For ordinary local development, use the project's development configuration.

A production-style `DEBUG=False` configuration requires correctly collected and served static files. Django's development server is not suitable for production hosting.

---

## 6. Flutter Development

From the `mobile` directory:

```powershell
cd mobile
flutter pub get
flutter analyze
flutter test
```

### Build Android APK

For a local development build:

```powershell
flutter build apk --debug
```

For a physical Android phone using an approved HTTPS test backend:

```powershell
flutter build apk --debug --dart-define=API_BASE_URL=https://YOUR-APPROVED-HOSTNAME
```

Do not append `/api/v1` to the override. The mobile application constructs its API routes.

Debug APK output:

```text
mobile/build/app/outputs/flutter-apk/app-debug.apk
```

### Private Android Testing

Tailscale Serve may be used to expose a loopback-bound development API privately to authorized test devices.

Example:

```powershell
tailscale serve --https=443 http://127.0.0.1:8000
```

Requirements:

- Tailscale configured on both devices.
- Private HTTPS enabled.
- Django running on the designated local API port.
- MySQL available.
- Appropriate `ALLOWED_HOSTS` configuration.
- Access restricted to authorized tailnet devices.

Do not use public Tailscale Funnel for this development setup.

Tailscale is a **temporary private QA arrangement**, not the intended production deployment architecture.

---

## 7. Testing and Quality Assurance

The project uses automated tests, focused regression testing, independent review and real-device QA.

### Automated Checks

Backend:

```powershell
python manage.py check
python manage.py makemigrations --check --dry-run
python -m pip check
git diff --check
```

Flutter:

```powershell
cd mobile
flutter analyze
flutter test
```

Backend database tests must use the approved MySQL testing environment. Some legacy tests can perform destructive database operations and require isolation.

### Recent Reported Validation

| Validation | Reported result |
|---|---|
| Flutter full suite, before subsequent fixes | 1,113/1,113 passed |
| Authentication/draft-recovery focused checkpoint | 214/214 passed |
| Account-isolation focused tests | 7/7 passed |
| Backend assessment management | 42/42 passed |
| Backend assessment concurrency | 6/6 passed |
| Backend question history and attempts | 21/21 passed |
| Backend assessment template tests | 7/7 passed |

These results are from separate development checkpoints. They are **not a claim that the complete current uncommitted worktree has passed one combined final regression run**.

The previously pushed GitHub Actions workflow was reported green. More recent local changes require review and fresh CI validation after approved integration.

### Quality Gates

Before V1 release:

- Core business workflows must work end-to-end.
- Role and ownership boundaries must be enforced server-side.
- Published content must remain immutable.
- Authentication and session recovery must be reliable.
- Video playback and uploads must pass real-device testing.
- Assessment scoring and certificate issuance must remain authoritative.
- Critical UI/UX defects must be corrected.
- Automated tests and GitHub CI must pass.
- Production security, backups and rollback procedures must be verified.
- Final release acceptance must be completed.

---

## 8. Current Development Focus

The project has progressed beyond the initial Flutter foundation and into cross-platform integration and V1 stabilization.

Current areas of work include:

- Completing Android and website functional QA.
- Improving consistency between Django and Flutter terminology, navigation and user experience.
- Simplifying Training Management screens.
- Removing obsolete development placeholders and disabled controls.
- Correcting Play/Pause control behavior.
- Improving certificate presentation and print formatting.
- Strengthening question-authoring validation.
- Closing remaining web/mobile management capability gaps.
- Final security, regression and deployment-readiness checks.

The intended V1 feature-completion target is **6 November 2026**, subject to validation results. This is a planning target, not a confirmed production-release date.

---

## 9. Engineering and Security Rules

Contributors and coding agents must:

- Inspect repository status and diffs before editing.
- Preserve all existing uncommitted changes.
- Avoid conflicting edits and shared-resource interference.
- Keep Django/MySQL authoritative.
- Preserve immutable published versions and historical records.
- Enforce access permissions on the backend.
- Avoid introducing unrestricted media routes.
- Avoid unsafe retries of non-idempotent operations.
- Protect credentials, tokens and private user data.
- Add focused regression tests for meaningful changes.
- Run broader validation at appropriate checkpoints.
- Obtain explicit approval before staging, committing or pushing changes.

Review `AGENTS.md` and the current repository documentation before significant implementation work.

---

## 10. Documentation

Project documentation includes:

- `AGENTS.md` — Engineering and coding-agent rules.
- `docs/PRD.md` — Product requirements.
- `docs/ARCHITECTURE.md` — System architecture.
- `docs/DESIGN.md` — UI/UX direction.
- `docs/TASKS.md` — Development tasks.
- `docs/MEMORY.md` — Technical decisions and lessons.
- `docs/SECURITY.md` — Security requirements.
- `docs/TESTING.md` — Testing strategy.
- `docs/DEPLOYMENT.md` — Deployment guidance.
- `docs/ROADMAP.md` — Repository milestone roadmap.
- `CHANGELOG.md` — Project change history.

Documentation must be kept consistent with actual repository behavior. Older milestone descriptions are historical and must not override current code, tests or verified implementation evidence.

---

## 11. Production Readiness

**The application is not yet production-ready.**

The current local development and Tailscale testing environment must not be treated as a production deployment.

Before release, complete production infrastructure configuration, secret management, secure HTTPS hosting, static/media serving, backups, restoration checks, monitoring, security review, final regression testing and employee acceptance.

---

## 12. Repository

**GitHub:** https://github.com/ayuxhdev/Training-Module-Application

**Organization:** Garden's Need Pvt. Ltd.

**Platform:** Garden's Need Training Module Application

**Android package:** `com.gardensneed.training`

**Development priority:** Reliable Flutter Android employee experience, alongside a fully supported Django web portal.

---

*An internal training platform designed to deliver consistent learning, secure assessments, reliable progress tracking and accountable employee development across Garden's Need.*