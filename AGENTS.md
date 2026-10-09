# AGENTS.md

This file defines the standing development rules for coding agents and contributors working on the Garden's Need Training Module Application.

These rules apply unless a task explicitly overrides them.

## Project Context

The Garden's Need Training Module Application is an internal employee training, assessment, certification, reporting, and workforce development platform.

The project currently contains:

- Django backend
- MySQL 8
- Django templates
- HTML/CSS/JavaScript
- REST API under `/api/v1/`
- Flutter Android application under `mobile/`
- Existing browser playback functionality
- Session-based protected video media
- Automated backend, Flutter, and JavaScript validation

The backend is authoritative for security-sensitive state and business rules.

Current major state:

- M0-M12: complete
- M13: Mobile API Foundation + Versioning, complete
- M14: Flutter / Android Foundation, complete
- M15: Employee App Core, complete
- M16: Learning + Secure Video, next
- M17-M23: planned

Current validation baseline:

- Django/MySQL: 348 tests
- Flutter: 81 tests
- JavaScript playback: 3 tests

Do not assume these numbers remain unchanged after future work. Use the current repository output as authoritative.

## Agent Operating Rules

Before editing:

1. Inspect the relevant existing implementation.
2. Inspect nearby tests.
3. Inspect existing helpers, models, services, API patterns, and permission rules.
4. Understand current behavior before proposing replacement behavior.
5. State a brief implementation plan.
6. Identify the expected files to change.

Use the existing architecture unless there is a demonstrated reason to change it.

Do not:

- perform unrelated refactoring
- introduce speculative abstractions
- rebuild working systems unnecessarily
- duplicate backend business rules in the mobile client
- modify unrelated configuration
- create parallel implementations of existing functionality
- silently change established business rules

Keep changes narrow, reviewable, and reversible where practical.

## Git and Review Workflow

Coding agents must not commit or push unless explicitly instructed.

The normal workflow is:

1. Inspect
2. Implement
3. Validate
4. Run CodeRabbit review
5. Fix confirmed findings when necessary
6. Re-run relevant validation
7. Confirm CodeRabbit is clear
8. Inspect the final diff
9. User commits
10. User pushes

Never reset, discard, or overwrite unrelated user work.

Do not create commits merely because a milestone is complete.

Do not provide instructions pretending that CodeRabbit is a prompt-driven coding agent. CodeRabbit findings should be treated as review findings and addressed by the implementation agent when appropriate.

## Core Development Principles

Follow these principles for every change:

- inspect the existing codebase before editing
- understand the current implementation before proposing replacements
- prefer the simplest correct implementation
- reuse existing models, serializers, repositories, services, helpers, permissions, and patterns
- use existing dependencies before adding new ones
- avoid unnecessary architectural changes
- avoid unrelated refactoring
- preserve existing behavior unless the task explicitly requires a change
- preserve historical data
- keep code readable and maintainable
- make narrow, reviewable changes

## Security Rules

Security-sensitive decisions must be enforced on the backend.

Never rely only on:

- hidden buttons
- disabled form fields
- JavaScript state
- URL structure
- browser-supplied ownership
- browser-supplied progress
- browser-supplied scores
- browser-supplied completion state

The backend must determine or validate:

- user permissions
- employee ownership
- reporting hierarchy
- manager scope
- training assignment ownership
- parent-child relationships
- training completion
- assessment scores
- certificate eligibility
- progress state
- playback authorization
- media access

## Authorization

Always preserve the application's role and scope model.

Important roles include:

- Administrator
- Training Coordinator
- Manager
- Trainer
- Supervisor
- Employee

Authorization must be enforced at the appropriate backend layer.

Direct URL or API access must never bypass permission checks.

Manager access must remain restricted to the authorized reporting hierarchy.

Employee access must remain restricted to the employee's permitted records.

Do not broaden access through:

- query parameters
- filters
- forms
- crafted URLs
- API payloads
- client-controlled identifiers

## Input Validation

Treat all client input as untrusted.

Validate:

- identifiers
- dates
- numeric values
- text fields
- state transitions
- ownership
- parent relationships
- uploaded metadata
- media identifiers
- session identifiers
- assessment data
- playback data

Malformed input should produce an appropriate controlled response such as:

- form validation error
- HTTP 400
- HTTP 403
- HTTP 404
- HTTP 409

Malformed user input should not normally result in HTTP 500.

## State-Changing Actions

Use POST or another appropriate state-changing HTTP method for mutations.

