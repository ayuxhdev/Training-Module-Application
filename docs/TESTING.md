# Testing

## 1. Purpose

This document defines the testing strategy for the Garden's Need Training Module Application.

Testing is part of implementation, not a separate cleanup phase.

The project verifies:

- business behavior
- authorization boundaries
- ownership rules
- data integrity
- lifecycle transitions
- concurrency-sensitive behavior
- malformed-input handling
- regression safety
- browser workflows
- mobile workflows
- production readiness
- security-sensitive behavior

Testing should be risk-based. High-risk changes receive deeper validation than cosmetic or low-risk changes.

---

## 2. Current Test Baseline

Current verified baseline:

```text
Django/MySQL: 348 / 348 passing
Flutter: 81 / 81 passing
Flutter analyze: 0 issues
JavaScript playback: 3 / 3 passing
```

The backend suite runs against MySQL rather than SQLite.

The Flutter suite validates the Android client foundation and employee learning flow implemented through M15.

The JavaScript tests cover the existing web playback behavior.

---

## 3. Testing Stack

Current testing tools include:

- Django built-in test framework
- MySQL 8
- Django test client
- Python assertions
- Flutter test framework
- Flutter analyzer
- JavaScript playback tests
- GitHub Actions CI

Planned or later-stage validation includes:

- Android runtime testing
- Playwright browser workflows where applicable
- production-like staging tests
- deployment smoke tests
- security-focused testing
- dependency vulnerability scanning
- final acceptance testing

---

## 4. Database Strategy

Backend automated tests must continue to run against MySQL.

Do not switch the main backend suite to SQLite merely for convenience.

MySQL exercises behavior closer to the real application, including:

- constraints
- transactions
- locking
- uniqueness
- date and time behavior
- concurrency-sensitive behavior

---

## 5. Main Verification Commands

Backend:

```powershell
python manage.py test
python manage.py check
python manage.py makemigrations --check --dry-run
python -m pip check
git diff --check
```

Repository state:

```powershell
git status --short
```

Flutter:

```powershell
flutter analyze
flutter test
```

JavaScript playback tests should be run when playback-related code changes.

---

## 6. Unit and Component Testing

Focused tests should cover individual business behaviors such as:

- form validation
- model validation
- permission helpers
- lifecycle rules
- assignment logic
- scoring
- certificate issuance
- certificate revocation
- playback validation
- API serialization
- API authentication

Tests should remain focused enough to identify the source of a failure.

---

## 7. View and API Testing

View and API tests should verify:

- authentication requirements
- authorization
- ownership
- Manager scope
- request validation
- HTTP status codes
- malformed requests
- state transitions
- error responses
- direct URL protection
- API-specific permission boundaries

A successful response is not sufficient if the underlying authorization boundary is incorrect.

---

## 8. Integration Testing

Integration tests verify behavior across multiple components.

Important workflows include:

```text
Employee
-> Assignment
-> Module
-> Lesson
-> Progress
-> Assessment
-> Completion
-> Certificate
```

For mobile:

```text
Login
-> Dashboard
-> Assignment
-> Training
-> Module
-> Lesson
-> Completion / Progress
```

Video integration must additionally verify the protected session-based media flow.

---

## 9. Regression Testing

Every confirmed defect should receive regression coverage when practical.

Preferred process:

```text
Reproduce
-> Write failing test
-> Confirm failure
-> Implement narrow fix
-> Focused validation
-> Broader validation
-> Full suite
```

Regression tests should remain unless the related behavior is intentionally removed.

---

## 10. Security Testing

Security-sensitive features require positive and negative tests.

Important areas include:

- authentication
- JWT/API authentication
- authorization
- object ownership
- Manager scope
- Employee self-scope
- direct URL access
- CSRF-sensitive mutations
- assessment scoring
- video progress
- protected media access
- certificate access
- reporting
- audit logs
- malformed input
- session behavior

Tests should verify both what users can do and what they cannot do.

---

## 11. Authorization Tests

Representative roles include:

```text
Administrator
Training Coordinator
Manager
Trainer
Supervisor
Employee
Anonymous user
```

