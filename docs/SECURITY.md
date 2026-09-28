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

The project uses Django's built-in authentication system.

Authentication requirements include:

- protected views require authenticated users
- login is handled through Django-backed authentication
- logout uses the configured application flow
- authentication does not automatically imply authorization

A valid login only establishes identity.

Every protected action must still enforce the required permission and scope.

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

All protected objects must remain protected when accessed through a direct URL.

The application must not rely only on navigation visibility.

Examples:

A Manager who cannot see an Employee in the interface must also be unable to open that Employee directly by changing the URL.

An Employee who cannot see another Employee's certificate must also be unable to access it by guessing its identifier.

Out-of-scope objects should return controlled responses such as:

```text
403 Forbidden
404 Not Found
```

depending on the established application behavior.

## 8. Manager Scope

Manager access is constrained by the recursive reporting hierarchy.

A Manager may operate only within the authorized reporting subtree.

Conceptually:

```text
Manager
 |
 +--> Direct Report
       |
       +--> Descendant
```

Manager scope must be calculated on the backend.

The client must not define the Manager's authorized employee set.

Filters, URL parameters, form fields, and crafted identifiers must never broaden this scope.

## 9. Employee Scope

Employees should primarily access their own records.

Examples include:

- their own assignments
- their own progress
- their own assessment attempts
- their own results
- their own certificates

The authenticated User-to-Employee relationship should be used as the trusted source of ownership where appropriate.

The backend should not trust an arbitrary employee ID supplied by the browser when ownership can be derived from the authenticated user.

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

Django CSRF protection must remain enabled.

State-changing forms and requests must include valid CSRF protection.

Do not disable CSRF globally to simplify frontend implementation.

Any API-like browser request using POST must follow the project's CSRF strategy.

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

## 22. Video Progress Security

Video progress is server authoritative.

The browser must not be allowed to declare:

- authoritative watched duration
- completion
- valid watched ranges

The backend validates playback observations.

Current protections include:

- session ownership
- assignment validation
- lesson validation
- heartbeat tracking
- watched ranges
- anti-skip logic
- idle-gap protection
- position validation
- concurrency-safe updates

## 23. Video Anti-Skip Boundary

The anti-skip system is designed to prevent simple manipulation.

A previously reproduced vulnerability allowed idle time to contribute excessive playback credit.

The hardened logic prevents credit across excessive idle gaps.

It also prevents a client from repeatedly regenerating tolerance across sessions.

Playback heartbeats should be sent frequently enough to remain within the server's accepted observation window.

## 24. Playback Metadata

Playback metadata must be validated.

Unbounded or structured values should not be blindly converted to strings and stored.

Session-related labels should remain controlled and length-limited.

Malformed playback metadata should return controlled validation errors.

## 25. Assessment Security

Assessment scoring is entirely server-side.

The browser must not be trusted to supply:

- final score
- pass/fail result
- correct answers
- authoritative completion

The backend must determine:

- attempt eligibility
- question data
- answer correctness
- score
- pass/fail
- training completion effect

## 26. Assessment Attempt Controls

Assessment logic must preserve:

- attempt limits
- prerequisite checks
- ownership
- assessment availability
- time boundaries
- completion state

Concurrency around attempt creation and submission must be handled safely.

Exact time boundaries should be covered by tests where relevant.

## 27. Question and Assessment Races

Save-time validation can still fail after a form has already validated.

The application must handle expected save-time uniqueness races without returning uncontrolled HTTP 500 responses.

A previously reproduced Question creation race could proceed into revision creation without a valid saved Question.

The flow now stops safely when Question creation returns validation errors.

## 28. Certificate Security

Certificates must be based on authoritative training completion.

The browser cannot directly request a certificate and become eligible simply by doing so.

Certificate creation must verify backend state.

Issuance is idempotent.

Repeated completion processing must not create duplicate certificates.

## 29. Certificate Revocation

Revocation must:

- require appropriate permission
- use a state-changing request
- preserve the certificate record
- preserve audit history
- validate revocation input

Revocation reasons are length bounded.

Revocation should never delete the historical certificate record.

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

Audit events should contain authoritative server-derived information.

The client must not control:

- actor
- target
- timestamp
- authoritative event type

Audit metadata should be whitelisted or deliberately constructed.

Do not store:

- passwords
- tokens
- secrets
- assessment answers
- unnecessary training body content

## 32. Transaction-Aware Auditing

Audit success events must correspond to committed business actions.

Where appropriate, audit creation uses transaction commit hooks.

This prevents:

```text
business action rolls back
but success audit record remains
```

The audit system is configured so that audit-log failure does not necessarily undo a valid business transaction.

