# Tasks and Roadmap

## 1. Purpose

This document tracks the current development roadmap, major work items, release gates, and milestone status for the Garden's Need Training Module Application.

The Excel roadmap remains the management tracker.

This file is the repository-side development roadmap.

## 2. Current Status

Current milestone:

```text
Milestone 11 - Documentation + Project Structure + CI
```

Current backend status:

```text
Core backend complete
```

Current automated test baseline:

```text
189 full tests passing on MySQL
```

Current project estimate:

```text
Approximately 70-75% complete
```

The application is still pre-release.

## 3. Current Priorities

Immediate priorities are:

1. Finish repository documentation.
2. Add GitHub Actions CI.
3. Verify CI against MySQL.
4. Preserve the 189-test backend baseline.
5. Begin Functional Frontend work after Milestone 11 closes.

## 4. Milestone Overview

```text
Milestone 0  - Project Setup & Foundation                    COMPLETE
Milestone 1  - Authentication & Organization                 COMPLETE
Milestone 2  - Training Content & Versioning                 COMPLETE
Milestone 3  - Training Assignments                          COMPLETE
Milestone 4  - Video Progress & Anti-Skip                    COMPLETE
Milestone 5  - Assessments & Scoring                         COMPLETE
Milestone 6  - Certificates                                  COMPLETE
Milestone 7  - Dashboards & Reports                          COMPLETE
Milestone 8  - Audit Logging & Backend Hardening             COMPLETE
Milestone 9  - Backend Cleanup & Simplification              COMPLETE
Milestone 10 - Security Hardening & Vulnerability Testing    COMPLETE
Milestone 11 - Documentation + Project Structure + CI        IN PROGRESS
Milestone 12 - Functional Frontend                           PLANNED
Milestone 13 - UX + Responsive + Accessibility               PLANNED
Milestone 14 - Full E2E + Integration Testing                PLANNED
Milestone 15 - Production + Deployment Hardening             PLANNED
Milestone 16 - Final Bug Hunt + Security + Repository Review PLANNED
Milestone 17 - Final Readability + Refactor Pass             PLANNED
Milestone 18 - Premium Visual Polish                         PLANNED
Milestone 19 - Final Acceptance + V1 Release                 PLANNED
```

## 5. Milestone 0 - Project Setup & Foundation

Status:

```text
COMPLETE
```

Completed work included:

- Django project creation
- application structure
- virtual environment
- MySQL setup
- environment configuration
- migrations
- superuser
- Git setup
- GitHub repository
- Django/MySQL compatibility resolution

Important decision:

```text
Django 5.2 LTS + MySQL 8
```

## 6. Milestone 1 - Authentication & Organization

Status:

```text
COMPLETE
```

Completed work included:

- login
- logout
- role groups
- permissions
- departments
- job roles
- employees
- recursive reporting hierarchy
- Manager scope
- Employee self-scope
- employee deactivation
- privileged-account protections
- direct URL authorization

Milestone test baseline:

```text
84 tests
```

## 7. Milestone 2 - Training Content & Versioning

Status:

```text
COMPLETE
```

Completed work included:

- Training
- TrainingVersion
- Module
- Lesson
- TEXT lessons
- VIDEO lessons
- ordering
- Draft / Published / Retired lifecycle
- publishing rules
- retirement rules
- published-content immutability
- final-assessment publishing requirement

Milestone test baseline:

```text
104 tests
```

## 8. Milestone 3 - Training Assignments

Status:

```text
COMPLETE
```

Completed work included:

- manual assignments
- role-based assignments
- due dates
- duplicate prevention
- assignment source
- historical snapshots
- Manager scope
- Employee visibility rules
- safe permission migration

Milestone test baseline:

```text
109 tests
```

## 9. Milestone 4 - Video Progress & Anti-Skip

Status:

```text
COMPLETE
```

Completed work included:

- resume endpoint
- start endpoint
- heartbeat endpoint
- end endpoint
- watched ranges
- progress persistence
- anti-skip logic
- idle-time protection
- session validation
- concurrency-safe locking

Important fixes included:

- reusable tolerance issue
- idle-time counting
- malformed session ID handling
- locking order

Milestone test baseline:

```text
127 tests
```

## 10. Milestone 5 - Assessments & Scoring

Status:

```text
COMPLETE
```

Completed work included:

- question bank
- question revisions
- answer options
- lesson quizzes
- final assessments
- attempts
- attempt limits
- prerequisites
- server-side scoring
- pass/fail
- assignment completion integration
- concurrency-safe assessment behavior

Milestone test baseline:

```text
150 tests
```

## 11. Milestone 6 - Certificates

Status:

```text
COMPLETE
```

Completed work included:

- automatic issuance
- unique certificate numbers
- issue timestamps
- employee snapshots
- training-version snapshots
- Employee access
- Administrator management
- Training Coordinator management
- revocation
- idempotent issuance

Milestone test baseline:

```text
154 tests
```

## 12. Milestone 7 - Dashboards & Reports

Status:

```text
COMPLETE
```

Completed work included:

- role-aware root dashboard
- Administrator metrics
- Training Coordinator metrics
- Manager subtree metrics
- Employee dashboard
- assignment reports
- overdue reporting
- completion percentage
- report filters
- filter scope protection

Milestone test baseline:

```text
159 tests
```

## 13. Milestone 8 - Audit Logging & Backend Hardening

Status:

```text
COMPLETE
```

Completed work included:

- central audit logging
- transaction-aware audit creation
- employee change events
- organization events
- training events
- assignment events
- assessment events
- certificate events
- completion events
- read-only audit interface
- Administrator audit access
- Training Coordinator audit access
- secret handling improvements
- malformed-input hardening

Milestone test baseline:

```text
164 tests
```

## 14. Milestone 9 - Backend Cleanup & Simplification

Status:

```text
COMPLETE
```

Completed work included:

- verified unused import removal
- unnecessary helper removal
- unused dependency cleanup
- backend simplification
- preservation of existing behavior

Deep readability refactoring was deliberately deferred.

Milestone test baseline:

```text
164 tests
```

## 15. Milestone 10 - Security Hardening & Vulnerability Testing

Status:

```text
COMPLETE
```

Completed work included:

- production secure-cookie defaults
- DEBUG fail-closed behavior
- playback metadata validation
- playback idle-gap hardening
- cross-session allowance hardening
- authentication review
- authorization review
- IDOR review
- assessment review
- certificate review
- reporting review
- audit review
- configuration hardening

Milestone test baseline:

```text
173 tests
```

## 16. Interim Backend Bug Hunt

Status:

```text
COMPLETE
```

This was completed after Milestone 10 and before Milestone 11.

It is not a separate numbered milestone.

Confirmed defects fixed included:

- repeated employee deactivation overwriting historical information
- duplicate deactivation success audit events
- due-today assignment timestamp ordering
- concurrent duplicate role assignment HTTP 500
- oversized due-period overflow
- Training save-time uniqueness race
- Question creation race continuing into revision creation

Each reproduced defect received regression coverage where practical.

Updated backend baseline:

```text
189 tests passing on MySQL
```

Verification passed:

```text
python manage.py test
python manage.py check
python manage.py makemigrations --check --dry-run
python -m pip check
git diff --check
```

## 17. Milestone 11 - Documentation + Project Structure + CI

Status:

```text
IN PROGRESS
```

### Documentation Tasks

Required root files:

```text
README.md
AGENTS.md
CHANGELOG.md
```

Required documentation files:

```text
docs/
├── PRD.md
├── ARCHITECTURE.md
├── DESIGN.md
├── TASKS.md
├── MEMORY.md
├── SECURITY.md
├── TESTING.md
└── DEPLOYMENT.md
```

### Current Documentation Progress

```text
README.md                COMPLETE
AGENTS.md                COMPLETE
CHANGELOG.md             COMPLETE
docs/PRD.md              COMPLETE
docs/ARCHITECTURE.md     COMPLETE
docs/SECURITY.md         COMPLETE
docs/TESTING.md          COMPLETE
docs/DEPLOYMENT.md       COMPLETE
docs/DESIGN.md           COMPLETE
docs/TASKS.md            IN PROGRESS
docs/MEMORY.md           PENDING
```

### CI Tasks

Still required:

```text
[ ] Create .github/workflows/ci.yml
[ ] Configure Python
[ ] Configure MySQL 8 service
[ ] Install dependencies
[ ] Run Django system check
[ ] Run migration consistency check
[ ] Run full MySQL test suite
[ ] Run pip check
[ ] Push workflow
[ ] Confirm GitHub Actions passes
```

### Milestone 11 Exit Criteria

Milestone 11 is complete only when:

```text
[ ] Required documentation exists
[ ] Documentation matches implemented behavior
[ ] No future feature is falsely described as implemented
[ ] GitHub Actions workflow exists
[ ] CI uses MySQL
[ ] CI passes
[ ] Full local test suite passes
[ ] Django check passes
[ ] Migration check passes
[ ] pip check passes
[ ] git diff --check passes
[ ] Changes reviewed
[ ] Stable changes committed and pushed
```

## 18. Milestone 12 - Functional Frontend

Status:

```text
PLANNED
```

Primary goal:

```text
Make the complete application usable through the browser.
```

Planned work includes:

- application shell
- navigation
- role-aware menus
- Administrator pages
- Training Coordinator pages
- Manager pages
- Employee pages
- organization forms
- training forms
- training version pages
- module pages
- lesson pages
- assignment pages
- video experience
- assessment experience
- certificate pages
- report pages
- audit pages
- validation feedback
- success/error messages

Architecture remains:

```text
Django Templates + HTML + CSS + basic JavaScript
```

Do not introduce React without an explicit architecture decision.

## 19. Milestone 13 - UX + Responsive + Accessibility

Status:

```text
PLANNED
```

Planned work includes:

- responsive layouts
- navigation improvements
- mobile behavior
- tablet behavior
- form usability
- error-state improvements
- empty states
- loading states
- training progress UI
- assessment usability
- video usability
- keyboard navigation
- visible focus states
- contrast review
- semantic HTML
- accessibility improvements

Playwright may begin being used heavily here.

## 20. Milestone 14 - Full E2E + Integration Testing

Status:

```text
PLANNED
```

Primary goal:

```text
Verify complete workflows through the browser.
```

Representative flows include:

```text
Administrator
-> Create Training
-> Create Version
-> Add Module
-> Add Lesson
-> Add Assessment
-> Publish
-> Assign Employee
```

and:

```text
Employee
-> Login
-> Open Assignment
-> Complete Lessons
-> Watch Video
-> Complete Quiz
-> Complete Final Assessment
-> Complete Training
-> Receive Certificate
```

Planned work includes:

- Playwright E2E tests
- role workflows
- direct URL tests
- negative authorization paths
- malformed browser flows
- browser integration bugs
- frontend/backend integration fixes

## 21. Milestone 15 - Production + Deployment Hardening

Status:

```text
PLANNED
```

Planned work includes:

- production environment selection
- production environment variables
- DEBUG=False verification
- secret management
- allowed hosts
- HTTPS
- secure cookies
- HSTS
- reverse proxy
- application server
- static files
- protected media
- database backups
- restore test
- operational logging
- smoke testing
- rollback procedure

## 22. Milestone 16 - Final Bug Hunt + Security + Repository Review

Status:

```text
PLANNED
```

This is the final broad technical review.

Planned work includes:

- whole-application bug hunt
- backend review
- frontend review
- E2E failure review
- authorization review
- IDOR review
- CSRF review
- session review
- cookie review
- playback review
- assessment review
- certificate review
- report review
- audit review
- dependency vulnerability scan
- secret scan
- migration review
- repository cleanup review
- TODO review
- debug artifact review

Strix or another authorized security tool may be used at this stage.

Automated findings must be reviewed manually.

Do not blindly apply generated security patches.

## 23. Milestone 17 - Final Readability + Refactor Pass

Status:

```text
PLANNED
```

Primary goal:

```text
Improve code readability without changing behavior.
```

Work should be done one important file at a time.

Focus areas:

- compressed logic
- unclear naming
- overly dense forms
- overly dense views
- repeated local patterns
- unnecessary complexity
- proven dead code

Code should favor readable formatting such as:

```python
actor = forms.ModelChoiceField(
    queryset=get_user_model().objects.none(),
    required=False,
    label="Performed By",
)
```

