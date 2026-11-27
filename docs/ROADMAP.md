# Garden’s Need Training Module Application Roadmap

## Current Status

V1 application development and integration completed on 27 November 2026. Production deployment, signing and rollout remain pending. See the [V1 integration checkpoint](V1_INTEGRATION_CHECKPOINT.md).

The Flutter Android app covers Administrator, Manager and Employee workflows in the custom portal. Framework administration stays on the web. Backend permissions and reporting scope govern access. iOS remains deferred.

Earlier milestone notes preserve what was known at those checkpoints. Use the status table and [launch gates](V1_INTEGRATION_CHECKPOINT.md#production-launch-gates) for current decisions.

<details>
<summary>Historical Android expansion and local integration evidence</summary>

### Approved Android scope expansion: three roles

Android now targets Administrator, Manager and Employee business functionality
already available in the custom Django portal. This supersedes the original
employee-only client assumption, while preserving the historical milestones and
QA evidence below. Framework `/admin/` User/Group/password/token administration is
excluded. Managers keep their existing recursive team scope and permissions; the
expansion does not grant new assignment, authoring or revocation authority.

The current local Batch 1 implements identity/capability discovery, authorized
management-only login, optional Employee context, personal-route/provider guards
and Team/Management account-access overviews. Batch 2 implements read-only
company/team dashboards, a permission-scoped employee directory/detail and
Department/Job Role reference lists through authenticated APIs and native Flutter
screens. Both batches are implemented locally and remain uncommitted; Android
role-based runtime QA and CI verification remain pending. Existing web redesign
and six mobile usability fixes are preserved as separate work.

| Batch | Scope | Status |
|---|---|---|
| 1 | Identity, effective capabilities, role-aware navigation and account isolation | Implemented locally; automated validation passed; Android runtime QA pending |
| 2 | Read-only company/team dashboards, scoped employee directory and reference lists | Implemented locally; automated validation passed; Android runtime QA pending |
| 3 | Employee, Department and Job Role management | Implemented locally; full cross-system integration and release acceptance unverified |
| 4 | Management assignments, manual creation, requirements and role-based batches | Implemented locally; full cross-system integration and release acceptance unverified |
| 5 | Catalog, version lifecycle, Draft modules and TEXT authoring | Implemented locally; full cross-system integration and release acceptance unverified |
| 6 | Validated Draft VIDEO upload/replacement and server metadata | Implemented locally; full cross-system integration and release acceptance unverified |
| 7 | Question bank, frozen revisions and assessment authoring | Implemented locally; full cross-system integration and release acceptance unverified |
| 8 | Management certificates/revocation, scoped reports and audit viewing | Django APIs and Flutter certificate/report/audit implementations exist locally and remain uncommitted. Focused automated checks are separate from pending disposable-MySQL integration, real-device acceptance, commit/push and CI verification. |
| 9 | Three-role cross-system, concurrency, accessibility and device acceptance | Open; cross-system concurrency, accessibility and device acceptance remain pending |

Each batch requires permission/IDOR negatives, account-switch coverage and relevant
web/mobile regression checks. Existing learner APIs remain personal. New management
APIs must reuse backend validation, audit/notification hooks and transaction rules.
No management feature is authorized solely by a client role label or cached
capability. Published immutability, pinned versions, scoring and protected playback
remain unchanged. This is a functional expansion requiring new release acceptance;
no completion percentage or delivery date is assigned here.

Batch 1 local checkpoint: **234/234 Django/API and role-scoping tests on MySQL**,
**72/72 focused Flutter tests**, **518/518 full Flutter tests**, analyzer clean,
Django system check passed and no migration drift. The test schema was removed;
these results do not claim a full Django regression, Android runtime PASS or CI.

Subsequent Batch 1–2 checkpoints passed **170/170 selected Django/MySQL tests**
(including **18/18 management API tests**) and **551/551 full Flutter tests**.
Flutter analysis was clean. The dedicated test schema was retained with its role
bootstrap verified. These were separate checkpoints, not a full Django-suite or
device acceptance result. The APK was built and installed, but emulator system
responsiveness and host memory prevented login-screen/role runtime verification.
Batches 3–8 have local implementation, but that is not release acceptance. Batch 8
report/audit viewing code is implemented locally; backend integration, real-device
acceptance and Batch 9 cross-system acceptance remain open.

The sections below retain historical milestone scope, validation records and
sequencing decisions. Historical test results are not current validation of later
uncommitted changes.

M0–M15 are historically implemented. M16 secure video is implemented, with final
acceptance still open. M17 management-certificate work is present in uncommitted
Django and Flutter changes and awaits real MySQL integration verification. M18
notification/resilience functionality substantially exists, but its full closure
is not established by this checkpoint. The prior M18 checkpoint **88a4cda** and
user-reported green CI remain historical evidence, not proof that the current
uncommitted work is integrated or release-ready.

The current milestone is **M19: Android Release Candidate - IN PROGRESS**.
The core integration journey passed; final release acceptance remains open.
Current Flutter fixes and this checkpoint remain uncommitted.

**Agreed sequencing adjustment:** M22 design work was brought forward after the
M19 integration checkpoint. M19, M20, M21, M22 and M23 remain open; the core
integration journey does not close their remaining gates.

The project follows an Android-first development strategy:

**Backend/Web Foundation → Mobile API Foundation → Android Foundation → Employee App Core → Learning/Playback → Assessments/Certificates → Resilience/Operations → Android Release Candidate → Production/Deployment Hardening → Final Review → Visual Polish → Final Acceptance & Android V1 Release**

iOS is intentionally outside the current Android V1 completion target. It will be evaluated after Android V1 is released and stabilized.

---

</details>

### Evidence status definitions

These are separate evidence dimensions, not interchangeable milestone labels:

- **IMPLEMENTED** — the feature exists in source; it may still be uncommitted.
- **AUTOMATED TESTED** — the relevant automated tests were actually run and passed;
  identify the test scope and run rather than inferring this from implementation.
- **INTEGRATION VERIFIED** — dependent components and the data store were exercised
  together in the intended environment.
- **MANUAL QA PASSED** — the stated manual/device/browser acceptance scenarios were
  completed and passed.
- **RELEASE APPROVED** — the authorized release gate and production approval passed.

An uncommitted implementation, a focused test, or a historical green CI run does
not by itself establish integration verification, manual QA, or release approval.

## Roadmap

| Milestone | Phase | Status | Notes |
|---|---|---|---|
| M0–M12 | Core Django Training Platform | Implemented (historical) | Core platform and web workflows are historical implementation; this status does not recertify the current worktree. |
| M13 | Mobile API Foundation & Versioning | Implemented (historical) | Versioned API foundation and server-side authorization were established; later integration remains subject to current validation. |
| M14 | Flutter / Android Foundation | Implemented (historical) | Flutter Android foundation was established; this is not current release approval. |
| M15 | Employee App Core | Implemented (historical) | Employee learning-flow foundation was implemented; historical validation remains in the milestone record. |
| M16 | Learning + Secure Video | Integrated | Protected tracking and completed-assignment replay. Physical-device QA passed. |
| M17 | Assessment + Certificates | Integrated | Assessment and certificate workflows are included. Hindi/Devanagari PDF shaping is deferred. |
| M18 | Notifications + Resilience | Integrated | Inbox and Android notifications are included. Production reminder scheduling is a launch gate. |
| M19 | Android Release Candidate | Integration accepted | Physical-device QA passed. Production signing remains pending. |
| M20 | Production + Deployment Hardening | Application hardening implemented | Infrastructure, production preflight, backup scheduling and isolated recovery verification are pending. |
| M21 | Final Bug Hunt + Security + Repository Review | Integration verified | The corrected PR and main CI passed, including the isolated 53-test profile. Run 5 is deferred. |
| M22 | Final Readability + Refactor + Garden’s Need Visual Polish | V1 scope integrated | Branding, orientation, deadline, certificate and panel alignment corrections are included. |
| M23 | Final Acceptance + Android V1 Release | Production acceptance pending | Production approval, smoke tests and internal rollout remain open. |

---

# M16: Learning + Secure Video

## Scope

- Training lesson experience
- Text learning integration
- Protected video playback
- Existing playback-session integration
- Heartbeats
- Resume behavior
- Progress synchronization
- Network interruption recovery
- Foreground/background lifecycle handling
- Anti-seek/anti-skip integration
- Secure media access
- Android `FLAG_SECURE` where appropriate
- Risk-based Android playback QA

The mobile application must reuse the existing M13 server-authoritative playback architecture.

The existing session-based protected media endpoint must be reused. A parallel or duplicate media API must not be introduced without an explicit architectural reason.

The backend remains authoritative for:

- authorization
- playback sessions
- playback progress
- completion
- anti-skip/anti-seek enforcement
- assessment eligibility
- training state

The Flutter application must not duplicate these business rules.

## Training Version Rules

The current versioning model is:

**Draft → Published → Retired**

Published training versions are immutable.

Assignments remain pinned to the version assigned to them.

Publishing a newer version does not automatically migrate existing assignments.

New assignments use the latest applicable published version.

Retired versions cannot receive new assignments, while existing assignments may continue using their pinned version.

Assessments, questions, answer keys, and related version-specific configuration remain tied to the applicable training version.

Certificates reference the version earned by the employee.

Draft content may be deleted where permitted by the existing backend rules, but published versions must not be deleted or mutated.

## Published Media Rules

Published media is immutable.

Replacing media on published training content requires a new training version rather than mutating the already-published media.

V1 media is streaming-oriented and must not provide unrestricted downloads.

Media access must remain authenticated and assignment-authorized.

## Media Architecture

The existing M13 session-based protected media architecture is the foundation for M16.

The application must not introduce a second independent protected-media route when the existing contract already satisfies the requirement.

Media storage remains behind the existing application/storage abstraction so that future migration to object storage can occur without changing authorization or business rules.

## Offline Rule

V1 does not support unrestricted offline course completion.

The application may support:

- clear offline state
- retry
- network recovery
- playback/progress recovery where technically appropriate
- session recovery

Authoritative completion remains server-controlled.

---

# M17: Assessment + Certificates

## Phase 1: secure mobile assessment API foundation

The assessment API foundation and subsequent certificate/Flutter integration are
implemented and committed at `afdadb4`. The earlier validation checkpoints below
are retained as historical records.

Employee-scoped overview, start/resume, attempt detail and submission endpoints reuse
the authoritative website operations. Passing prevents new attempts for the same
assessment/assignment through both clients. Deadlines are enforced on submission;
answer drafts, automatic expiry, abandonment and offline queues are not introduced.
See `docs/ARCHITECTURE.md`, API Architecture, for the response and error contracts.

## Implemented mobile and certificate integration

- Certificate list/detail APIs are read-only, JWT/active-Employee and ownership-scoped,
  with pagination, historical snapshots and revoked-state access.
- Flutter assessment models, repository, Riverpod controllers and screens cover
  eligibility, start/resume, questions, submission, results, retries and attempt history.
- Flutter certificate models, repository, controllers and list/detail screens are
  integrated into Profile, Dashboard and completed-training navigation. Assessment
  entry points reuse assignment/module routes and the existing three-tab shell.
- App-level Light/Dark themes follow the system preference without resetting learner
  state; contrast, large text and reduced-motion behavior have regression coverage.
- Android core M17 end-to-end flows passed. The revoked-certificate runtime case was
  blocked because no fixture existed; it is not recorded as a runtime PASS.

Latest known checks were performed at different checkpoints: **436/436 Django/MySQL**
tests passed during foundation validation; **316/316 Flutter** tests passed after
theme integration, with a clean analyzer and successful debug APK build. These are
not claims of a combined rerun or of a committed, merged or released milestone.
The subsequent ordering-review checkpoint passed **59/59 focused API tests** and
**438/438 full Django/MySQL tests**, with clean system and migration-drift checks.
Flutter was not rerun at that checkpoint.

Certificate PDF generation and document downloads remain outside the baseline M17 requirement.

## Scope

- Assessment UI
- Question rendering
- Answer selection/submission
- Attempt handling
- Pass/fail results
- Retry behavior
- Server-authoritative scoring
- Completion state
- Certificate access
- Certificate display
- Version-aware certificate handling

The mobile client must not reproduce authoritative assessment or scoring rules locally.

Assessment configuration and answer keys remain tied to the applicable training version.

Certificates must retain the historical training version against which they were earned.

Certificate revocation must not modify the historical training version.

---

# M18: Notifications + Resilience

## Scope

- Notifications
- Retry behavior
- Network recovery
- Session expiration
- Refresh-token edge cases
- Login/session recovery
- Foreground/background lifecycle behavior
- API failure handling
- Operational logging
- Health checks
- Error visibility
- Production-readiness improvements

## First batch: learner read isolation and recovery

At the start of Batch 1, notification events and channels were unspecified and no
notification infrastructure existed. Batch 1 introduced no notification delivery
or offline completion. The confirmed in-app scope and subsequent batches are below.

This batch uses existing Flutter repositories, providers and authentication to:

- Scope assignment/Dashboard reads to the active authenticated employee and cancel
  obsolete requests, including pagination, on identity changes or provider disposal.
- Keep old responses/content out of the current learner's UI.
- Disable implicit assignment-read retries and offer explicit read recovery.
- Route explicit 401/403 recovery through existing logout/sign-in, without automatic
  JWT refresh or automatic replay of state-changing requests.
- Provide network/timeout messages, accessible announcements and scrollable error
  layouts for large text/small screens in both system themes.

Batch acceptance requires account/race/cancellation negative tests, explicit-retry
and refresh-failure tests, responsive accessibility checks, the full Flutter suite
and analyzer. The user subsequently confirmed Batch 1 Android QA passed; it was not
rerun during the notification API batch.

## Batches 2A-2D: in-app notifications

V1 is in-app only: ASSIGNED, APPROACHING, OVERDUE and COMPLETED, with employee-owned
read/unread state. No push, Firebase, SMS, email or external delivery service is added.

Batch 2A adds notification persistence and deterministic database-unique event keys.
Manual/role assignment and successful completion create notifications in their
business transactions. Its full Django/MySQL validation passed **458/458**.

Batch 2B adds JWT/active-employee APIs under `/api/v1/notifications/`: paginated GET
list, GET `unread-count/`, POST `<id>/read/` and POST `read-all/`. Queries use only
the authenticated employee; foreign IDs return 404. POST actions accept no fields.
Read metadata changes use an owner-scoped conditional SQL update, preserving the
first read timestamp and immutable event content. GET/HEAD perform no writes.

The Batch 2A migration was subsequently applied to the explicitly authorized local
development database. Batch 2C added the Flutter Notification Center and Dashboard
bell, including account isolation and actual system Light/Dark themes. Its latest
Flutter validation passed **386/386** after the contrast fix; this is historical
evidence and is not a Flutter rerun during Batch 2D.

Batch 2D adds `generate_training_notifications`: APPROACHING means strictly future
and within 24 hours (inclusive); OVERDUE uses the existing strict `due_at < now`
report semantics. Active Employees with open assignments pinned to published or
retired versions qualify. Completed/cancelled assignments and missing deadlines do not.
Per-assignment atomic Employee → TrainingVersion → Assignment locking rechecks
eligibility before validated insertion. Unique keys include assignment, type and
canonical UTC deadline; changed deadlines form new contexts.

Initial rollout requires an explicit, fixed, timezone-aware `--activation-cutoff`.
Deadlines before it are excluded, preventing historical overdue backfill. M20 must
persist the operator-selected activation timestamp in deployment configuration and
supply that same value to hourly invocations; never replace it with each run's time.
No cutoff date, scheduler, background thread, retention cleanup or backfill is
installed here. These deployment dependencies do not add M18 feature requirements.
M18 notification/resilience functionality is substantially implemented; final
acceptance/review and operational closure remain pending.

## Final implementation and acceptance checkpoint

All four notification types, employee-owned APIs, read/unread state, Flutter screens
and reminder generation are implemented. Core populated Android QA passed, including
read/count synchronization, owned-assignment navigation, offline Retry, account
switching, system themes and large-text portrait/landscape layouts. The Dark Mode
heading contrast and singular/plural count defects are fixed.

Latest separate validation checkpoints: Django/MySQL **494/494** (Batch 2D);
Flutter **392/392**, focused notification tests **55/55**, analyzer clean and debug
APK successful (final count-copy fix). These were not rerun together or during the
documentation/lifecycle acceptance task. Historical batch counts above remain valid.

The five disposable notifications were deleted after populated QA. Assignment **95**
was cancelled and retained with explicit authorization; existing learner history was
preserved. Focused lifecycle checks on 2026-10-17 passed background/resume, offline
recovery, logout/account switching, expired-session recovery and system themes.
In-flight-request timing and expiry occurring specifically while backgrounded could
not be safely established. See `docs/TASKS.md` for exact outcomes and remaining
live-QA limitations. They are verification limits, not confirmed implementation defects.

The production objectives below overlap M20. This batch performs no deployment,
backup, secret, monitoring-service or infrastructure configuration. M19 retains
release-candidate/device/pilot gates; M21 retains the comprehensive final audit;
M22 retains broad visual redesign and readability refactoring.

Production-oriented work should include:

- environment/secrets management
- database backup verification
- deployment health checks
- rollback procedure
- release/version management
- operational monitoring
- manual production approval

---

# M19: Android Release Candidate

M19 is the primary release-hardening milestone.

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

## Required Activities

- Feature freeze
- Full backend regression
- Full API regression
- Android regression
- Security audit
- Architecture audit
- Data/permission/IDOR audit
- Playback audit
- Network/lifecycle testing
- Performance testing
- Real-device testing
- Device compatibility testing
- UX/usability review
- Production deployment rehearsal
- Pilot deployment
- Employee pilot feedback
- Pilot fixes
- Final regression
- Release approval preparation

## Release Candidate Gate

Android must not be considered release-candidate ready merely because the application builds.

Release-candidate readiness requires:

- implementation complete
- automated tests passing
- security validation passing
- runtime/device QA passing
- no critical/blocking defects
- production/staging checks passing
- pilot completed where applicable
- final regression passing
- documentation updated
- roadmap checkpoint updated
- Git/CI checkpoint confirmed

---

# M20: Production + Deployment Hardening

M20 focuses on making the application and its supporting infrastructure safe to operate in production.

Application safeguards and operator procedures are implemented in the M20
hardening batch; validation is recorded in its execution report. Deployment,
restore rehearsal and infrastructure gates remain outstanding. See
`docs/M20_OPERATIONS.md`; this is not a production release or CI-clearance claim.

## Scope

- Production configuration review
- Environment/secrets management
- Database configuration
- Backup verification
- Restore verification
- Deployment procedure
- Rollback procedure
- Health checks
- Monitoring
- Error visibility
- Logging review
- Production media/storage readiness
- Android release configuration
- Version/build management
- CI/CD reliability
- Operational documentation

Production configuration must remain separated from development/test configuration.

Sensitive credentials must not be committed to the repository.

Deployment procedures must be reproducible and documented.

---

# M21: Final Bug Hunt + Security + Repository Review

M21 is a final cross-system review before visual polish and final acceptance.

## Scope

### Functional Review

- Backend workflows
- API workflows
- Authentication
- Authorization
- Assignments
- Training versions
- Learning progress
- Video playback
- Assessments
- Certificates
- Employee flows
- Manager/admin workflows

### Security Review

- Authentication
- Token handling
- Permission boundaries
- IDOR/ownership enforcement
- Protected media access
- Session authorization
- Input validation
- Upload validation
- Audit logging
- Sensitive information exposure
- Android security controls

### Repository Review

- Dead code
- Unused dependencies
- Accidental files
- Temporary files
- Debug artifacts
- Secret/config exposure
- Documentation consistency
- CI consistency
- Test reliability
- Migration state
- Git hygiene

Only genuine defects or justified maintainability issues should be fixed.

Avoid broad refactors that introduce unnecessary regression risk.

---

# M22: Final Readability + Refactor + Garden’s Need Visual Polish

M22 is the deliberate final product-polish phase. By user agreement, bring its
design work forward after the M19 Phase 2B checkpoint, then resume final M19 QA.
This sequencing change does not mark M22 complete.

The purpose is not to redesign the application's architecture.

## Maintainability

- Improve readability where genuinely beneficial
- Remove unnecessary duplication
- Simplify confusing code
- Remove obsolete code
- Improve naming where justified
- Reduce avoidable technical debt
- Keep business logic centralized
- Avoid unnecessary abstractions

Refactoring must not change established business behavior without explicit justification.

## UI/UX Polish

The final Garden’s Need visual direction should be established deliberately during this milestone.

Potential areas include:

- visual hierarchy
- typography
- spacing
- cards and surfaces
- icons
- transitions
- animations
- micro-interactions
- loading states
- empty states
- error states
- progress indicators
- navigation transitions
- accessibility
- responsive layouts
- Android-specific interaction patterns

The final UI should feel polished, modern, interactive, and appropriate for Garden’s Need.

Visual decisions should be reviewed before broad implementation rather than allowing agents to independently invent the final brand direction.

M22 is the appropriate stage for substantial visual refinement because the underlying application functionality should already be stable.

---

# M23: Final Acceptance + Android V1 Release

M23 is the final acceptance and release milestone for Android V1.

## Required Activities

- Final functional acceptance
- Final backend regression
- Final API regression
- Final Android regression
- Final security validation
- Final playback validation
- Final assessment/certificate validation
- Final real-device testing
- Final performance verification
- Final UX review
- Production deployment verification
- Release build verification
- Release signing verification
- Pilot/acceptance sign-off
- Production release
- Post-release smoke testing
- Final documentation checkpoint
- Final roadmap checkpoint

## Android V1 Release Gate

Android V1 is released only when:

- all required milestone work is complete
- automated tests pass
- security review passes
- runtime/device QA passes
- no critical or blocking defects remain
- production configuration is verified
- backup/rollback procedures are verified
- release build is verified
- release approval is obtained
- documentation is current
- Git/CI state is verified
- post-release smoke testing is successful

---

# Phase Completion Rules

A milestone or phase must not be marked `Complete` merely because its code exists.

Before marking a milestone `Complete`:

1. Implementation is complete.
2. Appropriate automated tests pass.
3. Security-sensitive behavior has been reviewed.
4. Runtime/browser/device QA has been completed where applicable.
5. No critical or blocking defects remain.
6. Documentation is updated.
7. `docs/ROADMAP.md` is updated.
8. Git state has been reviewed.
9. Required commit/push checkpoint has been completed by the user.

If a required exit criterion is incomplete, the milestone remains `In Progress`.

---

# Development Principles

- Backend remains authoritative for permissions, progress, scoring, completion, and security.
- Do not duplicate backend business rules in the mobile client.
- Avoid unnecessary migrations.
- Avoid unnecessary architecture changes.
- Reuse existing server-authoritative playback and business logic.
- Do not create duplicate API contracts when an existing contract satisfies the requirement.
- Keep implementation tasks narrowly scoped.
- Do not add unrelated features during milestone work.
- Android is the current release target.
- iOS is deferred until Android V1 is released and stable.
- Mobile development must not weaken existing web behavior.
- Published training versions are immutable.
- Existing assignments remain pinned to their assigned versions.
- Published media is immutable.
- V1 does not support unrestricted offline course completion.
- Security-sensitive, architectural, playback, and media changes require tighter review and regression testing.
- Risk-based testing is preferred over indiscriminate test expansion.
- Production behavior must be validated against production-like staging conditions before release.

---

# Documentation Responsibilities

`docs/ROADMAP.md` is the canonical product-development roadmap.

At each milestone checkpoint:

- completed milestone → `Complete`
- active milestone → `In Progress`
- blocked milestone → `Blocked`
- future milestone → `Planned`

Do not maintain manually duplicated completion percentages in the roadmap.

Current test counts should be recorded only where useful and should reflect the actual current repository state.

Historical test counts and historical milestone records must not be rewritten merely because the current test count has increased.

Project-agent instructions, coding-agent workflow, model preferences, tool-specific instructions, and repository operating rules belong in `AGENTS.md` or appropriate development documentation rather than this roadmap.

---

# Current Checkpoint

V1 application development and integration completed on 27 November 2026. Production deployment, signing and rollout remain pending. Follow the [launch gates](V1_INTEGRATION_CHECKPOINT.md#production-launch-gates) and the [production runbook](V1_RELEASE_RUNBOOK.md). Run 5 and Hindi/Devanagari PDF shaping remain deferred.