This tradeoff is intentional and should not be changed casually.

## 33. Audit Permissions

The normal audit interface is read-only.

Authorized users currently include the groups explicitly granted the audit viewing permission, including:

- Administrator
- Training Coordinator

Manager and Employee users must not gain audit access without an explicit authorization change.

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

Production must use:

```text
DEBUG=False
```

The project uses a fail-closed default for DEBUG.

If DEBUG is not explicitly enabled for development, it should not silently become true.

Local development currently uses:

```env
DEBUG=true
```

## 36. Django Secret Key

Production requires a strong:

```text
DJANGO_SECRET_KEY
```

A production application must not start with a predictable or committed fallback secret.

Secret rotation should be planned carefully because it may affect signed state and sessions.

## 37. Allowed Hosts

Production should use explicit allowed hosts.

Do not use broad or unsafe host configuration without a deployment-specific reason.

Allowed hosts must match the actual deployment environment.

## 38. HTTPS

Production must use HTTPS.

Relevant production settings may include:

- SSL redirect
- secure session cookie
- secure CSRF cookie
- HSTS

The exact final values will be established during the production and deployment hardening milestone.

## 39. Secure Cookies

When running in production:

- session cookies should be secure
- CSRF cookies should be secure

The application already defaults these settings securely when debug mode is disabled.

Do not weaken them merely to work around a deployment configuration issue.

Fix the deployment configuration instead.

## 40. HSTS

HTTP Strict Transport Security should be configured during production hardening.

The exact HSTS duration should not be chosen blindly.

A short initial deployment validation period may be appropriate before increasing the value.

HSTS configuration should reflect the actual HTTPS deployment architecture.

## 41. Proxy and HTTPS Awareness

If the application is deployed behind a reverse proxy, proxy headers and secure-request detection must be configured correctly.

Incorrect proxy configuration can cause:

- broken CSRF behavior
- incorrect HTTPS detection
- redirect loops
- insecure cookie behavior

This must be verified against the real production environment.

## 42. Static and Media Security

Static and media files require separate consideration.

Static assets may generally be public application assets.

Training media may contain internal content and may require access control.

Protected training video must not be assumed secure merely because its URL is difficult to guess.

A final protected-media strategy will be completed during deployment hardening.

## 43. Video Content Protection Boundary

A normal web application cannot fully prevent:

- operating-system screen recording
- external camera recording
- determined local capture

Web-based protections can reduce casual misuse but cannot guarantee prevention.

Potential V1 protections may include:

- authenticated video access
- temporary playback authorization
- employee watermarking
- audit logging
- session controls

Stronger capture prevention may require a native mobile application.

For Android, platform-specific secure window controls may be considered in a future native application.

## 44. Session Security

Session security should preserve:

- authenticated ownership
- secure cookie behavior in production
- CSRF protection
- session invalidation behavior
- reasonable login lifecycle

Future production review should consider whether additional controls are needed for:

- session duration
- concurrent sessions
- one-device policies
- login throttling

These should not be claimed as implemented unless verified.

## 45. Brute-Force and Rate Limiting

Application-level login throttling has not been established as a verified current feature.

Before public or externally exposed deployment, rate limiting should be reviewed at:

- reverse proxy
- infrastructure
- application

Do not claim login throttling is implemented unless it is actually verified.

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

Known invalid user actions should not normally produce HTTP 500.

Controlled failure modes include:

```text
400 - invalid request
403 - not authorized
404 - unavailable or out of scope
409 - state conflict
```

Unexpected server failures should still be logged and investigated.

Confirmed uncontrolled failures should receive regression tests where practical.

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

Security testing currently includes automated regression coverage for important authorization and malformed-input paths.

Current automated baseline:

```text
189 full tests passing on MySQL
```

Security-related test areas include:

- direct URL authorization
- Manager hierarchy scope
- Employee self-scope
- privileged account protections
- CSRF-sensitive mutation behavior
- malformed playback input
- playback anti-skip
- duplicate state transitions
- concurrency-sensitive assignment behavior
- assessment ownership
- certificate access
- reporting scope
- audit permissions

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

The core backend has already received a dedicated security hardening pass and an additional interim backend bug hunt.

Important fixes have included:

- fail-closed DEBUG behavior
- production secure-cookie defaults
- idle playback abuse prevention
- cross-session playback tolerance control
- malformed playback metadata validation
- repeated employee-deactivation protection
- assignment race handling
- save-time uniqueness error handling

Current automated baseline:

```text
189 full tests passing on MySQL
```

The application should still be treated as pre-release until frontend, E2E, deployment, and final security milestones are complete.