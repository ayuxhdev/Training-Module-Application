# Project Memory

## 1. Purpose

This document stores durable technical decisions, important implementation lessons, significant bug history, security rationale, and architectural constraints for the Garden's Need Training Module Application.

This is not:

- a chat transcript
- a daily task log
- a place for secrets
- a substitute for source code
- a substitute for Git history

Use this file to preserve information that future developers and coding agents need in order to avoid repeating old mistakes.

---

## 2. Project Identity

Product:

```text
Garden's Need Training Module Application
```

Purpose:

```text
Internal employee training, assessment, certification, reporting, and workforce development.
```

Current architecture:

```text
Django web application
Django REST API
Flutter Android application
MySQL 8
Django templates
HTML
CSS
JavaScript
Protected training media
```

Current backend baseline:

```text
348 / 348 Django tests passing on MySQL
```

Current mobile baseline:

```text
81 / 81 Flutter tests passing
Flutter analyze: 0 issues
Android debug APK: successful
```

Current JavaScript playback baseline:

```text
3 / 3 playback tests passing
```

---

## 3. Current Milestone State

Completed:

```text
M0-M12: complete
M13: Mobile API Foundation & Versioning: complete
M14: Flutter / Android Foundation: complete
M15: Employee App Core: complete
```

Next:

```text
M16: Learning + Secure Video
```

Planned:

```text
M17: Assessment + Certificates
M18: Notifications + Resilience
M19: Android Release Candidate
M20: Production + Deployment Hardening
M21: Final Bug Hunt + Security + Repository Review
M22: Readability + Refactor + Garden's Need Visual Polish
M23: Final Acceptance + Android V1 Release
```

`docs/ROADMAP.md` is the canonical roadmap.

Do not reintroduce the old M11-M18 milestone structure from historical documentation.

---

## 4. Backend Authority Rule

The backend is authoritative for security-sensitive state.

Never trust the browser or mobile client for:

- permissions
- ownership
- Manager scope
- employee identity
- training progress
- assessment score
- pass/fail result
- completion
- certificate eligibility
- parent relationships

Client-side controls improve usability only.

They do not replace backend authorization or validation.

---

## 5. Role Model

Current role groups include:

```text
Administrator
Training Coordinator
Manager
Trainer
Supervisor
Employee
```

Role names alone are not the complete authorization model.

Security decisions must use the actual:

- permissions
- ownership
- reporting scope
- object state
- assignment state

---

## 6. Manager Scope

Managers are restricted to their recursive reporting subtree.

The correct authorization pattern is:

```text
Start with authorized Manager scope
-> apply optional filters inside that scope
```

Never:

```text
start from all employees
-> apply user-selected filters
-> attempt scope validation afterward
```

Filters must never broaden authorization.

This rule applies to dashboards, reports, APIs, and direct object access.

---

## 7. Employee Scope

Employees generally operate only on their own records.

Where possible:

```text
request.user
-> Employee
-> owned objects
```

Do not trust arbitrary employee IDs supplied by the client when ownership can be derived from the authenticated user.

---

## 8. Training Version Lifecycle

Training versions follow:

```text
DRAFT
PUBLISHED
RETIRED
```

Published training versions are immutable.

Retired training versions remain immutable.

Draft versions may be edited and may be deleted where permitted.

Anything that has been published must not be deleted.

---

## 9. Assignment Version Pinning

Assignments are pinned to the training version assigned to the employee.

Rules:

- existing assignments remain on their assigned version
- new assignments use the latest published version
- employees are not automatically migrated to newer versions
- retired versions cannot receive new assignments
- existing assignments may continue against a retired version

Do not silently migrate employees to a newer version.

---

## 10. Published Assessment and Certificate History

Published assessment structure and answer keys are frozen with the training version.

Historical attempts must continue to reference the version and question revisions that were actually used.

Certificates reference the earned training version.

Certificate revocation does not modify the underlying training version or historical certificate record.

---

## 11. Version Correction Policy

A corrected published training version requires a new version.

Do not edit published media or published learning content in place.

