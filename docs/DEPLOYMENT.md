# Deployment

## 1. Purpose

This document defines deployment requirements for the Garden's Need Training Module Application.

The application is currently pre-release.

Production infrastructure is not yet finalized. This document therefore distinguishes established security requirements from deployment-specific decisions that must be verified when the hosting architecture is selected.

---

## 2. Current Deployment Status

Current state:

```text
Production deployment: not completed
Production hardening: planned
```

The current roadmap schedules production and deployment hardening in:

```text
M20 - Production + Deployment Hardening
```

The system must be treated as development/pre-release until the production release gates are completed.

---

## 3. Current Production Architecture Direction

The intended production architecture remains deliberately simple.

Conceptually:

```text
User
 |
HTTPS
 |
Reverse Proxy / Hosting Router
 |
Django Application
 |
MySQL 8
```

Additional infrastructure may include:

```text
Static storage
Protected media storage
Database backup storage
Operational logs
Monitoring
```

The exact provider, server, reverse proxy, application server, and storage architecture must be documented only after they are selected and verified.

---

## 4. Production Requirements

Production must provide:

- Python runtime compatible with the application
- current supported Django version used by the project
- MySQL 8
- HTTPS
- secure secret management
- explicit allowed hosts
- secure cookies
- static-file handling
- protected media strategy
- database backups
- operational logging
- deliberate migration procedure
- rollback procedure
- smoke testing
- release monitoring

Production must not depend on developer-machine assumptions.

---

## 5. Environment Configuration

Production configuration must be supplied through environment variables or the hosting platform's secure configuration system.

Important settings include:

- DEBUG
- DJANGO_SECRET_KEY
- database name
- database user
- database password
- database host
- database port
- allowed hosts
- HTTPS/security settings

The exact variable names must always be verified against the current `config/settings.py`.

Do not invent configuration names in deployment documentation.

---

## 6. DEBUG

Production must run with:

```env
DEBUG=false
```

Production traffic must never run with DEBUG enabled.

Debug pages may expose:

- configuration
- filesystem paths
- stack traces
- database information
- internal application details

Local development may explicitly enable DEBUG through the local environment.

---

## 7. Django Secret Key

Production requires a strong unique secret.

Conceptually:

```env
DJANGO_SECRET_KEY=<strong-random-secret>
```

Requirements:

- unique to the production environment
- securely generated
- not committed to Git
- not stored in source code
- not exposed in screenshots or logs
- stored through the hosting platform's secret mechanism

Do not reuse a development secret.

---

## 8. Allowed Hosts

Production must use explicit allowed hosts.

Conceptually:

```env
ALLOWED_HOSTS=training.example.com
```

The actual syntax must match the current settings implementation.

Do not use unrestricted hosts without a documented reason and security review.

---

## 9. Database

Production uses MySQL 8.

Use a dedicated application database and a dedicated application database user.

Do not run Django using:

```text
root
```

The application database user should receive only the privileges required by the application.

---

## 10. Database Credentials

Database credentials must be supplied securely.

Never:

- commit passwords
- store credentials in Markdown
- paste production passwords into issues
- reuse development passwords
- expose credentials in logs

If a real production credential is ever committed, remove it and rotate it.

---

## 11. Database Backups

A verified backup strategy is required before production release.

The strategy must define:

- frequency
- retention
- storage location
- access control
- encryption where appropriate
- restore procedure
- restore testing

A backup that has never been restored successfully is not fully verified.

---

## 12. Database Restore Test

Before V1 release, perform at least one restore test in a non-production environment.

Verify:

- database restoration succeeds
- migrations remain consistent
- application starts
- important records are readable
- required relationships remain intact

Document the verified restore procedure.

---

## 13. Database Migrations

Production migrations must be deliberate.

Typical command:

```powershell
python manage.py migrate
```

Before applying migrations:

1. verify the target environment
2. confirm the database backup
3. inspect migration files
4. verify the current schema state
5. understand data transformations
6. understand rollback implications

Never run migrations blindly against production.

---

## 14. Migration Consistency

Before deployment:

```powershell
python manage.py makemigrations --check --dry-run
```

Unexpected migration output must be investigated.

Do not create schema changes accidentally during deployment.

---

## 15. Static Files

Django development static serving must not be treated as the final production solution.

Production may use:

- reverse proxy/static server
- hosting-platform static storage
- object storage/CDN
- another verified deployment-specific solution

The selected implementation must be documented after it is tested.

---

## 16. Collectstatic

Where required:

```powershell
python manage.py collectstatic
```

The exact command and destination depend on the final static-file architecture.

Test the process in staging or an equivalent production-like environment first.

---

## 17. Training Media

Training videos are protected internal learning content.

Do not expose them through an unrestricted public media URL.

