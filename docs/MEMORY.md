# Project Memory

## 1. Purpose

This document stores durable technical decisions, important implementation lessons, significant bug history, and architectural rationale for the Garden's Need Training Module Application.

This is not:

- a chat transcript
- a task log
- a place for secrets
- a substitute for source code
- a substitute for Git history

Use this file to preserve information that future developers or coding agents may need in order to avoid repeating old mistakes.

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
Django monolith
Python 3.14
Django 5.2 LTS
MySQL 8
Django templates
HTML
CSS
Basic JavaScript
```

Current backend baseline:

```text
189 full tests passing on MySQL
```

## 3. Core Architectural Decision

V1 uses a Django monolith.

Do not introduce:

- React
- a separate SPA
- microservices
- a separate API architecture

without an explicit architectural decision.

The current architecture is intentionally simple.

Reasons include:

- small development team
- lower operational complexity
- easier authorization
- easier deployment
- faster V1 development
- easier debugging
- fewer moving parts

## 4. Django Version Decision

The project uses:

```text
Django 5.2 LTS
```

An earlier Django 6.x setup conflicted with the project's MySQL 8.0 environment.

The project was moved to Django 5.2 LTS for compatibility and stability.

Do not casually upgrade Django without verifying:

- MySQL compatibility
- dependency compatibility
- migrations
- test suite
- deployment implications

## 5. Database Decision

The project uses:

```text
MySQL 8
```

Development and automated backend testing use MySQL.

Do not switch the main test suite to SQLite merely for convenience.

Important behavior already depends on realistic handling of:

- transactions
- uniqueness
- locking
- date/time behavior
- constraints
- concurrency

## 6. User Model Decision

The application uses Django's built-in User model.

Do not introduce a custom User model unless there is a strong future requirement.

Employee-specific business data belongs in:

```text
Employee
```

rather than replacing the authentication model.

## 7. Backend Authority Rule

The backend is authoritative for security-sensitive state.

Never trust the browser for:

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

Frontend controls improve usability only.

They do not replace backend authorization.

## 8. Role Model

Current role groups:

```text
Administrator
Training Coordinator
Manager
Trainer
Supervisor
Employee
```

Role names alone should not be treated as the whole authorization model.

Use actual:

- permissions
- ownership
- scope
- object state

when making security decisions.

## 9. Manager Scope Decision

Managers are restricted to their recursive reporting subtree.

This includes descendants, not only direct reports.

The correct pattern is:

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

## 10. Employee Scope Decision

Employees should generally operate on their own records.

Where possible, ownership should be derived from:

```text
request.user
-> Employee
-> owned objects
```

Do not trust an arbitrary employee ID from the browser when the backend can derive ownership directly.

## 11. Historical Data Principle

The application preserves historical facts.

Examples include:

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

## 12. Training Versioning Decision

Training follows:

```text
Training
└── TrainingVersion
    └── Module
        └── Lesson
