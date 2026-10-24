# M20 production configuration and operations

**Status: application hardening implemented; deployment/restore rehearsal pending.**
No provider, domain, application server, external monitoring vendor or scheduler
has been activated by this batch. No backup or restore was run against live data.
Examples below are operator procedures, not evidence of a deployed environment.

## Audit and scope

| Area | Finding and classification | Implementation/evidence |
|---|---|---|
| Authentication/ownership | Already implemented; preserve | JWT rotation/blacklisting, eligibility, permission and object-scope regressions remain unchanged |
| Static files | Already implemented; production serving requires infrastructure | Existing manifest storage and asset tests; preflight now requires manifest and six hashed shell/player assets |
| Video | Already implemented; production serving needs rehearsal | Existing authorization, GET/HEAD/range and replay tests; no public media route; production roots must be disjoint |
| Environment/HTTPS | Missing deployable profile; implemented here | `config.production`, explicit hosts/secrets, secure cookies, HTTPS, bounded DB connections, opt-in proxy trust |
| Operational diagnostics | Missing; implemented here | Public minimal liveness, restricted readiness, read-only preflight, allowlisted JSON logs |
| Backups | Procedures only; tooling missing | `ops.mysql_backup` creates/verifies bundles; actual off-host storage, encryption and isolated restore are operator gates |
| Reminders | Eligibility/deduplication already implemented; scheduler absent | Existing locked service and UTC keys retained; persisted cutoff and safe operation events added; interruption/retry tests |
| Rate limits | Implemented locally; insufficient across multiple workers | Existing DRF cache throttles are per-process under default cache; edge/shared enforcement and web-login protection require infrastructure verification |
| Release/rollback | Infrastructure/operator action required | Procedure below; no automatic migration, destructive rollback or live smoke mutation |
| Dependencies | Pinned Python dependencies; system dependency required | Maintained ffprobe required for uploads; WSGI/ASGI host and vulnerability review remain release gates |

## 1. Select and validate the profile

Development/CI continue using `config.settings` with process-local `DEBUG=True`.
The application does not infer production from a developer's `DEBUG=False` alone.
All production/staging **web, worker, scheduler and management** processes must use
`DJANGO_SETTINGS_MODULE=config.production`. `manage.py --settings=config.production`
is an equivalent explicit override. WSGI entry point remains `config.wsgi:application`.
Do not use Django `runserver` for production.

Use `.env.production.example` as a variable inventory, never as a credential file.
Inject real values through service-owned secret/environment configuration. Do not
copy the development `.env` into the deployment. `python-dotenv` does not override
exported environment values, but an accidentally deployed `.env` remains unsafe.

Required: `DJANGO_ENVIRONMENT=staging|production`, `DEBUG=false`, a unique secret
of at least 50 characters with sufficient randomness, explicit `ALLOWED_HOSTS`,
all five `DB_*` connection fields, absolute `STATIC_ROOT` and `PRIVATE_MEDIA_ROOT`.
The profile rejects missing/weak secrets, root DB users, wildcard hosts, relative
storage paths and overlapping public/private/application storage. Provision media
outside the checkout; copy existing stored keys under that private root through a
separately approved deployment procedure. Do not rename published media keys.

Remote MySQL requires `DB_SSL_CA` pointing to a trusted CA file and uses
`VERIFY_IDENTITY`. The DB certificate must match `DB_HOST`; do not disable checks
to get a deployment working. Loopback transport requires a protected same-host DB.
Only the migration operator needs DDL rights; the running app should use the
minimum runtime permissions. Strict transactional SQL mode and connection health
checks are enabled. Connection/read/write timeouts are bounded and configurable.
These socket timeouts do not replace an application-server request deadline.

HTTPS redirects and secure cookies are mandatory in the production profile.
`TRUST_X_FORWARDED_PROTO=true` is allowed only after a controlled proxy strips any
client-supplied forwarded-protocol header, sets the correct value, and the Django
backend is unreachable directly. Forwarded Host is never trusted. Configure edge
host validation separately. Test forged forwarded headers and redirect loops.
CSRF trusted origins are optional explicit HTTPS origins; same-origin remains the
default. No CORS middleware or cross-origin browser API policy is added. Native
Android HTTP clients do not need browser CORS permissions.