Do not use GET for:

- deactivation
- publishing
- retirement
- revocation
- assignment creation
- completion
- destructive actions
- other state-changing operations

Maintain CSRF protection where applicable.

## Database Safety

Use transactions where multiple related writes must succeed or fail together.

Use locking or database constraints when concurrency can affect correctness.

Examples include:

- employee state changes
- assignment creation
- assessment attempts
- progress updates
- certificate issuance
- lifecycle transitions

When handling uniqueness or race conditions:

1. reproduce the failure
2. identify the exact conflict
3. handle the expected conflict explicitly
4. do not suppress unrelated validation errors
5. preserve database integrity

Do not make destructive schema changes unless explicitly approved.

## Permission Migrations

Permission migrations must be:

- additive
- non-destructive
- safe to rerun through Django migrations

Use existing Django permission APIs where possible.

Do not:

- delete unrelated permissions
- remove groups
- clear permission sets
- create destructive reverse migrations

A safe no-op reverse migration is preferred when reversal would remove legitimate production permissions.

## Historical Data

Preserve historical records where the system depends on them.

Do not casually delete:

- employees
- assignments
- training versions
- certificates
- assessment history
- audit logs
- published media

Use deactivation, retirement, revocation, or historical snapshots where the architecture requires them.

## Audit Logging

Important state-changing operations should use the existing audit system when appropriate.

Audit records must use server-derived information.

Do not trust the client to supply:

- actor
- target
- timestamp
- authoritative event type

Do not log:

- passwords
- secrets
- tokens
- private credentials
- assessment answers
- complete training content unless explicitly required

Audit logging must not create misleading success events for failed or rolled-back operations.

Media access, playback session lifecycle, and other security-sensitive playback events should remain auditable.

## Training Versioning

The training hierarchy is:

```text
Training
└── Training Version
    └── Module
        └── Lesson
```

Training version lifecycle:

```text
DRAFT → PUBLISHED → RETIRED
```

Rules:

- Draft versions may be edited.
- Draft versions may be deleted when safe.
- Published versions are immutable.
- Retired versions remain historically available.
- Published versions cannot be deleted.
- Retired versions cannot receive new assignments.
- Existing assignments remain pinned to their assigned version.
- Existing learners may continue working on a retired version.
- New assignments use the latest published version.
- Assessment questions and answer keys are frozen with the assigned version.
- Certificates reference the version actually earned.

Do not silently redesign version lifecycle behavior.

If a published training version requires correction, determine the required new-version behavior rather than mutating the published version.

## Assignment Rules

Assignments may originate from:

- manual assignment
- role-based assignment

Always validate:

- active employee
- permitted training version
- duplicate assignment
- due date
- role scope
- manager scope

Assignments remain pinned to their assigned training version.

Do not automatically migrate employees to a newer version unless an explicit business rule is introduced and approved.

Handle concurrent assignment creation safely.

If a duplicate appears because another request created the same assignment after an initial lookup, only treat it as a duplicate when the exact expected assignment exists.

Do not hide unrelated validation failures.

## Video and Media Rules

V1 media is streaming-only.

Do not introduce media downloads unless explicitly approved.

Published media is immutable.

Replacing published media requires a new training version.

The existing M13 session-based protected media endpoint is the authoritative media access mechanism.

Do not create a parallel unrestricted media route when the existing session-based architecture can be reused.

Media access must remain authorized against:

- authenticated user
- assignment
- lesson
- training version
- playback session

Media upload validation must remain fail-closed.

Where applicable, validate:

- file size
- file type
- extension
- actual file content
- checksum

Storage must remain behind a suitable abstraction where practical so local storage can later be replaced by object storage without changing authorization rules.

Preferred V1 video format is MP4/H.264/AAC with HTTP range streaming.

Reuse the existing playback architecture and Flutter `video_player` unless a demonstrated requirement requires a different implementation.

Do not add a new playback library speculatively.

## Video Progress Rules

The backend controls video progress.

Do not trust the browser or mobile client to declare:

- watched duration
- completion
- valid coverage
- playback ownership
- session validity

Preserve:

- resume behavior
- watched ranges
- anti-skip logic
- idle-time protections
- session validation
- assignment scope
- lesson ownership

Do not weaken anti-skip protections for convenience.

Playback clients must send heartbeats frequently enough to satisfy the server's idle-gap rules.

The server remains authoritative for completion.

## Screen Capture

