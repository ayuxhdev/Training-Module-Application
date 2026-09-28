# Deployment

## 1. Purpose

This document defines the production deployment requirements and deployment checklist for the Garden's Need Training Module Application.

The application is still pre-release.

The exact production infrastructure may change later, but the deployment must preserve the application's existing security, database, and authorization assumptions.

## 2. Current Deployment Status

Current status:

```text
Production deployment not yet completed.
```

Deployment hardening is scheduled for:

```text
Milestone 15 - Production + Deployment Hardening
```

The current application should be treated as a development/pre-release system until that milestone is complete.

## 3. Production Architecture

The initial production deployment should remain simple.

Conceptually:

```text
User Browser
     |
   HTTPS
     |
     v
Reverse Proxy / Web Server
     |
     v
Django Application
     |
     v
MySQL 8
```

Additional infrastructure may include:

```text
Static File Storage
Media / Training Video Storage
Database Backup Storage
Application Logs
Monitoring
```

The exact hosting provider and server layout should be finalized during the deployment milestone.

## 4. Production Requirements

Production deployment must include:

- Python-compatible production environment
- Django 5.2 LTS
- MySQL 8
- HTTPS
- secure secret management
- explicit allowed hosts
- secure cookies
- static file handling
- media file strategy
- database backups
- operational logging
- migration procedure
- rollback procedure
- smoke testing

Production must not depend on local development assumptions.

## 5. Environment Variables

Production configuration must use environment variables.

Do not commit production configuration values into Git.

Required configuration should follow the variable names used by:

```text
config/settings.py
```

Important production configuration includes:

- DEBUG
- DJANGO_SECRET_KEY
- database name
- database user
- database password
- database host
- database port
- allowed hosts
- HTTPS/security settings

The exact variable names must be verified against the current implementation before deployment.

## 6. DEBUG

Production must use:

```env
DEBUG=false
```

The application should never run production traffic with:

```env
DEBUG=true
```

Django debug pages may expose sensitive internal information.

The current settings are intentionally designed so that DEBUG defaults to disabled.

Local development explicitly enables it through the local environment.

## 7. Django Secret Key

Production requires a strong secret key.

Example configuration:

```env
DJANGO_SECRET_KEY=<strong-random-secret>
```

Requirements:

- unique to the production environment
- generated securely
- not committed to Git
- not shared in screenshots
- not stored in source code
- protected through the hosting environment's secret-management mechanism

Do not reuse a development secret.

## 8. Allowed Hosts

Production must define explicit allowed hosts.

Example concept:

```env
ALLOWED_HOSTS=training.example.com
```

The actual format must match the parsing implemented in `config/settings.py`.

Do not deploy using unrestricted host configuration unless the deployment architecture specifically requires it and the risk is understood.

## 9. Database Configuration

Production uses MySQL 8.

The application should use a dedicated MySQL user.

Do not run the Django application using:

```text
root
```

or another broad database administrator account.

The production database user should have only the privileges required by the application.

## 10. Database Credentials

Database credentials must be stored securely.

Do not:

- commit them to Git
- put them directly in documentation
- paste production passwords into issue trackers
- reuse local development passwords

Credentials should be provided through the production environment.

## 11. Database Name

Production should use a dedicated application database.

Example concept:

```text
gardens_training
```

The final production name may differ.

Do not assume the development database should automatically become the production database.

## 12. Database Backups

A backup plan is required before production use.

Backups should include the MySQL database.

The backup plan should define:

- backup frequency
- retention period
- storage location
- encryption/access protection
- restore procedure
- restore testing

A backup that has never been successfully restored should not be considered fully verified.

## 13. Backup Security

Backups contain internal employee and training data.

They should be treated as sensitive.

Protect backups using:

- restricted access
- secure storage
- encryption where available
- retention controls

Do not place backups in public directories.

## 14. Database Restore Test

Before release, perform at least one restore test in a non-production environment.

Verify that:

- the database restores successfully
- migrations remain consistent
- the application can start
- important records are readable

Document the restore procedure after it has been verified.

## 15. Migrations

Production deployment must run Django migrations deliberately.

Typical command:

```powershell
python manage.py migrate
```

Before running migrations:

1. ensure the correct environment is loaded
2. ensure the database backup is current
3. review migration files
4. verify the target database
5. understand whether the migration is reversible

Do not run migrations blindly against production.

## 16. Migration Check Before Deployment

Before deployment, run:

```powershell
python manage.py makemigrations --check --dry-run
```

Expected result:

```text
No changes detected
```

Unexpected migrations should be investigated before release.

## 17. Static Files