A separate business decision may be required if a safety-critical correction means employees who completed an older version must retrain.

Do not invent automatic retraining behavior during implementation.

---

## 12. Media Immutability

Published media is immutable.

Replacing published media requires a new training version.

V1 media is streaming-only.

No unrestricted client-side downloads are part of the V1 requirement.

---

## 13. Media Architecture

M13 introduced the protected session-based media architecture.

The existing route is authoritative:

```text
assignments/<assignment_id>/lessons/<lesson_id>/sessions/<session_id>/media/
```

The route must remain tied to:

- authenticated employee
- authorized assignment
- exact lesson
- valid playback session

Do not create a parallel unrestricted media route.

Media access, playback session activity, and completion should remain auditable.

Storage should remain behind an abstraction so local storage can later move to protected object storage without changing authorization rules.

---

## 14. Media Upload Validation

Training media upload validation should fail closed.

Current validation direction includes:

- permitted video formats
- maximum size
- extension sanity checks
- actual file signature/magic-byte validation
- controlled validation failures

Do not rely only on a filename extension or client-supplied MIME type.

Do not silently accept files when validation encounters an unexpected read or parsing failure.

The same video checksum may be reused where the product permits it. Do not introduce a global checksum uniqueness rule without an explicit business requirement.

---

## 15. Video Progress Authority

Video completion is server-authoritative.

The client sends playback observations.

The server decides:

- valid watched ranges
- valid progression
- completion
- allowable playback tolerance

Never trust:

```text
completed = true
```

from a client as an authoritative completion decision.

---

## 16. Video Idle-Time Security

A serious playback vulnerability previously allowed idle time between requests to become valid playback credit.

The fix rejects excessive idle gaps and prevents inactive time from replenishing playback allowance.

Cross-session state also matters.

Creating repeated playback sessions must not regenerate unlimited progression tolerance.

Do not weaken this security behavior merely to simplify mobile heartbeat logic.

The Flutter client should send heartbeats comfortably within the server's idle boundary.

---

## 17. Playback Metadata

Session and device metadata must remain bounded and controlled strings.

Do not blindly stringify:

- arrays
- objects
- arbitrary structured payloads

Malformed playback metadata must result in controlled client errors rather than uncontrolled server failures.

---

## 18. Assessment Authority

Assessment scoring remains server-side.

The client must never decide:

- correct answer
- score
- pass
- fail
- authoritative completion

The backend calculates results using stored question revisions and answer data.

---

## 19. Question Revision History

Question revisions preserve historical assessment meaning.

An old assessment attempt must not silently change because the current Question was edited later.

Do not replace revision-based historical behavior with mutable direct Question references without redesigning the assessment history model.

---

## 20. Certificate Issuance

Certificate issuance is authoritative and idempotent.

Repeated completion processing must not create duplicate certificates.

A revoked certificate remains a historical record.

Preserve:

- certificate identifier
- issue information
- earned version
- historical snapshot
- revocation state

---

## 21. Audit Architecture

Audit events use server-derived:

- actor
- target
- timestamp
- event type

The client must never become authoritative for these values.

Important success events should be recorded only after the associated business transaction succeeds.

Transaction commit hooks may be used where appropriate.

Audit-write failures are intentionally handled separately from already-successful business transactions. Do not change this tradeoff without considering both business integrity and audit guarantees.

Do not store unnecessary sensitive data in audit metadata.

Never store:

- passwords
- authentication tokens
- secrets
- unnecessary assessment answers
- unnecessary private information

Backend terminology:

```text
actor
```

User-facing terminology:

```text
Performed By
```

---

## 22. Historical Data Principle

The application preserves historical facts.

Important examples include:

- training versions
- question revisions
- assignment snapshots
- assessment attempts
- certificates
- audit records

Prefer:

- versioning
- deactivation
- retirement
- revocation
- snapshots

over destructive deletion.

---

## 23. Concurrency Strategy

Use combinations of:

```text
transaction.atomic
select_for_update
database uniqueness
validation
specific conflict handling
```

