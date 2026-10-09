# Tasks and Roadmap

## 1. Purpose

This document tracks repository-level development tasks, milestone work, validation requirements, and release gates for the Garden's Need Training Module Application.

`docs/ROADMAP.md` is the canonical milestone roadmap.

This file provides the practical task-level view of that roadmap.

The Excel roadmap may remain the management tracker, but it must not override the repository's actual implementation state.

---

## 2. Current Status

Current milestone:

```text
M16 - Learning + Secure Video
```

Completed milestones:

```text
M0–M13 - Core Platform + Mobile API Foundation
M14    - Flutter / Android Foundation
M15    - Employee App Core
```

Current application state:

```text
Backend/Web platform: Complete
Mobile API foundation: Complete
Flutter/Android foundation: Complete
Employee learning foundation: Complete
Secure video learning: Next
```

Current verified automated baseline:

```text
Django/MySQL: 348 tests passing
Flutter: 81 tests passing
JavaScript playback tests: 3 tests passing
```

Additional verified checks include:

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
M16    - Learning + Secure Video              NEXT
M17    - Assessment + Certificates             PLANNED
M18    - Notifications + Resilience            PLANNED
M19    - Android Release Candidate             PLANNED
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
NEXT
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
PLANNED
```

## Tasks

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
PLANNED
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

---

# 11. M19 - Android Release Candidate

Status:

```text
PLANNED
```

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
M16 - Learning + Secure Video
```

Immediate priorities:

```text
1. Verify existing M13 playback contracts.
2. Verify protected session-based media access.
3. Verify training-version and media immutability rules.
4. Build Flutter VIDEO lesson playback.
5. Integrate playback sessions.
6. Integrate progress and heartbeats.
7. Integrate resume behavior.
8. Handle network and lifecycle recovery.
9. Preserve backend anti-seek/anti-skip authority.
10. Apply appropriate Android screen-capture protection.
11. Run focused playback QA.
12. Run full regression.
```

No M17, M18, M19, M20, M21, M22, or M23 implementation should begin merely because those milestones are documented.

The project should progress sequentially through the roadmap, with each milestone passing its exit criteria before the next milestone becomes active.