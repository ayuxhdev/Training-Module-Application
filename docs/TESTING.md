# Testing

## 1. Purpose

This document defines the testing strategy for the Garden's Need Training Module Application.

Testing is treated as part of implementation, not as a separate cleanup step.

The project aims to verify:

- correct business behavior
- authorization boundaries
- ownership rules
- data integrity
- lifecycle transitions
- concurrency-sensitive behavior
- malformed-input handling
- regression safety
- browser workflows
- production readiness

## 2. Current Test Baseline

Current backend baseline:

```text
189 full tests passing on MySQL
```

The complete backend test suite currently runs against MySQL rather than SQLite.

This baseline was established after the interim backend bug-hunt completed between Milestones 10 and 11.

## 3. Testing Stack

Current testing tools include:

- Django built-in test framework
- MySQL 8
- Django test client
- Python assertions
- project-specific regression tests

Planned later-stage testing includes:

- Playwright
- browser workflow testing
- end-to-end integration testing
- deployment smoke testing
- security-focused testing

## 4. Database Strategy

Backend automated tests should continue to run against MySQL.

Do not switch the main test suite to SQLite only for convenience.

Using MySQL helps exercise behavior closer to the actual application environment, including:

- database constraints
- locking behavior
- transaction behavior
- uniqueness behavior
- date and time behavior
- concurrency-sensitive logic

## 5. Main Verification Commands

Run the complete test suite:

```powershell
python manage.py test
```

Run Django system checks:

```powershell
python manage.py check
```

Check for missing migrations:

```powershell
python manage.py makemigrations --check --dry-run
```

Check installed dependency consistency:

```powershell
python -m pip check
```

Check the Git diff for whitespace errors:

```powershell
git diff --check
```

These checks should pass before stable work is committed.

## 6. Test Categories

The project uses several categories of testing.

### 6.1 Unit and Component-Level Tests

These test focused pieces of business behavior.

Examples include:

- form validation
- model validation
- permission helpers
- lifecycle rules
- assignment logic
- scoring behavior
- certificate behavior

### 6.2 View Tests

View tests verify:

- authentication requirements
- permissions
- ownership
- form handling
- HTTP status codes
- redirects
- malformed requests
- state transitions

### 6.3 Integration Tests

Integration tests verify behavior across multiple parts of the system.

Examples include:

```text
Employee
-> Training Assignment
-> Lesson Progress
-> Assessment
-> Completion
-> Certificate
```

These tests become increasingly important as the frontend and complete workflows are finished.

### 6.4 Regression Tests

Every confirmed defect should receive a regression test when practical.

A regression test should:

1. reproduce the original failure
2. fail before the fix
3. pass after the fix
4. remain in the suite permanently unless the related behavior is intentionally removed

Regression tests protect against reintroducing previously fixed bugs.

## 7. Security Testing

Security-sensitive features require both positive and negative tests.

Important areas include:

- authentication
- authorization
- object ownership
- Manager reporting scope
- Employee self-scope
- direct URL access
- CSRF-sensitive mutations
- assessment scoring
- video progress
- certificate access
- reporting
- audit logs

Security testing should verify not only what users can do, but also what they cannot do.

## 8. Authorization Tests

Authorization tests should cover different user roles.

Examples include:

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

- permitted views succeed
- unauthorized views fail
- direct URLs cannot bypass authorization
- crafted identifiers do not broaden access
- filters do not broaden scope

## 9. Manager Scope Testing

Manager behavior should be tested against the recursive reporting hierarchy.

Tests should include:

- direct reports
- nested reports
- employees outside the hierarchy
- crafted employee IDs
- crafted department filters
- crafted role filters
- report filtering

A Manager should never gain access outside the authorized reporting subtree.

## 10. Employee Scope Testing

Employees should be tested for self-only access.

Examples include:

- own assignments
- own progress
- own assessment attempts
- own certificates

Negative tests should verify that an Employee cannot access another Employee's records.

## 11. Training Lifecycle Testing

Training lifecycle tests should cover:

```text
DRAFT
PUBLISHED
RETIRED
```

Important cases include:

- valid publishing
- invalid publishing
- publishing without required final assessment structure
- attempts to modify published content
- attempts to modify retired content
- retirement
- repeated lifecycle actions
- direct URL mutation attempts

## 12. Assignment Testing

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

- due period of zero
- concurrent duplicate assignment creation
- database uniqueness races
- extremely large due periods
- empty role-assignment batches

## 13. Video Progress Testing

Video progress testing should verify:

- resume position
- session creation
- heartbeat behavior
- watched ranges
- session end behavior
- completion thresholds
- malformed session identifiers
- malformed playback metadata
- idle gaps
- anti-skip behavior
- cross-session behavior
- ownership

Tests should ensure that clients cannot manufacture completion by:

- skipping large sections
- waiting while idle
- repeatedly creating sessions
- manipulating client-reported positions

## 14. Assessment Testing

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