Production must have a proper static-file strategy.

Django development static serving must not be treated as the final production architecture.

Production static handling may use:

- reverse proxy
- hosting platform static service
- object storage/CDN
- another deployment-specific solution

The final implementation should be chosen during Milestone 15.

## 18. Collecting Static Files

If the selected deployment requires Django's static collection process, run:

```powershell
python manage.py collectstatic
```

The actual command and destination depend on the final static-file configuration.

This should be tested in staging or a production-like environment first.

## 19. Media Files

Media requires more careful handling than normal public static assets.

The application may eventually contain:

- training videos
- training media
- internal learning content

Internal training media must not be assumed safe simply because the file URL is difficult to guess.

## 20. Protected Training Media

The final deployment should evaluate authenticated or controlled access to training media.

Possible approaches may include:

- authenticated Django access
- protected reverse-proxy routes
- temporary signed URLs
- controlled object-storage access
- short-lived playback authorization

The exact solution must match the final hosting architecture.

Do not document one of these as implemented until it has actually been built and tested.

## 21. Video Security Boundary

A browser-based application cannot fully prevent:

- OS-level screen recording
- screenshots
- external camera recording
- determined local capture

Web protections can reduce casual misuse but do not provide absolute prevention.

Potential future controls include:

- employee watermark
- temporary playback tokens
- session restrictions
- access logging

Native mobile capture protection remains future scope.

## 22. HTTPS

Production must use HTTPS.

Plain HTTP should not be used for authenticated production traffic.

HTTPS protects:

- login credentials
- session cookies
- CSRF tokens
- employee data
- training activity

A valid TLS certificate must be installed and maintained.

## 23. HTTPS Redirect

Production may enable HTTP-to-HTTPS redirect.

This should be verified with the real deployment environment.

Incorrect reverse-proxy configuration can cause redirect loops.

Do not enable production redirect behavior blindly without testing.

## 24. Secure Session Cookies

Production session cookies should be secure.

Expected production behavior includes:

```text
SESSION_COOKIE_SECURE = True
```

The current project settings default secure cookies appropriately when DEBUG is disabled.

Do not weaken this setting to work around an HTTPS configuration problem.

## 25. Secure CSRF Cookies

Production CSRF cookies should also use secure transport.

Expected production behavior includes:

```text
CSRF_COOKIE_SECURE = True
```

This must be tested through the actual deployed HTTPS environment.

## 26. HSTS

HTTP Strict Transport Security should be evaluated during production hardening.

Relevant settings may include:

```text
SECURE_HSTS_SECONDS
SECURE_HSTS_INCLUDE_SUBDOMAINS
SECURE_HSTS_PRELOAD
```

Do not immediately choose an aggressive long-term HSTS configuration without verifying HTTPS behavior.

A staged rollout is safer.

## 27. Reverse Proxy

A production Django application will commonly run behind a reverse proxy or hosting platform router.

The proxy may be responsible for:

- HTTPS termination
- static files
- request forwarding
- security headers
- rate limiting

Django must correctly understand whether the original request was secure.

## 28. Proxy Security Header

If HTTPS terminates at a trusted reverse proxy, the application may require appropriate secure proxy configuration.

This must only be configured when the proxy is trusted and known.

Incorrect proxy trust can create security problems.

Final settings must reflect the actual infrastructure.

## 29. Application Server

Django's development server:

```powershell
python manage.py runserver
```

must not be used as the production application server.

The final production environment should use a supported production server appropriate to the operating system and hosting platform.

The exact server choice will be decided during deployment implementation.

## 30. Windows vs Linux Deployment

Local development currently occurs on Windows.

Production does not have to use Windows.

A Linux deployment is generally suitable for Django and MySQL, but the actual environment should be chosen based on:

- hosting
- administration skills
- maintenance requirements
- cost
- security
- backup strategy

Deployment documentation should be updated once the target platform is selected.

## 31. Dependency Installation

Production dependencies should be installed from the project's dependency file.

Typical process:

```powershell
python -m pip install --upgrade pip
pip install -r requirements.txt
```

Use a clean environment.

Do not rely on packages that happen to be installed globally on a developer machine.

## 32. Virtual Environment

Production should use an isolated Python environment where appropriate.

Example concept:

```text
.venv
```

The actual mechanism may differ depending on the hosting platform.

## 33. Dependency Verification

Before deployment, run:

```powershell
python -m pip check
```

This verifies basic installed-package dependency consistency.

A dedicated vulnerability scan will be included during the final security milestone.

## 34. Application Checks

Before deployment, run:

```powershell
python manage.py check
```