HSTS starts at one hour. Increase only after certificate/redirect verification;
subdomains/preload are separate reviewed opt-ins. Preload requires at least one
year and complete subdomain coverage. CSP is not blindly introduced around the
existing inline scripts. Final header/CSP assessment remains part of M21.

## 2. Deployment sequence (operator only)

1. Select an approved immutable release and confirm its real CI results. Preserve
   the previous application/environment and static manifest. No CI result is
   implied for uncommitted M20 changes.
2. Provision the selected production WSGI/ASGI host, HTTPS proxy, private storage,
   DB account, ffprobe, logs and backup destinations. Server/provider selection is
   deliberately not invented here. Install pinned `requirements.txt` and run
   `python -m pip check` in an isolated release environment.
3. Load protected production environment. Verify the target DB name/host without
   displaying passwords. Inspect `python manage.py showmigrations` and
   `python manage.py migrate --plan`; confirm approved migration files and their
   reversibility/old-code compatibility. Never reseed or manually rewrite migration
   history. Validate the six role groups against the canonical permission migrations.
4. Establish a maintenance window for schema/media changes. Make and verify the
   DB/media backup pair below. Obtain approval for the actual target and plan.
5. Apply `python manage.py migrate --noinput` only as that authorized deployment
   action. This task has not executed it.
6. Collect matching release assets with `python manage.py collectstatic --noinput`.
   Do not use `--clear` or `--no-post-process`. Preserve older hashed files for
   rollback/open pages. Do not overwrite shared developer collected files.
7. Run `python manage.py check --deploy --fail-level ERROR` and review every warning,
   `python manage.py makemigrations --check --dry-run`, then
   `python manage.py production_preflight --database`. Before reminder activation,
   add `--require-reminders`. Preflight normally rejects all deployment warnings.
   A deliberately staged HSTS rollout may explicitly use `--acknowledge-staged-hsts`
   after review; it prints and allows only `security.W005` (subdomains) and
   `security.W021` (preload). No warnings are globally silenced. Do not enable
   preload or all-subdomain HSTS merely to make checks green.
   Preflight is read-only: validates configuration,
   ffprobe availability, media directory, hashed assets, DB connectivity/InnoDB
   tables and migration history; it does not migrate, collect, repair or seed.
8. Activate the release using the selected host's approved deployment mechanism.
   Check HTTPS, cookies, CSRF, static assets, role logins, foreign-object denials,
   protected ranges, and Android/API compatibility. No contract or token-lifetime
   changes are introduced here. Old supported clients must continue working.
9. Enable the approved hourly scheduler only after selecting the fixed cutoff.
   Confirm monitoring/backup jobs have observable exit status and last-success
   timestamps. Obtain operator signoff; a preflight pass alone is not deployment.

## 3. Static and private-media serving

Serve only `STATIC_ROOT` at `/static/`, with no directory listing. Keep its
`staticfiles.json` with the same release. Test the actual URLs from rendered HTML,
including the shell and player hashes. Cache hashed files as immutable; do not
cache authenticated HTML or API/media responses in a shared proxy cache.

**Never alias PRIVATE_MEDIA_ROOT, the checkout, backups, or `/media/` publicly.**
Never grant a public object-storage ACL for video/certificate objects. Do not put
private files under an app `static/` directory or `STATICFILES_DIRS`.

The current implementation remains authenticated Django streaming, not X-Accel,
public URLs, signed URLs or CDN delivery. Choose worker/timeouts/capacity around
long-lived streams; this batch does not claim throughput or decoder performance.
Forward Authorization, Cookie, Range and HEAD correctly. Do not strip range
headers or buffer/cache private videos as public objects. Verify 200, 206,
Content-Range/Length, 416, HEAD, client disconnect and cleanup in the selected host.
Every request retains session freshness or completed read-only replay checks.
No media-delivery or progress algorithm was changed.

Before release, unauthenticated direct `/media/...`, `/training/videos/...` and
`/static/training/videos/...` probes must fail at the **real proxy**, not merely
Django's resolver. Test an authorized range and foreign Employee denial without
exposing tokens in command lines, screenshots or access logs.

## 4. Health, logs and monitoring

- `GET/HEAD /health/live/`: public `{"status":"ok"}`, no DB lookup, no-store.
  It proves only that the application can respond. Use HTTPS and the real allowed
  Host; no SSL bypass/redirect exemption is added.
