# Tasks and Roadmap

## 1. Purpose

This document tracks repository-level development tasks, milestone work, validation requirements, and release gates for the Garden's Need Training Module Application.

`docs/ROADMAP.md` is the canonical milestone roadmap.

This file provides the practical task-level view of that roadmap.

The Excel roadmap may remain the management tracker, but it must not override the repository's actual implementation state.

---

## 2. Current Status

### Approved multi-role Android expansion

Android scope now includes Administrator, Manager and Employee business workflows
from the custom Django portal. The employee-only assumption in historical entries
is superseded, not a reason to rewrite their milestone names or QA evidence.
Framework `/admin/` User/Group/password/token administration remains excluded.

Batch 1 is implemented locally: effective capability discovery, management-only
login, optional Employee context, protected personal navigation/providers and
Team/Management account-access overviews. Batch 2 is also implemented locally:
read-only company/team dashboards, employee directory/detail and Department/Job
Role reference lists, with authenticated APIs and native Flutter navigation.
Management mutations remain future work. Manager reporting hierarchy, existing permissions,
personal learning security and appearance persistence remain unchanged.

Historical Batch 1 validation: **234/234 Django/API and role-scoping tests on isolated
MySQL**, **72/72 focused Flutter tests**, **518/518 full Flutter tests**; Flutter
analyzer and Django system/migration checks passed. The isolated MySQL schema was
removed. No persistent QA data was modified. Android runtime verification remains
pending; this batch is not committed and no CI result is claimed.

Subsequent Batch 1–2 checkpoints passed **170/170 selected Django/MySQL tests**
(including **18/18 management API tests**) and **551/551 full Flutter tests**,
with clean Flutter analysis. The dedicated MySQL test database was retained and
its role bootstrap verified. These separate checkpoints do not represent a full
Django-suite run or CI. Android login/role runtime QA remains pending: the new APK
was built and installed, but emulator system responsiveness and host memory
blocked verification. Both batches remain uncommitted.

The final combined web/mobile regression gate is separate from these implementation
checkpoints and remains pending; they do not establish release readiness.

The approved nine-batch sequence is recorded in `docs/ROADMAP.md`. Batches 3-9
remain planned and require separate authorization before implementation.

Current milestone:

```text
M19 - Android Release Candidate (IN PROGRESS; core integration checkpoint passed)
```

Completed milestones:

```text
M0–M13 - Core Platform + Mobile API Foundation
M14    - Flutter / Android Foundation
M15    - Employee App Core
M16    - Learning + Secure Video
M17    - Assessment + Certificates (afdadb4; pushed/CI green per user confirmation)
M18    - Notifications + Resilience (88a4cda; pushed/CI green per user confirmation)
```

Current application state:

```text
Backend/Web platform: Complete
Mobile API foundation: Complete
Flutter/Android foundation: Complete
Employee learning foundation: Complete
Secure video learning and read-only replay: Complete
Assessment and certificate APIs: Implemented and foundation-verified
Flutter assessments and certificates: Data/state, screens and navigation implemented
App-level Light/Dark themes: Implemented; follow system preference
Android M17 QA: Core flows passed; revoked-certificate case blocked by missing fixture
```

Historical M15 automated baseline (retained for reference):

```text
Django/MySQL: 348 tests passing
Flutter: 81 tests passing
JavaScript playback tests: 3 tests passing
```

Checks recorded with that historical baseline include:

```text
Django check: passing
Migration consistency: passing
pip check: passing
git diff --check: passing
Flutter analyze: passing
Android debug APK build: passing
GitHub Actions CI: passing
```

The application remains pre-release.

---

# 3. Milestone Overview

```text
M0–M12 - Core Django Training Platform       COMPLETE
M13    - Mobile API Foundation & Versioning   COMPLETE
M14    - Flutter / Android Foundation         COMPLETE
M15    - Employee App Core                    COMPLETE
M16    - Learning + Secure Video              COMPLETE
M17    - Assessment + Certificates             COMPLETE
M18    - Notifications + Resilience            COMPLETE
M19    - Android Release Candidate             IN PROGRESS
M20    - Production + Deployment Hardening     PLANNED
M21    - Final Bug Hunt + Security Review      PLANNED
M22    - Readability + Refactor + Visual Polish PLANNED
M23    - Final Acceptance + Android V1 Release PLANNED
```

---

# 4. Completed Foundation: M0–M12

Milestones M0 through M12 established the core Django/web platform.

Completed areas include:

- project foundation
- authentication
- organization structure
- roles and permissions
- employees
- reporting hierarchy
- training content
- training versions
- training assignments
- video progress
- playback sessions
- anti-skip logic
- assessments
- scoring
- certificates
- dashboards
- reports
- audit logging
- backend hardening
- security hardening
- functional web workflows
- backend regression coverage

These milestones are historical and should not be reopened unless a genuine regression or release-blocking defect is discovered.

---

# 5. M13 - Mobile API Foundation & Versioning

Status:

```text
COMPLETE
```

## Completed

- `/api/v1/` API foundation
- API versioning
- JWT authentication
- token refresh
- logout
- authenticated employee profile
- dashboard API
- assignment APIs
- assignment detail APIs
- lesson completion API
- learning progress API
- playback session creation
- playback progress
- playback session ending
- protected session-based media access
- employee ownership enforcement
- permission enforcement
- API error handling
- API regression tests

## Validation

```text
Django/MySQL suite: 348 passing
Django check: passing
Migration check: passing
pip check: passing
git diff --check: passing
GitHub Actions CI: passing
```

M13 is complete.

---

# 6. M14 - Flutter / Android Foundation

Status:

```text
COMPLETE
```

## Completed

### Android Foundation

- Flutter Android project
- Android application configuration
- package identity cleanup
- feature-based project structure
- Android build configuration
- environment configuration

### Networking

- Dio API client
- API configuration
- API error handling
- authentication interceptor
- bearer-token handling
- secure token storage

### Authentication

- employee-code login
- JWT access/refresh storage
- session restoration
- `/auth/me`
- logout
- Riverpod authentication state
- GoRouter authentication guards
- startup restoration
- authentication error handling

### Application Shell

- application shell
- dashboard route
- learning route
- profile route
- login route
- navigation
- authentication loading state
- authentication error state

### Base UI

- reusable cards
- text fields
- buttons
- badges
- loading states
- error states
- empty states
- theme foundation
- typography foundation
- spacing foundation
- color foundation

### Dashboard/Profile

- authenticated employee data
- dashboard API integration
- profile API integration
- loading states
- error states
- refresh behavior

## Validation

```text
Flutter tests: passing
Flutter analyze: passing
Android debug APK: passing
CodeRabbit review: clear
GitHub Actions CI: passing
```

M14 is complete.

---

# 7. M15 - Employee App Core

Status:

```text
COMPLETE
```

## Step 1 - Assignment List

Completed:

- assignment model
- learning repository
- assignment list provider
- real assignment API integration
- assignment status
- loading state
- empty state
- error state
- retry
- pull-to-refresh

## Step 2 - Assignment Detail

Completed:

- assignment detail
- assignment metadata
- training entry
- route integration
- malformed-ID handling
- API error handling

## Step 3 - Module + Lesson Navigation

Completed:

- module navigation
- lesson navigation
- curriculum traversal
- route integration
- training entry flow

## Step 4 - TEXT Lesson Completion

Completed:

- TEXT lesson screen
- completion API integration
- completion state
- navigation
- friendly unsupported handling for non-TEXT lessons

## Step 5 - Learning Progress

Completed:

- flattened lesson sequence
- previous lesson navigation
- next lesson navigation
- completion persistence
- navigation locking during completion
- stale async-result protection
- route identity reset
- assignment-detail invalidation
- friendly error handling

## Step 6 - Integration QA

Completed end-to-end flow:

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

## Final M15 Validation

```text
Flutter tests: 81 passing
Flutter analyze: passing
Android debug APK: successful
CodeRabbit review: clear
GitHub Actions CI: passing
```

M15 is complete.

---

# 8. M16 - Learning + Secure Video

Status:

```text
COMPLETE
```

Primary goal:

```text
Build the complete secure employee learning experience for VIDEO lessons.
```

M16 must build on the existing M13 playback architecture rather than creating a parallel implementation.

## 8.1 Pre-Implementation Verification

Before implementation:

- inspect existing M13 playback API contracts
- inspect session creation
- inspect protected media endpoint
- inspect heartbeat/progress behavior
- inspect session ending
- verify training-version pinning
- verify published-media immutability
- verify existing authorization rules
- verify existing anti-skip behavior
- verify Flutter video architecture
- verify Android package identity
- verify staging/test media requirements

Do not redesign already-correct backend behavior without a concrete defect.

## 8.2 Video Player Foundation

Planned:

- Flutter `video_player`
- authenticated protected media integration
- playback state
- loading state
- buffering state
- error state
- completion state
- playback controls appropriate for V1
- clean disposal of media resources

