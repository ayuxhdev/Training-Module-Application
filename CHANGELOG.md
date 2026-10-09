# Changelog

All meaningful changes to the Garden's Need Training Module Application are recorded here.

The project has not yet reached its first production release.

---

## [Unreleased]

### Current Development Status

- Core backend and web platform implementation completed.
- Mobile API foundation completed.
- Flutter/Android foundation completed.
- Employee App Core completed.
- Current milestone: **M16 - Learning + Secure Video**.
- Current verified automated baseline:
  - **348 Django/MySQL tests passing**
  - **81 Flutter tests passing**
  - **3 JavaScript playback tests passing**
- Flutter analyze passes.
- Android debug APK builds successfully.
- GitHub Actions CI passes.
- Migration consistency checks pass.
- `pip check` passes.
- `git diff --check` passes.

The application remains pre-release.

### Upcoming Milestones

- **M16:** Learning + Secure Video
- **M17:** Assessment + Certificates
- **M18:** Notifications + Resilience
- **M19:** Android Release Candidate
- **M20:** Production + Deployment Hardening
- **M21:** Final Bug Hunt + Security + Repository Review
- **M22:** Readability + Refactor + Garden's Need Visual Polish
- **M23:** Final Acceptance + Android V1 Release

---

# Backend Foundation

### Added

- Django project structure.
- MySQL 8 database integration.
- Environment-based configuration.
- Git and GitHub repository setup.
- Django application structure for:
  - accounts
  - organization
  - training
  - assessments
  - certifications
  - reports
  - audit

---

# Authentication and Organization

### Added

- Login and logout.
- Role-based access control.
- Six application roles:
  - Administrator
  - Training Coordinator
  - Manager
  - Trainer
  - Supervisor
  - Employee
- Department management.
- Job role management.
- Employee management.
- Reporting hierarchy.
- Recursive Manager employee scope.
- Employee self-scope.
- Employee deactivation.

### Security

- Protected direct URL access.
- Prevented unauthorized access outside permitted organizational scope.
- Protected privileged accounts from unsafe Training Coordinator actions.
- Preserved historical employee relationships.

---

# Training Content and Versioning

### Added

- Training records.
- Training versions.
- Modules.
- Lessons.
- Text lessons.
- Video lessons.
- Draft, Published, and Retired lifecycle states.
- Ordered training content.
- Training publishing workflow.

### Changed

- Published and retired versions made immutable according to lifecycle rules.
- Publishing validation requires a valid final assessment structure.

---

# Training Assignments

### Added

- Manual training assignments.
- Role-based training assignments.
- Assignment due dates.
- Assignment source tracking.
- Historical assignment snapshots.
- Duplicate assignment protection.
- Role-aware assignment visibility.

### Fixed

- Due-today role assignments now use one authoritative timestamp.
- Duplicate assignment races no longer produce HTTP 500 responses.
- Oversized role-based due periods now return controlled validation errors.

---

# Video Progress and Anti-Skip

### Added

- Video resume position.
- Watch sessions.
- Playback heartbeat handling.
- Watched-range tracking.
- Server-authoritative completion.
- Anti-skip protection.
- Idle-time protection.
- Concurrency-safe progress handling.

### Fixed

- Reusable playback tolerance issue.
- Idle-time credit issue.
- Malformed session identifier handling.
- Playback locking order.
- Cross-session playback allowance behavior.
- Idle playback could no longer manufacture valid completion.

---

# Assessments and Scoring

### Added

- Question bank.
- Question revisions.
- Answer options.
- Lesson quizzes.
- Final assessments.
- Assessment attempts.
- Attempt limits.
- Prerequisites.
- Server-side scoring.
- Pass/fail evaluation.
- Assignment completion integration.

### Fixed

- Duplicate assessment creation validation.
- Assessment attempt concurrency handling.
- Training completion race-related behavior.
- Question creation race handling.
- Revision creation now stops safely when question creation fails.

---

# Certificates

### Added

- Automatic certificate issuance.
- Unique certificate numbers.
- Certificate issue timestamps.
- Employee snapshots.
- Training version snapshots.
- Employee certificate access.
- Administrator and Training Coordinator certificate management.
- Certificate revocation.

### Changed