- `GET/HEAD /health/ready/`: active superuser via JWT or Django session, one
  `SELECT 1`, `ok` or generic `unavailable`/503. Normal unauthorized requests get
  401/403. If DB failure prevents identity lookup itself, the response is generic
  503. This cannot confirm schema, media, external storage or full user journeys.
  Do not store a superuser password in a monitoring URL. Local protected operator
  preflight is an alternative; continuous monitoring integration is not installed.
- `production_preflight --database`: operator diagnostic for deployment gates,
  not a high-frequency HTTP probe. It emits no DB credentials or employee data.
- Production JSON logs allow only timestamp, severity, fixed event, safe status,
  reminder count/duration, exception type and a code-location fingerprint. Raw
  messages, exception text, paths, request bodies/queries, headers, SQL, JWTs and
  arbitrary extras are omitted. This intentionally trades free-form error detail
  for privacy; use the release source and fingerprint for controlled diagnosis.
  Business audit records retain their existing separate access controls.
- Configure proxy/application-server logs separately: exclude Authorization,
  cookies, URL queries and request bodies; use route names/aggregate status where
  possible. Python logging cannot sanitize external proxy/service logs.
- Alert on readiness/5xx errors, auth-rate anomalies, backup verification age,
  reminder failures or missing hourly completion, slow requests, DB capacity,
  disk/media growth and TLS certificate expiry. Set numeric thresholds from the
  pilot baseline and approve them; no vendor, threshold or SLO is invented here.
- Existing local-memory DRF throttles are not cross-worker protection. Configure
  and test edge login/refresh/web-login limits, trusted client-IP forwarding and
  backend isolation before internet exposure. No speculative cache dependency is added.

## 5. Hourly reminder activation and recovery

Persist one operator-selected, timezone-aware `NOTIFICATIONS_ACTIVATED_AT` in the
same protected service configuration used by every scheduled invocation. Leave
it empty until rollout approval. Do not calculate `now` in the scheduled command.

With production environment loaded, the one-shot invocation is:

```text
python manage.py generate_training_notifications --settings=config.production
```

Existing `--activation-cutoff` remains supported. If configuration supplies a
cutoff, an explicit argument must denote that **same instant**, including when
expressed with another UTC offset. Missing, naive, invalid and future cutoffs
fail before scanning. Logs emit started/completed/failed events with aggregate
counts and elapsed time. Nonzero exit or absence of completion must alert.

For a selected Linux scheduler, an illustrative crontab entry is
`0 * * * * /absolute/release/.venv/bin/python /absolute/release/manage.py generate_training_notifications --settings=config.production`.
Cron must receive the protected environment through the host's approved mechanism;
it does not load interactive-shell environment automatically. The Windows Task
Scheduler equivalent uses the absolute venv Python, the same arguments, checkout
as Start In, hourly trigger, protected service identity and environment. These
are configuration recipes, **not installed jobs**. Configure a host-native
single-instance policy; services still deduplicate concurrent calls in the DB.

Never rerun the global reminder job on the live QA DB just to smoke-test it.
After interruption, rerun with the original cutoff: per-assignment transactions
and deterministic deadline/event keys preserve earlier successful events and
create only missing ones. Existing tests cover UTC boundaries, retirement,
eligibility changes, rollback and duplicates; added tests cover persisted cutoff
and interrupted-scan recovery. Restarts/redeployments must not change the cutoff.
Catch-up reevaluates current eligibility: once a deadline is overdue, it creates
an OVERDUE event rather than reconstructing a missed APPROACHING event. Alert on
missed runs; rerunning is not a guarantee of every historical reminder window.
No historical backfill, delivery channels or retention cleanup is introduced.

## 6. Non-destructive backup tooling

`python -m ops.mysql_backup` offers only `create` and `verify`. It has **no restore,
delete, prune, flush or database-creation command**. Do not run it against live
data as part of automated tests; tests mock MySQL subprocesses.

Provision an absolute private output directory outside application/static/media
trees, encrypted at rest and accessible only to the backup service/operator.
Provision compatible MySQL 8 `mysql`/`mysqldump` client binaries on the backup host.
Create a separate private MySQL option file with required credentials/TLS options
in `[client]`. POSIX permissions must be 0700 for directories and 0600 for files.
On Windows the operator must verify restrictive NTFS ACLs (for example with
`icacls`); Python mode bits cannot certify Windows ACLs. Do not put credentials
on CLI arguments or in source. Remote backup clients also need certificate
verification in the private option file; the tool forces the chosen TCP host/port.

