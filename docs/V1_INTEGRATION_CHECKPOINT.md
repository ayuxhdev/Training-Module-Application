# V1 integration checkpoint — 27 November 2026

V1 application development and integration are complete for the Django website
and Flutter Android app. Production deployment, production acceptance, signing
and employee rollout are pending.

## Verified evidence

| Scope | Result | Evidence |
|---|---|---|
| GitHub main | PR #2 merged as `d3244e1f2c9b668f78cdf9b898c382ec5416814e` | [Merged PR #2](https://github.com/ayuxhdev/Training-Module-Application/pull/2) |
| Corrected PR | Required aggregate, ordinary and isolated MySQL jobs passed for `15f625f2aed1450aa0eb1918e79c16cac8b1e1ce` | [PR CI run](https://github.com/ayuxhdev/Training-Module-Application/actions/runs/45967472818) |
| Merged main | Ordinary Django MySQL suite ran 1,750 tests with 55 skips and zero failures or errors. Django checks, migration drift check, JavaScript tests, Flutter analysis/tests and the debug APK build passed. The isolated profile passed 53 tests, including its six required concurrency scenarios. The aggregate passed. | [Main CI run](https://github.com/ayuxhdev/Training-Module-Application/actions/runs/45969119241) |
| Manual acceptance | Operator-confirmed physical Android QA passed. Authenticated website functional and security QA passed 7/7. | Operator checkpoint |
| Review | The operator confirmed CodeRabbit clean on the final reviewed changes. | Operator checkpoint |

The [original CI run](https://github.com/ayuxhdev/Training-Module-Application/actions/runs/45952801141)
reported 14 failures and 14 errors. The corrected PR addressed all 28 outcomes.
The six role-requirement concurrency scenarios in the isolated profile are
separate from JWT refresh/logout concurrency in the ordinary suite.

## Changes integrated

- Protected browser and Android playback, including server-authoritative progress,
  session checks and anti-skip behavior. Completed-assignment replay is protected
  and read-only. Android fullscreen restores the prior orientation policy on exit
  while preserving screen-capture protection.
- Consistent Flutter assignment deadlines, readable long certificate identifiers,
  web and mobile branding, and layout corrections for Dashboard, Employee Profile
  and Notifications.
- Malformed password-change requests return HTTP 400 before account or token
  changes. Incomplete assessment drafts remain editable. Freeze requires at least
  two answer options with exactly one correct answer, and publication requires a
  frozen revision. Scoring and authorization remain server-side.
- Corrected MySQL race synchronization, duplicate-create savepoint fixtures,
  synchronous audit assertions, notification timestamps and UI regressions.
- Recovery instructions use the verified database backup bundle and private-media
  checks. Application-only rollback has a compatibility gate. Data restoration
  uses a separate schema and separate private media, and a failed recovery leaves
  writers and timers stopped.

Hindi/Devanagari certificate PDF shaping and the broader Run 5 remain deferred.
The passing isolated 53-test profile is separate from Run 5.

## Production launch gates

1. Obtain management approval, the hosting budget, a release owner and a rollout
   window. Prepare the company-controlled GitHub repository, configure CI and
   review protections, and verify the exact approved release revision there.
2. Procure and harden the VPS. Configure restricted SSH, firewall rules, service
   identities, Gunicorn, Nginx, DNS and trusted HTTPS for
   `training.gardensneed.com`.
3. Provision a separate production MySQL schema with least-privilege runtime,
   migration and backup accounts, and private production media. Keep the original
   development database and isolated QA database separate. Exclude synthetic QA
   users, training data and fixtures from production.
4. Configure production secrets and settings. Verify proxy trust, request-size
   limits, authentication throttles and authorized byte-range playback. Apply
   approved migrations, collect static files, and verify the hashed static
   manifest and the favicon through production HTTPS. Run production preflight.
5. Verify automated database and private-media backups, retention and alerts.
   Rehearse actual recovery in an isolated schema and media root. Record rollback
   compatibility and failure behavior before opening traffic.
6. Put Android signing credentials under company control with restricted access
   and recovery procedures. Build and verify the signed production APK using
   `API_BASE_URL=https://training.gardensneed.com`. Record its version, hash and
   signing certificate. The CI debug build is integration evidence.
7. Sign off production smoke tests for authentication, role boundaries, core
   training, authorized video, assessments, certificates and notifications.
   Approve employee onboarding, support ownership and phased internal rollout.

See the [canonical roadmap](ROADMAP.md),
[production runbook](V1_RELEASE_RUNBOOK.md), [operations procedures](M20_OPERATIONS.md)
and [testing guide](TESTING.md).
