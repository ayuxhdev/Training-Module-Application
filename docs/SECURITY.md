# Security

## 1. Purpose

This document describes the security model, security assumptions, implemented protections, known boundaries, and production requirements for the Garden's Need Training Module Application.

Security is treated as a core product requirement rather than a final cosmetic step.

The application is designed around the principle that the backend is authoritative for all security-sensitive state.

## 2. Security Objectives

The application should protect against:

- unauthorized access
- privilege escalation
- IDOR-style object access
- forged ownership
- forged Manager scope
- forged training progress
- forged assessment results
- unsafe state transitions
- malformed input
- concurrency-related integrity failures
- CSRF on state-changing actions
- secret exposure
- insecure production configuration
- misleading audit history

The V1 release target is:

- no known exploitable critical or high-severity security issue
- no known important reproducible release-blocking bug left unresolved

This does not imply that the software can be guaranteed to be invulnerable.

## 3. Core Security Principle

The frontend is never the final authority for sensitive business state.

The backend must determine or validate:

- user identity
- user permission
- employee ownership
- reporting hierarchy
- Manager scope
- parent-child relationships
- assignment ownership
- training state
- progress state
- assessment score
- pass/fail result
- training completion
- certificate eligibility
- audit actor
- audit target
- audit timestamp

Client-side state may improve usability, but it must not replace server-side authorization or validation.

## 4. Authentication

The browser application uses Django authentication and session middleware. The web login uses Django's `LoginView`; logout uses Django's `LogoutView` and is a POST action. Authentication establishes identity, while views and querysets still apply permission, ownership, and lifecycle checks.

The mobile-facing API is path-versioned under `/api/v1/` and uses Simple JWT bearer access tokens, with Django session authentication also enabled by DRF. Implemented routes are `POST /api/v1/auth/login/`, `POST /api/v1/auth/refresh/`, `POST /api/v1/auth/logout/`, `GET /api/v1/auth/me/`, `GET /api/v1/status/`, and `GET /api/v1/dashboard/`. Login issues tokens only to a Django-authenticated user linked to an active Employee. Refresh rechecks Employee and Django-user active status before standard Simple JWT refresh behavior. Employee data API views require an authenticated user with an active Employee record.

Simple JWT currently issues 30-minute access tokens and 7-day refresh tokens. Refresh tokens rotate and rotated tokens are blacklisted. Logout requires the authenticated user's refresh token and blacklists it; it does not immediately revoke access tokens already issued, which remain valid until expiry. Protected API endpoints also check active Employee status on each request. API login is throttled at 5 requests/minute using DRF's anonymous throttle; refresh is throttled at 20/minute using its user throttle. These depend on Django's configured cache and do not replace infrastructure rate limiting.

The API currently exposes `v1` in the URL path; it does not negotiate a version through headers.

## 5. Role Model

Current application roles are:

- Administrator
- Training Coordinator
- Manager
- Trainer
- Supervisor
- Employee

Roles are implemented using the project's existing Django permission/group structure.

Security decisions should rely on actual permissions and scope logic rather than only role names.

## 6. Authorization Layers

Authorization may involve several layers.

Typical authorization flow:

```text
Request
   |
   v
Authenticated?
   |
   v
Required permission?
   |
   v
Object within authorized scope?
   |
   v
Current lifecycle/state permits action?
   |
   v
Proceed
```

A user should not be authorized solely because:

- a button is visible
- a route is known
- an object ID was supplied
- the user belongs to a broad role

## 7. Direct URL Protection

Authorization is applied on direct requests as well as navigation links. The employee dashboard filters assignments and certificates by `request.user.employee`; certificate detail lookup is scoped to that Employee unless the user has certificate view permission. Out-of-scope certificate IDs return 404. Training, assessment, organization, and reporting views apply their relevant Django permissions, ownership, Manager scope, and lifecycle checks in the backend.