Prefer the existing playback stack unless actual requirements require a different library.

## 8.3 Playback Sessions

Integrate:

- session creation
- protected media access
- heartbeat
- progress synchronization
- session end
- server-authoritative completion

The mobile application must not independently decide authoritative completion.

## 8.4 Resume Behavior

Implement:

- resume from server-authoritative progress
- local UI synchronization
- recovery after navigation
- recovery after app lifecycle changes
- recovery after temporary network failure

## 8.5 Anti-Skip / Anti-Seek

The Flutter client must integrate with the existing backend rules.

Do not recreate backend anti-skip rules locally.

Test:

- forward seeking
- backward seeking
- rapid seeking
- repeated seeking
- buffering
- pause/resume
- app backgrounding
- network interruption
- session expiration

## 8.6 Network and Lifecycle Recovery

Handle:

- temporary network loss
- API timeout
- heartbeat failure
- app backgrounding
- app foregrounding
- route changes
- player disposal
- session expiration
- stale playback state

Failure behavior must be clear to the employee.

## 8.7 Screen Capture Protection

Where appropriate, Android `FLAG_SECURE` should be used for protected learning screens.

Do not claim that this makes media impossible to capture.

The goal is to apply the strongest practical Android protection available for V1.

## 8.8 Media Rules

Published media remains immutable.

V1 media remains streaming-oriented.

Do not add unrestricted media downloads.

Reuse the existing protected session-based media endpoint.

Do not create a second protected-media API merely for Flutter.

## 8.9 M16 Testing

Risk-based testing should include:

### Low risk

- normal playback
- pause/resume
- navigation
- completion
- normal progress synchronization

### Medium risk

- network interruption
- background/foreground
- buffering
- repeated pause/resume
- session recovery
- player disposal/recreation

### High risk

- rapid seeking
- anti-skip bypass attempts
- stale session use
- unauthorized media access
- cross-assignment media access
- heartbeat manipulation
- malformed identifiers
- expired sessions
- concurrent session behavior

## M16 Exit Criteria

```text
[ ] VIDEO lesson opens successfully
[ ] Protected media requires valid authorization
[ ] Playback session is created correctly
[ ] Media is streamed through the existing protected route
[ ] Heartbeats synchronize correctly
[ ] Progress is persisted correctly
[ ] Resume works
[ ] Session end works
[ ] Completion remains server-authoritative
[ ] Anti-seek/anti-skip behavior is preserved
[ ] Network interruption is handled
[ ] App lifecycle transitions are handled
[ ] Player resources are disposed correctly
[ ] Protected learning screens use appropriate Android security controls
[ ] Unauthorized media access is rejected
[ ] Cross-assignment media access is rejected
[ ] Focused tests pass
[ ] Full Flutter suite passes
[ ] Full Django/MySQL suite passes
[ ] Flutter analyze passes
[ ] Android debug build passes
[ ] CI passes
[ ] Code review is clear
```

---

# 9. M17 - Assessment + Certificates

Status:

```text
COMPLETE — committed at afdadb4; pushed/CI green per user confirmation
```

## Phase 1: secure mobile assessment API foundation

- Reuse shared web/API eligibility, start/resume and atomic submission operations.
- Add JWT/active-Employee overview, attempt start/resume, detail and submit endpoints.
- Enforce passed-assessment restart rejection on the website and API.
- Preserve pinned published/retired versions, prerequisites, frozen questions,
  deadlines, Decimal scoring, MySQL lock order, completion and certificate issuance.
- Cover ownership, malformed input, answer-key confidentiality, retries, deadlines,
  concurrent requests and exactly-once certificate issuance in isolated MySQL tests.
- Contracts documented in `docs/ARCHITECTURE.md`; backend/API foundation and
  subsequent Flutter integration are implemented.

Historical Phase 1 verification (MySQL 8.0.46): 25 assessment API tests, 55 assessment/web
regressions and 31 JWT tests passed (111 focused); 404/404 full Django tests passed.
Both new MySQL concurrency tests ran. Django check, migration-drift check, dependency
check and scoped whitespace checks passed. Models and migrations were unchanged.

## Completed M17 integration

- Read-only certificate list/detail APIs use JWT, active-Employee checks and strict
  ownership scoping; issued/revoked states and historical snapshots are preserved.
- Flutter assessment models, repository and Riverpod controllers support overview,
  eligibility, start/resume, answer selection, submission, results, retries and history.
  Screens handle loading/errors, deadlines, duplicate actions and uncertain-submission
  reconciliation without client-side grading or persisted answer drafts.