The existing M13 architecture provides a protected session-based endpoint:

```text
assignments/<assignment_id>/lessons/<lesson_id>/sessions/<session_id>/media/
```

It verifies the authenticated employee's assignment, lesson, and active/recent watch-session state, including byte-range requests.

This endpoint is the authoritative V1 media path.

Do not create a second unrestricted video route.

---

## 18. Production Media Delivery

The current protected Django media path is suitable for the existing architecture and local/development validation.

For production, large video delivery should be evaluated carefully.

Potential production approaches include:

- protected reverse-proxy delivery
- private object storage
- temporary signed access
- controlled storage handoff
- authenticated Django streaming where appropriate

Any production optimization must preserve the existing authorization rules.

Do not document an alternative media architecture as implemented until it has actually been built and verified.

---

## 19. Media Storage Boundary

Training media should remain behind a storage abstraction.

This allows a future move from local filesystem storage to protected object storage without changing the authorization model.

Production media should not be placed in a public static directory.

The selected production storage must support the required byte-range/seek behavior for video playback.

---

## 20. Video Security Boundary

A browser or mobile application cannot absolutely prevent:

- screenshots
- OS-level recording
- external camera recording
- determined local capture

Web and Android controls reduce casual misuse but do not provide absolute capture prevention.

Possible future controls include:

- watermarking
- short-lived playback authorization
- session restrictions
- additional access logging
- Android `FLAG_SECURE` where appropriate

These controls must not be represented as complete capture prevention.

---

## 21. HTTPS

Production must use HTTPS.

Authenticated traffic must not rely on plain HTTP.

HTTPS protects:

- credentials
- cookies
- CSRF tokens
- employee information
- training activity
- API traffic

A valid TLS certificate must be maintained.

---

## 22. HTTPS Redirect

HTTP-to-HTTPS redirect may be enabled after the production proxy configuration is verified.

Test for:

- redirect loops
- incorrect proxy headers
- mixed-content problems
- incorrect secure-request detection

Do not enable redirect behavior blindly.

---

## 23. Secure Cookies

When DEBUG is disabled, secure session cookies must remain enabled.

Expected production behavior includes:

```text
SESSION_COOKIE_SECURE = True
```

Do not weaken secure cookies to work around deployment problems.

Fix the HTTPS/proxy configuration instead.

---

## 24. Secure CSRF Cookies

Production CSRF cookies should use secure transport.

Expected behavior includes:

```text
CSRF_COOKIE_SECURE = True
```

Verify this through the real HTTPS environment.

---

## 25. HSTS

HSTS should be configured deliberately during production hardening.

Relevant settings include:

```text
SECURE_HSTS_SECONDS
SECURE_HSTS_INCLUDE_SUBDOMAINS
SECURE_HSTS_PRELOAD
```

Do not enable aggressive long-term HSTS settings until the HTTPS configuration has been verified.

---

## 26. Reverse Proxy

The production Django application will commonly operate behind a reverse proxy or hosting router.

The proxy may provide:

- TLS termination
- static files
- request forwarding
- security headers
- rate limiting

Django must correctly determine whether the original request was secure.

---

## 27. Proxy Trust

Secure proxy configuration must only trust a known and controlled proxy.

Incorrect forwarded-header trust can create security problems.

Final proxy settings must match the actual hosting architecture.

---

## 28. Application Server

Do not use:

```powershell
python manage.py runserver
```

for production traffic.

Use a supported production application server appropriate to the final hosting platform.

The exact server should be documented after selection and validation.

---

## 29. Operating System

Local development currently occurs on Windows.

Production may use Linux or another supported environment.

A Linux deployment is a reasonable option, but the final decision should consider:

- hosting
- administration
- maintenance
- cost
- security
- backup strategy
- team familiarity

Do not document an unselected platform as final.

---

## 30. Dependency Installation

Use a clean production environment.

Dependencies should come from the project's dependency files.

Conceptually:

```powershell
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

Do not depend on packages that happen to exist globally on a developer machine.

---

## 31. Dependency Verification

Before deployment:

```powershell
python -m pip check
```

This verifies installed-package consistency.

A vulnerability scan such as `pip-audit` should be included in the final release-security workflow after the tool is selected and adopted.

---

## 32. Django Deployment Checks

Before production:

```powershell
python manage.py check
```

Also evaluate:

```powershell
python manage.py check --deploy
```

Deployment warnings must be reviewed against the actual environment.

Do not blindly suppress warnings.

---

## 33. Automated Test Requirement

The latest verified automated baseline must pass before release.

Current baseline:

```text
Django/MySQL: 348 / 348
Flutter: 81 / 81
Flutter analyze: 0 issues
JavaScript playback: 3 / 3
```

The baseline may increase as development continues.

Always use the latest verified counts.

---

## 34. CI Requirement

GitHub Actions CI covers the major automated validation surfaces.

The expected CI coverage includes:

- dependency installation
- MySQL
- Django checks
- migration consistency
- Django/MySQL tests
- pip check
- Flutter analyze
- Flutter tests
- JavaScript playback tests

CI must pass before a release candidate is treated as stable.

---

## 35. E2E Requirement

Browser E2E validation should cover critical Django web workflows.

Important flows include:

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
-> Reports
-> Logout
```