### Backup identity and completeness prerequisites

Have the DBA verify the **actual dedicated backup identity's** effective grants
against the exact MySQL client/server versions before relying on a backup. The
application connection's grants do not establish the backup identity's access.
The [MySQL 8 mysqldump privilege requirements](https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html)
include `SELECT` for table data, `SHOW VIEW` for views, `TRIGGER` on dumped tables,
`EVENT` on the selected database, and **global `SELECT` for `--routines`**. The
latter is broad: approve and isolate this backup identity; do not automatically
grant it to the application. Do not assume `SHOW_ROUTINE` alone satisfies the
documented mysqldump requirement. No grants are changed by this tooling.

The selected `--single-transaction`, `--no-tablespaces` and
`--set-gtid-purged=OFF` options avoid the documented conditional `LOCK TABLES`,
`PROCESS` and GTID-related `RELOAD`/`FLUSH_TABLES` requirements; verify this against
the deployed versions/options rather than granting broad privileges speculatively.
Keep option files limited to connection/credential/TLS configuration. Do not use
`force`, `ignore-error`, table exclusions, `no-data` or other export overrides.
The command explicitly disables `force`; expected export errors must fail the job,
not be suppressed to work around insufficient privileges.

Inventory tables, views, procedures, functions, events and triggers using an
authorized metadata identity before backup, and compare that inventory during
the isolated restore rehearsal. Metadata visibility is privilege-filtered: an
empty `information_schema.ROUTINES`/`EVENTS`/`TRIGGERS` result is not proof that
objects are absent unless the inspecting identity can see all relevant objects.
Checksum verification cannot establish object completeness or effective grants.

Before backup, confirm target/maintenance ownership, prohibit concurrent DDL, and
capture a coordinated private-media snapshot. Published media is immutable but
draft uploads can change, so freeze writes or use a tested storage-consistent
snapshot method for the DB/media pair. Snapshot IDs are operator assertions:
the tool records them but cannot verify an external storage snapshot exists.
The DDL freeze includes routines, events, triggers and views; their definitions
are not made transactionally consistent merely by `--single-transaction`.

Example, replacing all placeholder paths/hostnames with approved values:

```text
python -m ops.mysql_backup create --defaults-file /secure/mysql-backup.cnf --database gardens_training --host 127.0.0.1 --port 3306 --expected-server APPROVED_MYSQL_HOSTNAME --environment production --output-dir /secure/backups --media-snapshot-id APPROVED_SNAPSHOT_ID
python -m ops.mysql_backup verify /secure/backups/EXACT_BUNDLE_DIRECTORY
```

The tool first reads `DATABASE()`, server hostname and non-InnoDB table count.
Mismatch fails before creating output. Dumps use single-transaction/quick,
no table locks/tablespaces/GTID modification, no CREATE DATABASE and no DROP TABLE
statements. Explicit `--routines`, `--events` and `--triggers` include stored
procedures/functions, scheduled events and triggers, respectively, even if an
option-file default would disable these exports. `--skip-force` and checked
subprocess exit status stop on export errors, including permission failures:
partial SQL receives neither a finalized `database.sql` nor a completion manifest,
and the CLI exits nonzero without reporting success.
Client credentials stay in the option file; inherited MYSQL_PWD is
removed. Connections and dumps have subprocess deadlines. Each backup gets an
exclusive directory; existing backups are never replaced. Partial output is
retained on failure and must not be considered a completed backup.

Successful bundles contain `database.sql` and `manifest.json`: database/server,
environment, UTC start/end times, byte count, SHA-256 and media snapshot reference.
`verify` checks size/hash and rejects missing/corrupt/empty content. It does not
execute SQL, prove restoreability, authenticate a tampered manifest, or verify the
media snapshot. Protect the manifest and copy the pair to approved independent
encrypted storage; verify after transfer. Keep grants/secrets configuration in a
separate secure recovery system: app-table dumps do not back up MySQL accounts.
Backups created before explicit routine/event export may pass checksum validation
while omitting those objects. Preserve them, but do not certify completeness from
their checksums; arrange a new authorized backup and isolated restore rehearsal.