- Certificate issuance made idempotent.
- Revocation preserves the historical certificate record.

---

# Dashboards and Reports

### Added

- Role-aware dashboards.
- Administrator and Training Coordinator company metrics.
- Manager reporting-hierarchy metrics.
- Employee training information.
- Employee certificate information.
- Assignment reports.
- Status filtering.
- Department filtering.
- Job role filtering.
- Training filtering.
- Training version filtering.
- Overdue reporting.
- Completion percentage reporting.

### Security

- Report filters cannot broaden Manager scope.
- Employees cannot access administrative reporting.
- Crafted filter values remain constrained by backend authorization.

---

# Audit Logging and Backend Hardening

### Added

- Central audit logging service.
- Audit events for important state changes including:
  - organization changes
  - employee changes
  - training changes
  - assignments
  - publishing and retirement
  - question changes
  - assessment attempts
  - assessment results
  - completion
  - certificate issuance
  - certificate revocation
- Read-only audit log interface.
- Administrator and Training Coordinator audit access.

### Security

- Audit information uses server-derived actors and targets.
- Audit events are created after successful transactions.
- Audit logging failures do not undo successful business operations.
- Sensitive assessment answers are excluded from audit metadata.
- Secrets removed from committed settings.
- Production settings require explicit secret configuration.
- Certificate revocation reason input bounded and validated.

---

# Backend Cleanup

### Changed

- Removed verified unused imports.
- Removed unnecessary pass-through helper.
- Removed obsolete dependency wrapper.
- Removed unused dependency entries.
- Simplified selected backend code without changing behavior.

### Notes

- Large readability refactoring intentionally deferred until the final readability milestone.

---

# Security Hardening

### Security

- Production `DEBUG` now defaults to disabled.
- Production secure cookies enabled by default.
- HTTPS and HSTS configuration made environment-aware.
- Playback metadata validation strengthened.
- Malformed playback metadata now returns controlled errors.
- Authentication and authorization boundaries reviewed.
- IDOR protections reviewed.
- CSRF protections reviewed.
- Report and audit authorization reviewed.
- Assessment and certificate authorization reviewed.

### Fixed

- Idle playback could previously create false watch credit after long gaps.
- Cross-session playback allowance could previously be abused.
- Production configuration could previously fall back to unsafe debug behavior.

---

# Interim Backend Bug Hunt

Performed after Milestone 10 and before Milestone 11.

### Fixed

- Repeated employee deactivation no longer overwrites the original deactivation reason or creates another success audit event.
- Employee deactivation now returns HTTP 409 when the employee is already inactive.
- Role assignments due today no longer fail because of timestamp ordering.
- Concurrent duplicate role assignment creation no longer produces HTTP 500.
- Extreme stored due periods now return controlled validation errors.
- Training creation uniqueness races now return form errors instead of HTTP 500.
- Question creation races no longer continue into revision creation without a saved Question.

### Testing

The backend baseline increased from:

```text
173 tests
```

to:

```text
189 tests passing on MySQL
```

Verification also passed:

```text
python manage.py check
python manage.py makemigrations --check --dry-run
python -m pip check
git diff --check
```

---

# M11 - Documentation + Project Structure + CI

### Status

**Complete**

### Added

Repository documentation was established and maintained for:

- project overview
- architecture
- design
- security
- testing
- deployment
- project memory
- development tasks
- agent instructions

### CI

Added GitHub Actions CI with:

- Python environment
- MySQL 8 service
- dependency installation
- Django system check
- migration consistency check
- full MySQL test suite
- `pip check`

### Fixed

The initial CI run exposed a Linux filename case-sensitivity issue caused by:

```text
Requirements.txt
```

The dependency file was renamed to:

```text
requirements.txt
```

GitHub Actions subsequently passed.

---

# M13 - Mobile API Foundation + Versioning

### Status

**Complete**

### Added

Introduced the versioned mobile API foundation under:

```text
/api/v1/
```

Added:

- JWT login
- JWT refresh
- JWT logout
- authenticated employee profile
- dashboard API
- assignment list API
- assignment detail API
- lesson completion API
- learning progress API
- playback session creation
- playback progress
- playback session ending
- protected session-based media access
- employee ownership enforcement
- API authorization
- API error handling

