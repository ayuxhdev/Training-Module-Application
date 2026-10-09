# Garden’s Need Training Module Application Roadmap

## Current Status

The Garden’s Need Training Module Application has completed **M15: Employee App Core**.

The current next milestone is:

**M16: Learning + Secure Video**

The project follows an Android-first development strategy:

**Backend/Web Foundation → Mobile API Foundation → Android Foundation → Employee App Core → Learning/Playback → Assessments/Certificates → Resilience/Operations → Android Release Candidate → Production/Deployment Hardening → Final Review → Visual Polish → Final Acceptance & Android V1 Release**

iOS is intentionally outside the current Android V1 completion target. It will be evaluated after Android V1 is released and stabilized.

---

## Roadmap

| Milestone | Phase | Status | Notes |
|---|---|---|---|
| M0–M12 | Core Django Training Platform | Complete | Core Django training platform, training workflows, assignments, secure playback, assessments, certificates, dashboards, audit logging, security foundations, and web portal completed. |
| M13 | Mobile API Foundation & Versioning | Complete | Versioned API foundation established under `/api/v1/`, including authentication, employee-scoped APIs, assignments, learning progress, playback sessions, protected media delivery, and ownership/authorization enforcement. |
| M14 | Flutter / Android Foundation | Complete | Flutter Android application foundation completed, including project structure, API/client architecture, secure authentication/session handling, navigation, application shell, reusable UI foundation, dashboard, profile, environment configuration, and Android build integration. |
| M15 | Employee App Core | Complete | Employee dashboard/profile integration, assignments, assignment detail, curriculum navigation, lesson navigation, text lesson completion, learning progress, previous/next navigation, and end-to-end learning-flow integration completed. |
| M16 | Learning + Secure Video | Next | Protected video playback, playback sessions, progress synchronization, resume behavior, lifecycle handling, network recovery, anti-seek/anti-skip integration, and Android screen-capture protection where appropriate. |
| M17 | Assessment + Certificates | Planned | Mobile assessment experience, attempt handling, server-authoritative scoring, results, completion state, and certificate access/display. |
| M18 | Notifications + Resilience | Planned | Notifications, authentication/session resilience, network recovery, lifecycle reliability, operational observability, and production-oriented reliability. |
| M19 | Android Release Candidate | Planned | Feature freeze and comprehensive security, architecture, data, playback, performance, device, UX, and regression validation, followed by pilot testing and release preparation. |
| M20 | Production + Deployment Hardening | Planned | Production deployment readiness, infrastructure/configuration hardening, secrets/environment management, backups, monitoring, rollback procedures, release automation, and operational readiness. |
| M21 | Final Bug Hunt + Security + Repository Review | Planned | Final cross-system defect hunt, security review, permission/IDOR review, dependency review, repository hygiene, documentation verification, and release-blocker elimination. |
| M22 | Final Readability + Refactor + Garden’s Need Visual Polish | Planned | Targeted maintainability improvements, removal of unnecessary technical debt, final UI/UX refinement, animation, interaction polish, accessibility refinement, and Garden’s Need visual identity integration. |
| M23 | Final Acceptance + Android V1 Release | Planned | Final acceptance testing, release gate verification, production approval, Android V1 release, post-release verification, and final project checkpoint. |

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

M22 is the deliberate final product-polish phase.

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

# Current Next Step

**M16: Learning + Secure Video**

Before and during M16 implementation, verify:

- existing M13 playback API contracts
- protected session-based media access
- published media immutability
- training-version pinning
- playback session lifecycle
- progress/heartbeat behavior
- Flutter video architecture
- Android lifecycle behavior
- network interruption recovery
- screen-capture protection requirements
- risk-based Android playback QA

Do not introduce a parallel media API or duplicate backend playback authority.

---

# Post-Android Scope

iOS is not part of the current Android V1 release target.

After Android V1 has been released and stabilized:

**Evaluate iOS → define iOS architecture/workflow → establish iOS roadmap → begin iOS development**