- Flutter certificate models, repository, controllers and list/detail screens support
  paginated API results, historical data and revoked-state display.
- Assignment/module assessment links, Profile certificates, Dashboard certificate
  links and post-assessment certificate navigation are integrated with existing routes.
- App-level Light/Dark themes follow the system preference; contrast, large text,
  reduced motion and retained state across theme changes are tested.
- Android core M17 end-to-end flows passed. Revoked-certificate runtime testing was
  blocked because no fixture existed; automated revoked-state coverage is present.

Latest known validation checkpoints were separate runs:

- Combined foundation validation: **436/436 Django/MySQL tests passed**.
- After app-level theme integration: **316/316 Flutter tests passed**, analyzer clean,
  and debug APK build successful.
- Subsequent ordering-review validation: **59/59 focused assessment/certificate API
  tests** and **438/438 full Django/MySQL tests passed**; system check and migration
  drift check passed. Flutter was not rerun for this backend/documentation change.
- These results do not imply a single combined rerun, commit, merge or release.

Answer autosave, automatic expiry workers, abandonment, offline submission queues,
certificate PDF generation and document downloads remain outside the implemented scope.

## Implemented tasks

- assessment screen
- question rendering
- answer selection
- submission
- attempt handling
- retry handling
- server-side scoring
- pass/fail result
- final assessment integration
- assignment completion state
- certificate access
- certificate display
- certificate version reference

## Rules

The mobile application must not reproduce authoritative scoring rules.

The backend remains authoritative for:

- attempt limits
- scoring
- pass/fail
- completion
- certificate eligibility

---

# 10. M18 - Notifications + Resilience

Status:

```text
IMPLEMENTATION COMPLETE — final lifecycle acceptance and consolidated review
```

## Tasks

- notification foundation
- authentication recovery
- token/session resilience
- network recovery
- retry behavior
- background/foreground reliability
- API error recovery
- operational logging
- health checks
- user-facing error handling

M18 should improve reliability without introducing unnecessary architecture changes.

## First batch and acceptance

- Assignment/Dashboard reads depend on active employee identity and cancel obsolete
  requests, including later pagination, on identity changes or provider disposal.
- Assignment failures wait for explicit retry; POST/mutation retry behavior is unchanged.
- Learning, assignment-detail and Dashboard show readable network/timeout recovery;
  pull-refresh failures render without an unhandled future. 401/403 recovery uses an
  explicit sign-out/sign-in action through the existing authentication controller.
- Shared error panels announce status and scroll on small/landscape screens with
  large text, preserving system themes and keyboard/touch controls.
- Validate account/logout/race, cancellation, retry and UI regressions, full Flutter
  suite and analyzer. Batch 1 Android recovery QA subsequently passed per user confirmation.

## First-batch validation

- Focused Flutter learning, Dashboard, networking, presentation and authentication
  regressions: **190/190 passed**.
- Complete Flutter suite: **337/337 passed**; analyzer: **clean**.
- Debug APK: **built successfully**, without installation or emulator use.
- Git whitespace checks: **passed**, including the new files.
- No Django/backend changes or migrations; Django/MySQL tests and system/migration
  checks were not rerun for this mobile/documentation batch. Earlier backend counts
  remain historical evidence, not M18 rerun results.
- Batch 1 Android QA subsequently passed per user confirmation; it was not rerun
  during the notification API batch. M18 remains incomplete and uncommitted.

## Notification Batches 2A/2B

- Confirmed V1 scope: in-app ASSIGNED, APPROACHING, OVERDUE and COMPLETED events with
  employee-specific read/unread state; no push, Firebase, SMS or email.
- Batch 2A persists unique, server-derived assignment/completion events atomically;
  full Django/MySQL validation: **458/458 passed** at that checkpoint.
- Batch 2B implements GET list/unread-count and POST individual-read/read-all APIs
  under `/api/v1/notifications/`. JWT and active Employee checks apply throughout;
  owned querysets prevent IDOR and arbitrary employee filters. POST accepts no fields.
- Repeated/concurrent reads preserve the first read timestamp. Mark-all uses one
  scoped conditional update without relaxing generic model/queryset write guards.
- The notification migration was subsequently applied to explicitly authorized local
  development. Test migrations still run only on the isolated MySQL test database.

### Batch 2B validation

- Focused MySQL notification checks: **42/42 passed** (22 API tests and all 20
  Batch 2A foundation regressions), including simultaneous read/read-all requests.