For production-specific validation, additional Django deployment checks should also be considered.

Example:

```powershell
python manage.py check --deploy
```

Any warnings must be reviewed in the context of the actual production configuration.

Do not ignore deployment warnings automatically.

## 35. Automated Tests

The complete automated suite must pass before release.

Current baseline:

```text
189 full tests passing on MySQL
```

The baseline may increase as development continues.

The final release should use the latest verified passing test count.

## 36. CI Requirement

GitHub Actions CI will be added during Milestone 11.

CI should verify at minimum:

- dependency installation
- MySQL startup
- Django system check
- migration consistency
- automated tests
- dependency consistency

CI must pass before a release candidate is considered stable.

## 37. E2E Requirement

Playwright E2E testing will be added during later milestones.

Before production release, critical browser workflows should pass.

Examples include:

```text
Login
Dashboard
Training Assignment
Lesson
Video
Assessment
Training Completion
Certificate
Reports
Logout
```

Negative authorization flows should also be tested.

## 38. Production Data

Do not use uncontrolled fake data in production.

Development and staging data should remain clearly separated from production records.

If test data must be created temporarily in production for deployment verification, it should be minimal, deliberate, and cleaned up safely.

Prefer smoke testing that does not alter important production records.

## 39. Superuser

A production superuser may be required for initial administration.

If created:

- use a strong password
- protect the credentials
- do not share the account unnecessarily
- do not use the account for ordinary employee activity

Named user accounts are preferable for normal operational accountability.

## 40. Initial Groups and Permissions

After deployment, verify that expected application groups and permissions exist.

Current role groups include:

```text
Administrator
Training Coordinator
Manager
Trainer
Supervisor
Employee
```

Permission migrations must be applied before relying on these roles.

## 41. Initial Production Verification

After deployment, verify:

- application starts
- database connection works
- migrations are applied
- static files load
- login page loads
- login succeeds
- logout succeeds
- expected dashboard loads
- unauthorized pages remain protected
- HTTPS works
- secure cookies are present
- no debug page is exposed

## 42. Smoke Test

A basic smoke-test checklist may include:

```text
[ ] Homepage responds
[ ] Login page responds
[ ] Valid login succeeds
[ ] Invalid login fails safely
[ ] Dashboard loads
[ ] Static CSS loads
[ ] Database reads work
[ ] Permission-protected URL rejects unauthorized account
[ ] Logout works
[ ] HTTPS remains active
```

The checklist should be expanded when the final frontend is complete.

## 43. Logging

Production needs operational logging.

Logging should help diagnose:

- startup failures
- database failures
- unexpected HTTP 500 errors
- deployment issues

Logging must avoid unnecessary sensitive information.

Do not log:

- passwords
- secret keys
- raw authentication tokens
- assessment answers

## 44. Error Monitoring

A production error-monitoring solution may be considered later.

Do not add a third-party monitoring dependency until:

- the deployment architecture is known
- privacy implications are understood
- the operational need is clear

Basic server and application logs are still required.

## 45. Audit Logs vs Operational Logs

Application audit logs and operational server logs have different purposes.

Audit logs answer questions such as:

```text
Who performed an important business action?
```

Operational logs answer questions such as:

```text
Why did the application fail or behave unexpectedly?
```

Do not use one as a substitute for the other.

## 46. Rate Limiting

Production exposure should include a review of rate limiting.

Areas to consider include:

- login
- repeated malformed requests
- expensive endpoints

Rate limiting may be implemented at:

- reverse proxy
- hosting platform
- application layer

Do not claim this protection exists until verified.

## 47. Session Policy

Before production, review:

- session lifetime
- logout behavior
- concurrent sessions
- session invalidation
- shared device use

The final policy should reflect actual Garden's Need operational requirements.

## 48. Shared Devices

Factory environments may eventually use shared devices.

Shared-device behavior requires additional consideration, including:

- rapid logout
- session leakage
- remembered credentials
- employee switching

A dedicated shared-device workflow remains future scope unless added before release.

## 49. Monitoring Database Capacity

Production should monitor database health over time.

Useful indicators include:

- disk usage
- backup size
- query performance
- connection count
- error rate

Optimization should be driven by measured problems.

## 50. File Storage Capacity

Training videos may consume significantly more storage than normal application data.

Before large-scale rollout, estimate:

- number of videos
- average video size
- expected growth
- backup implications
- bandwidth requirements

Video storage may eventually belong outside the application server filesystem.

## 51. Security Review Before Deployment

Before production release, review:

- secrets
- repository
- dependencies
- authentication
- permissions
- IDOR
- CSRF
- cookies
- HTTPS
- headers
- sessions
- direct URLs
- media access
- playback
- assessments
- certificates
- reports
- audit logs

This review is scheduled primarily for Milestone 16.

## 52. Secret Scan

Before release, inspect the repository for accidental secrets.

Check for:

- `.env`
- database passwords
- secret keys
- API keys
- access tokens
- private certificates
- copied credentials

If a real secret was ever committed, rotating the secret is required.

Simply deleting it from the current source file is not sufficient.

## 53. Dependency Vulnerability Scan

Before production release, run a trusted dependency vulnerability scanner.

A likely option is:

```text
pip-audit
```

The actual selected tool should be documented after adoption.

Findings should be reviewed rather than blindly patched.

## 54. Staging Environment

A staging or production-like environment is strongly recommended before V1 release.

Staging should resemble production in:

- database engine
- HTTPS behavior
- secure cookies
- environment settings
- static handling
- media access

Do not use real sensitive production data unless necessary and properly protected.

## 55. Deployment Sequence

A typical deployment sequence may be:

```text
1. Confirm stable Git commit
2. Confirm CI passes
3. Back up production database
4. Load production environment variables
5. Install/update dependencies
6. Apply migrations
7. Collect/deploy static assets
8. Restart application
9. Run smoke tests
10. Review logs
```

The exact process must be adapted to the final hosting environment.

## 56. Rollback Strategy

Every production deployment should have a rollback plan.

Rollback planning should consider:

- application code
- database migrations
- static assets
- configuration

Code rollback may involve returning to the previous stable Git commit.

Database rollback is more complicated.

Do not assume every migration can safely be reversed.

## 57. Migration Rollback

Before applying a production migration, understand:

- whether it is reversible
- whether data is transformed
- whether old code can run against the new schema

For dangerous migrations, a database backup may be the safest recovery mechanism.

## 58. Failed Deployment

If deployment fails:

1. stop further changes
2. identify whether the failure is code, configuration, database, or infrastructure
3. preserve logs
4. roll back if necessary
5. verify database integrity
6. rerun smoke tests
7. document the failure if it reveals a reusable lesson

Do not improvise multiple production changes simultaneously.

## 59. Zero-Downtime Deployment

Zero-downtime deployment is not a V1 requirement unless business operations demand it.

Prefer a simpler, reliable deployment process first.

If short maintenance windows are acceptable, complexity can be reduced significantly.

## 60. Production Release Gate

Production release should occur only when:

```text
[ ] Core functionality is complete
[ ] Full automated test suite passes
[ ] GitHub Actions CI passes
[ ] Playwright E2E tests pass
[ ] Final bug hunt is complete
[ ] Final security review is complete
[ ] Dependency scan is reviewed
[ ] DEBUG is false
[ ] Strong secret is configured
[ ] Allowed hosts are configured
[ ] HTTPS is working
[ ] Secure cookies are verified
[ ] Database backup is configured
[ ] Restore procedure has been tested
[ ] Static files work
[ ] Protected media strategy is verified
[ ] Deployment smoke tests pass
[ ] Documentation is current
[ ] Rollback procedure exists
```

## 61. Post-Deployment Verification

Immediately after a production release:

1. inspect application health
2. verify login
3. verify important dashboards
4. verify static assets
5. check application logs
6. check database connectivity
7. verify HTTPS
8. verify secure cookies
9. test at least one protected route
10. confirm no unexpected migration or startup errors occurred

## 62. Post-Release Monitoring

After V1 release, observe actual usage.

Pay attention to:

- unexpected errors
- performance bottlenecks
- confusing workflows
- permission issues
- training completion problems
- assessment problems
- certificate issues
- support requests

Future changes should be prioritized using real operational evidence.

## 63. Production Incident Preparation

The team should know how to:

- disable an account
- revoke compromised credentials
- rotate secrets
- restore backups
- roll back deployment
- inspect audit records
- inspect operational logs

More detailed incident procedures may be added after the hosting architecture is finalized.

## 64. Deployment Documentation Maintenance

This file must be updated when the real production architecture is selected.

Replace assumptions with verified information such as:

- hosting provider
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

Do not leave deployment-specific guesses in the final production documentation.

## 65. Current Deployment Readiness

Current status:

```text
Backend core: complete
Backend baseline: 189 tests passing on MySQL
Documentation: in progress
CI: pending
Frontend: pending completion
E2E: pending
Production hardening: pending
Final security review: pending
Deployment: not yet production-ready
```

The next immediate deployment-related task is GitHub Actions CI during Milestone 11.

Full deployment implementation remains scheduled for Milestone 15.