The API dashboard uses the authenticated user's linked Employee and does not accept a client-selected employee ID. Direct object access must be evaluated against each view's queryset and permission checks; hidden navigation links are not authorization controls.

## 8. Manager Scope

Organization employee queries derive the Manager's own Employee record and recursive reporting descendants through `employee_scope()`. Report and assignment querysets apply this scope before user filters, so filters cannot expand those querysets beyond the computed hierarchy. Other routes use their own permission and scope checks; Manager membership alone is not a universal grant.

## 9. Employee Scope

The employee dashboard API derives the Employee from the authenticated User and filters assignments and certificates to that Employee. Web certificate list/detail access is similarly owner-scoped for users without certificate view permission. Learner progress and assessment attempts are tied to the assignment and its exact lesson/version or assessment. API views use `IsActiveEmployee`; relevant assignment and progress validations also reject inactive Employees.

## 10. Training Coordinator Restrictions

Training Coordinators have significant operational permissions, but they must not automatically gain access to privileged account operations.

Existing privileged-account protections should remain intact.

Training Coordinator actions must not be allowed to:

- improperly link privileged accounts
- improperly deactivate protected privileged accounts
- bypass organization security rules

## 11. Object Ownership

Ownership-sensitive resources include:

- Employee records
- TrainingAssignment
- LessonProgress
- VideoWatchSession
- AssessmentAttempt
- Certificate

Ownership must be established using trusted backend relationships.

Never trust ownership from:

- query parameters
- hidden fields
- JavaScript
- arbitrary POST values

without validating them against server-side state.

## 12. Parent-Child Relationships

The application contains nested relationships such as:

```text
Training
└── TrainingVersion
    └── Module
        └── Lesson
```

and:

```text
Assessment
└── AssessmentQuestion
    └── QuestionRevision
```

The client must not be allowed to attach a child object to an unauthorized or unrelated parent.

Parent context should be derived from trusted backend context where possible.

## 13. State-Changing Requests

Mutating actions must use appropriate HTTP methods.

GET should remain safe and non-mutating.

State-changing examples include:

- employee deactivation
- training publishing
- training retirement
- assignment creation
- certificate revocation

These actions should use POST or another appropriate mutation method.

## 14. CSRF Protection

Django's `CsrfViewMiddleware` is enabled. Web forms and state-changing browser actions use Django CSRF protection; logout and certificate revocation are POST-only. DRF `SessionAuthentication` enforces CSRF for unsafe requests authenticated by a browser session. Bearer-token API requests do not rely on cookie authentication for identity. CSRF remains enabled globally.

## 15. Input Validation

All client input is untrusted.

Input validation must cover:

- IDs
- dates
- due periods
- text values
- session IDs
- playback metadata
- form values
- assessment submissions
- filter values
- state transitions

Expected malformed input should result in controlled responses rather than HTTP 500.

Typical responses may include:

```text
400 Bad Request
403 Forbidden
404 Not Found
409 Conflict
```

## 16. Repeated State Transitions

Repeated mutations must be handled safely.

Example:

An already inactive employee should not be deactivated again as if the operation were new.

Repeated deactivation currently returns:

```text
409 Conflict
```

This prevents:

- overwriting the original deactivation reason
- misleading duplicate audit events
- inaccurate history

Similar patterns should be considered for other lifecycle transitions.

## 17. Concurrency Security

Concurrency is treated as a data-integrity and security concern.

Potentially sensitive operations may use:

- `transaction.atomic`
- `select_for_update`
- database uniqueness constraints
- validation
- narrow exception handling

Concurrency-sensitive areas include:

- employee deactivation
- assignments
- assessment attempts
- video progress
- certificate issuance

The application should not assume that a successful pre-save lookup guarantees the database state will remain unchanged before save.

## 18. Duplicate Creation Races

Expected uniqueness races should be handled narrowly.

For example, if a role-assignment batch checks that an assignment does not exist, another request may create it before the save occurs.

Correct behavior is:

1. attempt the operation
2. detect the specific uniqueness or validation conflict
3. verify that the exact expected assignment now exists
4. treat only that specific case as a duplicate
5. allow unrelated validation errors to surface normally

Do not broadly catch and suppress all integrity errors.

## 19. Training Lifecycle Security

Training versions use:

```text
DRAFT
PUBLISHED
RETIRED
```

Security-sensitive lifecycle rules include:

- Draft content may be edited according to permissions.
- Published content must be protected from unsafe modification.
- Retired content must preserve historical integrity.
- Publishing must enforce required validation.
- Publishing and retirement must be mutation requests.
- Historical assignments must remain tied to the correct version.

Do not bypass lifecycle rules through direct URLs or crafted form submissions.

## 20. Training Assignment Security

Training assignment creation must validate:

- employee eligibility
- employee status
- training-version state
- duplicate assignment
- due date
- authorization scope
- assignment source

Only appropriate published versions should be available for normal new assignment flows.

Role-based assignment operations must not become a way to bypass authorization.

## 21. Due-Date Safety

Due dates must be validated before assignment creation.

A previously reproduced issue showed that independently generating:

- assignment timestamp
- due timestamp

could produce an invalid ordering when the due period was zero.

The application now uses one authoritative timestamp where required.

Extremely large due periods must also be rejected before Python date arithmetic can raise an uncontrolled `OverflowError`.

## 22. Video Progress and Delivery Security

Progress and completion are computed and stored by the backend. The browser submits playback observations, not authoritative watched duration, completion, or watched ranges. Playback requests resolve an assignment owned by the authenticated Employee and a VIDEO lesson in that assignment's exact TrainingVersion. Mutations lock Employee, TrainingVersion, and assignment in a consistent order before progress/session writes.

Video bytes are served through the authenticated `video_media` view, not a public `MEDIA_URL` route. It requires the owner's open watch session for that assignment and lesson, with a recent session update. It supports byte ranges and returns private, no-store responses. Filesystem paths are not returned. Production storage/CDN delivery must preserve this authorization boundary; a public object URL would bypass it.

TEXT completion is a CSRF-protected POST for an owned assignment lesson. VIDEO completion depends on backend-validated watched coverage and the lesson's configured threshold.

## 23. Video Anti-Skip Boundary

The backend records watched intervals from successive server-timed observations. Unique intervals are merged, so replay does not increase unique coverage. Forward progress is bounded by observed playback advancement and elapsed server time; movement into unwatched content without a valid observation is rejected. Backward seeks are allowed, including into already watched content, without adding duplicate coverage.

A heartbeat gap greater than 30 seconds resets the position baseline and does not establish continuous playback credit across that gap. The heartbeat tolerance is 2 seconds and is bounded across session/progress history. The client cannot submit trusted active-watch totals or set completion. Closed/stale sessions, ownership, lesson/version matching, position bounds, and assignment state are validated server-side. These controls cannot prevent screen recording or capture outside the application.

## 24. Playback Metadata

Optional `session_identifier` and `device_identifier` values must be strings no longer than 128 characters. Invalid or structured values produce controlled validation responses. They are metadata only and do not establish identity or authorize playback.

## 25. Assessment Security

Answers are accepted only for an in-progress attempt owned through the authenticated user's active Employee assignment. The server loads the attempt's questions and frozen revisions, verifies each selected option belongs to that revision, and calculates correctness, points, score, and pass/fail. Client-supplied score, correctness, pass state, or completion is not authoritative. Submitted attempts and recorded answers are protected from ordinary edits by model validation.

## 26. Assessment Attempt Controls

Attempt creation and submission validate assignment ownership, active Employee state, assignment status, assessment/version relationship, prerequisites, and attempt limits. Attempts retain the exact assessment question revision/options presented to the learner. Creation and submission serialize on the Employee, TrainingVersion, and assignment before attempt-level work, with database uniqueness and validation as additional integrity controls. Required lesson completion, quiz prerequisites, and final-assessment requirements are checked by backend logic.