Android screen-capture protection should be applied where appropriate using platform-supported mechanisms such as `FLAG_SECURE`.

Do not claim that screen capture can be made impossible.

Do not introduce screen-capture behavior that breaks legitimate application functionality without validating the affected flows.

## Assessment Rules

Assessment scoring must remain server-side.

Never trust the client to supply:

- score
- pass/fail result
- attempt completion
- correct answers

Preserve:

- attempt limits
- prerequisites
- question revisions
- final assessment rules
- assignment completion logic

Assessment creation and submission must handle concurrency and duplicate state safely.

## Certificate Rules

Certificate issuance must be based on authoritative training completion.

Certificate issuance must remain idempotent.

Do not create duplicate certificates for the same authoritative completion.

Revocation must preserve the certificate record.

Employee access must remain restricted to permitted certificates.

Certificates must continue referencing the version actually earned.

## Reports and Dashboards

Report filters must never broaden user scope.

Manager filters must stay inside the manager's authorized employee hierarchy.

Employee users must not gain administrative reporting access.

Derived values such as overdue state and completion percentage must be calculated from trusted backend data.

## Mobile Architecture

The V1 mobile application is Android-first.

Current mobile stack:

- Flutter
- Dart
- Android
- Riverpod
- GoRouter
- Dio
- secure token storage
- REST API

The Flutter application consumes backend-authoritative state.

The mobile application must not duplicate or replace backend:

- authorization
- scoring
- playback validation
- completion rules
- versioning rules

Client-side controls improve usability, not security.

iOS is deferred until Android V1 is stable and released unless explicitly brought forward.

## Offline Rules

Offline behavior must not create unauthorized authoritative completion.

V1 does not support unrestricted offline course completion.

The server remains authoritative for:

- completion
- progress
- assessment results
- certificates
- assignment state

Do not introduce local-only completion claims that can later overwrite authoritative server state without an explicit synchronization design.

## UI Direction

The final Garden's Need visual system is intentionally not locked during the current functional milestones.

Do not prematurely hard-code a final:

- color palette
- animation system
- visual identity
- typography system
- interaction language

The mobile application should remain clean, usable, and consistent during M14-M21.

Major Garden's Need visual polish, animation, and interaction refinement belong to the dedicated M22 readability/refactor/visual-polish milestone.

When M22 begins, UI/UX direction should be reviewed deliberately before implementation.

Functionality and correctness take priority over decorative polish during earlier milestones.

## Testing Rules

For every meaningful change:

1. reproduce the issue when fixing a bug
2. write or update a focused test
3. make the smallest correct fix
4. run affected tests
5. run broader tests when appropriate
6. run the full relevant suite before milestone completion

Confirmed bugs should receive regression tests whenever practical.

Do not switch backend testing to SQLite for convenience.

The primary backend validation database is MySQL.

Flutter validation should include:

- `flutter analyze`
- focused Flutter tests
- full Flutter tests when appropriate
- debug APK build for milestone-level Android work

Existing JavaScript playback tests must continue to pass when playback-related backend or frontend behavior changes.

Important verification commands include:

```powershell
python manage.py test
python manage.py check
python manage.py makemigrations --check --dry-run
python -m pip check
git diff --check
```

For mobile work, use the repository's Flutter commands and validate the Android build where appropriate.

## Risk-Based Testing

Testing effort should match the risk of the change.

### Low risk

Examples:

- copy changes
- isolated UI layout changes
- documentation changes

Use focused validation.

### Medium risk

Examples:

- API behavior
- Flutter navigation
- repository changes
- assignment or lesson state
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
- lifecycle/versioning
- security-sensitive database changes

Use focused tests, broader regression coverage, negative testing, and the relevant full suite.

Do not add large numbers of redundant tests merely to increase test count.

## Negative Testing

Important security and behavior tests should include negative cases where relevant.

Examples:

- unauthorized access
- direct URL access
- malformed IDs
- duplicate requests
- repeated state transitions
- invalid parent relationships
- ownership violations
- permission boundary violations
- race conditions
- malformed payloads
- empty results
- exact time boundaries
- exact score boundaries
- invalid playback sessions
- invalid media access
- retired-version restrictions

## Bug-Fix Workflow

When fixing a defect:

1. reproduce it
2. identify the narrow root cause
3. add a regression test
4. implement the smallest correct fix
5. run focused tests
6. run relevant broader tests
7. run the full MySQL suite before final completion when appropriate

Do not refactor large areas merely because a bug was found nearby.