Tests should verify:

- permitted actions succeed
- unauthorized actions fail
- direct URLs cannot bypass authorization
- crafted identifiers do not broaden access
- filters do not broaden scope
- API and web authorization remain aligned

---

## 12. Manager Scope Testing

Manager authorization must follow the recursive reporting hierarchy.

Test:

- direct reports
- nested reports
- employees outside the hierarchy
- crafted employee IDs
- crafted department filters
- crafted role filters
- report filters
- dashboard filters
- API object access

A Manager must never gain access outside the authorized reporting subtree.

---

## 13. Employee Scope Testing

Employees should be restricted to their own records.

Test:

- own assignments
- own progress
- own assessment attempts
- own certificates
- own training data

Negative tests must verify that an Employee cannot access another Employee's records through:

- direct URLs
- IDs
- query parameters
- API paths
- manipulated client state

---

## 14. Training Lifecycle Testing

Training versions follow:

```text
DRAFT
PUBLISHED
RETIRED
```

Test:

- valid publishing
- invalid publishing
- required final assessment structure
- published content immutability
- retired content immutability
- retirement
- repeated lifecycle actions
- direct URL mutation attempts
- new assignment behavior
- existing assignment behavior

Published versions must remain immutable.

---

## 15. Assignment Testing

Assignment tests should cover:

- manual assignment
- role-based assignment
- published-version requirements
- employee eligibility
- duplicate prevention
- due dates
- assignment source
- historical snapshots
- Manager scope
- concurrency

Important regression cases include:

- zero-day due periods
- concurrent duplicate assignment creation
- uniqueness races
- extremely large due periods
- empty role-assignment batches

Assignments remain pinned to their assigned training version.

---

## 16. Video Progress Testing

Video testing should verify:

- session creation
- session authorization
- resume position
- heartbeat behavior
- watched ranges
- progress updates
- session end
- completion thresholds
- malformed session identifiers
- malformed playback metadata
- idle gaps
- anti-skip behavior
- cross-session behavior
- ownership
- protected byte-range requests

Tests must ensure clients cannot manufacture completion by:

- skipping large sections
- waiting while idle
- repeatedly creating sessions
- manipulating client-reported positions
- bypassing assignment ownership

The server remains authoritative.

---

## 17. Media Upload Testing

Media upload tests should verify:

- supported formats
- unsupported formats
- extension validation
- actual file signature validation
- maximum file size
- malformed files
- unreadable files
- checksum handling
- storage behavior
- failure handling

Validation should fail closed.

A filename or client MIME type alone must not be treated as proof of file type.

---

## 18. Assessment Testing

Assessment tests should cover:

- question creation
- question revisions
- answer options
- quizzes
- final assessments
- attempt limits
- prerequisites
- submission
- server-side scoring
- pass/fail logic
- completion integration

Important boundaries include:

- exact pass threshold
- just-below-pass result
- perfect score
- attempt limits
- repeated submissions
- concurrent attempts
- question creation races

The browser or Flutter client must never become the authority for scoring.

---

## 19. Certificate Testing

Certificate tests should cover:

- automatic issuance
- completion eligibility
- unique certificate creation
- idempotent issuance
- employee ownership
- administrative access
- revocation
- repeated revocation behavior
- historical preservation

Repeated completion processing must not create duplicate certificates.

---

## 20. Dashboard Testing

Dashboard tests should verify:

- anonymous behavior
- authenticated routing
- Administrator metrics
- Training Coordinator metrics
- Manager scope
- Employee self-only data
- empty states
- no-assignment scenarios

Dashboard calculations must use only data inside the user's authorized scope.

---

## 21. Reporting Testing

Reporting tests should cover:

- status filters
- overdue filters
- department filters
- job-role filters
- training filters
- training-version filters
- completion percentages
- Manager scope
- Employee denial

Crafted filters must never broaden authorization.

---

## 22. Audit Testing

Audit tests should verify:

- expected events are created
- actor is server-derived
- target is correct
- successful events occur only after successful operations
- failed operations do not create misleading success events
- sensitive data is not recorded
- authorized users can view logs
- unauthorized users cannot access logs
- audit records remain read-only

