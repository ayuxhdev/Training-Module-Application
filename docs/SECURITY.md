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

This principle applies to both the Django web application and the Flutter Android application.

## 4. Authentication

The browser application uses Django authentication and session middleware. Web login uses Django's `LoginView`; logout uses Django's `LogoutView` and is a POST action. Authentication establishes identity, while views and querysets still apply permission, ownership, and lifecycle checks.

The mobile-facing API is path-versioned under `/api/v1/` and uses Simple JWT bearer access tokens, with Django session authentication also enabled by DRF.

Implemented API areas include:

- `POST /api/v1/auth/login/`
- `POST /api/v1/auth/refresh/`
- `POST /api/v1/auth/logout/`
- `GET /api/v1/auth/me/`
- `GET /api/v1/auth/status/` where applicable to the deployed API surface
- `GET /api/v1/dashboard/`
- assignment APIs
- learning/progress APIs
- protected playback-session APIs

API login issues tokens only to a Django-authenticated user linked to an active Employee. Refresh rechecks Employee and Django-user active status before standard Simple JWT refresh behavior.

Employee-facing API views require an authenticated user with an active Employee record.

Simple JWT currently uses:

- 30-minute access tokens
- 7-day refresh tokens
- refresh-token rotation
- blacklist-after-rotation

API logout requires the authenticated user's refresh token and blacklists it after validating token ownership. Logout does not immediately revoke already-issued access tokens. Existing access tokens remain valid until expiry unless another server-side control rejects the request.

Protected API endpoints also check active Employee status on each request.

API login and refresh throttling are configured through DRF. These controls depend on Django's configured cache and do not replace infrastructure-level rate limiting.

The API currently exposes `v1` in the URL path. It does not negotiate a version through headers.

## 5. Role Model

Current application roles are:

- Administrator
- Training Coordinator
- Manager
- Trainer
- Supervisor
- Employee

Roles are implemented using the project's existing Django permission and group structure.

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

Authorization must be enforced server-side.

## 7. Direct URL Protection

Authorization applies to direct requests as well as navigation links.

The employee dashboard filters assignments and certificates by the authenticated user's Employee.

Certificate detail lookup is scoped to that Employee unless the user has the required certificate-view permission. Out-of-scope certificate IDs return an appropriate not-found response rather than exposing another Employee's certificate.

Training, assessment, organization, reporting, assignment, and certificate views apply their relevant Django permissions, ownership, Manager scope, and lifecycle checks in the backend.

The API dashboard derives the Employee from the authenticated User and does not accept a client-selected Employee ID.

Hidden navigation links are never treated as authorization controls.

## 8. Manager Scope

Organization employee queries derive the Manager's own Employee record and recursive reporting descendants through `employee_scope()`.

Report and assignment querysets apply this scope before user filters, so filters cannot expand the queryset beyond the computed hierarchy.

Other routes use their own permission and scope checks. Manager membership alone is not a universal grant.

## 9. Employee Scope

Employee-facing resources derive ownership from the authenticated User and its linked Employee record.

Assignments, lesson progress, watch sessions, assessment attempts, and certificates must remain tied to the authorized Employee and assignment relationships.

The client must not be able to substitute another Employee ID to obtain another Employee's training state.

API views use active-Employee validation, and relevant assignment, progress, session, and assessment operations reject inactive Employees.

## 10. Training Coordinator Restrictions

Training Coordinators have significant operational permissions, but they must not automatically gain access to privileged account operations.

Existing privileged-account protections must remain intact.

Training Coordinator actions must not be allowed to:

- improperly link privileged accounts
- improperly deactivate protected privileged accounts
- bypass organization security rules
- bypass lifecycle or ownership authorization

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

Parent context should be derived from trusted backend context wherever possible.

## 13. State-Changing Requests

Mutating actions must use appropriate HTTP methods.

GET should remain safe and non-mutating.

State-changing examples include:

- Employee deactivation
- training publishing
- training retirement
- assignment creation
- lesson completion
- playback progress updates
- playback session start/end
- assessment submission
- certificate revocation

