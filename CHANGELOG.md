# Changelog

All meaningful changes to the Garden's Need Training Module Application are recorded here.

The project has not yet reached its first production release.

## [Unreleased]

### Current Development Status

- Core backend implementation completed.
- Current automated test baseline: **189 full tests passing on MySQL**.
- Current milestone: **Milestone 11 - Documentation + Project Structure + CI**.
- Frontend completion, E2E testing, deployment hardening, final security review, readability cleanup, and visual polish remain before V1 release.

---

## Backend Foundation

### Added

- Django 5.2 LTS project structure.
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

## Authentication and Organization

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

## Training Content and Versioning

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

## Training Assignments

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

## Video Progress and Anti-Skip

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

## Assessments and Scoring

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

## Certificates

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

## Dashboards and Reports

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

## Audit Logging and Backend Hardening

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

## Backend Cleanup

### Changed

- Removed verified unused imports.
- Removed unnecessary pass-through helper.
- Removed obsolete dependency wrapper.
- Removed unused dependency entries.
- Simplified selected backend code without changing behavior.

### Notes

- Large readability refactoring intentionally deferred until the final readability milestone.

---

## Security Hardening

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

## Interim Backend Bug Hunt

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

Automated backend baseline increased from:

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

## Planned for V1

### Milestone 11

- Documentation.
- Project structure documentation.
- GitHub Actions CI.

### Milestone 12

- Functional frontend completion.

### Milestone 13

- Responsive UX.
- Accessibility.
- Frontend usability improvements.

### Milestone 14

- Full Playwright E2E and integration testing.

### Milestone 15

- Production and deployment hardening.

### Milestone 16

- Final bug hunt.
- Final security review.
- Dependency review.
- Repository review.

### Milestone 17

- Final readability and refactor pass.

### Milestone 18

- Premium Garden's Need visual polish.

### Milestone 19

- Final acceptance testing.
- V1 release.