### Security

- Employee-scoped access enforced.
- Assignment ownership enforced.
- Lesson access remains tied to authorized assignments.
- Protected media access remains session-based.
- Authentication and authorization remain server-authoritative.

### Testing

M13 completed with:

```text
348 Django/MySQL tests passing
```

Additional checks passed:

```text
Django check
Migration consistency
pip check
git diff --check
GitHub Actions CI
```

---

# M14 - Flutter / Android Foundation

### Status

**Complete**

### Added

Created the Android-first Flutter application foundation.

### Android

- Flutter Android project.
- Feature-based project structure.
- Android build configuration.
- Package identity cleanup.
- Environment configuration.

### Networking

- Dio API client.
- API configuration.
- API error handling.
- Authentication interceptor.
- Bearer token handling.
- Secure token storage.

### Authentication

- Employee-code login.
- JWT access/refresh storage.
- Session restoration.
- `/auth/me` integration.
- Logout.
- Riverpod authentication state.
- GoRouter authentication guards.
- Startup restoration.
- Authentication loading/error handling.

### Application Shell

- Dashboard.
- Learning.
- Profile.
- Login.
- Application shell.
- Route protection.
- Authentication state handling.

### Base UI

- Reusable cards.
- Text fields.
- Buttons.
- Status badges.
- Loading views.
- Error views.
- Empty views.
- Theme foundation.
- Typography foundation.
- Spacing foundation.
- Color foundation.

### Dashboard and Profile

- Real dashboard API integration.
- Real authenticated employee profile.
- Loading/error states.
- Pull-to-refresh.
- Accessible metric layout.

### Testing

M14 completed with:

```text
Flutter test suite passing
Flutter analyze passing
Android debug APK successful
CodeRabbit review clear
GitHub Actions CI passing
```

---

# M15 - Employee App Core

### Status

**Complete**

### Added

Employee learning foundation including:

- assignment list
- assignment status
- assignment detail
- training entry
- module navigation
- lesson navigation
- TEXT lesson screen
- TEXT lesson completion
- learning progress
- previous/next lesson navigation
- route integration
- end-to-end learning-flow integration

### Learning Flow

The completed flow is:

```text
Assignment
→ Assignment Detail
→ Module
→ Lesson
→ TEXT Lesson
→ Completion
→ Progress
→ Previous/Next
→ Completed State
```

### Reliability

Added protections for:

- stale asynchronous results
- route identity changes
- duplicate completion requests
- navigation during completion
- stale assignment detail state
- friendly API errors

### Testing

M15 completed with:

```text
Flutter tests: 81 passing
Flutter analyze: passing
Android debug APK: successful
CodeRabbit review: clear
GitHub Actions CI: passing
```

---

# Pre-M16 Hardening and Release Preparation

### Status

**Complete**

Before beginning M16, the project underwent a read-only architectural audit and cleanup pass.

### Reviewed

- Android package identity.
- Backend training lifecycle.
- Media architecture.
- Playback/session architecture.
- CI.
- Documentation consistency.
- Published-version behavior.
- Assignment version pinning.

### Media Hardening

Added/strengthened:

- uploaded media validation
- media size validation
- media content validation
- MP4/MOV/WebM magic-byte validation
- fail-closed validation behavior
- session audit logging
- media-related audit coverage

Global checksum uniqueness was intentionally not enforced because reuse of identical immutable media across versions/lessons was not established as a V1 business rule.

### CI Improvements

Updated CI to:

- use `actions/setup-node@v4`
- use a Flutter release compatible with the project's Dart SDK
- run Flutter analysis/tests
- preserve existing Django/MySQL validation
- run JavaScript playback tests

### Documentation

Historical changelog/test counts were preserved while current verified baselines were updated.

### Validation

The hardening pass verified:

```text
Django/MySQL: 348 tests passing
Flutter: 81 tests passing
JavaScript playback: 3 tests passing
Flutter analyze: passing
Android debug APK: successful
Django check: passing
Migration check: passing
pip check: passing
git diff --check: passing
```

No video playback implementation was added during this preparation work.

---

# M16 - Learning + Secure Video

### Status

**Next**

The next milestone focuses on the actual secure VIDEO learning experience.

Planned work:

- Flutter video player integration
- protected media streaming
- playback session integration
- playback heartbeat
- progress synchronization
- resume behavior
- session ending
- network recovery
- app lifecycle recovery
- anti-seek/anti-skip integration
- Android screen-capture protection where appropriate
- playback error handling
- risk-based playback QA

### Architecture Rules

M16 must reuse the existing M13 session-based protected media architecture.

Do not create a parallel protected media endpoint without an explicit architectural requirement.

The backend remains authoritative for:

- authorization
- playback sessions
- progress
- anti-skip behavior
- completion

V1 remains streaming-oriented and does not provide unrestricted media downloads.

Published media remains immutable.

---

# M17 - Assessment + Certificates

### Status

**Planned**

Planned work:

- mobile assessment UI
- question rendering
- answer selection
- attempt handling
- retry handling
- server-authoritative scoring
- pass/fail results
- completion state
- certificate access
- certificate display
- version-aware certificate handling

---

# M18 - Notifications + Resilience

### Status

**Planned**

Planned work:

- notifications
- session resilience
- authentication recovery
- network recovery
- retry behavior
- lifecycle reliability
- API error recovery
- operational observability
- health checks

---

# M19 - Android Release Candidate

### Status

**Planned**

Planned work:

- feature freeze
- Android regression
- backend regression
- API regression
- playback regression
- assessment regression
- certificate regression
- security review
- permission review
- IDOR review
- real-device testing
- performance review
- network testing
- lifecycle testing
- pilot testing
- release-candidate build

---

# M20 - Production + Deployment Hardening

### Status

**Planned**

Planned work:

- production configuration
- secrets/environment management
- database configuration
- production media/storage readiness
- backup verification
- restore verification
- deployment procedure
- rollback procedure
- health checks
- monitoring
- logging
- production smoke testing
- Android release configuration
- build/version management
- CI/CD reliability

---

# M21 - Final Bug Hunt + Security + Repository Review

### Status

**Planned**

Planned work:

- final functional bug hunt
- authentication review
- authorization review
- IDOR review
- protected media review
- session security review
- input validation review
- upload validation review
- audit review
- dependency review
- secret scan
- repository cleanup
- temporary/debug artifact review
- documentation consistency review

Only genuine defects and justified maintainability issues should be addressed.

---

# M22 - Readability + Refactor + Garden's Need Visual Polish

### Status

**Planned**

### Readability

- targeted readability improvements
- removal of unnecessary duplication
- improved naming
- removal of obsolete code
- targeted refactoring
- maintainability improvements

### Visual Polish

The final Garden's Need visual direction is intentionally reserved for M22.

Planned areas include:

- typography
- colors
- spacing
- navigation
- dashboards
- cards
- progress indicators
- loading states
- empty states
- error states
- animations
- transitions
- micro-interactions
- accessibility
- responsive refinement
- Garden's Need visual identity

The visual direction should be reviewed before broad implementation.

---

# M23 - Final Acceptance + Android V1 Release

### Status

**Planned**

Final work:

- final acceptance testing
- final backend regression
- final API regression
- final Android regression
- final playback validation
- final assessment validation
- final certificate validation
- final security validation
- final device testing
- final performance verification
- final UX review
- production verification
- release build verification
- release signing verification
- production deployment
- post-release smoke testing
- documentation finalization
- Android V1 sign-off

---

# Versioning Rules

The V1 training lifecycle is:

```text
Draft → Published → Retired
```

Published training versions are immutable.

Assignments remain pinned to their assigned version.

New assignments use the latest applicable published version.

Retired versions cannot receive new assignments, but existing assignments may continue where permitted.

Assessments and answer keys remain frozen with their applicable training version.

Certificates reference the version earned by the employee.

Published media is immutable.

Replacing published media requires a new training version.

---

# Release Philosophy

The project should progress sequentially through the roadmap.

A milestone is not complete merely because its code exists.

A milestone should be marked complete only after:

- implementation is complete
- appropriate tests pass
- security-sensitive behavior is reviewed
- runtime/device QA is complete where applicable
- no critical/blocking defect remains
- documentation is current
- CI is passing
- the repository checkpoint is stable

The next milestone should not begin prematurely simply because future work has already been documented.