Retention frequency, RPO/RTO, archive tiers and authorized deletion policy require
business/operator approval. No guessed retention or automatic deletion is added.
Inventory exact completed bundles and restore evidence before selecting anything
for deletion. Never delete the last verified recovery pair or open incident copy.

## 7. Isolated restore rehearsal — separate explicit authorization required

No restore was executed in this batch. Rehearse on a new, disposable MySQL instance
with no network/credentials granting access to development or production DBs.
Never use the preserved local test DB, persistent QA DB or an existing staging DB.

1. Record the authorized target instance, expected hostname and empty schema.
   Use a restore account granted rights only on `restore_rehearsal`. Provision
   that empty database only after approval, outside this tool.
   Keep the isolated instance's MySQL `event_scheduler` OFF before import so
   restored events cannot execute. The DBA must approve routine/view/trigger/event
   creation privileges, original `DEFINER` handling and any binary-logging
   restrictions on stored functions. Do not weaken production settings or rewrite
   object definitions to bypass an import failure.
2. Verify the selected trusted backup bundle and matching private-media snapshot.
   The completion manifest/checksum is an integrity check, not a signature.
3. Connect with a private **restore-specific** option file. Verify
   `SELECT DATABASE(), @@hostname` and zero app tables before importing. Stop on
   any unexpected identity or existing data. Do not edit SQL to bypass failures.
4. In an authorized Linux/Bash operator terminal only, import with the MySQL
   client's stdin, not a password argument:

   ```sh
   mysql --defaults-file=/secure/restore-only.cnf --host=ISOLATED_HOST --port=3306 restore_rehearsal < /secure/backups/EXACT_BUNDLE/database.sql
   ```

   PowerShell does not support that Bash input-redirection syntax. Use an approved
   operator script that passes the SQL file as subprocess stdin, not `Get-Content`
   text conversion; preserve exact bytes. No automatic restore script is supplied.
5. Mount/copy the matching media snapshot privately into that isolated app's
   `PRIVATE_MEDIA_ROOT`. Keep internet exposure and schedulers disabled; use a
   non-production secret. Do not reuse production JWTs or log real records.
6. Verify table counts/referential integrity, migrations, six groups/grants,
   pinned versions, attempts, certificates and audit history against backup
   evidence. Compare restored procedure/function/event/trigger/view names and
   definitions with the authorized source inventory, without publishing sensitive
   definitions. Check media keys/checksums against the snapshot without exposing
   paths. Run read-only preflight and bounded authorized web/API/media smoke tests.
   Any intended replay must remain read-only; never create coverage as a restore test.
7. Record backup ID, snapshot ID, target identity, actual duration, checks and
   recovery limits. Obtain operator signoff before marking restore verified.
   Dispose of the entire isolated environment only under separate authorization.

## 8. Failed deployment and rollback

Stop activation on failed preflight, schema drift, missing hashed assets, broken
auth/CSRF, unauthorized media access, login/learning/completion regressions or
unexplained error-rate/latency growth. Preserve sanitized diagnostics and backups.
Pause scheduled jobs during recovery without changing the persisted cutoff.

Prefer restoring the previous application/environment/manifest when compatible
with the current schema. Keep previous hashed assets and private media keys.
Never assume migration reversibility or run backwards migrations automatically.
If data recovery is necessary, obtain explicit incident approval for a verified
restore plan, account for writes since backup, and rehearse before production.
No reset/flush/drop/restore operation belongs in an automatic deployment retry.

After rollback, verify HTTPS, roles, ownership, protected ranges, immutable version
links, assessment/certificate consistency and scheduler/backup health before
resuming service. Document the incident and the chosen recovery point.

## 9. Test-database safety and permission-group incident

The normal backend profile is MySQL (`config.settings`). The explicit
`config.test_settings` fallback uses in-memory SQLite; it does not verify MySQL
row locks. CI uses a disposable MySQL 8 service and runs the complete Django suite.
Database-free checks can run without either database. Do not select SQLite to
claim that a MySQL concurrency regression passed.

Django `TestCase` normally rolls its fixtures back. `TransactionTestCase` instead
commits test writes and flushes database data during teardown. `--keepdb` preserves
the database/schema between runs; it does **not** prevent these teardown flushes.
The application groups are created by data migrations, not a `post_migrate`
receiver. Django's auth receiver recreates permission definitions after a flush,
but does not replay application migrations or restore their group/grant data.