## 27. Question and Assessment Races

Question revision creation locks the Question while determining its next revision number. Assessment sequence uniqueness is validated against the backend-resolved TrainingVersion, with database constraints as the final integrity layer. Attempt starts/submissions use parent-to-assignment locking before assignment saves. These controls cover tested race paths, not every database or infrastructure failure.

## 28. Certificate Security

A backend service issues a certificate only after assignment completion and a submitted, passing FINAL assessment for the same assignment and exact TrainingVersion. The certificate stores a server-generated identifier and issue time with employee/training snapshots. A certificate is unique per assignment; repeat issuance returns the existing certificate. Ordinary edits and deletion of issued certificate content are rejected by model validation.

## 29. Certificate Revocation

Certificate list/detail views show an Employee only that Employee's certificates unless the user has certificate view permission. Revocation requires certificate change permission, is POST-only, requires a non-empty bounded reason, preserves the record, and writes an audit event. Normal model validation prevents un-revoking a revoked certificate.

## 30. Reporting Security

Reports are generated from already-authorized querysets.

Correct order:

```text
All records
   |
   v
Apply authorization scope
   |
   v
Apply user filters
   |
   v
Render result
```

Filters must not be used to construct a broader initial queryset.

Manager report filters remain constrained to the Manager's authorized reporting subtree.

Employees do not receive administrative reporting access.

## 31. Audit Security

Audit events use server-derived actor, target, timestamp, and action, with deliberately constructed before/after data. Configured audit snapshots use an allowlist; assessment answers, passwords, tokens, and secrets are not included in those snapshots. The audit interface requires `audit.view_auditlog` and is read-only. The validated model manager rejects ordinary updates, bulk writes, and deletions, while model validation also rejects instance updates/deletion. This is application-level protection, not tamper-proof storage against privileged database access or direct SQL.

## 32. Transaction-Aware Auditing

`record_event()` schedules audit writes with `transaction.on_commit(..., robust=True)`, so rolled-back business transactions do not create success events. Audit write failure is configured not to undo an already committed business operation; audit persistence is not guaranteed against database or operational failure.

## 33. Audit Permissions

The audit view checks `audit.view_auditlog`. The current permission assignment grants it to Administrator and Training Coordinator groups, not Manager or Employee groups. Effective access also depends on deployed group membership and direct Django permissions.

## 34. Secret Management

Secrets must never be committed to the repository.

Examples include:

- `.env`
- database passwords
- Django secret key
- API keys
- authentication tokens
- private credentials

The project previously removed a committed fallback Django secret.

Production now requires explicit secret configuration.

## 35. DEBUG Security

`DEBUG` is environment-configured and defaults to `False`. When false, settings require `DJANGO_SECRET_KEY`; when true and no key is supplied, a random process-local key is generated for development. Development does not enforce HTTPS by default.

## 36. Django Secret Key

With `DEBUG=False`, the application refuses to start without `DJANGO_SECRET_KEY` and has no committed fallback. With DEBUG enabled it generates a random key at startup, which is development behavior, not production secret management. Django's password hasher stores password hashes. JWTs are signed tokens, not encrypted tokens.

## 37. Allowed Hosts

`ALLOWED_HOSTS` is populated from the environment. If empty while DEBUG is true, settings allow localhost loopback names for development. The application does not provide a production host allowlist; deployments must configure explicit hostnames and verify Django deployment checks.

## 38. HTTPS and Transport Settings

`SECURE_SSL_REDIRECT` is environment-configurable and defaults to false. HSTS seconds default to zero; include-subdomains and preload also default to false. HTTPS redirect and HSTS are therefore not automatically enabled by application defaults, including with DEBUG disabled. Production must terminate HTTPS correctly and configure these settings for its proxy/domain architecture. Local development may use HTTP.

## 39. Secure Cookies