These actions should use POST or another appropriate mutation method.

## 14. CSRF Protection

Django's `CsrfViewMiddleware` is enabled.

Web forms and state-changing browser actions use Django CSRF protection. Logout and certificate revocation are POST-only.

DRF `SessionAuthentication` enforces CSRF for unsafe requests authenticated through a browser session.

Bearer-token API requests do not rely on cookie authentication for API identity.

CSRF remains enabled globally.

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
- media-upload metadata

Expected malformed input should result in controlled responses rather than uncontrolled server errors.

Typical responses may include:

```text
400 Bad Request
403 Forbidden
404 Not Found
409 Conflict
```

## 16. Repeated State Transitions

Repeated mutations must be handled safely.

For example, an already inactive Employee should not be deactivated again as though the operation were new.

Repeated deactivation returns a conflict response where appropriate.

This prevents:

- overwriting the original deactivation reason
- misleading duplicate audit events
- inaccurate history

Similar protections should be considered for other lifecycle transitions.

## 17. Concurrency Security

Concurrency is treated as a data-integrity and security concern.

Potentially sensitive operations may use:

- `transaction.atomic`
- `select_for_update`
- database uniqueness constraints
- validation
- narrow exception handling

Concurrency-sensitive areas include:

- Employee deactivation
- assignments
- assessment attempts
- video progress
- watch sessions
- certificate issuance

The application must not assume that a successful pre-save lookup guarantees that the database state remains unchanged before the final write.

## 18. Duplicate Creation Races

Expected uniqueness races should be handled narrowly.

For example, if an assignment operation checks that an assignment does not exist, another request may create it before the save occurs.

Correct behavior is:

1. attempt the operation
2. detect the specific uniqueness or validation conflict
3. verify that the exact expected object now exists
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
- Published content is immutable.
- Retired content preserves historical integrity.
- Publishing enforces required validation.
- Publishing and retirement are mutation requests.
- Historical assignments remain tied to their assigned TrainingVersion.
- Retired versions cannot receive new assignments.
- Existing assignments may continue against their assigned version.

Published training versions must not be modified through direct URLs or crafted form submissions.

Any correction requiring changes to already-published content should be handled through a new version rather than mutating the published version.

## 20. Training Assignment Security

Training assignment creation must validate:

- Employee eligibility
- Employee status
- training-version state
- duplicate assignment
- due date
- authorization scope
- assignment source

Normal new assignments should use an appropriate published TrainingVersion.

Assignments remain pinned to their assigned version.

The application does not automatically migrate Employees to newer published versions.

Role-based assignment operations must not become a way to bypass authorization.

## 21. Due-Date Safety

Due dates must be validated before assignment creation.

A previously reproduced issue showed that independently generating:

- assignment timestamp
- due timestamp

could produce an invalid ordering when the due period was zero.

The application uses an authoritative timestamp where required.

Extremely large due periods must also be rejected before Python date arithmetic can produce an uncontrolled `OverflowError`.

## 22. Published Media Security

Published training media is treated as immutable content.

Replacing published media must require a new TrainingVersion rather than modifying the existing published version.

V1 media is streaming-only. Media downloads are not part of the V1 product model.

The existing M13 session-based protected media endpoint is reused rather than introducing a parallel unrestricted media route.

The protected media path must validate:

- authenticated identity
- Employee status
- assignment ownership
- lesson relationship
- exact TrainingVersion relationship
- valid watch-session state
- media authorization

Media files must not be exposed through an unrestricted public `MEDIA_URL` or equivalent public object URL.

## 23. Video Delivery Security

Video bytes are served through the authenticated protected media view rather than a public media route.

The existing session-based delivery model requires an authorized open watch session for the relevant assignment and lesson, with recent session activity.

The endpoint supports byte-range requests required for normal video playback and returns private/no-store responses where configured.

Filesystem paths are not returned to clients.

Production storage or CDN integration must preserve the same authorization boundary. A public object URL that bypasses the application authorization layer is not acceptable.

## 24. Video Progress and Completion Security