```

TrainingVersion states:

```text
DRAFT
PUBLISHED
RETIRED
```

Important rationale:

A completed employee record must continue to reference the training version that was actually completed.

New edits should not rewrite historical training.

## 13. Published Content Rule

Published and retired training content must remain protected from unsafe editing.

Do not loosen this rule to simplify forms or frontend development.

If changes are needed after publication, versioning is the intended mechanism.

## 14. Publishing Rule

Publishing requires valid training structure.

A valid final assessment is required according to the current backend publishing rules.

Do not bypass publishing validation from:

- admin UI
- direct URL
- custom frontend
- scripts

without intentionally changing the product rule.

## 15. State-Changing Request Rule

Mutating actions should not use GET.

Examples include:

- employee deactivation
- training publishing
- training retirement
- certificate revocation
- assignment creation

Use POST or another appropriate mutation method.

## 16. Permission Migration Rule

Permission migrations should remain:

- additive
- non-destructive

Preferred pattern:

```python
group.permissions.add(permission)
```

Avoid:

- clearing permission sets
- deleting unrelated permissions
- destructive reverse migrations

Where reversal could damage legitimate production permissions, a no-op reverse migration may be safer.

## 17. Employee Deactivation Decision

Employees are deactivated rather than casually deleted.

Historical relationships must remain intact.

Important regression:

Repeated deactivation previously:

- returned success again
- overwrote the original deactivation reason
- created another success audit event

The fix:

- locks the Employee row
- detects already-inactive state
- returns HTTP 409
- preserves original history

Do not reintroduce repeated-success behavior.

## 18. Assignment Timestamp Lesson

A role assignment with:

```text
due_in_days = 0
```

previously failed because:

- `due_at` was calculated first
- `assigned_at` was generated later
- `due_at` could become slightly earlier than `assigned_at`

This violated validation/database expectations.

The fix uses one authoritative timestamp for both calculations.

Lesson:

When two persisted timestamps must have a defined relationship, derive them from the same base timestamp.

## 19. Role Assignment Race Lesson

Role-based batch assignment originally:

1. checked existing assignments
2. attempted creation

A concurrent request could create the assignment between those two steps.

This could cause an uncaught validation/uniqueness error and HTTP 500.

Current behavior:

- detects the conflict
- verifies whether the exact Employee/TrainingVersion assignment now exists
- treats only that case as a skipped duplicate
- allows unrelated validation errors to surface

Do not broadly suppress:

```text
ValidationError
IntegrityError
```

without checking the real cause.

## 20. Due-Period Overflow Lesson

A valid stored role requirement could contain a due period large enough to exceed Python's datetime range.

This caused:

```text
OverflowError
```

and HTTP 500.

Current behavior validates the due period before creating assignments.

Lesson:

Model-valid integers are not automatically safe for date arithmetic.

## 21. Training Creation Race Lesson

A Training may pass form validation and still encounter a uniqueness conflict at save time because of concurrency.

Previously this could return HTTP 500.

Current behavior converts expected save-time uniqueness/validation conflicts into form errors.

Important:

A success audit event must not be recorded when the save did not succeed.

## 22. Question Creation Race Lesson

Question creation may also fail at save time after form validation.

Previously, revision creation could continue even though the Question was not successfully saved.

Current behavior:

```text
Question save fails
-> form receives error
-> revision creation stops
```

Lesson:

Dependent writes must never continue after the parent creation fails.

## 23. Concurrency Strategy

Use combinations of:

```text
transaction.atomic
select_for_update
database uniqueness
validation
specific conflict handling
```

where correctness depends on concurrent state.

Do not add locking automatically everywhere.

Use it where a demonstrated or plausible race affects:

- security
- data integrity
- idempotency
- lifecycle state

## 24. Lock Ordering Lesson

Video progress previously required corrections to locking order.

Current approach prefers consistent parent-first locking.

Conceptual order:

```text
Employee
-> TrainingVersion
-> Assignment / Progress / Session
```

Avoid changing locking order casually.

Inconsistent lock ordering may increase deadlock risk.

## 25. Video Progress Authority

Video completion is server-authoritative.

The client sends observations.

The server decides:

- valid watched ranges
- valid progression
- completion

Never trust the client to send:

```text
completed = true
```

as an authoritative decision.

## 26. Video Idle-Time Vulnerability

A serious playback bug was found during security hardening.

Previous behavior allowed idle time between requests to be converted into valid playback credit.

A user could potentially manufacture video completion without actually watching the required duration.

The fix:

- rejects playback credit across excessive idle gaps
- prevents idle time from replenishing playback allowance
- shares relevant observation allowance across sessions

Current expected playback heartbeat frequency should remain comfortably below the idle threshold.

Frontend target:

```text
approximately every 10-15 seconds
```

Current server idle boundary is stricter than long inactive gaps.

Do not weaken this security logic merely to simplify frontend heartbeat code.

## 27. Playback Session Lesson

Creating new video sessions must not regenerate unlimited progress tolerance.

Cross-session state matters.

A client must not be able to gain additional fake watch credit simply by repeatedly creating sessions.

## 28. Playback Metadata Rule

Session/device metadata must remain bounded strings.

Do not blindly stringify:

- arrays
- objects
- arbitrary structured payloads

Malformed playback metadata should return controlled client errors.

## 29. Assessment Authority

Assessment scoring is server-side.

The client must never decide:

- correct answer
- score
- pass
- fail
- authoritative completion

The backend calculates results using stored question revisions and answers.

## 30. Question Revision Rationale

Question revisions preserve historical assessment consistency.

A historical attempt should not silently change meaning because the current Question was edited later.

Do not replace revision-based history with a direct mutable Question reference without redesigning the assessment history model.

## 31. Assessment Attempt Rule

Attempt creation must enforce:

- ownership
- prerequisites
- attempt limits
- assessment eligibility

Concurrency around attempt creation must remain safe.

## 32. Certificate Issuance Decision

Certificate issuance is automatic after authoritative completion when requirements are satisfied.

Certificate issuance is idempotent.

Repeated completion processing should return or preserve the existing certificate rather than creating duplicates.

## 33. Certificate Revocation Decision

Revocation does not delete the certificate.

A revoked certificate remains a historical record.

Preserve:

- certificate identifier
- issue information
- snapshots
- revocation state

## 34. Audit Architecture Decision

Audit events use server-derived:

- actor
- target
- timestamp
- event type

The client must never become authoritative for these values.

## 35. Audit Commit Rule

Important success events are recorded after the related business transaction commits.

Current design uses transaction commit hooks where appropriate.

This prevents:

```text
business action rolled back
+
success audit event persisted
```

## 36. Robust Audit Logging Decision

Audit logging is intentionally configured so that an audit-write failure does not necessarily undo an already-successful business transaction.

This is a deliberate tradeoff.

Do not change this behavior without considering:

- data integrity
- operational impact
- audit guarantees

## 37. Audit Metadata Rule

Do not store unnecessary sensitive data.

Avoid audit metadata containing:

- passwords
- tokens
- secrets
- assessment answers
- complete training text
- unnecessary private information

Only store useful, controlled metadata.

## 38. Audit UI Terminology

Backend model field:

```text
actor
```

Visible UI terminology:

```text
Performed By
```

Do not rename the backend field merely to match the UI label unless there is a real schema reason.

## 39. Reports Scope Rule

Reports must start from an authorized queryset.

Then apply filters.

This applies especially to Manager reports.

A crafted filter value must never widen the underlying authorization scope.

## 40. Empty Live Data Lesson

Several live tests were partially limited because the development database contained no published training or assignments.

Do not create fake long-lived development records merely to make a manual test look more complete unless useful.

Automated tests should create controlled test data.

## 41. Production DEBUG Decision

Production DEBUG defaults to:

```text
False
```

This was intentionally changed during security hardening.

Local development must explicitly use:

```env
DEBUG=true
```

Do not restore an unsafe default of DEBUG=True.

## 42. Secret Key Decision

No committed fallback Django secret should exist.

When DEBUG is disabled, production requires explicit:

```text
DJANGO_SECRET_KEY
```

Failing closed is intentional.

## 43. Secure Cookie Decision

When DEBUG is disabled, production security defaults should use secure:

- session cookies
- CSRF cookies

Do not disable secure-cookie defaults to work around an HTTPS deployment problem.

Fix the deployment environment instead.

## 44. HTTPS and HSTS Decision

Final values for:

- SSL redirect
- HSTS
- proxy HTTPS configuration

should be chosen during the real deployment milestone.

Do not invent final production values before the hosting architecture is known.

## 45. Media Security Boundary

Internal training video may require protected delivery.

Potential future V1 deployment approaches include:

- authenticated media routes
- signed URLs
- protected reverse-proxy delivery
- temporary playback authorization

Do not claim a specific media-security implementation exists until it is built and verified.

## 46. Browser Capture Boundary

A browser application cannot guarantee prevention of:

- screenshots
- OS-level screen recording
- external camera capture

Web security can reduce casual misuse but cannot provide absolute prevention.

Native Android security features may be considered later if capture prevention becomes a stronger requirement.

## 47. Readability Decision

The project deliberately postponed the deep readability/refactor pass until late in V1.

Reason:

Doing a major cleanup while functionality is still changing creates unnecessary churn.

Current approach:

- keep new code readable
- make small local readability improvements
- defer broad restructuring to Milestone 17

## 48. Preferred Code Style

Prefer open formatting.

Example:

```python
actor = forms.ModelChoiceField(
    queryset=get_user_model().objects.none(),
    required=False,
    label="Performed By",
)
```

Avoid dense one-line code when expanded formatting improves readability.

## 49. Dependency Philosophy

Prefer:

1. Django built-ins
2. Python standard library
3. existing project packages
4. new dependencies only when justified

Every new package creates:

- maintenance cost
- security surface
- compatibility risk

Do not add dependencies merely to save a few lines of code.

## 50. Testing Philosophy

Confirmed defects should receive regression tests whenever practical.

Preferred bug-fix process:

```text
Reproduce
-> Write failing test
-> Narrow fix
-> Focused tests
-> Broader tests
-> Full MySQL suite
```

## 51. Current Test History

Important milestone test baselines:

```text
Milestone 1  -> 84
Milestone 2  -> 104
Milestone 3  -> 109
Milestone 4  -> 127
Milestone 5  -> 150
Milestone 6  -> 154
Milestone 7  -> 159
Milestone 8  -> 164
Milestone 9  -> 164
Milestone 10 -> 173
```

Interim backend bug hunt:

```text
189 tests passing on MySQL
```

The 189 count is the starting baseline for Milestone 11.

It is not the Milestone 11 closing test count.

## 52. Verification Standard

Important backend work should normally finish with:

```powershell
python manage.py test
python manage.py check
python manage.py makemigrations --check --dry-run
python -m pip check
git diff --check
```

Review:

```powershell
git status --short
```

before commit.

## 53. Live Testing Rule

Automated tests are not the only validation.

Live browser testing is useful for:

- user flows
- navigation
- visible errors
- forms
- deployment behavior

However:

A manual live test is not a replacement for a regression test when a backend bug has been reproduced.

## 54. Git Workflow

Preferred sequence:

```text
Implement
-> Test
-> Review
-> Live test when useful
-> Commit
-> Push
```

Do not push unstable changes.

Take a stable commit before beginning risky work.

## 55. CI Decision

GitHub Actions CI is part of Milestone 11.

CI should use MySQL.

Do not use SQLite in CI just to simplify the workflow.

Minimum CI goals:

```text
install dependencies
MySQL 8
manage.py check
migration check
full test suite
pip check
```

## 56. Frontend Decision

The V1 frontend remains:

```text
Django Templates
HTML
CSS
Basic JavaScript
```

Do not introduce React automatically.

The main reason is that the current product does not need the extra architectural complexity.

## 57. Frontend Development Order

The frontend is deliberately staged.

### Milestone 12

```text
Functionality
```

Make every required user flow usable.

### Milestone 13

```text
Usability + responsiveness + accessibility
```

Improve interaction quality.

### Milestone 18

```text
Premium visual polish
```

Apply final brand treatment.

This avoids rebuilding polished UI while functionality is still changing.

## 58. Design Direction

Current intended visual direction:

```text
Deep forest green
Ivory / white
Charcoal
Restrained brass
```

Desired character:

```text
professional
calm
premium
practical
```

Avoid excessive decorative styling.

## 59. Playwright Timing

Playwright is installed but should become a major tool during:

```text
Milestone 13
Milestone 14
```

Use it for:

- browser flows
- responsive testing
- direct URL testing
- role isolation
- E2E workflows

Do not distract current documentation work with premature E2E setup.

## 60. Context7 Timing

Context7 is available for current framework/library documentation.

Use it when:

- Django behavior may have changed
- GitHub Actions syntax needs current confirmation
- third-party library documentation is needed

Do not use it for facts already clearly established by the current codebase.

## 61. Strix Timing

Strix is reserved for the final major security review.

Target milestone:

```text
Milestone 16
```

Use it only against authorized:

- local
- staging
- owned environments

Automated findings must be reviewed.

Do not blindly apply security-agent patches.

## 62. GitBook Decision

GitBook is optional.

Repository Markdown remains the source of truth.

GitBook may later provide a nicer documentation surface, but it should not become a second conflicting documentation source.

## 63. Linear Decision

Linear is optional.

Use it only if the backlog becomes large enough that repository tasks and the Excel roadmap are no longer sufficient.

Do not add project-management overhead before it provides real value.

## 64. OmniRoute Decision

OmniRoute is optional backup tooling.

It is not required for the application architecture.

Do not block development milestones on OmniRoute configuration.

Use it only if it provides useful additional model capacity without consuming significant setup time.

## 65. Full Bug Hunt Timing

A comprehensive whole-application bug hunt is intentionally deferred until after:

- frontend completion
- browser testing
- E2E integration

Reason:

A final bug hunt is more valuable against the complete product.

Avoid performing the same comprehensive review twice unless a specific current risk justifies it.

## 66. Final Security Review Timing

The final broad security review is scheduled for:

```text
Milestone 16
```

It should review the completed system including:

- backend
- frontend
- browser flows
- dependencies
- secrets
- repository
- deployment configuration

## 67. Final Readability Timing

Deep readability/refactor work belongs in:

```text
Milestone 17
```

Work one important file at a time.

Preserve behavior.

Run tests after each meaningful refactor.

## 68. Premium Polish Timing

Premium visual styling belongs in:

```text
Milestone 18
```

Do not mix major backend logic changes into that milestone.

If a genuine bug is discovered during visual work, fix it separately and test it.

## 69. V1 Release Standard

V1 should not release until:

```text
functional flows complete
automated tests pass
CI passes
E2E tests pass
deployment is secure
final bug hunt complete
final security review complete
documentation accurate
premium visual pass complete
final acceptance passes
```

## 70. Future Scope

Future versions may add:

- skill matrix
- practical assessments
- supervisor verification
- machine certifications
- QR verification
- notifications
- multilingual content
- AI knowledge assistant
- RAG over internal factory knowledge
- native mobile application
- stronger mobile capture protections

These are not implemented V1 features.

## 71. Long-Term Product Direction

A possible future hierarchy is:

```text
Company
└── Department
    └── Role
        └── Training Path
            └── Training
                └── Training Version
                    └── Module
                        └── Lesson
                            └── Quiz
                                └── Final Assessment
                                    └── Practical Assessment
                                        └── Certification
                                            └── Skill Level
```

This is product direction only.

It does not describe the complete current database schema.

## 72. Documentation Rule

When documentation and code disagree:

```text
Inspect the current implementation.
```

Do not automatically assume documentation is correct.

Update documentation when implementation intentionally changes.

Do not silently change production behavior just to make it match stale documentation.

## 73. Memory Maintenance Rule

Add information to this file only when it is likely to matter later.

Good candidates:

- important architecture decisions
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

## 74. Current Project State

At the time this document was created:

```text
Milestones 0-10: complete
Interim backend bug hunt: complete
Milestone 11: in progress
Backend baseline: 189 tests passing on MySQL
CI: pending
Functional frontend: next major milestone
Production deployment: pending
V1 release: pending
```

## 75. Current Next Step

Immediate next step after documentation:

```text
Add GitHub Actions CI.
```

After CI is verified:

```text
Close Milestone 11.
```

Then begin:

```text
Milestone 12 - Functional Frontend
```