- Complete Django/MySQL suite: **480/480 passed** at the Batch 2B checkpoint.
- Django system check, migration drift check and scoped whitespace checks: **passed**.
- No new migration; at the Batch 2B validation checkpoint,
  `notifications.0001_initial` was unapplied to persistent development. It was
  subsequently applied with explicit authorization. The isolated MySQL test database
  was removed after validation.
- Flutter/device tests were not rerun for this Django/API/documentation-only batch.
  M18 remains in progress and uncommitted; CodeRabbit is reserved for its final checkpoint.

## Batch 2C and Batch 2D

- Batch 2C implements the Flutter Notification Center, Dashboard bell, pagination,
  read actions, explicit recovery and account isolation. The subsequent live-theme
  contrast fix passed **386/386 Flutter tests**, analyzer, debug APK build and actual
  Light → Dark → Light emulator verification. These checks were not rerun in Batch 2D.
- Batch 2D adds `generate_training_notifications --activation-cutoff <FIXED_ACTIVATION_ISO8601>`.
  APPROACHING: future deadlines within the next 24 hours, including the upper boundary.
  OVERDUE: strictly past deadlines, matching report semantics. Exact `due_at == now`
  generates neither until time advances.
- Only active Employees' open assignments with pinned published/retired versions
  qualify. Per-assignment Employee → TrainingVersion → Assignment locks recheck
  eligibility before validated insertion; no training/progress/scoring state is saved.
- Unique assignment/type/UTC-deadline keys prevent duplicate events under repeat and
  concurrent runs. New deadlines receive distinct keys; rollback removes the reminder.
- Initial historical backfill is disabled. An operator must explicitly choose a
  timezone-aware activation timestamp and persist it in deployment configuration.
  Every hourly invocation must receive that same cutoff; do not reset it per run.
  Deadlines before activation are excluded. Missing, naive, invalid or future cutoffs
  fail before generation. No activation date is selected or persisted by this batch.
- M20 owns production hourly scheduling and rollout configuration. No scheduled task,
  background thread, Celery/Redis, retention cleanup, email/SMS or push is introduced.

### Batch 2D validation

- Notification/reminder/API regressions: **56/56 passed**, including actual concurrent
  MySQL command execution and lock-order assertions.
- Training/assessment regressions: **194/194 passed**; full Django/MySQL suite:
  **494/494 passed**. These used isolated `test_gardens_training`, removed afterward;
  fast password hashing was overridden only inside the test process, not app settings.
- Django system check, migration drift and scoped whitespace checks: **passed**.
- No new migration, live reminder invocation, scheduler or live notification fixture.
  Flutter was not rerun for this backend/documentation-only batch. M18 stays open.

## Final implementation and populated-QA checkpoint

- Notification backend, APIs and Flutter UI are implemented for ASSIGNED,
  APPROACHING, OVERDUE and COMPLETED, with employee-owned read/unread state.
- Populated Android QA passed: bell/count synchronization, all four event types,
  individual read and mark-all, first-read timestamp preservation, owned-assignment
  navigation, pull-refresh, offline Retry, logout/account switching, Light/Dark Mode,
  large text and portrait/landscape layouts. No crash/layout exception was observed.
- Dark Mode heading contrast and notification singular/plural copy are fixed.
  The copy fix added six 0/1/2-count app-theme/semantics cases and contrast coverage.
- Latest Flutter checkpoint: focused notifications **55/55**, full suite **392/392**,
  analyzer clean, debug APK successful and whitespace checks passed.
- Latest backend checkpoint remains **494/494 Django/MySQL** from Batch 2D, with
  system/migration checks passing then. The backend and Flutter checkpoints were
  separate runs; neither full suite was rerun for this documentation/lifecycle task.
- Disposable Notification IDs **1–5** were deleted. QA Assignment **95** was
  cancelled and retained with explicit authorization because assignment history
  cannot be deleted. Baseline checks verified existing assignments, Employees,
  LessonProgress, VideoWatchSession, attempts and certificates unchanged. This final
  acceptance task must not change Assignment 95 or other QA records.

### Focused lifecycle QA — 2026-10-17 (Asia/Kolkata)

Exclusive use of `emulator-5554` was explicitly authorized. The installed M18 debug
APK reported `1.0.0` (build 1), last updated at 11:18:11 local time. It was used as
installed, without rebuilding/reinstalling or changing source, authentication
configuration or QA business records. The later count-copy build/test checkpoint
above is separate; this lifecycle pass does not claim a device retest of that copy.