Progress and completion are calculated and stored by the backend.

The client submits playback observations. It does not become authoritative for:

- total watched duration
- watched ranges
- completion state
- completion eligibility

Playback requests resolve the authenticated Employee's assignment and the exact lesson/version relationship.

Progress and session mutations use consistent locking and validation where required.

TEXT lesson completion is a CSRF-protected POST for an owned assignment lesson.

VIDEO completion depends on backend-validated watched coverage and the configured lesson completion threshold.

The Flutter application must not duplicate the backend's authoritative completion rules.

## 25. Video Anti-Skip Boundary

The backend records watched intervals from successive server-timed observations.

Unique intervals are merged, so replay does not increase unique coverage.

Forward progress is bounded by observed playback advancement and elapsed server time. Movement into unwatched content without a valid observation is rejected.

Backward seeks are allowed, including into already watched content, without adding duplicate coverage.

A heartbeat gap greater than the configured tolerance resets the position baseline and does not establish continuous playback credit across the gap.

The heartbeat tolerance and session/progress history are bounded server-side.

The client cannot submit trusted active-watch totals or directly set completion.

Closed or stale sessions, ownership, lesson/version matching, position bounds, and assignment state are validated server-side.

These controls do not prevent screen recording, external cameras, or determined local capture.

## 26. Playback Metadata

Optional `session_identifier` and `device_identifier` values are metadata only.

They must be bounded and validated as strings.

They do not establish:

- identity
- ownership
- authorization
- completion

Malformed or structured values must produce controlled validation responses.

## 27. Assessment Security

Assessment answers are accepted only for an in-progress attempt authorized through the authenticated Employee's assignment.

The server loads the attempt's questions and frozen revisions.

It verifies that selected options belong to the relevant question revision and calculates:

- correctness
- points
- score
- pass/fail result

Client-supplied score, correctness, pass state, or completion is never authoritative.

Submitted attempts and recorded answers are protected from ordinary unauthorized edits through model and service validation.

## 28. Assessment Attempt Controls

Attempt creation and submission validate:

- assignment ownership
- active Employee state
- assignment status
- assessment/version relationship
- prerequisites
- attempt limits
- required lesson completion
- assessment requirements

Attempts retain the exact assessment question revisions/options presented to the learner.

Creation and submission use parent-level locking and database constraints where required for integrity.

## 29. Question and Assessment Races

Question revision creation locks the Question while determining its next revision number.

Assessment sequence uniqueness is validated against the backend-resolved TrainingVersion, with database constraints providing the final integrity layer.

Attempt starts and submissions use the required parent-to-assignment locking order before assignment-level writes.

These controls cover tested race paths but do not guarantee immunity from every database or infrastructure failure.

## 30. Certificate Security

A backend service issues a certificate only after:

1. the assignment is complete
2. the required FINAL assessment has been submitted
3. the FINAL assessment has passed
4. the assessment belongs to the same assignment
5. the assessment belongs to the exact TrainingVersion

The certificate stores a server-generated identifier and issue time with appropriate Employee and training snapshots.

A certificate is unique per assignment.

Repeat issuance returns the existing certificate rather than creating duplicate certificates.

Issued certificate content cannot be ordinarily edited or deleted.

Certificates reference the earned TrainingVersion and do not mutate that version.

## 31. Certificate Revocation

Certificate list/detail views show an Employee only that Employee's certificates unless the user has the required certificate-view permission.

Revocation requires certificate-change permission.

Revocation:

- is POST-only
- requires a non-empty bounded reason
- preserves the certificate record
- writes an audit event
- cannot normally be reversed through ordinary model mutation

## 32. Reporting Security

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

## 33. Audit Security

Audit events use server-derived:

- actor
- target
- timestamp
- action

Before/after data is deliberately constructed.

Configured audit snapshots use an allowlist.

Sensitive values such as passwords, authentication tokens, secrets, and inappropriate assessment data must not be included in audit snapshots.

The audit interface requires the appropriate audit-view permission and is read-only.

The validated model manager rejects ordinary updates, bulk writes, and deletions where configured. Model validation also protects against ordinary instance mutation/deletion.