Negative authorization flows must also be tested.

Android runtime testing becomes especially important for the M19 release candidate.

---

## 36. Production Data

Never use uncontrolled fake data in production.

Keep staging and production data separate.

If a production smoke test requires data creation:

- keep it minimal
- make it deliberate
- document it
- clean it up safely where appropriate

Prefer read-only or low-impact verification.

---

## 37. Production Administrative Access

A production administrative account may be required.

If created:

- use a strong unique credential
- protect it
- avoid unnecessary sharing
- use named accounts for ordinary operational activity

Do not use a shared superuser for routine employee operations.

---

## 38. Groups and Permissions

After deployment, verify expected role groups and permissions.

Current groups:

```text
Administrator
Training Coordinator
Manager
Trainer
Supervisor
Employee
```

Permission migrations must be applied before relying on the final role configuration.

---

## 39. Initial Deployment Verification

After deployment verify:

- application starts
- database connection works
- migrations are correct
- static assets load
- login page loads
- valid login succeeds
- invalid login fails safely
- logout succeeds
- authorized dashboard loads
- unauthorized routes remain protected
- HTTPS works
- secure cookies are present
- DEBUG is not exposed
- protected media remains protected

---

## 40. Smoke Test

Basic smoke test:

```text
[ ] Homepage responds
[ ] Login page responds
[ ] Valid login succeeds
[ ] Invalid login fails safely
[ ] Dashboard loads
[ ] Static assets load
[ ] Database reads work
[ ] Protected URL rejects unauthorized account
[ ] Logout works
[ ] HTTPS remains active
[ ] Secure cookies behave correctly
[ ] Protected media remains inaccessible without authorization
```

Expand this checklist after the final product workflows are complete.

---

## 41. Operational Logging

Production logs should help diagnose:

- startup failures
- database failures
- unexpected HTTP errors
- application failures
- deployment problems

Do not log:

- passwords
- secret keys
- raw authentication tokens
- unnecessary assessment answers
- sensitive employee information

---

## 42. Audit Logs vs Operational Logs

These serve different purposes.

Audit logs answer:

```text
Who performed an important business action?
```

Operational logs answer:

```text
Why did the application fail or behave unexpectedly?
```

Neither should be treated as a replacement for the other.

---

## 43. Error Monitoring

A third-party error-monitoring service may be evaluated after the deployment architecture is known.

Before adding one, consider:

- privacy
- employee data
- operational value
- retention
- cost
- integration complexity

Do not add a monitoring dependency without a justified requirement.

---

## 44. Rate Limiting

Production exposure should include a rate-limiting review.

Consider:

- login
- malformed requests
- expensive API endpoints
- authentication endpoints

Rate limiting may be provided by:

- reverse proxy
- hosting platform
- application layer

Do not claim rate limiting exists until verified.

---

## 45. Session Policy

Before production release, review:

- session lifetime
- logout behavior
- concurrent sessions
- token invalidation
- shared-device behavior
- credential persistence

The final policy should match actual Garden's Need operational requirements.

---

## 46. Shared Devices

Factory environments may use shared devices.

Shared-device concerns include:

- rapid logout
- employee switching
- remembered credentials
- stale sessions
- session leakage

A dedicated shared-device workflow remains future scope unless explicitly added before V1.

---

## 47. Database Capacity

Monitor:

- disk usage
- backup size
- query performance
- connection count
- error rate

Database optimization should be driven by measured behavior.

---

## 48. Media Capacity

Training videos may consume significantly more storage and bandwidth than ordinary application data.

Before large-scale rollout, estimate:

- number of videos
- average video size
- expected growth
- storage requirements
- backup implications
- bandwidth requirements

Production media may eventually need object storage rather than application-server filesystem storage.

---

## 49. Security Review Before Release

The final broad security review belongs to M21.

Review:

- secrets
- repository state
- dependencies
- authentication
- permissions
- IDOR
- CSRF
- cookies
- HTTPS
- security headers
- sessions
- direct URLs
- media access
- playback
- assessments
- certificates
- reports
- audit logs
- deployment configuration

---

## 50. Secret Scan

Before release inspect the repository for:

- `.env`
- database passwords
- Django secret keys
- API keys
- access tokens
- private certificates
- copied credentials