| Scenario | Result | Runtime evidence / limit |
|---|---|---|
| Notification Center background/resume | PASS | Home then existing MainActivity resume retained a usable Notification Center. |
| Background during an in-flight notification read | BLOCKED | Refresh was initiated, but emulator latency did not reliably expose a still-pending GET at backgrounding. No pending-request PASS is claimed. No disposable notification remained for a mark-read POST; no fixture was created. |
| Disconnect while backgrounded, resume, explicit refresh | PASS | The resumed screen showed Connection unavailable with Retry. |
| Restore connectivity and Retry | PASS | Notification list/unread-count GETs returned 200 and the current empty/zero state rendered. |
| Logout/account switch after resume | PASS | `employee_test` logout returned 204; manual login as `qa_replay_web` loaded that learner's Profile and a fresh 0 unread / 0 notifications state. Both feeds are empty after cleanup; distinct populated-account isolation was verified in the earlier populated QA pass. |
| Existing expired session after resume | PASS | Notification GETs returned 401; Sign in required and the explicit Sign in again action led to Login, followed by successful manual QA login. |
| Exact expiry occurring while backgrounded | BLOCKED | The existing token was already expired. No token inspection, clock/authentication changes or forced expiry was used. |
| Light/Dark appearance after resume | PASS | Readable empty/error states survived background/resume in both system themes. |
| Crashes, unhandled errors or stale identity | PASS for observed scenarios | App-scoped error logs contained no matching Flutter exceptions, fatal crashes or RenderFlex overflows; the new learner identity replaced the prior Profile. |

Screenshots and accessibility labels were captured outside Git, including
`m18-lifecycle-light-resume.png`, `m18-lifecycle-refresh-resumed.png`,
`m18-lifecycle-offline-dark.png`, `m18-lifecycle-retry-dark.png`,
`m18-lifecycle-dark-resume.png`, `m18-lifecycle-switched-profile.png` and
`m18-lifecycle-switched-notifications.png`.
Emulator Wi-Fi/mobile data, zero network latency and Light Mode were restored.
No existing QA assignment, notification, progress, attempt or certificate was changed;
Assignment 95 remained untouched. Login/logout used only normal authentication flows.
The blocked scenarios are verification limits, not reproducible defects.

### Specialized live-QA limitations

- Direct authenticated pagination, crafted-ID/IDOR and repeated-mutation requests
  were not exercised in the live API credential session. Automated API regressions
  cover these behaviors, including concurrent reads.
- Inaccessible-assignment notification navigation lacked a safe live fixture;
  the widget regression covers the controlled inaccessible state.
- Full TalkBack interaction remains unverified; semantics, labels, contrast, large
  text and responsive layouts have automated and sampled runtime evidence.
- These are QA limitations, not confirmed defects or new feature requirements.

## Decisions and remaining work

The notification event types, in-app channel and read/unread API behavior are now
confirmed and implemented, including Flutter screens and deadline generation. The
approaching window is 24 hours, hourly execution is required, and initial historical
backfill is disabled. Core disposable-fixture notification QA and the safely
reproducible lifecycle checks are complete, with the explicit limits recorded above.
The current checkpoint is consolidated review; no additional feature is required.
The operator-selected activation cutoff and scheduler deployment belong to M20.
Retention is not implemented. No automatic JWT refresh, persistent offline cache or
offline completion is introduced.
The authenticated `/api/v1/status/` is an API connectivity check, not a comprehensive
infrastructure readiness probe. Production monitoring, deployment health checks,
backups and secret configuration belong to M20; broad visual work remains M22.
No further M18 feature requirement was identified by the acceptance audit. M18 is
not committed, pushed or released; no M18 CI result is claimed.

---

# 11. M19 - Android Release Candidate

Status:

```text
IN PROGRESS
```

## Phase 2B integration checkpoint - 2026-10-19

The core cross-system journey passed. Assignment **96** was created through the
Django web portal for `qa_employee`, pinned to published TrainingVersion **3**.
Android completed TEXT Lesson **7** and VIDEO Lesson **8**; server-confirmed unique
video coverage is **55.350/69 seconds (80.217%)**, meeting the 80% threshold.

Assessment **2** passed on Attempt **39** (**1/1, 100%**), after failed Attempts
**37** and **38**. All three permitted attempts are consumed. Assignment 96 is
**COMPLETED**, with exactly one Certificate **36**, ASSIGNED Notification **6**
and COMPLETED Notification **7**. No duplicate certificate or notification events
were found.

