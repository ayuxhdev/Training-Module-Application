# AGENTS.md

This file defines the standing development rules for coding agents and contributors working on the Garden's Need Training Module Application.

These rules apply unless a task explicitly overrides them.

## Project Context

The project is an internal employee training, assessment, certification, reporting, and workforce development platform for Garden's Need.

Current architecture:

- Python 3.14
- Django 5.2 LTS
- MySQL 8
- Django templates
- HTML
- CSS
- basic JavaScript
- Django built-in User model
- monolithic Django architecture

The backend is the authoritative source for security-sensitive state.

## Core Development Principles

Follow these principles for every change:

- inspect the existing codebase before editing
- understand the current implementation before proposing replacements
- prefer the simplest correct implementation
- use Django and Python built-ins before adding packages or custom abstractions
- reuse existing models, forms, helpers, permissions, and patterns
- avoid unnecessary architectural changes
- avoid unrelated refactoring
- preserve existing behavior unless the task explicitly requires a change
- preserve historical data
- keep code readable and maintainable
- make narrow, reviewable changes

## Security Rules

Security-sensitive decisions must be enforced on the backend.

Never rely only on:

- hidden buttons
- disabled form fields
- JavaScript state
- URL structure
- browser-supplied ownership
- browser-supplied progress
- browser-supplied scores
- browser-supplied completion state

The backend must determine or validate:

- user permissions
- employee ownership
- reporting hierarchy
- manager scope
- training assignment ownership
- parent-child relationships
- training completion
- assessment scores
- certificate eligibility
- progress state

## Authorization

Always preserve the application's role and scope model.

Important roles include:

- Administrator
- Training Coordinator
- Manager
- Trainer
- Supervisor
- Employee

Authorization must be enforced at the view/service/model level as appropriate.

Direct URL access must never bypass permission checks.

Manager access must remain restricted to the authorized reporting hierarchy.

Employee access must remain restricted to the employee's own permitted records.

Do not broaden access through filters, query parameters, forms, or crafted URLs.

## Input Validation

Treat all client input as untrusted.

Validate:

- identifiers
- dates
- numeric values
- text fields
- state transitions
- ownership
- parent relationships
- uploaded metadata
- session identifiers
- assessment data
- playback data

Malformed input should return:

- a controlled form error
- HTTP 400
- HTTP 403
- HTTP 404
- HTTP 409

as appropriate.

Malformed user input should not normally result in HTTP 500.

## State-Changing Actions

Use POST or another appropriate state-changing HTTP method for mutations.

Do not use GET for:

- deactivation
- publishing
- retirement
- revocation
- assignment creation
- completion
- destructive or mutating actions

Maintain CSRF protection.

## Database Safety

Use transactions where multiple related writes must succeed or fail together.

Use locking when concurrency can affect correctness.

Examples include:

- employee state changes
- assignment creation
- assessment attempts
- progress updates
- certificate issuance

When handling uniqueness or race conditions:

- reproduce the failure
- handle the specific expected conflict
- do not suppress unrelated validation errors
- preserve database integrity

Do not make destructive schema changes unless explicitly approved.

## Permission Migrations

Permission migrations must be:

- additive
- non-destructive
- safe to rerun through Django migrations

Use existing permission APIs such as:

```python
group.permissions.add(permission)
```

Do not:

- delete unrelated permissions
- remove groups
- clear permission sets
- create destructive reverse migrations

A safe no-op reverse migration is preferred when reversal would remove legitimate production permissions.

## Historical Data

Preserve historical records where the system depends on them.

Do not casually delete:

- employees
- assignments
- training versions
- certificates
- assessment history
- audit logs

Use deactivation, retirement, revocation, or historical snapshots where the existing architecture requires them.

## Audit Logging

Important state-changing operations should use the existing audit system when appropriate.

Audit records must use server-derived information.

Do not trust the client to supply:

- actor
- target
- timestamp
- authoritative event type

Avoid storing unnecessary sensitive content in audit metadata.

Do not log:

- assessment answers
- passwords
- secrets
- tokens
- private credentials
- complete training content unless explicitly required

Audit logging must not create misleading success events for failed or rolled-back operations.

## Training Rules

Respect the training hierarchy:

```text
Training
└── Training Version
    └── Module
        └── Lesson
```

Training version states:

```text
DRAFT
PUBLISHED
RETIRED
```

Published and retired content must remain protected according to existing immutability rules.

Do not weaken publishing validation.

Do not create unsafe shortcuts around versioning.

## Assignment Rules

Assignments may come from:

- manual assignment
- role-based assignment

Always validate:

- active employee
- permitted training version
- duplicate assignment
- due date
- role scope
- manager scope

Handle concurrency safely.

If a duplicate appears because another request created the same assignment after an initial lookup, only treat it as a duplicate when the exact expected assignment now exists.

Do not hide unrelated validation failures.

## Video Progress Rules

The backend controls video progress.

Do not trust the browser to declare:

- watched duration
- completion
- valid coverage
- playback ownership

Preserve:

- resume behavior
- watched ranges
- anti-skip logic
- idle-time protections
- session validation
- assignment scope
- lesson ownership

Do not weaken anti-skip protections for convenience.

Playback clients should send heartbeats frequently enough to stay within the server's idle-gap rules.

## Assessment Rules

Assessment scoring must remain server-side.

Never trust the browser to supply:

- score
- pass/fail result
- attempt completion
- correct answers

Preserve:

- attempt limits
- prerequisites
- question revisions
- final assessment rules
- assignment completion logic

Assessment creation and submission must handle concurrency and duplicate state safely.

## Certificate Rules

Certificate issuance must remain based on authoritative training completion.