If a real secret was committed, rotation is required.

Deleting it from the current source is not sufficient because it may remain in Git history.

---

## 51. Dependency Vulnerability Scan

Before production release, run a trusted dependency vulnerability scanner.

A candidate tool is:

```text
pip-audit
```

The selected tool and workflow should be documented once adopted.

Findings must be reviewed rather than blindly patched.

---

## 52. Staging Environment

A staging or production-like environment is strongly recommended before V1 release.

Staging should resemble production in:

- database engine
- HTTPS behavior
- secure cookies
- environment settings
- static handling
- media access
- proxy behavior

Do not use real sensitive production data unless necessary and properly protected.

---

## 53. Deployment Sequence

A typical deployment sequence is:

```text
1. Confirm stable Git commit
2. Confirm CI passes
3. Back up production database
4. Load production environment configuration
5. Install/update dependencies
6. Apply migrations
7. Collect/deploy static assets
8. Restart application
9. Run smoke tests
10. Review logs
11. Confirm protected media behavior
```

Adapt the sequence to the final hosting platform.

---

## 54. Rollback Strategy

Every production deployment must have a rollback plan.

Consider:

- application code
- database migrations
- static assets
- configuration
- media changes

Code rollback may involve returning to a previous stable Git commit.

Database rollback is more complicated.

Never assume a migration is safely reversible.

---

## 55. Migration Rollback

Before applying a migration, understand:

- whether it is reversible
- whether data is transformed
- whether old application code can run against the new schema
- whether a backup restore is the safer recovery mechanism

For dangerous migrations, database backup and restore may be preferable to reverse migration.

---

## 56. Failed Deployment

If deployment fails:

1. stop further changes
2. identify whether the problem is code, configuration, database, or infrastructure
3. preserve logs
4. roll back if necessary
5. verify database integrity
6. rerun smoke tests
7. document reusable lessons

Do not improvise multiple unrelated production changes simultaneously.

---

## 57. Zero-Downtime Deployment

Zero-downtime deployment is not a V1 requirement unless business operations require it.

Prefer a simple, reliable deployment process.

A short controlled maintenance window may be acceptable if operational requirements permit it.

---

## 58. Production Release Gate

Production release requires:

```text
[ ] Core functionality complete
[ ] Latest automated test suites pass
[ ] GitHub Actions CI passes
[ ] Critical browser E2E flows pass
[ ] Android release-candidate validation passes
[ ] Final bug hunt complete
[ ] Final security/repository review complete
[ ] Dependency vulnerability scan reviewed
[ ] DEBUG disabled
[ ] Strong production secret configured
[ ] Allowed hosts configured
[ ] HTTPS verified
[ ] Secure cookies verified
[ ] Database backup configured
[ ] Restore procedure tested
[ ] Static files verified
[ ] Protected media strategy verified
[ ] Smoke tests pass
[ ] Rollback procedure documented
[ ] Documentation current
```

---

## 59. Post-Deployment Verification

Immediately after release:

1. inspect application health
2. verify login
3. verify important dashboards
4. verify static assets
5. inspect logs
6. verify database connectivity
7. verify HTTPS
8. verify secure cookies
9. verify protected routes
10. verify protected media
11. confirm no unexpected migration/startup errors

---

## 60. Post-Release Monitoring

After V1 release monitor:

- unexpected errors
- performance bottlenecks
- confusing workflows
- permission problems
- training completion problems
- playback problems
- assessment problems
- certificate problems
- support requests

Prioritize future changes using actual operational evidence.

---

## 61. Production Incident Preparation

The team should know how to:

- disable an account
- revoke compromised credentials
- rotate secrets
- restore backups
- roll back deployment
- inspect audit records
- inspect operational logs
- investigate protected media access

More detailed incident procedures can be added after the hosting architecture is finalized.

---

## 62. Documentation Maintenance

Update this file whenever the real production architecture changes.

Replace assumptions with verified information such as:

- hosting provider
- operating system
- server type
- domain
- reverse proxy
- application server
- database host
- static storage
- media storage
- backup schedule
- deployment commands
- rollback commands
- monitoring

Do not leave deployment-specific guesses in the final production documentation.

---

## 63. Current Deployment Readiness

Current state:

```text
Backend/API: complete through M15
Flutter Android foundation: complete through M15
Current backend tests: 348 / 348
Current Flutter tests: 81 / 81
Current JavaScript playback tests: 3 / 3
CI: implemented and part of current validation
Frontend/web: existing and maintained
M16: next
Production hardening: planned for M20
Final bug/security review: M21
Android release candidate: M19
Final acceptance: M23
Production V1 release: pending
```

The application is not yet production-ready.

Deployment-specific infrastructure should be finalized during M20 rather than invented prematurely.