Flutter fixes address premature pause during buffering, observation scheduling
across interrupted playback, and stale initialization closing newer sessions.
Latest validation: **418/418 Flutter tests passed**, analyzer clean and fresh debug
APK built; Android runtime completion subsequently verified. Earlier full baseline:
Django/MySQL **497/497**, Flutter **408/408**, JavaScript **33 passed, 1 optional
browser test skipped**. These are separate checkpoints; Django/JavaScript were not
rerun for this documentation update. Historical results remain valid as recorded.

**Unresolved performance issue:** frequent Android emulator video buffering.
Final physical-device, performance, accessibility and release-candidate checks
remain pending. M19 stays **IN PROGRESS**; the core journey does not satisfy every
release gate. Current Flutter fixes and this checkpoint remain uncommitted; no new
CI result is claimed.

**Agreed revised sequence:** bring M22 design forward after this M19 checkpoint,
then resume final M19 QA against the resulting application. Neither milestone is
complete. This does not authorize unrelated refactoring or remove M20/M21/M23
obligations.

## Tasks

- feature freeze
- Android regression
- backend regression
- API regression
- playback regression
- assessment regression
- certificate regression
- security review
- permission/IDOR review
- device testing
- performance review
- lifecycle review
- network testing
- pilot testing
- release candidate build

## Release Candidate Gate

```text
[ ] Required features complete
[ ] Automated tests pass
[ ] Runtime QA passes
[ ] Security review passes
[ ] No critical/blocking defects remain
[ ] Pilot validation complete
[ ] Documentation current
[ ] CI green
[ ] Release build verified
```

---

# 12. M20 - Production + Deployment Hardening

Status:

```text
PLANNED
```

## Tasks

- production environment configuration
- secrets management
- database configuration
- production media/storage configuration
- backup verification
- restore verification
- deployment procedure
- rollback procedure
- health checks
- monitoring
- logging
- production smoke tests
- Android release configuration
- build/version management
- CI/CD reliability

Production credentials must never be committed to the repository.

---

# 13. M21 - Final Bug Hunt + Security + Repository Review

Status:

```text
PLANNED
```

## Functional Review

- authentication
- authorization
- assignments
- training versions
- learning
- video
- assessments
- certificates
- dashboards
- reports
- audit logging

## Security Review

- authentication
- token handling
- permissions
- IDOR
- protected media
- session authorization
- input validation
- upload validation
- audit logging
- sensitive information exposure
- Android security controls

## Repository Review

- dead code
- unused dependencies
- temporary files
- debug artifacts
- secrets
- documentation contradictions
- CI configuration
- migration state
- test reliability
- repository hygiene

Only genuine defects or justified maintainability problems should be fixed.

---

# 14. M22 - Readability + Refactor + Garden's Need Visual Polish

By user agreement, bring M22 design forward after the M19 Phase 2B checkpoint,
then resume final M19 QA. M22 remains planned, not complete.

Status:

```text
PLANNED
```

## Maintainability

- improve confusing code
- remove unnecessary duplication
- improve naming
- simplify overly complex logic
- remove obsolete code
- improve readability
- avoid unnecessary abstractions

Refactoring must preserve behavior.

## Visual Polish

This is the deliberate final Garden's Need UI/UX design phase.

Potential work:

- final typography
- final colors
- spacing
- cards
- navigation
- dashboards
- progress indicators
- animations
- transitions
- micro-interactions
- loading states
- empty states
- error states
- accessibility
- responsive refinement
- Garden's Need visual identity

The final visual direction should be reviewed before broad implementation.

Do not let coding agents independently lock the final visual identity before this milestone.

---

# 15. M23 - Final Acceptance + Android V1 Release

Status:

```text
PLANNED
```

## Final Tasks

- final acceptance testing
- final backend regression
- final API regression
- final Android regression
- final playback validation
- final assessment validation
- final certificate validation
- final security review
- final device testing
- final performance review
- final UX review
- production verification
- release build verification
- release signing verification
- production deployment
- post-release smoke test
- documentation checkpoint
- final sign-off

## V1 Release Gate

```text
[ ] All required milestones complete
[ ] Automated tests pass
[ ] CI passes
[ ] Security review passes
[ ] Runtime/device QA passes
[ ] No critical/blocking defects remain
[ ] Production configuration verified
[ ] Backup/rollback verified
[ ] Release build verified
[ ] Documentation current
[ ] Post-release smoke test passes
```

---

# 16. Versioning and Training Rules

The following rules are locked for V1.

## Lifecycle

```text
Draft → Published → Retired
```

## Published Versions