This is application-level protection. It is not tamper-proof storage against privileged database access or direct SQL.

## 34. Transaction-Aware Auditing

`record_event()` schedules audit writes with `transaction.on_commit(..., robust=True)` where appropriate.

This prevents rolled-back business transactions from producing success audit events.

Audit persistence failure is not configured to undo an already committed business operation.

Therefore, audit persistence is not guaranteed against every database or operational failure.

## 35. Audit Permissions

Audit access is controlled through the application's audit-view permission.

The current permission assignment grants this capability to the intended administrative/training roles rather than ordinary Employees.

Effective access also depends on deployed group membership and direct Django permissions.

## 36. Secret Management

Secrets must never be committed to the repository.

Examples include:

- `.env`
- database passwords
- Django secret key
- API keys
- authentication tokens
- private credentials

The project previously removed a committed fallback Django secret.

Production requires explicit secret configuration.

Repository history should also be reviewed if a secret was ever committed.

## 37. DEBUG Security

`DEBUG` is environment-configured and defaults to `False`.

When `DEBUG=False`, settings require `DJANGO_SECRET_KEY`.

When `DEBUG=True` and no key is supplied, a random process-local development key may be generated.

Development does not automatically enforce HTTPS.

Production must never depend on development defaults.

## 38. Django Secret Key

With `DEBUG=False`, the application refuses to start without `DJANGO_SECRET_KEY`.

There is no committed production fallback secret.

With DEBUG enabled, generating a random startup key is development behavior and is not production secret management.

Django password hashing is used for passwords.

JWTs are signed tokens, not encrypted tokens.

## 39. Allowed Hosts

`ALLOWED_HOSTS` is populated from the environment.

Development may allow localhost loopback names when appropriate.

Production deployments must configure explicit hostnames and verify Django deployment checks.

The application does not assume that a permissive development host configuration is suitable for production.

## 40. HTTPS and Transport Settings

`SECURE_SSL_REDIRECT` is environment-configurable and defaults to false.

HSTS settings are also configurable and default to disabled.

Therefore, HTTPS redirect and HSTS are not automatically enabled merely because `DEBUG=False`.

Production must:

- terminate HTTPS correctly
- configure Django's secure-request behavior
- configure the required host/domain settings
- verify proxy behavior
- verify CSRF behavior
- verify secure-cookie behavior

Local development may use HTTP.

## 41. Secure Cookies

`SESSION_COOKIE_SECURE` and `CSRF_COOKIE_SECURE` default to secure behavior when `DEBUG=False`, while development behavior may be relaxed unless explicitly configured.

Secure cookie flags require HTTPS to function correctly in deployment.

Cookie security settings do not themselves create HTTPS.

## 42. HSTS

HSTS is disabled by default.

It may be enabled through environment configuration after HTTPS has been verified across the deployed domain and proxy architecture.

`includeSubDomains` and `preload` are separate opt-ins and must not be enabled without deliberate deployment review.

## 43. Proxy and HTTPS Awareness

The deployment must deliberately configure trusted reverse-proxy behavior when TLS is terminated upstream.

Forwarded protocol headers must not be trusted from untrusted clients.

Production verification must include:

- HTTPS redirects
- CSRF origin behavior
- secure cookies
- proxy headers
- host validation
- Django deployment checks

## 44. Static and Media Security

Static assets are separate from protected training videos.

Training video files must not be exposed through a public media route or unrestricted object URL.

Production storage/CDN integration must preserve authorization or provide an equivalent authorized delivery path.

Django application settings alone do not establish infrastructure-level storage security.

## 45. Video Content Protection Boundary

The authenticated playback endpoint, Employee/assignment/lesson checks, short-lived open watch-session requirement, and session controls restrict ordinary direct media retrieval.

These controls do not provide DRM.

They cannot prevent:

- operating-system screen recording
- external camera recording
- determined local capture

Platform-specific Android protections such as `FLAG_SECURE` may be added where appropriate during the mobile learning/video milestone, but such controls are defense-in-depth rather than a replacement for server authorization.