Certificate issuance must remain idempotent.

Do not create duplicate certificates for the same authoritative completion.

Revocation must preserve the certificate record.

Employee access must remain restricted to permitted certificates.

## Reports and Dashboards

Report filters must never broaden user scope.

Manager filters must stay inside the manager's authorized employee hierarchy.

Employee users must not gain administrative reporting access.

Derived values such as overdue state or completion percentage must be calculated from trusted backend data.

## Environment and Secrets

Never commit:

- `.env`
- database passwords
- secret keys
- API keys
- access tokens
- private credentials

Production must fail closed when required security configuration is missing.

Do not change unrelated environment settings while implementing feature work.

Do not modify Git configuration unless explicitly requested.

## Dependencies

Do not add a new dependency unless:

- the existing stack cannot reasonably solve the problem
- the dependency provides clear value
- the security and maintenance cost is justified

Prefer:

- Django built-ins
- Python standard library
- existing project dependencies

before adding packages.

## Code Readability

Prefer open, readable code over compressed one-liners.

Example:

```python
actor = forms.ModelChoiceField(
    queryset=get_user_model().objects.none(),
    required=False,
    label="Performed By",
)
```

Prefer this over dense single-line equivalents.

Use:

- descriptive names
- small focused functions
- clear control flow
- explicit validation
- straightforward conditions

Do not create abstractions only to reduce line count.

Deep readability refactoring is planned as a dedicated late-stage milestone.

Until then, make local readability improvements only when they directly support the current task.

## Testing Rules

For every meaningful change:

1. reproduce the issue when fixing a bug
2. write or update a focused test
3. make the smallest correct fix
4. run affected app tests
5. run the full test suite when appropriate

Confirmed bugs should receive regression tests whenever practical.

Current baseline:

```text
189 full tests passing on MySQL
```

Do not switch the project test strategy to SQLite for convenience.

Important verification commands include:

```powershell
python manage.py test
python manage.py check
python manage.py makemigrations --check --dry-run
python -m pip check
git diff --check
```

## Negative Testing

Important security and behavior tests should include negative cases where relevant.

Examples:

- unauthorized access
- direct URL access
- malformed IDs
- duplicate requests
- repeated state transitions
- invalid parent relationships
- ownership violations
- permission boundary violations
- race conditions
- malformed payloads
- empty results
- exact time boundaries
- exact score boundaries

## Bug-Fix Workflow

When fixing a defect:

1. reproduce it
2. identify the narrow root cause
3. add a regression test
4. implement the smallest correct fix
5. run focused tests
6. run relevant broader tests
7. run the full MySQL suite before final completion when appropriate

Do not refactor large areas merely because a bug was found nearby.

## Before Editing

Before making changes:

- inspect relevant files
- inspect nearby tests
- inspect existing helpers and permission patterns
- understand current behavior
- state a brief plan
- identify expected files to change

## After Editing

Before considering work complete, report:

- files changed
- behavior changed
- tests added or updated
- focused test results
- full test results
- Django check result
- migration check result
- dependency check result
- diff check result
- assumptions
- anything not verified

## Git Rules

Do not commit or push automatically unless explicitly instructed.

Before commit:

- working tree should contain only intended changes
- tests should pass
- checks should pass
- no secrets should be present
- no unrelated files should be modified

Stable work should be committed before starting a risky new milestone.

## Frontend Rules

V1 frontend architecture remains:

- Django templates
- HTML
- CSS
- basic JavaScript

Do not introduce React or another SPA architecture without explicit approval.

The frontend must not duplicate or replace backend authorization logic.

Frontend controls improve usability, not security.

## UI Direction

The intended Garden's Need visual direction is:

- deep forest green
- ivory / white
- charcoal
- restrained brass accents

The visual system should feel professional, premium, calm, and suitable for internal business software.

Functionality comes before visual polish.

Major visual polish is intentionally scheduled near the end of V1 development.

## Browser and E2E Testing

Playwright will be used during frontend and integration milestones.

Do not treat frontend work as complete based only on template rendering.

Important browser flows should eventually cover:

- login
- role dashboards
- training assignment
- lesson progression
- video playback
- assessment attempts
- training completion
- certificates
- reporting
- unauthorized access
- direct URL protection

## Production Rules

Production deployment must use:

```text
DEBUG=False
```

Production requires:

- strong secret key
- explicit allowed hosts
- HTTPS
- secure cookies
- appropriate HSTS
- correct static handling
- correct media protection
- database backups
- logging
- rollback planning

Do not weaken production defaults merely to simplify local development.

## Scope Control

Do not implement future features while working on V1 unless explicitly requested.

Future features may include:

- skill matrix
- practical assessment
- supervisor verification
- machine certification
- QR verification
- notifications
- multilingual support
- AI-assisted knowledge access
- native mobile features

Future scope must remain clearly separated from implemented V1 functionality.

## Current Roadmap

Current milestone:

```text
Milestone 11 - Documentation + Project Structure + CI
```

Remaining major milestones:

```text
Milestone 12 - Functional Frontend
Milestone 13 - UX + Responsive + Accessibility
Milestone 14 - Full E2E + Integration Testing
Milestone 15 - Production + Deployment Hardening
Milestone 16 - Final Bug Hunt + Security + Repository Review
Milestone 17 - Final Readability + Refactor Pass
Milestone 18 - Premium Visual Polish
Milestone 19 - Final Acceptance + V1 Release
```

## Final Rule

If a requested change conflicts with the existing security model, data integrity model, or documented architecture, do not silently work around the conflict.

Identify the conflict and choose the safest narrow implementation that preserves the established system unless explicit approval is given to change the architecture.