# Garden’s Need Training Module Application Roadmap

## Current Status

The Android-first development roadmap is currently complete through **M13 Phase 4**.

The next milestone is **M14: Flutter / Android Foundation**.

The project follows an Android-first strategy:

**Backend/Web Foundation → Android Foundation → Employee App → Learning/Playback → Assessments/Certificates → Resilience/Operations → Android Release Candidate → Android Release**

iOS is intentionally outside the current completion target and will be evaluated after Android is released and stable.

---

## Roadmap

| Milestone | Phase | Status | Notes |
|---|---|---|---|
| M0–M12 | Core Django Training Platform | Complete | Core Django training platform, training workflows, assessments, certificates, playback, security foundations, and web portal completed. |
| M13 | Phase 1: API Foundation & Versioning | Complete | Versioned API foundation established under `/api/v1/`. |
| M13 | Phase 2: Mobile Authentication | Complete | JWT authentication, refresh/logout behavior, employee activity checks, ownership enforcement, and authentication security validation completed. |
| M13 | Phase 3: Employee Profile & Dashboard API | Complete | Employee-scoped profile/dashboard APIs completed with ownership/IDOR protections, deterministic behavior, and dashboard test coverage. |
| M13 | Phase 4: Application Shell & UI Foundation | Complete | Enterprise application shell, responsive navigation/sidebar, mobile drawer, accessibility foundations, redesigned login, and modernized Employee/Manager/Admin dashboards completed. |
| M13 | Phase 4 Step 5: Assignments & Learning API Foundation | Complete | JWT-authenticated assignments, assignment detail/curriculum APIs, learning progress, text completion, video playback sessions, protected media delivery, and ownership/authorization enforcement completed using existing server-authoritative learning/playback logic. |
| M14 | Flutter / Android Foundation | Planned | Establish Flutter project structure, Android configuration, API/client architecture, authentication/session handling, secure token storage, navigation, app shell, environment configuration, and staging integration. |
| M15 | Employee App Core | Planned | Employee profile, dashboard, assignments, curriculum, assignment status/progress, API integration, loading/empty/error states, and conservative offline/network handling. |
| M16 | Learning + Secure Video | Planned | Lesson experience, text learning, secure video playback, resume/progress synchronization, playback/session integration, network interruption recovery, lifecycle handling, anti-seek/anti-skip integration, and Android screen-capture protection where appropriate. |
| M17 | Assessment + Certificates | Planned | Assessment UI, question/answer flows, attempt handling, server-authoritative scoring, results, completion handling, and certificate access/display. |
| M18 | Notifications + Resilience | Planned | Notifications, retry/resilience behavior, network recovery, session/auth edge cases, foreground/background handling, production-oriented reliability, and operational observability. |
| M19 | Android Release Candidate | Planned | Feature freeze, comprehensive security/architecture/data/UX/performance audit, full regression, Android-specific QA, real-device testing, pilot testing, pilot fixes, final regression, and Android release. |

---

## M14: Flutter / Android Foundation

### Scope

- Flutter project structure
- Android application configuration
- API/client architecture
- Environment configuration
- JWT authentication integration
- Secure token/session storage
- Navigation
- Initial application shell
- API error handling foundation
- Loading/error state foundation
- Staging environment integration

### Required foundation work

Before deep mobile development begins:

- Production-like staging environment must exist.
- Staging must use MySQL.
- Representative seed/demo data must be available.
- Mobile API contracts must be documented/verified against the implemented backend.
- Android build/install/run workflow must be validated.
- At least one real Android device should be available for later testing.

---

## M15: Employee App Core

### Scope

- Employee profile
- Employee dashboard
- Assignments
- Assignment detail
- Training curriculum
- Assignment status
- Learning progress
- Loading states
- Empty states
- Error states
- Network/offline states
- API integration

The mobile client must consume the backend's authoritative state.

The mobile client must not independently determine:

- authorization
- assignment ownership
- completion
- progress authority
- assessment scoring
- certificate validity

---

## M16: Learning + Secure Video

### Scope