`SESSION_COOKIE_SECURE` and `CSRF_COOKIE_SECURE` default to true when `DEBUG=False`; in DEBUG mode they default to false unless explicitly enabled. Secure cookie flags require HTTPS to work in deployment and do not themselves enable HTTPS.

## 40. HSTS

HSTS is disabled by default (`SECURE_HSTS_SECONDS=0`) and can be configured through environment variables. Enable it only after validating HTTPS across the deployed domain and proxy setup; include-subdomains and preload are separate opt-ins.

## 41. Proxy and HTTPS Awareness

Settings do not configure a trusted reverse-proxy HTTPS header. A deployment behind a proxy must deliberately configure TLS termination and Django secure-request behavior. Forwarded protocol headers must not be trusted from untrusted clients; verify redirect, CSRF, and secure-cookie behavior in the deployed topology.

## 42. Static and Media Security

Static assets are separate from protected training videos. The playback route streams video only after authenticated assignment, lesson, and current watch-session checks. Do not expose these files through a public media route or direct public object URL. Production storage/CDN integration must preserve authorization or provide an equivalent authorized delivery path; Django settings alone do not establish that infrastructure behavior.

## 43. Video Content Protection Boundary

The authenticated playback endpoint, owner/lesson checks, short-lived open watch-session requirement, and session controls restrict ordinary direct media retrieval. These controls do not provide DRM and cannot prevent operating-system screen recording, external camera recording, or determined local capture. Employee watermarking and platform-specific Android capture controls are not implemented by this web playback path; they would require separate product and platform work.

## 44. Session Security

The web application uses Django sessions and CSRF middleware. API access tokens last 30 minutes; refresh tokens last 7 days and rotate with blacklist-after-rotation. API logout blacklists the supplied refresh token after checking its owner, but does not immediately revoke issued access tokens. Active Employee checks prevent API use after Employee deactivation; otherwise access-token expiry is the revocation bound. Session duration and concurrent-session policies are not separately configured here.

## 45. Brute-Force and Rate Limiting

DRF throttling is configured for API login (5 requests/minute, anonymous scope) and refresh (20 requests/minute, user scope). No equivalent application throttle is configured here for web login, logout, or every other endpoint. DRF throttles use Django's configured cache and are not a substitute for edge/network rate limiting or a guarantee under every cache deployment.

## 46. Dependency Security

Dependencies should be minimized.

Before adding a dependency:

1. check whether Django or Python already solves the problem
2. evaluate maintenance status
3. evaluate security implications
4. justify the dependency

Current verification includes:

```powershell
python -m pip check
```

A dedicated vulnerability scanner should also be run during the final security milestone.

Potential tools include:

- `pip-audit`
- other trusted dependency scanners

The final selected tool should be documented when actually adopted.

## 47. Repository Security

Before release, the repository must be reviewed for:

- committed secrets
- `.env` files
- debug code
- temporary credentials
- test credentials accidentally reused in production
- TODO security bypasses
- unsafe broad permissions
- stale dependencies
- accidental private data

Git history may also require review if a secret was ever committed.

Removing a secret from the current file alone does not remove it from repository history.

## 48. Error Handling

DRF exceptions handled by `api.exceptions.custom_exception_handler` use a JSON envelope with `error.code`, `error.message`, and `error.fields`, preserving the HTTP status. Validation failures normally return 400; authentication, permission, not-found, and throttling failures retain framework statuses such as 401, 403, 404, or 429. Unknown `/api/v1/` routes deliberately return JSON 404 without authentication. Unexpected exceptions without a DRF response are not wrapped and remain server errors; this handler does not guarantee every failure becomes a controlled 4xx.

## 49. Information Disclosure

Error pages and responses should not reveal unnecessary sensitive details.

Production must not expose Django debug pages.

Sensitive internal information should not be included in:

- error messages
- audit metadata
- logs returned to users
- client-visible configuration

## 50. Logging

Operational logging should support troubleshooting without becoming a sensitive-data store.