This explains the fresh-CI failure corrected in `eea613b`: discovery placed the
two assessment API transaction tests immediately before the six M21 tests, whose
fixture unnecessarily required a seeded Administrator group. The M21 fixture now
creates its own learner/superuser, accepts an empty group baseline, and still
checks that its exact cleanup preserves the groups/grants present at entry.
Production role bootstrap was not changed.

The same flush mechanism is **strongly supported**, not forensically confirmed,
as the explanation of the earlier local loss of six groups and 96 grants. The
preserved test database, `--keepdb`, and migration history remaining applied fit
that mechanism. Available records do not identify the exact earlier command or
exclude another actor. They do not establish a development/production incident.
Never restore roles in any existing database without target verification and
explicit authorization.

Before a local database run, check both OS test processes and MySQL connections;
coordinate exclusive ownership. Inspect the effective test database name, host,
server identity and migration state without printing credentials. Django normally
derives a `test_` name unless `DATABASES["default"]["TEST"]["NAME"]` overrides it;
a prefix alone is not proof that a database is disposable. Do not use the ordinary
full-suite command on a preserved/shared test database. A guarded local run must
reject database creation/drop, TRUNCATE and flush, use only the verified test
target, and compare groups, grants, permission definitions and migration history
before/after. Do not repair schema or bootstrap state automatically.

### Current flush-based exclusions for a preserved local test database

All eight methods below inherit `TransactionTestCase` and therefore flush the
effective test database on teardown. They must run on disposable, independently
verified MySQL infrastructure; the CI full-suite command includes them. Their
local exclusion is an infrastructure limitation, not equivalent coverage.

| File / class | Method | Coverage requiring disposable MySQL |
|---|---|---|
| `api/v1/test_assessments.py` / `AssessmentAPIConcurrencyTests` | `test_concurrent_starts_resume_one_sequential_attempt` | Concurrent start/resume and sequential attempt uniqueness |
| Same | `test_concurrent_final_submissions_grade_once_and_issue_one_certificate` | Single grading/completion/certificate under concurrent submission |
| `api/v1/test_notifications.py` / `NotificationReadConcurrencyTests` | `test_simultaneous_individual_and_read_all_preserve_one_read_timestamp` | Concurrent read-one/read-all preserve first-read time |
| `assessments/tests.py` / `AssessmentLockingTests` | `test_revision_creations_serialize_on_question` | Question revision numbering under concurrent creation |
| Same | `test_submission_waits_for_employee_before_locking_assignment` | Submission Employee-before-Assignment lock order |
| Same | `test_start_attempt_waits_for_employee_before_locking_assignment` | Attempt-start Employee-before-Assignment lock order |
| `notifications/test_reminders.py` / `DeadlineReminderConcurrencyTests` | `test_concurrent_commands_create_one_notification` | Concurrent deadline scans deduplicate events |
| `notifications/tests.py` / `NotificationConcurrencyTests` | `test_concurrent_events_pass_validation_then_database_deduplicates_the_insert` | Event insertion race and database-enforced uniqueness |

Earlier reports referring to six exclusions are not the current inventory.
Committed source already contained these eight methods at `88a4cda`, before M21;
the six-to-eight discrepancy cannot be attributed to two new M21 tests. The exact
older selection is not recorded here. Derive exclusions from current discovery
and report each method rather than carrying forward an unsupported count. The six
M21 cases use exact fixture cleanup without flush and are a separate set.

If another disposable MySQL database cannot be provisioned with approved
credentials, do not broaden grants or reuse development data. Leave those eight
cases to the isolated CI service. To reproduce the group lifecycle separately,
an operator can provision a new empty test database, run migrations, record the
canonical groups, run the assessment API transaction tests, then inspect the
groups and migration history before running the M21 cases. This experiment is not
authorized against the preserved test database. No such destructive local
experiment is claimed by this document.

## 10. Manifest and infrastructure signoff evidence

Static assertions must use Django's active static storage URL, not a literal
unhashed path. The timed assessment template uses `{% static %}` for both
`assessments/timer.js` and `assessments/timer.css`; the corresponding tests resolve
the expected URLs with `django.templatetags.static.static`. Deadline, scoring and
timeout enforcement remain server-side and unchanged.