- exact score thresholds
- exact time limits
- repeated submission
- duplicate assessment creation
- concurrent attempts
- question creation races

The browser must never become the authority for scoring.

## 15. Certificate Testing

Certificate tests should cover:

- automatic issuance
- completion eligibility
- unique certificate creation
- idempotent issuance
- employee ownership
- administrative access
- revocation
- repeated revocation behavior

Certificate history must remain preserved.

## 16. Dashboard Testing

Dashboard tests should verify:

- anonymous root behavior
- authenticated role routing
- Administrator metrics
- Training Coordinator metrics
- Manager scope
- Employee self-only data
- empty dashboards
- no assignment scenarios

Dashboard calculations must only use data inside the user's authorized scope.

## 17. Reporting Testing

Reporting tests should cover:

- status filters
- overdue filters
- department filters
- job-role filters
- training filters
- training-version filters
- completion percentage
- Manager scope
- Employee denial

Tests should verify that crafted filter values cannot broaden authorization.

## 18. Audit Testing

Audit tests should verify:

- expected events are created
- actor is server-derived
- target is correct
- success events occur only after successful operations
- failed operations do not create misleading success events
- sensitive information is not recorded
- authorized users can view logs
- unauthorized users cannot access logs
- audit records remain read-only

## 19. Retry Testing

Operations that may be repeated should have retry tests.

Examples include:

- repeated employee deactivation
- repeated certificate issuance
- repeated revocation
- repeated publish or retire operations
- duplicate assignment attempts
- repeated assessment submissions

The system should return controlled and predictable behavior rather than corrupting historical state.

## 20. Boundary Testing

Boundary conditions should be tested explicitly.

Examples include:

### Time Boundaries

- due today
- assessment deadline exactly reached
- playback heartbeat near idle threshold
- session end boundary

### Score Boundaries

- exactly passing score
- just below passing score
- perfect score

### Numeric Boundaries

- zero due period
- very large due period
- malformed numeric input

Boundary bugs often appear where ordinary happy-path tests do not.

## 21. Malformed Input Testing

Malformed input should not normally produce uncontrolled HTTP 500 responses.

Test examples include:

- invalid IDs
- missing IDs
- malformed UUIDs
- invalid form values
- oversized text
- malformed playback metadata
- invalid query parameters
- invalid dates
- invalid state values

Expected responses may include:

```text
400
403
404
409
```

depending on the situation.

## 22. Concurrency Testing

Concurrency-sensitive behavior should be tested where practical.

Important areas include:

- employee state changes
- assignment creation
- assessment attempt creation
- question creation
- video progress
- certificate issuance

Tests should verify that:

- duplicate records are not created
- expected race conditions are handled
- unrelated validation errors are not swallowed
- database state remains valid

## 23. Bug-Fix Testing Workflow

For a reproduced bug:

1. identify the failing behavior
2. add a test that reproduces it
3. confirm the test fails before the fix
4. implement the narrowest correct fix
5. rerun the focused test
6. run the affected app tests
7. run the complete MySQL suite
8. run project checks

This workflow was used during the interim backend bug hunt.

## 24. Interim Backend Bug-Hunt Results

The interim backend bug-hunt reproduced and fixed several defects.

Examples include:

- repeated employee deactivation overwriting historical information
- due-today assignment timestamp ordering
- assignment duplicate race
- due-period overflow
- Training save-time uniqueness race
- Question creation race

Each confirmed defect received regression coverage.

The final suite increased from:

```text
173 tests
```

to:

```text
189 tests
```

All 189 tests passed on MySQL.

## 25. Focused Test Runs

During development, run the smallest relevant test set first.

Example:

```powershell
python manage.py test training
```

or:

```powershell
python manage.py test assessments
```

Focused tests provide faster feedback.

After the focused tests pass, run broader tests before final completion.

## 26. Full Test Run

Important completed work should finish with:

```powershell
python manage.py test
```

Current expected result:

```text
189 tests passing
```

If the number increases because new tests are added, the latest verified passing count becomes the new baseline.

## 27. Migration Testing

After model or migration-related changes, run:

```powershell
python manage.py makemigrations --check --dry-run
```

Unexpected migration output should be investigated before commit.

Do not create schema migrations unintentionally.

## 28. Dependency Testing

Run:

```powershell
python -m pip check
```

This verifies that installed Python dependencies are internally consistent.

A full dependency vulnerability scan will be added during the final security milestone.

## 29. Git Diff Testing

Run:

```powershell
git diff --check
```

This catches common whitespace errors.

Also review:

```powershell
git status --short
```

before commit to ensure only intended files are modified.

## 30. Continuous Integration

GitHub Actions will be added during Milestone 11.

CI should run automatically on important repository events such as:

- pushes to the main branch
- pull requests targeting the main branch

The CI environment should use MySQL.

Minimum CI checks should include:

```text
install dependencies
start/configure MySQL
Django system check
migration consistency check
full test suite
dependency consistency check
```