Avoid logging:

- passwords
- authentication tokens
- raw secrets
- assessment answers
- unnecessary personal information

Production logging strategy will be finalized during deployment hardening.

## 51. Personal and Employee Data

The application stores employee-related training information.

Access should follow least-privilege principles.

Users should only see information required for their role.

Reports and dashboards must not expose unrelated employee data.

## 52. Database Security

Production database access should use:

- dedicated application credentials
- least-required privileges
- protected credentials
- network restrictions where practical
- backups
- controlled administrative access

The application should not run using a broad database administrator account.

## 53. Backup Security

Database backups may contain sensitive employee and training information.

Backups should therefore be:

- access controlled
- stored securely
- tested for restore
- retained according to business requirements

Backup procedures will be finalized during deployment planning.

## 54. Security Testing

Automated regression tests cover API login/refresh/logout, inactive or missing Employee rejection, JWT and session-authenticated requests, API error envelopes, and login/refresh throttling. Other suites cover direct URL authorization, Manager hierarchy scope, Employee ownership, CSRF-sensitive mutations, malformed playback input, anti-skip/progress, assessment ownership/scoring/prerequisites, certificate issuance/access/revocation, reporting scope, and audit permissions/immutability. Test counts change over time; use current test and CI output rather than a fixed count here. MySQL is used for authoritative full-suite runs.

## 55. Final Security Review

A broader final security review is intentionally scheduled after the frontend and E2E work.

This is important because:

- frontend routes may introduce new access paths
- browser workflows may reveal integration defects
- deployment configuration introduces new risks
- security testing is more useful against the completed application

The final review should include:

- authentication
- authorization
- IDOR
- CSRF
- session behavior
- cookies
- headers
- input validation
- uploads/media
- secrets
- dependencies
- privilege escalation
- race conditions
- direct URLs
- audit behavior
- deployment configuration

## 56. Security Tooling Plan

Current development should not be interrupted by excessive tooling.

Planned late-stage security tooling may include:

- dependency vulnerability scanning
- repository secret review
- Strix or another authorized application security testing tool
- manual targeted review
- Playwright security-path E2E tests

Automated security-tool findings must be reviewed before changes are applied.

Do not blindly accept automated patches.

## 57. Security Release Gate

V1 should not be released until:

- full automated suite passes
- E2E testing passes
- final security review completes
- production configuration is verified
- dependency review completes
- no known exploitable critical or high-severity issue remains
- no known important reproducible release-blocking bug remains unresolved
- repository secret review is complete
- HTTPS and secure-cookie behavior is verified

## 58. Incident Response Preparation

Before production operation, the team should know how to:

- disable a compromised account
- rotate credentials
- rotate the Django secret if necessary
- restore a database backup
- inspect audit history
- identify affected training records
- roll back a bad deployment

Detailed operational procedures may be added during deployment hardening.

## 59. Security Change Policy

Changes affecting security-sensitive architecture should receive focused review.

Examples include:

- authentication changes
- permission changes
- Manager scope changes
- ownership logic
- session behavior
- playback completion logic
- assessment scoring
- certificate issuance
- audit behavior
- production settings

For such changes:

1. inspect current behavior
2. identify the security boundary
3. add or update tests
4. make the narrowest correct change
5. run focused tests
6. run the complete suite
7. review the final diff

## 60. Current Security Status

Implemented application controls include Django session authentication and CSRF middleware, a path-versioned JWT API, active Employee checks on API endpoints, permission and object-scope checks, server-authoritative training/assessment/certificate state, authenticated video delivery, and append-oriented audit behavior. The sections above describe the boundaries of those controls.

Production readiness depends on configuration. HTTPS redirect and HSTS are off by default, production hostnames must be supplied, reverse-proxy behavior must be verified, and protected media storage must preserve the authenticated delivery boundary. `pip check` verifies dependency compatibility; it is not a vulnerability scan. This document records application behavior and does not certify any deployment.