## 46. Session Security

The web application uses Django sessions and CSRF middleware.

API access tokens currently last 30 minutes.

Refresh tokens currently last 7 days and rotate with blacklist-after-rotation.

API logout blacklists the supplied refresh token after validating ownership but does not immediately revoke already-issued access tokens.

Active Employee checks prevent API use after Employee deactivation.

Otherwise, access-token expiry remains an important revocation boundary.

Session duration and concurrent-session policies are not separately defined as a universal application policy.

## 47. Brute-Force and Rate Limiting

DRF throttling is configured for API authentication flows.

Current controls include throttling for:

- API login
- API refresh

These throttles use Django's configured cache.

They are not a substitute for:

- edge/network rate limiting
- WAF controls
- infrastructure protection
- monitoring

No assumption should be made that application throttling alone protects every endpoint or every deployment topology.

## 48. Dependency Security

Dependencies should be minimized.

Before adding a dependency:

1. check whether Django or Python already solves the problem
2. evaluate maintenance status
3. evaluate security implications
4. justify the dependency

Current compatibility verification includes:

```powershell
python -m pip check
```

`pip check` verifies dependency compatibility. It is not a vulnerability scanner.

A dedicated vulnerability scanner should be used during the final security milestone.

Potential tooling includes:

- `pip-audit`
- other trusted dependency scanners

The selected production process should be documented when adopted.

## 49. Repository Security

Before release, the repository must be reviewed for:

- committed secrets
- `.env` files
- debug code
- temporary credentials
- test credentials accidentally reused in production
- security bypass TODOs
- unsafe broad permissions
- stale dependencies
- accidental private data

Git history may also require review if a secret was ever committed.

Removing a secret from the current working tree does not remove it from repository history.

## 50. Error Handling

DRF exceptions handled by the application's custom exception handler use a consistent JSON envelope containing fields such as:

```text
error.code
error.message
error.fields
```

while preserving the appropriate HTTP status.

Validation failures normally return 400.

Authentication, permission, not-found, and throttling failures retain framework statuses such as:

- 401
- 403
- 404
- 429

Unknown `/api/v1/` routes may return JSON 404 responses without authentication.

Unexpected exceptions without a DRF response remain server errors.

The custom exception handler does not guarantee that every failure becomes a controlled 4xx response.

## 51. Information Disclosure

Error pages and responses should not reveal unnecessary sensitive details.

Production must not expose Django debug pages.

Sensitive internal information should not be included in:

- error messages
- audit metadata
- user-visible logs
- client-visible configuration
- API responses

## 52. Logging

Operational logging should support troubleshooting without becoming a sensitive-data store.

Avoid logging:

- passwords
- authentication tokens
- raw secrets
- assessment answers
- unnecessary personal information
- complete protected media paths where inappropriate

Production logging strategy will be finalized during deployment hardening.

## 53. Personal and Employee Data

The application stores Employee-related training information.

Access follows least-privilege principles.

Users should only see information required for their role.

Reports, dashboards, assignments, certificates, assessments, and training records must not expose unrelated Employee data.

## 54. Database Security

Production database access should use:

- dedicated application credentials
- least-required privileges
- protected credentials
- network restrictions where practical
- backups
- controlled administrative access

The application should not run using a broad database administrator account.

MySQL is the authoritative database for full-suite validation and production-oriented testing.

## 55. Backup Security

Database backups may contain sensitive Employee and training information.

Backups should therefore be:

- access controlled
- stored securely
- tested for restore
- retained according to business requirements

Backup and restore procedures will be finalized during deployment hardening.

## 56. Security Testing

Automated regression coverage includes security-sensitive areas such as:

- API login
- token refresh
- logout
- inactive or missing Employee rejection
- JWT and session-authenticated requests
- API error handling
- authentication throttling
- direct URL authorization
- Manager hierarchy scope
- Employee ownership
- CSRF-sensitive mutations
- malformed playback input
- video progress and anti-skip behavior
- assessment ownership
- assessment scoring
- assessment prerequisites
- certificate issuance
- certificate access
- certificate revocation
- reporting scope
- audit permissions and immutability