rather than compressed equivalents.

After each refactor:

- run focused tests
- preserve behavior
- run full suite where appropriate

## 24. Milestone 18 - Premium Visual Polish

Status:

```text
PLANNED
```

Primary goal:

```text
Make the application feel like a finished Garden's Need product.
```

Visual direction:

- deep forest green
- ivory / white
- charcoal
- restrained brass accents

Planned work includes:

- typography
- exact colors
- navigation styling
- cards
- tables
- forms
- dashboards
- badges
- progress indicators
- spacing
- responsiveness
- polish
- consistent interaction states

No backend business-logic changes should be introduced during this pass unless a genuine bug is discovered.

## 25. Milestone 19 - Final Acceptance + V1 Release

Status:

```text
PLANNED
```

Final tasks include:

- final automated test run
- final CI verification
- final Playwright run
- final browser smoke test
- final responsive review
- final security review confirmation
- production configuration confirmation
- documentation review
- README setup test
- Git status review
- release commit
- version tag
- deployment
- post-deployment smoke test
- V1 sign-off

## 26. V1 Release Gates

V1 must not be considered ready until all major release gates pass.

### Functional Gate

```text
[ ] Required workflows work end-to-end
```

### Automated Testing Gate

```text
[ ] Full automated suite passes
[ ] CI passes
```

### E2E Gate

```text
[ ] Important Playwright flows pass
```

### Security Gate

```text
[ ] Final security review complete
[ ] No known exploitable critical/high-severity issue remains
```

### Bug Quality Gate

```text
[ ] No known important reproducible release-blocking bug remains unresolved
```

### Deployment Gate

```text
[ ] Production configuration verified
[ ] HTTPS verified
[ ] Secure cookies verified
[ ] Backup strategy verified
[ ] Smoke test passes
```

### Documentation Gate

```text
[ ] README accurate
[ ] Architecture accurate
[ ] Security documentation accurate
[ ] Testing documentation accurate
[ ] Deployment documentation accurate
```

### Visual Gate

```text
[ ] Final premium visual pass complete
[ ] Responsive review complete
[ ] Accessibility review complete
```

## 27. Current Blockers

Current known blocker:

```text
None
```

Milestone 11 can proceed normally.

If a blocker appears, record:

- issue
- affected milestone
- impact
- temporary workaround
- required decision

## 28. Deferred Work

The following work is intentionally deferred and should not interrupt current V1 development unless priorities change:

- skill matrix
- practical assessment
- supervisor verification
- machine certification
- QR verification
- notifications
- multilingual support
- AI knowledge assistant
- retrieval-augmented knowledge
- native mobile application
- native Android screen-capture protection
- advanced workforce analytics

## 29. Tooling Plan

Current development tools include:

- VS Code
- Git
- GitHub
- GitHub Copilot
- Codex
- Context7
- Playwright

Potential later tools:

### Context7

Use when current framework or library documentation is needed.

### Playwright

Primary use:

```text
Milestones 13-14
```

### Strix

Potential use:

```text
Milestone 16
```

for authorized final security testing.

### GitBook

Optional.

Repository Markdown remains the source of truth.

### Linear

Optional if the bug/feature backlog becomes difficult to manage.

## 30. Development Workflow

Preferred workflow:

```text
Inspect
-> Plan
-> Implement
-> Focused Tests
-> Broader Tests
-> Full MySQL Suite
-> Django Check
-> Migration Check
-> pip Check
-> Diff Check
-> Live Test if useful
-> Review
-> Commit
-> Push
```

Do not commit unstable work.

## 31. Current Baseline to Protect

Before starting a major new milestone, preserve this current backend baseline:

```text
189 full tests passing on MySQL
```

If future work adds tests, the latest verified passing count becomes the new baseline.

A decrease in test count should be investigated unless tests were deliberately and correctly removed.

## 32. Current Next Action

Current immediate action:

```text
Finish Milestone 11 documentation.
```

After documentation:

```text
Create GitHub Actions CI.
```

After CI passes:

```text
Close Milestone 11.
```

Then begin:

```text
Milestone 12 - Functional Frontend
```