To validate a candidate release without changing shared collected files, use an
isolated process with `DEBUG=False`, manifest storage, and a new temporary
`STATIC_ROOT`; collect there and run the timed/untimed rendering checks against
the verified test database. This is a static-storage test, not a live deployment.
For actual deployment, preserve the release manifest and request the exact hashed
URLs from authenticated rendered HTML at the real HTTPS proxy. Check HTTP 200,
CSS/JavaScript content types and the actual release content, including assessment
timer assets. Preflight's six-asset allowlist does not replace this complete-page
asset check. Browser cache refresh alone does not fix an outdated deployment.

Release signoff must attach actual evidence for the following infrastructure
gates; source tests or the reported green CI do not satisfy them:

- Approved host/service definitions, protected identities/environments, startup
  ordering, graceful worker restart, and rollback to the prior compatible release.
- Real HTTPS/host/proxy/CSRF checks, trusted forwarded headers, secure cookies,
  private storage ACLs and denial of public private-media aliases.
- Runtime/migration/backup account grants, remote MySQL certificate verification,
  actual ffprobe version/execution, and reviewed dependency vulnerabilities.
- Cross-worker API and web-login rate limiting. Current in-process throttles and
  absence of a web-login throttle require edge/shared enforcement before exposure.
- Authorized protected-media range/HEAD/error checks, certificate access and
  revocation checks, and sustained worker/network/decoder capacity measurements.
- Completed off-host encrypted DB/media recovery pairs, independently checked
  object inventory, an authorized isolated restore rehearsal and approved RPO/RTO.
- Fixed reminder activation cutoff, installed hourly job under the correct
  profile, observed completion/failure/missed-run alerts, and restart recovery.
- Monitoring ownership, reviewed thresholds, TLS/backup-age/capacity alerts and a
  safe authentication plan for restricted readiness (currently active superuser
  only). Do not distribute privileged probe credentials to public monitors.

Numeric alert thresholds, provider-specific service units, production grants,
retention targets and capacity acceptance criteria still require operator
selection/signoff; this guide does not invent them. Final CSP/header policy and
dependency-vulnerability review also remain security release gates. No deployment,
restore, scheduler activation, privileged-account change or M20/M21 closure is
implied by these procedures.

## Validation and remaining release gates

Automated checks exercise production settings isolation/fail-closed behavior,
health access/failure privacy, log redaction, static preflight gates, mocked
consistent backup/verification/failure paths, cutoff persistence and interrupted
reminder recovery. Preserved local MySQL validation excludes the eight flush-based
cases listed above; disposable CI runs them. No existing database is reset or
recreated. See the actual execution report for totals and limitations; no live
deployment result is implied.

Local follow-up evidence, 24 October 2026 (not a full-suite or CI result):

- 165 focused MySQL tests passed, zero failures/errors/skips, including all six
  M21 concurrency cases, authentication/identity, Employee lifecycle, assessment
  endpoints, operations and reminder-recovery checks. Flush, TRUNCATE and
  database creation, database drops and table drops were blocked; group/grant,
  permission-definition and migration-history snapshots were preserved.
- Timed/untimed rendering with a temporary manifest collection: 2 passed after
  reproducing the old timed-page assertion failure. No shared static output changed.
- Database-free operations rerun: 24 passed with database access blocked.
  SQLite verification: all six MySQL-only cases skipped without fixture setup.
- Discovery found 730 tests and the eight flush-based cases above; these eight
  were not executed locally. The preceding groups are overlapping checks and must
  not be added into a claimed distinct full-suite total. The reported green CI
  checkpoint predates these test/documentation edits.

Still required: selected infrastructure/application server, service secrets and
least privilege, actual HTTPS/proxy/static/range rehearsal, off-host encrypted
backups and isolated restore, approved RPO/RTO/retention, activation cutoff/hourly
scheduler monitoring, capacity tests, dependency-vulnerability review (M21), and
final Android/API smoke checks. M20 is not deployment-complete.

Primary references: [Django deployment checklist](https://docs.djangoproject.com/en/5.2/howto/deployment/checklist/),
[Django proxy trust](https://docs.djangoproject.com/en/5.2/ref/settings/#secure-proxy-ssl-header),
[MySQL consistent dump requirements](https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html).