## API Rules

The existing M13 API foundation should be reused.

Important existing API areas include:

```text
/api/v1/auth/
/api/v1/dashboard/
/api/v1/assignments/
/api/v1/assignments/<id>/lessons/<id>/complete/
/api/v1/assignments/<id>/lessons/<id>/progress/
/api/v1/assignments/<id>/lessons/<id>/sessions/
/api/v1/assignments/<id>/lessons/<id>/sessions/<id>/end/
/api/v1/assignments/<id>/lessons/<id>/sessions/<id>/media/
```

Do not create duplicate endpoints when an existing endpoint already provides the required behavior.

Extend existing API patterns consistently.

Keep API authorization and business rules server-side.

## Browser and E2E Testing

Playwright remains part of the browser/integration validation strategy.

Do not consider browser-facing work complete based only on template rendering.

Important browser flows include:

- login
- role dashboards
- training assignment
- lesson progression
- video playback
- assessment attempts
- training completion
- certificates
- reporting
- unauthorized access
- direct URL protection

Browser tests should be added or updated when a change materially affects these flows.

## Environment and Secrets

Never commit:

- `.env`
- database passwords
- secret keys
- API keys
- access tokens
- private credentials

Production must fail closed when required security configuration is missing.

Do not change unrelated environment settings while implementing feature work.

Do not modify Git configuration unless explicitly requested.

## Dependencies

Do not add a dependency unless:

- the existing stack cannot reasonably solve the problem
- the dependency provides clear value
- the security and maintenance cost is justified

Prefer:

- Django built-ins
- Python standard library
- existing project dependencies
- existing Flutter packages

before adding packages.

## Code Readability

Prefer readable code over compressed one-liners.

Use:

- descriptive names
- small focused functions
- clear control flow
- explicit validation
- straightforward conditions

Do not create abstractions merely to reduce line count.

Deep readability refactoring is intentionally planned for M22.

Until then, make local readability improvements only when they directly support the current task.

## Documentation Rules

`docs/ROADMAP.md` is the canonical roadmap.

Keep related documentation aligned with the canonical roadmap, including:

- `docs/TASKS.md`
- `CHANGELOG.md`
- `AGENTS.md`
- other milestone-specific documentation

Do not invent completed milestones or test counts.

Historical test counts should remain historically accurate.

Current validation counts should be based on actual repository output.

Documentation changes should not silently change implementation behavior.

## Production Rules

Production deployment must use:

```text
DEBUG=False
```

Production requires:

- strong secret key
- explicit allowed hosts
- HTTPS
- secure cookies
- appropriate HSTS
- correct static handling
- protected media handling
- database backups
- logging
- rollback planning

Do not weaken production defaults merely to simplify local development.

## Scope Control

Do not implement future features while working on V1 unless explicitly requested.

Future scope may include:

- skill matrix
- practical assessment
- supervisor verification
- machine certification
- QR verification
- multilingual support
- AI-assisted knowledge access
- additional native mobile features

Future scope must remain clearly separated from implemented V1 functionality.

## Current Roadmap

Current milestone:

```text
M16 - Learning + Secure Video
```

Remaining major milestones:

```text
M17 - Assessment + Certificates
M18 - Notifications + Resilience
M19 - Android Release Candidate
M20 - Production + Deployment Hardening
M21 - Final Bug Hunt + Security + Repository Review
M22 - Readability + Refactor + Garden's Need Visual Polish
M23 - Final Acceptance + Android V1 Release
```

Do not skip milestone scope without an explicit decision.

## M16 Rules

M16 should build on the existing M13-M15 foundation.

M16 must:

- integrate secure video playback into the existing learning flow
- reuse the existing session-based protected media endpoint
- preserve server-authoritative progress
- preserve anti-skip behavior
- preserve session validation
- handle playback errors safely
- support resume behavior
- apply appropriate Android screen-capture protection
- avoid unrestricted downloads
- avoid duplicating backend playback rules

M16 must not silently redesign:

- training version lifecycle
- assignment version pinning
- assessment architecture
- certificate architecture
- media authorization
- backend business rules

If an existing lifecycle or business rule is ambiguous, stop and resolve the ambiguity before implementing a conflicting rule.

## Final Rule

If a requested change conflicts with the existing security model, data integrity model, versioning model, media architecture, or documented roadmap, do not silently work around the conflict.

Identify the conflict and choose the safest narrow implementation that preserves the established system unless explicit approval is given to change the architecture.