---

## 23. Retry and Idempotency Testing

Operations that may be repeated should have controlled retry behavior.

Examples:

- repeated employee deactivation
- repeated certificate issuance
- repeated revocation
- repeated publish/retire actions
- duplicate assignment attempts
- repeated assessment submission
- repeated API requests where appropriate

The system should preserve historical integrity rather than create duplicates or overwrite prior facts.

---

## 24. Boundary Testing

Explicitly test boundary conditions.

Time:

- due today
- deadline exactly reached
- playback heartbeat near idle threshold
- session end boundary

Scores:

- exactly passing
- just below passing
- perfect score

Numeric values:

- zero due period
- very large due period
- malformed numeric input

Playback:

- minimum valid progress
- anti-skip boundaries
- idle threshold
- session transitions

---

## 25. Malformed Input Testing

Malformed input should normally produce controlled errors rather than uncontrolled HTTP 500 responses.

Test:

- invalid IDs
- missing IDs
- malformed UUIDs
- invalid form values
- oversized text
- malformed playback metadata
- invalid query parameters
- invalid dates
- invalid state values
- invalid authentication data

Expected responses depend on context and may include:

```text
400
401
403
404
409
```

---

## 26. Concurrency Testing

Concurrency-sensitive behavior should be tested where practical.

Important areas:

- employee state changes
- assignment creation
- assessment attempts
- question creation
- video progress
- certificate issuance
- version lifecycle changes

Verify that:

- duplicate records are not created
- expected races are handled
- unrelated errors are not swallowed
- database state remains valid
- historical records remain intact

Use database locking and uniqueness constraints where justified.

---

## 27. Bug-Fix Testing Workflow

For a reproduced bug:

1. identify the failing behavior
2. add a regression test
3. confirm the test fails before the fix
4. implement the narrowest correct fix
5. run the focused test
6. run affected application tests
7. run the complete MySQL suite
8. run project checks
9. perform runtime validation when risk warrants it

---

## 28. Current Backend Regression History

Important defects previously reproduced and fixed include:

- repeated employee deactivation overwriting history
- due-today assignment timestamp ordering
- concurrent duplicate assignment creation
- due-period datetime overflow
- Training save-time uniqueness race
- Question creation race
- video idle-time credit vulnerability
- cross-session playback tolerance issues
- malformed playback metadata handling

These defects are protected by regression coverage where practical.

---

## 29. Flutter Testing

Flutter testing should cover meaningful application behavior, including:

- authentication
- API error handling
- secure token storage
- dashboard data
- assignment rendering
- assignment status
- training navigation
- module navigation
- lesson navigation
- text lesson completion
- progress refresh
- stale-state protection
- route identity changes
- completion loading states

Current baseline:

```text
81 / 81 passing
flutter analyze: 0 issues
```

Do not duplicate backend business logic merely to create client-side tests.

---

## 30. Android Runtime Testing

Runtime testing should be risk-based.

Higher-risk areas include:

- authentication
- token refresh/logout
- assignment loading
- protected API calls
- training navigation
- video playback
- playback session lifecycle
- pause/resume
- seeking
- progress synchronization
- completion
- network interruption
- Android lifecycle changes

Video runtime testing becomes a primary M16 concern.

---

## 31. JavaScript Playback Testing

The existing web playback implementation remains part of the product.

Current baseline:

```text
3 / 3 passing
```

Playback-related changes should run the JavaScript suite in addition to affected Django tests.

---

## 32. CI Testing

GitHub Actions CI should validate the major automated surfaces.

Minimum expectations:

```text
Backend dependencies
MySQL
Django check
Migration consistency
Django/MySQL test suite
pip check
Flutter dependencies
Flutter analyze
Flutter tests
JavaScript playback tests
```

CI must use disposable credentials.

Production secrets must never be stored directly in workflows.

CI should use maintained action versions and a Flutter version compatible with the Dart SDK declared by `mobile/pubspec.yaml`.

---

## 33. Browser E2E Testing