CI must use disposable credentials.

Real development or production secrets must never be stored directly in the workflow.

## 31. CI Success Criteria

A CI run should be considered successful only when:

- dependencies install successfully
- MySQL becomes healthy
- Django settings load
- `manage.py check` passes
- migration check passes
- automated tests pass
- `pip check` passes

A failed CI run should block treating the branch as release-ready.

## 32. Frontend Testing

Frontend testing becomes a larger focus during Milestone 12.

Frontend testing should include:

- page rendering
- navigation
- form errors
- empty states
- role-specific views
- responsive behavior
- JavaScript interactions
- assessment experience
- video experience

Frontend tests must not assume that hidden controls provide security.

Backend authorization remains mandatory.

## 33. Playwright Testing

Playwright is planned for Milestones 13 and 14.

Playwright should test complete browser flows rather than only isolated pages.

Important flows include:

```text
Login
-> Dashboard
-> Assigned Training
-> Lesson
-> Video
-> Quiz
-> Final Assessment
-> Completion
-> Certificate
```

Administrative flows may include:

```text
Login
-> Create Training
-> Create Version
-> Add Modules/Lessons
-> Configure Assessment
-> Publish
-> Assign Employee
-> Review Reports
```

## 34. Playwright Role Coverage

E2E testing should cover representative users from important roles.

At minimum:

- Administrator
- Training Coordinator
- Manager
- Employee

Trainer and Supervisor flows should be tested according to their actual implemented V1 permissions.

## 35. Negative E2E Testing

Playwright should also test negative scenarios.

Examples:

- unauthenticated protected page access
- Employee opening administrative routes
- Manager opening out-of-scope employee URLs
- Employee opening another Employee's certificate
- malformed direct URLs
- state-changing operations without valid workflow
- invalid form input

## 36. Responsive Testing

Responsive testing should cover practical viewport sizes.

Examples include:

- desktop
- laptop
- tablet
- mobile

Important workflows should remain usable at smaller widths.

Responsive testing is especially important for:

- dashboards
- tables
- forms
- training pages
- video
- assessments

## 37. Accessibility Testing

Accessibility testing should include:

- keyboard navigation
- visible focus
- form labels
- heading structure
- contrast
- error messages
- button semantics
- link semantics

Automated accessibility tooling may assist, but manual checks remain important.

## 38. Deployment Smoke Testing

After deployment, run basic smoke tests.

Examples include:

- application loads
- login works
- logout works
- database connection works
- static assets load
- authorized dashboard loads
- protected routes remain protected
- HTTPS works
- secure cookies behave correctly

Deployment smoke testing should not modify important production data unnecessarily.

## 39. Production Security Testing

Before V1 release, production-like or staging testing should verify:

- HTTPS
- secure cookies
- CSRF
- allowed hosts
- proxy behavior
- redirects
- media protection
- session handling
- authorization boundaries
- error handling

## 40. Final Bug Hunt

A complete whole-application bug hunt is intentionally scheduled after frontend and E2E development.

This prevents performing the same comprehensive review twice.

The final bug hunt should cover:

- backend
- frontend
- browser interactions
- integrations
- permissions
- malformed input
- concurrency
- deployment behavior
- repository state

## 41. Final Security Review

Milestone 16 includes the final major security review.

Expected areas include:

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
- assessments
- certificates
- reports
- audit logs
- production settings

Additional authorized tools such as Strix may be used at that stage.

Automated findings must be manually reviewed.

## 42. Release Testing Standard

V1 should not be released until:

- backend automated tests pass
- CI passes
- E2E flows pass
- responsive testing passes
- important accessibility checks pass
- deployment smoke tests pass
- final bug hunt completes
- final security review completes
- no known important release-blocking bug remains unresolved

## 43. Test Documentation

When major bugs are fixed, preserve enough context to understand:

- what failed
- why it failed
- how it was fixed
- what regression test now protects it

Important long-term lessons may also be recorded in:

```text
docs/MEMORY.md
```

## 44. Test Data

Tests should create their own controlled data.

Do not depend on manually created development records unless a specific live verification requires them.

Automated tests should remain reproducible.

## 45. Live Testing

Automated tests do not replace all live testing.

Live manual verification is useful for:

- UI behavior
- navigation
- visual state
- complete user flows
- browser behavior
- deployment configuration

However, live testing should not replace regression tests for confirmed backend defects.

## 46. Current Testing Status

Current state:

```text
Backend automated suite: 189 / 189 passing
Database: MySQL
Django check: passing
Migration check: passing
pip check: passing
git diff --check: passing
```

Upcoming testing work:

```text
Milestone 11 - CI
Milestone 12 - frontend functional testing
Milestone 13 - responsive/accessibility/browser testing
Milestone 14 - full Playwright E2E + integration testing
Milestone 16 - final bug/security testing
Milestone 19 - final acceptance testing
```

The current backend baseline should be preserved while the application moves into frontend development.