when correctness depends on concurrent state.

Do not add locking automatically everywhere.

Locking is especially important where races affect:

- security
- data integrity
- idempotency
- lifecycle state
- playback state

Maintain consistent lock ordering.

Video progress historically required parent-first locking corrections. Do not casually change established lock ordering.

---

## 24. Important Concurrency Lessons

### Employee deactivation

Repeated deactivation previously:

- returned success again
- overwrote the original reason
- created another success audit event

Current behavior:

- locks the Employee row
- detects the already-inactive state
- returns HTTP 409
- preserves the original history

Do not reintroduce repeated-success behavior.

### Assignment timestamps

`due_in_days = 0` previously produced timestamp ordering problems.

Use one authoritative timestamp when calculating related persisted timestamps.

### Role assignment race

Do not broadly suppress `ValidationError` or `IntegrityError`.

When a uniqueness race occurs:

- identify the actual conflict
- verify the expected Employee/TrainingVersion assignment
- treat only the legitimate duplicate as a skipped assignment
- allow unrelated errors to surface

### Due-period overflow

Model-valid integers can still exceed Python's datetime range.

Validate date arithmetic before creating assignments.

### Training creation race

A save-time uniqueness conflict may occur after form validation.

Expected conflicts should become controlled form errors.

Do not record a success audit event when the save failed.

### Question creation race

Dependent revision creation must stop if the parent Question save fails.

---

## 25. Security Configuration

Production security defaults include:

```text
DEBUG = False
```

Production must provide an explicit:

```text
DJANGO_SECRET_KEY
```

There must be no committed fallback production secret.

When DEBUG is disabled, secure cookies must remain enabled.

Do not weaken secure-cookie behavior to compensate for incorrect HTTPS deployment.

Final HSTS, proxy, and HTTPS settings must be verified against the actual hosting architecture.

---

## 26. Browser Capture Boundary

A browser cannot guarantee prevention of:

- screenshots
- OS-level screen recording
- external camera recording

Web protections can reduce casual misuse but cannot provide absolute prevention.

Android-specific capture protection may be implemented where appropriate, including `FLAG_SECURE`, but this does not guarantee prevention of every form of capture.

---

## 27. Mobile Architecture

The current mobile client is:

```text
Flutter
Android-first
```

Backend business rules remain authoritative.

Flutter should not duplicate:

- authorization rules
- completion rules
- scoring rules
- versioning rules
- playback security rules

The mobile client consumes the existing M13 API foundation.

iOS is deferred until Android is stable and released.

---

## 28. Flutter Testing Baseline

Current Flutter baseline:

```text
81 / 81 tests passing
flutter analyze: 0 issues
debug APK: successful
```

The mobile test suite should grow only where behavior warrants meaningful regression protection.

Avoid writing large numbers of low-value tests solely to increase coverage.

---

## 29. JavaScript Playback Baseline

Current JavaScript playback tests:

```text
3 / 3 passing
```

These remain part of the validation baseline because the existing Django web learner playback implementation is still supported.

---

## 30. Dependency Philosophy

Prefer:

1. Django built-ins
2. Python standard library
3. existing project packages
4. new dependencies only when justified

Every new package introduces maintenance, compatibility, and security considerations.

Do not add dependencies merely to save a small amount of code.

---

## 31. Testing Philosophy

Confirmed defects should receive regression coverage whenever practical.

Preferred process:

```text
Reproduce
-> Write failing test
-> Narrow fix
-> Focused tests
-> Broader tests
-> Full MySQL suite
-> Required project checks
```

Use risk-based testing.

High-risk security, playback, authorization, concurrency, and data-integrity changes deserve stronger validation than cosmetic or low-risk changes.

---

## 32. Current Verification Baseline

Current known passing baseline:

```text
Django/MySQL: 348 / 348
Flutter: 81 / 81
Flutter analyze: 0 issues
JavaScript playback: 3 / 3
```

Also verified during recent M16 preparation:

```text
manage.py check: passing
migration drift check: clean
pip check: clean
git diff --check: clean
Android debug APK: successful
```

Do not replace these current counts with historical counts from old documentation.

---

## 33. Verification Commands

Backend:

```powershell
python manage.py test
python manage.py check
python manage.py makemigrations --check --dry-run
python -m pip check
git diff --check
```

Review repository state:

```powershell
git status --short
```

Flutter:

```powershell
flutter analyze
flutter test
```

JavaScript playback tests should also be run when playback-related code changes.

---

## 34. CI

CI now covers the project's major automated validation surfaces.

The CI direction includes:

```text
Django/MySQL tests
Django checks
migration consistency
pip check
Flutter analyze
Flutter tests
JavaScript playback tests
```

CI should use disposable credentials.

Real production or development secrets must never be committed into workflow files.

GitHub Actions setup should use maintained action versions.

The Flutter CI version must remain compatible with the Dart SDK required by `mobile/pubspec.yaml`.

---

## 35. Documentation Rule

When documentation and code disagree:

```text
Inspect the current implementation.
```

Do not modify production behavior merely to satisfy stale documentation.

Update documentation when implementation intentionally changes.

`docs/ROADMAP.md` is the canonical milestone roadmap.

---

## 36. Agent Workflow

Implementation agents must:

- inspect existing code before changing it
- preserve established architecture
- avoid unrelated refactors
- avoid unnecessary migrations
- validate their changes
- report failures honestly

Agents must not commit or push unless explicitly instructed.

Preferred workflow:

```text
Implement
-> Validate
-> CodeRabbit review
-> Fix legitimate findings
-> Revalidate
-> Inspect staged diff
-> Commit
-> Push
```

CodeRabbit is a review system, not an implementation agent.

---

## 37. UI and Product Design Timing

The mobile app's current M14-M15 UI is functional foundation work.

The final Garden's Need visual identity is intentionally not locked yet.

The eventual product should be:

- polished
- animated where useful
- beautiful
- interactive
- professional
- aligned with Garden's Need branding

Final visual direction belongs primarily to M22.

Do not prematurely rebuild functional screens merely to impose final visual styling.

---

## 38. Offline Boundary

V1 does not support authoritative offline course completion.

The server remains authoritative for:

- playback progress
- completion
- assessments
- certificates

Offline caching may improve resilience and usability where safe, but it must not create an alternate authoritative completion path.

---

## 39. Release Architecture

V1 is Android-first.

Before release:

- Android identity must remain correct
- production configuration must be verified
- protected media must be verified
- backend and mobile integration must be tested
- release candidate validation must pass
- final security and repository review must pass

---

## 40. Future Scope

Potential future capabilities include:

- notifications
- practical assessments
- supervisor verification
- skill matrices
- machine certifications
- QR verification
- multilingual content
- AI knowledge assistant
- RAG over internal factory knowledge
- stronger mobile capture controls
- iOS client

These are not assumed to be implemented V1 features.

---

## 41. Memory Maintenance Rule

Add information only when it is likely to matter later.

Good candidates:

- architecture decisions
- security decisions
- difficult bugs
- concurrency lessons
- migration decisions
- unusual deployment constraints
- reasons for rejecting major alternatives

Do not add:

- daily progress
- trivial edits
- temporary thoughts
- copied chat history
- secrets
- passwords
- tokens

When an old decision is superseded, update or remove it rather than accumulating contradictory instructions.

---

## 42. Current Project State

Current state:

```text
M0-M12: complete
M13: complete
M14: complete
M15: complete
M16: next
M17-M23: planned
```

Current validation:

```text
Django/MySQL: 348 / 348
Flutter: 81 / 81
Flutter analyze: 0 issues
JavaScript playback: 3 / 3
```

Current architectural direction:

```text
Django web
+
Django REST API
+
Flutter Android
+
MySQL
+
protected session-based training media
```

Immediate next development milestone:

```text
M16 - Learning + Secure Video
```

M16 must build on the existing M13 API and media architecture rather than introducing duplicate backend rules or parallel media endpoints.