Published versions are immutable.

Anything that requires changing published training content requires a new version.

## Assignments

Assignments remain pinned to their assigned version.

New assignments use the latest applicable published version.

The application must not automatically migrate employees to newer versions.

Retired versions cannot receive new assignments, but existing assignments may continue where permitted by the backend.

## Assessments

Assessment questions and answer keys are frozen with the applicable training version.

## Certificates

Certificates reference the training version earned by the employee.

Certificate revocation must not modify the historical training version.

## Media

Published media is immutable.

Replacing published media requires a new version.

---

# 17. Mobile Architecture Rules

The Flutter application is a client of the backend, not a second business-logic layer.

Backend authority includes:

```text
Authorization
Assignment ownership
Training version
Progress
Playback sessions
Anti-skip rules
Completion
Assessment scoring
Certificate eligibility
```

Flutter is responsible primarily for:

```text
Presentation
Navigation
Local UI state
User interaction
API orchestration
Loading/error feedback
Device-specific behavior
```

Do not duplicate authoritative business rules in Flutter.

---

# 18. Offline Rules

V1 does not provide authoritative offline course completion.

Offline behavior may include:

- clear offline state
- retry
- network recovery
- session recovery
- progress recovery where technically appropriate

The server remains authoritative for completion.

---

# 19. Media Architecture Rules

The existing M13 session-based protected media architecture must be reused.

Do not introduce a parallel media authorization system.

Do not introduce a duplicate protected media route without a concrete architectural requirement.

Media storage must remain behind an abstraction so future object-storage migration does not require rewriting authorization logic.

---

# 20. Development Workflow

Preferred workflow:

```text
Inspect
→ Plan
→ Implement
→ Focused Tests
→ Broader Tests
→ Full MySQL Suite
→ Flutter Tests
→ Analyze
→ Build
→ Live/Runtime QA
→ Code Review
→ Stage
→ Inspect Staged Diff
→ Commit
→ Push
→ CI Verification
```

Agents must not commit or push unless explicitly requested.

---

# 21. Defect Workflow

For confirmed defects:

```text
Reproduce
→ Add/confirm regression coverage
→ Narrow Fix
→ Focused Verification
→ Broader Verification
→ Review
```

Avoid unrelated refactors while fixing a defect.

---

# 22. Testing Strategy

Testing should be risk-based.

## Low Risk

Use focused tests and normal regression.

Examples:

- simple UI changes
- copy changes
- isolated presentation changes

## Medium Risk

Use focused tests plus runtime validation.

Examples:

- navigation
- authentication flows
- API integration
- learning state
- lifecycle behavior

## High Risk

Use adversarial/security/regression testing.

Examples:

- authorization
- IDOR
- protected media
- playback sessions
- anti-skip
- authentication
- assessment scoring
- certificate eligibility
- concurrency

Avoid adding tests merely to increase test count.

Tests should protect meaningful behavior.

---

# 23. Current Validation Baseline

The current verified baseline is:

```text
Django/MySQL tests: 348 passing
Flutter tests: 81 passing
JavaScript playback tests: 3 passing
```

Additional checks:

```text
Django check: passing
Migration consistency: passing
pip check: passing
git diff --check: passing
Flutter analyze: passing
Android debug APK: passing
GitHub Actions CI: passing
```

If new tests are added, the verified baseline should be updated.

If tests are removed, the reason must be understood and documented where appropriate.

Historical test counts should not be rewritten simply because the current test count is higher.

---

# 24. Documentation Rules

`docs/ROADMAP.md` is the canonical milestone roadmap.

`docs/TASKS.md` tracks practical milestone tasks and exit criteria.

`CHANGELOG.md` records historical changes.

`AGENTS.md` contains repository/agent operating instructions.

Do not duplicate milestone definitions unnecessarily across documents.

When milestone state changes, update the appropriate documentation.

Do not claim work is complete until its exit criteria have been satisfied.

---

# 25. Current Next Action

The next development milestone is:

```text
M17 - Assessment + Certificates
```

Immediate priorities:

```text
1. Review the verified Phase 1 assessment API foundation.
2. Integrate Flutter assessment overview and start/resume.
3. Integrate answering, submission, results, retries and history.
4. Add certificate access/display using existing issuance and ownership rules.
5. Run focused mobile/security regressions and M17 runtime QA.
```

No M18, M19, M20, M21, M22, or M23 implementation should begin merely because those milestones are documented.

The project should progress sequentially through the roadmap, with each milestone passing its exit criteria before the next milestone becomes active.