- Training lesson experience
- Text learning
- Video playback
- Playback sessions
- Heartbeats
- Resume behavior
- Progress synchronization
- Network interruption recovery
- Foreground/background lifecycle handling
- Anti-seek/anti-skip integration
- Secure media access
- Android `FLAG_SECURE` where appropriate

Existing server-authoritative playback and progress logic must be reused rather than duplicated in the mobile application.

### Required product decisions before deep implementation

Training version lifecycle must be explicitly defined, including:

- What happens to existing assignments when a training version is republished?
- Whether existing employees remain on the old version
- Whether progress can be carried forward
- Whether employees may finish an older version
- Assessment behavior across versions
- Certificate semantics across versions
- Version retirement behavior

Content/video management must also be defined:

- upload workflow
- storage
- validation
- processing
- replacement
- publishing/unpublishing

The web/backend side remains responsible for managing and publishing training content. The mobile application consumes the published content.

### Offline rule

V1 must not support unrestricted offline course completion.

Network recovery, retry, resume, and clear offline-state handling are supported, while authoritative completion remains server-controlled.

---

## M17: Assessment + Certificates

### Scope

- Assessment UI
- Question rendering
- Answer submission
- Attempt handling
- Pass/fail results
- Retry behavior
- Server-authoritative scoring
- Completion state
- Certificate access
- Certificate display

The mobile client must not reproduce authoritative assessment/scoring rules locally.

---

## M18: Notifications + Resilience

### Scope

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

Production deployment must include:

- environment/secrets management
- database backup verification
- deployment health checks
- rollback procedure
- versioned Android builds
- manual production approval

---

## M19: Android Release Candidate

M19 is the release-hardening milestone.

### Required activities

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
- Responsive/device testing
- UX/usability review
- Production deployment rehearsal
- Pilot deployment
- Employee pilot feedback
- Pilot fixes
- Final regression
- Release approval
- Android production release

### Release gate

Android must not be considered complete merely because the application builds.

Release requires:

- implementation complete
- automated tests passing
- security validation passing
- runtime/device QA passing
- no critical/blocking defects
- production/staging checks passing
- pilot completed
- final regression passing
- documentation updated
- roadmap checkpoint updated
- GitHub/CI checkpoint confirmed

---

## Phase Completion Rules

A phase must not be marked `Complete` merely because its code exists.

Before marking a phase `Complete`:

1. Implementation is complete.
2. Appropriate automated tests pass.
3. Security-sensitive behavior has been reviewed.
4. Runtime/browser/device QA has been completed where applicable.
5. No critical or blocking defects remain.
6. Documentation is updated.
7. `docs/ROADMAP.md` is updated.
8. The Git checkpoint is reviewed.
9. The required commit/push checkpoint is completed by the user.

If any required exit criterion is incomplete, the phase remains `In Progress`.

---

## Development Principles

- Backend remains authoritative for permissions, progress, scoring, completion, and security.
- Avoid unnecessary migrations.
- Avoid unnecessary architecture changes.
- Reuse existing server-authoritative playback/business logic.
- Do not duplicate business rules in the mobile client.
- Keep implementation tasks narrowly scoped.
- Do not add unrelated features during milestone work.
- Android is the current release target.
- iOS is deferred until Android is released and stable.
- Mobile development must not weaken existing web behavior.
- Security-sensitive, architectural, playback, and media changes require tighter review and regression testing.

---

## Documentation Responsibilities

`docs/ROADMAP.md` is the canonical product-development roadmap.

At each milestone checkpoint:

- completed phase → `Complete`
- active phase → `In Progress`
- blocked phase → `Blocked`
- future phase → `Planned`

Do not maintain manually duplicated completion percentages in the roadmap.

Project-agent instructions, model preferences, coding-agent workflow, and tool-specific instructions belong in `AGENTS.md` or appropriate development documentation rather than this roadmap.

---

## Current Next Step

**M14: Flutter / Android Foundation**

Before implementation expands beyond the foundation, validate:

- Flutter/Android toolchain
- Android build/install/run
- API connectivity
- JWT/session handling
- secure token storage
- navigation/app shell
- staging connectivity
- representative staging data

---

## Post-Android Scope

iOS is not part of the current Android release target.

After Android release and stabilization:

**Evaluate iOS → define iOS architecture/workflow → begin iOS development**