Test counts change over time.

The current validation baseline should be taken from the latest CI and local test output rather than hard-coded into this security document.

MySQL is used for authoritative full-suite backend runs.

Flutter analysis/tests and JavaScript playback tests are also part of the repository's validation workflow.

## 57. Final Security Review

A broader final security review is scheduled after the remaining frontend, Android, and E2E work.

This is intentional because:

- frontend routes may introduce new access paths
- Android workflows may reveal integration defects
- video playback introduces additional security boundaries
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
- protected video delivery
- Android media protections
- secrets
- dependencies
- privilege escalation
- race conditions
- direct URLs
- audit behavior
- deployment configuration

## 58. Security Tooling Plan

Current development should not be interrupted by excessive security tooling.

Planned late-stage security tooling may include:

- dependency vulnerability scanning
- repository secret review
- authorized application security testing
- targeted manual review
- Playwright security-path E2E tests
- Android-specific security verification where applicable

Automated security-tool findings must be reviewed before changes are applied.

Do not blindly accept automated security patches.

## 59. Security Release Gate

V1 should not be released until:

- full automated suite passes
- Android/Flutter validation passes
- E2E testing passes
- final security review completes
- production configuration is verified
- dependency review completes
- no known exploitable critical or high-severity issue remains
- no known important reproducible release-blocking bug remains unresolved
- repository secret review is complete
- HTTPS and secure-cookie behavior is verified
- protected media delivery is verified in the production-like topology

## 60. Incident Response Preparation

Before production operation, the team should know how to:

- disable a compromised account
- rotate compromised credentials
- rotate the Django secret if necessary
- revoke applicable authentication credentials
- restore a database backup
- inspect audit history
- identify affected training records
- invalidate or replace compromised media access paths
- roll back a bad deployment

Detailed operational procedures may be added during deployment hardening.

## 61. Security Change Policy

Changes affecting security-sensitive architecture should receive focused review.

Examples include:

- authentication changes
- permission changes
- Manager scope changes
- ownership logic
- session behavior
- playback session behavior
- playback completion logic
- assessment scoring
- certificate issuance
- audit behavior
- production settings
- protected media delivery

For such changes:

1. inspect current behavior
2. identify the security boundary
3. add or update focused tests
4. make the narrowest correct change
5. run focused tests
6. run the complete relevant suite
7. review the final diff
8. run the appropriate automated review

## 62. Current Security Status

The application currently has implemented security controls across the Django web platform, M13 API foundation, and M14-M15 Flutter Android foundation.

Implemented controls include:

- Django session authentication
- Django CSRF protection
- path-versioned JWT API authentication
- active Employee validation
- permission and object-scope checks
- Manager hierarchy scope enforcement
- server-authoritative training state
- server-authoritative learning progress
- server-authoritative assessment scoring
- server-authoritative certificate eligibility
- authenticated session-based video delivery
- protected playback progress/session handling
- concurrency controls in security-sensitive areas
- append-oriented audit behavior
- environment-based production secrets
- secure-cookie production defaults
- API throttling
- automated backend, Flutter, and playback validation

M16 is the next major learning/video milestone. It must preserve the existing security boundary rather than introduce a parallel media authorization model.

The M16 implementation must:

- reuse the existing M13 protected session-based media endpoint
- keep published media immutable
- keep the backend authoritative for playback/completion
- avoid unrestricted media URLs
- validate assignment, lesson, version, Employee, and session authorization
- apply appropriate Android media protections where required
- preserve the existing anti-skip and progress integrity model

Production readiness still depends on deployment configuration.

HTTPS redirect and HSTS are configurable rather than universally enabled by application defaults. Production hostnames must be supplied, reverse-proxy behavior must be verified, secure-cookie behavior must be tested, and protected media storage must preserve the authenticated delivery boundary.

`pip check` verifies dependency compatibility; it is not a vulnerability scan.

This document records application security behavior and requirements. It does not certify any particular deployment as secure.