Browser E2E testing remains relevant to the Django web application.

Where Playwright is used, prioritize complete workflows rather than isolated screenshots.

Important workflows include:

```text
Login
-> Dashboard
-> Assignment
-> Training
-> Lesson
-> Video
-> Assessment
-> Completion
-> Certificate
```

Administrative workflows should include appropriate training creation, versioning, publishing, assignment, and reporting flows.

---

## 34. Negative E2E Testing

Negative browser testing should cover:

- unauthenticated protected-page access
- Employee opening administrative routes
- Manager opening out-of-scope employee URLs
- Employee opening another Employee's certificate
- malformed direct URLs
- invalid form input
- unauthorized state-changing operations
- invalid workflow transitions

---

## 35. Responsive Testing

Responsive testing should cover practical viewport sizes.

At minimum:

- desktop
- laptop
- tablet
- mobile

Important areas:

- dashboards
- tables
- forms
- training pages
- video
- assessments

Responsive validation should remain relevant to the Django web portal.

---

## 36. Accessibility Testing

Accessibility checks should include:

- keyboard navigation
- visible focus
- form labels
- heading structure
- contrast
- error messages
- button semantics
- link semantics

Automated tooling can assist but does not replace manual verification.

---

## 37. Deployment Smoke Testing

After deployment, verify:

- application loads
- login works
- logout works
- database connection works
- static assets load
- authorized dashboard loads
- protected routes remain protected
- HTTPS works
- secure cookies behave correctly
- protected media access behaves correctly

Smoke testing should avoid unnecessary modification of production data.

---

## 38. Production Security Testing

Before release, production-like or staging testing should verify:

- HTTPS
- secure cookies
- CSRF
- allowed hosts
- proxy behavior
- redirects
- media protection
- authentication/session behavior
- authorization boundaries
- error handling
- security headers
- deployment configuration

---

## 39. Final Bug Hunt

The final whole-application bug hunt belongs to M21 after the major functional work is complete.

It should cover:

- backend
- API
- Flutter application
- Django web portal
- browser interactions
- permissions
- malformed input
- concurrency
- playback
- assessments
- certificates
- deployment behavior
- repository state

Avoid repeating a complete bug hunt unnecessarily before the system is sufficiently complete.

---

## 40. Final Security Review

M21 includes the final broad security and repository review.

Expected areas:

- authentication
- authorization
- IDOR
- CSRF
- sessions
- cookies
- headers
- secrets
- dependency vulnerabilities
- input validation
- playback
- media access
- assessments
- certificates
- reports
- audit logs
- deployment configuration
- repository hygiene

Authorized security tooling may be used where appropriate.

Automated findings must be manually reviewed before implementation.

---

## 41. Release Acceptance Testing

M23 final acceptance should verify:

- core workflows
- backend/API integration
- Android application
- training playback
- assessments
- certificates
- authorization
- deployment
- documentation
- release configuration

Release is blocked by unresolved high-impact defects.

---

## 42. Test Data

Automated tests should create controlled data.

Do not depend on manually created development records.

Production and staging data must remain separate.

Deterministic seed scenarios may be used for production-like staging validation.

---

## 43. Live Testing

Automated tests do not replace runtime verification.

Live testing is useful for:

- UI behavior
- navigation
- visible errors
- complete user flows
- Android behavior
- browser behavior
- deployment configuration
- media playback

However, a confirmed backend defect should receive regression coverage rather than being protected only by manual testing.

---

## 44. Current Testing Status

Current verified state:

```text
Django/MySQL: 348 / 348 passing
Flutter: 81 / 81 passing
Flutter analyze: 0 issues
JavaScript playback: 3 / 3 passing
```

Additional checks:

```text
Django check: passing
Migration drift: clean
pip check: clean
git diff --check: clean
Android debug APK: successful
```

Current testing focus:

```text
M16: learning + secure video
M17: assessment + certificates
M18: notifications + resilience
M19: Android release candidate
M20: production/deployment hardening
M21: final bug hunt + security/repository review
M23: final acceptance
```

Testing baselines should always use the latest verified counts rather than historical counts from older documentation.