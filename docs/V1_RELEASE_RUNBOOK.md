# Garden's Need Training Module — V1 Production Deployment & Rollback Runbook

**Target Internal Release Date:** November 26–27, 2026  
**Document Status:** Operational Runbook (UNEXECUTED — Awaiting Infrastructure & Release Gate Approvals)  
**Configuration Profile:** `DJANGO_SETTINGS_MODULE=config.production`  
**WSGI Entry Point:** `config.wsgi:application`  
**Application ID:** `com.gardensneed.training`

---

## A. Infrastructure Prerequisites

Before deploying the application, the system administrator and DBA must provision and verify the following host and network requirements:

1. **Host Environment:**
   - Dedicated Linux server (e.g., Ubuntu 24.04 LTS / 22.04 LTS) or approved enterprise hosting instance.
   - Python runtime: Python 3.12+ (matches supported Django 5.2 LTS).
   - System packages: `mysql-client` (8.0+), `default-libmysqlclient-dev`, `pkg-config`, `build-essential`.
   - Media engine: `ffprobe` (from FFmpeg package) installed and available on PATH (`ffprobe -version` returns 0).
   - WSGI application server: `gunicorn` installed in the production virtual environment.
   - Reverse proxy: Nginx or Caddy terminating TLS.

2. **Storage Boundaries (Strictly Disjoint):**
   - Application Root: `/srv/gardens-app/current` (Git release checkout, read-only to app user).
   - Static Output: `/srv/gardens-static/releases/<RELEASE_ID>` (Served directly by Nginx at `/static/`).
   - Private Media Storage: `/srv/gardens-private/media` (Protected training videos; **never** publicly aliased in Nginx).
   - Backup Destination: `/srv/gardens-backups` (Restricted filesystem, 0700 permissions, off-host synced).

3. **MySQL 8 Database Provisioning:**
   - Database name: `gardens_training`.
   - Dedicated Application Account: `gardens_app` (strictly non-root).
   - Runtime Application Grants:
     ```sql
     -- UNEXECUTED: To be run by DBA on production MySQL 8 instance
     CREATE USER 'gardens_app'@'127.0.0.1' IDENTIFIED BY '<STRONG_PASSWORD>';
     GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, REFERENCES ON `gardens_training`.* TO 'gardens_app'@'127.0.0.1';
     FLUSH PRIVILEGES;
     ```
   - Dedicated Backup Account: `gardens_backup` with `SELECT, SHOW VIEW, TRIGGER, EVENT` on `gardens_training.*` and global `SELECT` (for routines).

4. **Environment Variables Inventory (`/etc/gardens/production.env` — Mode 0600):**
   ```bash
   # UNEXECUTED: Template configuration; populate via secret management
   DJANGO_SETTINGS_MODULE=config.production
   DJANGO_ENVIRONMENT=production
   DEBUG=false
   DJANGO_SECRET_KEY=<STRONG_RANDOM_SECRET_MIN_50_CHARS>
   ALLOWED_HOSTS=training.gardensneed.com
   CSRF_TRUSTED_ORIGINS=https://training.gardensneed.com
   TRUST_X_FORWARDED_PROTO=true
   SECURE_HSTS_SECONDS=3600
   SECURE_HSTS_INCLUDE_SUBDOMAINS=false
   SECURE_HSTS_PRELOAD=false

   DB_NAME=gardens_training
   DB_USER=gardens_app
   DB_PASSWORD=<STRONG_PASSWORD>
   DB_HOST=127.0.0.1
   DB_PORT=3306
   DB_CONNECT_TIMEOUT=5
   DB_READ_TIMEOUT=30
   DB_WRITE_TIMEOUT=30
   DB_CONN_MAX_AGE=60

   STATIC_ROOT=/srv/gardens-static/releases/<RELEASE_ID>
   PRIVATE_MEDIA_ROOT=/srv/gardens-private/media
   VIDEO_FFPROBE_PATH=ffprobe
   NOTIFICATIONS_ACTIVATED_AT=<YYYY-MM-DDTHH:MM:SSZ>
   ```

---

## B. Pre-Deployment Backup and Validation

Before performing any migration or activating code:

1. **Verify Git Commit and Tag:**
   Ensure deploying from an approved immutable Git commit tag that has passed all CI checks:
   ```bash
   # UNEXECUTED
   git fetch --tags
   git checkout tags/v1.0.0-rc1
   git status --short
   ```

2. **Run Dependency Integrity Check:**
   ```bash
   # UNEXECUTED
   python -m pip install --upgrade pip
   python -m pip install -r requirements.txt
   python -m pip install gunicorn
   python -m pip check
   ```

3. **Capture Pre-Deployment Database and Media Backup:**
   Execute the non-destructive backup tool:
   ```bash
   # UNEXECUTED
   python -m ops.mysql_backup create \
     --defaults-file /etc/gardens/backup.cnf \
     --database gardens_training \
     --host 127.0.0.1 \
     --port 3306 \
     --expected-server <MYSQL_SERVER_HOSTNAME> \
     --environment production \
     --output-dir /srv/gardens-backups \
     --media-snapshot-id snapshot-$(date -u +%Y%m%dT%H%M%SZ)

   # Verify the generated bundle checksum:
   python -m ops.mysql_backup verify /srv/gardens-backups/<BUNDLE_DIR>
   ```

4. **Verify Stored Media Snapshot:**
   Create a filesystem / volume snapshot of `/srv/gardens-private/media` corresponding to the `--media-snapshot-id` recorded above.

---

## C. Safe Migration Procedure

> [!IMPORTANT]
> **Reliable Environment Loading:**  
> Management commands run under the production profile (`--settings=config.production`) require all mandatory production environment variables from `/etc/gardens/production.env`. Always load the protected environment securely into the execution subshell before executing commands:
> ```bash
> # UNEXECUTED: Load protected environment variables (mode 0600) into subshell
> set -a
> source /etc/gardens/production.env
> set +a
> ```

1. **Inspect Pending Migrations:**
   ```bash
   # UNEXECUTED
   python manage.py showmigrations --settings=config.production
   python manage.py migrate --plan --settings=config.production
   ```
   Confirm that all listed migrations are planned and no schema ambiguity exists.

2. **Dry-Run Model Validation:**
   ```bash
   # UNEXECUTED
   python manage.py makemigrations --check --dry-run --settings=config.production
   ```
   *Must report zero missing migrations.*

3. **Apply Database Migrations:**
   Execute migrations within the approved maintenance window:
   ```bash
   # UNEXECUTED
   python manage.py migrate --noinput --settings=config.production
   ```

4. **Verify Application Groups and Permissions:**
   Ensure Django permission migrations populated the six authoritative role groups:
   - `Administrator`
   - `Training Coordinator`
   - `Manager`
   - `Trainer`
   - `Supervisor`
   - `Employee`

---

## D. Django Production Startup

1. **Collect Static Assets with Content Hashing:**
   ```bash
   # UNEXECUTED
   python manage.py collectstatic --noinput --settings=config.production
   ```
   Verify that `staticfiles.json` manifest is written under `STATIC_ROOT` and that shell and player hashed assets exist.

2. **Execute Read-Only Production Preflight:**
   ```bash
   # UNEXECUTED
   python manage.py production_preflight --database --require-reminders --acknowledge-staged-hsts --settings=config.production
   ```
   *Must output: `Production preflight passed.`*

3. **Start Gunicorn Service (via Systemd):**
   Example service unit `/etc/systemd/system/gardens-django.service`:
   ```ini
   # UNEXECUTED
   [Unit]
   Description=Garden's Need Training Module Django Application
   After=network.target mysql.service

   [Service]
   User=gardens_app
   Group=gardens_app
   WorkingDirectory=/srv/gardens-app/current
   EnvironmentFile=/etc/gardens/production.env
   ExecStart=/srv/gardens-app/venv/bin/gunicorn \
       --workers 4 \
       --bind 127.0.0.1:8000 \
       --timeout 60 \
       --access-logfile - \
       --error-logfile - \
       config.wsgi:application
   Restart=always

   [Install]
   WantedBy=multi-user.target
   ```
   Reload and start:
   ```bash
   # UNEXECUTED
   sudo systemctl daemon-reload
   sudo systemctl restart gardens-django
   sudo systemctl status gardens-django
   ```

4. **Configure Nginx Reverse Proxy:**
   Example hardened Nginx configuration:
   ```nginx
   # UNEXECUTED
   # Upstream rate limit zone for JWT refresh endpoint
   limit_req_zone $binary_remote_addr zone=training_refresh:10m rate=20r/m;
   log_format training_minimal '$time_iso8601 $request_method $status $body_bytes_sent $request_time';

   # Port 80: HTTP-to-HTTPS redirect for approved hostname
   server {
       listen 80;
       server_name training.gardensneed.com;
       server_tokens off;

       # Deny unapproved / spoofed Host headers with 421 Misdirected Request
       if ($host != training.gardensneed.com) { return 421; }

       # ACME challenge for automated Let's Encrypt renewal
       location ^~ /.well-known/acme-challenge/ {
           root /var/lib/letsencrypt;
           try_files $uri =404;
       }

       # 308 Permanent Redirect preserving request method and POST payloads
       location / {
           return 308 https://training.gardensneed.com$request_uri;
       }
   }

   # Port 443: Terminated TLS and protected application reverse proxy
   server {
       listen 443 ssl http2;
       server_name training.gardensneed.com;
       server_tokens off;

       # Host validation
       if ($host != training.gardensneed.com) { return 421; }

       ssl_certificate /etc/ssl/certs/gardens_training.crt;
       ssl_certificate_key /etc/ssl/private/gardens_training.key;
       ssl_protocols TLSv1.2 TLSv1.3;

       # Trusted proxy header sanitization
       proxy_http_version 1.1;
       proxy_set_header Host training.gardensneed.com;
       proxy_set_header Connection "";
       proxy_set_header X-Forwarded-For $remote_addr;
       proxy_set_header X-Forwarded-Proto https;
       proxy_set_header X-Forwarded-Host "";
       proxy_set_header Forwarded "";
       proxy_set_header X-Real-IP "";

       # Security Headers
       add_header X-Content-Type-Options nosniff always;
       add_header X-Frame-Options DENY always;
       add_header Referrer-Policy same-origin always;

       # Default body size limit
       client_max_body_size 2m;
       proxy_cache off;
       proxy_intercept_errors off;

       # Static Files (direct serving, immutable caching for hashed assets)
       location ^~ /static/ {
           alias /srv/gardens-static/releases/<RELEASE_ID>/;
           expires 1y;
           add_header Cache-Control "public, immutable";
           access_log off;
           autoindex off;
       }

       # Block direct media routing (must be routed through authenticated Django views)
       location ~ ^/media(?:/|$) {
           deny all;
           return 404;
       }

       # Authorized protected video range streaming and replay
       location ~ ^/(?:api/v1/)?assignments/[0-9]+/lessons/[0-9]+/(?:sessions/[0-9]+/media|replay/media)/$ {
           proxy_buffering off;
           proxy_read_timeout 120s;
           proxy_pass http://127.0.0.1:8000;
       }

       # All three login routes restricted to 16 KiB
       location ~ ^/(?:accounts/login|admin/login|api/v1/auth/login)/?$ {
           client_max_body_size 16k;
           proxy_pass http://127.0.0.1:8000;
       }

       # Refresh token route with edge rate limiting (20/min per-IP)
       location ~ ^/api/v1/auth/refresh/?$ {
           client_max_body_size 16k;
           limit_req zone=training_refresh burst=19 nodelay;
           limit_req_status 429;
           error_page 429 = @training_refresh_limited;
           proxy_pass http://127.0.0.1:8000;
       }
       location @training_refresh_limited {
           default_type application/json;
           add_header Retry-After 3 always;
           add_header Cache-Control no-store always;
           add_header X-Content-Type-Options nosniff always;
           return 429 '{"error":{"code":"throttled","message":"Too many requests.","fields":{}}}';
       }

       # Large video uploads restricted strictly to actual upload endpoints (up to 2050m)
       location ~ ^/(?:modules/[0-9]+/lessons/new|lessons/[0-9]+/edit|api/v1/management/versions/[0-9]+/modules/[0-9]+/video-lessons(?:/[0-9]+)?)/$ {
           client_max_body_size 2050m;
           client_body_timeout 120s;
           proxy_request_buffering on;
           proxy_send_timeout 120s;
           proxy_read_timeout 120s;
           proxy_pass http://127.0.0.1:8000;
       }

       # Proxy all remaining application traffic
       location / {
           proxy_pass http://127.0.0.1:8000;
           proxy_read_timeout 60s;
       }
   }
   ```
   Reload Nginx:
   ```bash
   # UNEXECUTED
   sudo nginx -t && sudo systemctl reload nginx
   ```

---

## E. HTTPS and API Verification

Execute smoke curls from an external client against the live endpoint:

1. **Liveness Check:**
   ```bash
   # UNEXECUTED
   curl -i https://training.gardensneed.com/health/live/
   ```
   *Expected:* HTTP 200, `{"status":"ok"}`, `Cache-Control: no-store`.

2. **Readiness Check (Unauthenticated Denial):**
   ```bash
   # UNEXECUTED
   curl -i https://training.gardensneed.com/health/ready/
   ```
   *Expected:* HTTP 401 or 403 (verifies readiness is protected from public probing).

3. **HTTP to HTTPS Redirect:**
   ```bash
   # UNEXECUTED
   curl -i http://training.gardensneed.com/health/live/
   ```
   *Expected:* HTTP 308 Permanent Redirect to `https://training.gardensneed.com/health/live/`.

4. **Security Cookie Verification:**
   Inspect `/accounts/login/` headers:
   ```bash
   # UNEXECUTED
   curl -i https://training.gardensneed.com/accounts/login/
   ```
   *Expected:* `Set-Cookie: csrftoken=...; Secure; SameSite=Lax`.

5. **Direct Media Protection:**
   ```bash
   # UNEXECUTED
   curl -i https://training.gardensneed.com/media/test.mp4
   curl -i https://training.gardensneed.com/static/training/videos/test.mp4
   ```
   *Expected:* HTTP 404 / 403 (direct filesystem access blocked).

---

## F. Flutter Release Configuration and Signing

1. **Set Up Release Signing Credentials on the Release Host:**
   Securely export signing environment variables:
   ```powershell
   # UNEXECUTED
   $env:ANDROID_RELEASE_STORE_FILE = "C:\secure\keystores\gardensneed-release.jks"
   $env:ANDROID_RELEASE_STORE_PASSWORD = "<SECURE_STORE_PASSWORD>"
   $env:ANDROID_RELEASE_KEY_ALIAS = "gardensneed"
   $env:ANDROID_RELEASE_KEY_PASSWORD = "<SECURE_KEY_PASSWORD>"
   ```

2. **Verify Fail-Closed Guard:**
   ```powershell
   # UNEXECUTED
   cd mobile/android
   .\gradlew :app:validateReleaseSigningCredentials
   ```
   *Must pass without exception when valid credentials are set.*

3. **Build the Production Release Artifact:**
   ```powershell
   # UNEXECUTED
   cd mobile
   flutter build apk --release --dart-define=API_BASE_URL="https://training.gardensneed.com"
   # Or for internal bundle distribution:
   flutter build appbundle --release --dart-define=API_BASE_URL="https://training.gardensneed.com"
   ```
   *Output:* `mobile/build/app/outputs/flutter-apk/app-release.apk`

4. **Verify Release Package Attributes:**
   - Verify non-debuggable: `android:debuggable="false"`.
   - Verify signature: `apksigner verify --verbose app-release.apk`.
   - Verify checksum: Record SHA-256 for distribution tracking.

---

## G. Small Internal Employee Rollout

1. **Pilot Cohort Selection:**
   - Select an initial pilot group of 5–10 trusted employees across 1–2 reporting managers.
   - Restrict initial assignments to one designated published pilot training course.

2. **Sideloading / Internal Distribution:**
   - Install the verified `app-release.apk` on pilot Android test devices.
   - Sideload via enterprise MDM or manual USB transfer (`adb install -r app-release.apk`).

3. **End-to-End Pilot Journey Verification:**
   - [ ] Employee logs in with production credentials.
   - [ ] Assigned training appears on Employee Dashboard.
   - [ ] Text lesson opens and completes.
   - [ ] Protected video lesson streams with HTTP 206 byte-ranges.
   - [ ] Anti-skip prevents jumping ahead; heartbeats sync progress.
   - [ ] `FLAG_SECURE` blocks external screenshots and screen recordings on the physical phone.
   - [ ] Assessment attempt is submitted and scored server-side.
   - [ ] Certificate PDF generates and renders correctly.
   - [ ] Manager logs in via web, reviews team progress, and exports CSV report.

---

## H. Monitoring and Failure Detection

1. **Activate Scheduled Jobs (Systemd Services and Timers):**
   Prefer appropriately configured systemd services and timers over raw crontab entries to ensure reliable environment loading (`EnvironmentFile=/etc/gardens/production.env`), process isolation, non-root execution, journald logging, and restart/timeout control.

   a) **Hourly Training Reminders** (`/etc/systemd/system/gardens-reminders.service` & `gardens-reminders.timer`):
   ```ini
   # UNEXECUTED: /etc/systemd/system/gardens-reminders.service
   [Unit]
   Description=Garden's Need Training Reminders Generator
   After=network.target mysql.service

   [Service]
   Type=oneshot
   User=gardens_app
   Group=gardens_app
   WorkingDirectory=/srv/gardens-app/current
   EnvironmentFile=/etc/gardens/production.env
   ExecStart=/srv/gardens-app/venv/bin/python manage.py generate_training_notifications --settings=config.production
   StandardOutput=journal
   StandardError=journal
   ```
   ```ini
   # UNEXECUTED: /etc/systemd/system/gardens-reminders.timer
   [Unit]
   Description=Hourly trigger for Garden's Need Training Reminders

   [Timer]
   OnCalendar=hourly
   Persistent=true

   [Install]
   WantedBy=timers.target
   ```

   b) **Login Rate Limiter Bucket Pruning** (`/etc/systemd/system/gardens-prune-buckets.service` & `gardens-prune-buckets.timer`):
   ```ini
   # UNEXECUTED: /etc/systemd/system/gardens-prune-buckets.service
   [Unit]
   Description=Prune expired login attempt buckets
   After=network.target mysql.service

   [Service]
   Type=oneshot
   User=gardens_app
   Group=gardens_app
   WorkingDirectory=/srv/gardens-app/current
   EnvironmentFile=/etc/gardens/production.env
   ExecStart=/srv/gardens-app/venv/bin/python manage.py prune_login_attempt_buckets --limit=200 --settings=config.production
   StandardOutput=journal
   StandardError=journal
   ```
   ```ini
   # UNEXECUTED: /etc/systemd/system/gardens-prune-buckets.timer
   [Unit]
   Description=Run login attempt bucket pruning every minute

   [Timer]
   OnCalendar=*:0/1
   Persistent=true

   [Install]
   WantedBy=timers.target
   ```

   Enable and start both timers:
   ```bash
   # UNEXECUTED
   sudo systemctl daemon-reload
   sudo systemctl enable --now gardens-reminders.timer gardens-prune-buckets.timer
   ```

2. **Operational Log Monitoring:**
   Inspect JSON formatted application logs at `/var/log/gardens/django.log`:
   - Watch for `"event": "readiness_failed"`.
   - Watch for `"event": "reminders_failed"`.
   - Check error rates: Any sudden burst of HTTP 5xx responses (> 1% of total requests).

3. **Key Alert Thresholds:**
   - Database Connection Latency: > 500ms.
   - Storage Capacity: `PRIVATE_MEDIA_ROOT` disk usage > 80%.
   - Backup Job Age: > 26 hours without a successful `manifest.json`.

---

## I. Rollback and Recovery Procedure

If a critical failure occurs during deployment or pilot validation:

1. **Trigger Conditions for Immediate Rollback:**
   - Production preflight fails during activation.
   - Database migration fails mid-execution or causes schema corruption.
   - Video streaming fails (HTTP 500 / 403 on valid session-based media).
   - High error rate (5xx > 5%) or authentication failures on the live endpoint.

2. **Quiesce production for an approved incident before recovery.**
   Enable maintenance at the proxy and confirm external automation and ad hoc workers cannot restart writers. An isolated rehearsal skips this production step. During an incident, run the following on the approved production host after authorizing sudo. If any unit cannot be stopped or its state cannot be verified, keep maintenance in place and resolve the failure before continuing.

   ```bash
   (
   set -euo pipefail
   timers=(gardens-reminders.timer gardens-prune-buckets.timer)
   writers=(gardens-django.service gardens-reminders.service gardens-prune-buckets.service)
   stop_failed=0
   sudo -n systemctl stop "${timers[@]}" || stop_failed=1
   sudo -n systemctl stop "${writers[@]}" || stop_failed=1
   (( stop_failed == 0 ))
   for unit in "${timers[@]}" "${writers[@]}"; do
       state=$(sudo -n systemctl show --property=ActiveState --value "$unit")
       [[ "$state" == inactive ]]
   done
   )
   ```

3. **Path A: Application-only rollback on the existing database and media.**
   With maintenance enabled and writes stopped, record the current application, static, environment, database and private-media targets. Use this path when the existing data and media are intact and the incident owner approves keeping them. Confirm the previous release supports the current schema, applied migration history, stored data and private-media keys. Review migrations and data changes since that release, including newer applied migrations the previous release may not recognize. A successful preflight alone does not prove backward compatibility. If compatibility is uncertain, rehearse with an approved isolated copy before proceeding. If data recovery is required, use Path B. Never run reverse migrations as part of Path A.

   Select the approved previous release, its matching STATIC_ROOT and a protected environment for that release that still targets the exact existing production database and PRIVATE_MEDIA_ROOT. Confirm the database identity and grants, media access, staticfiles.json and hashed assets. Update the code link, service environment and Nginx static alias together while maintenance is active. Require both sudo nginx -t and a successful Nginx reload. Run production_preflight --database from the selected application with its protected environment. Keep maintenance enabled and all writers and timers stopped if any check fails. Pass only to the Path A activation checks in step 5. No database import or new media root is required for this path.

4. **Path B: Restore the database and private media into an isolated target.**
   Follow [the isolated restore procedure](M20_OPERATIONS.md#7-isolated-restore-rehearsal--separate-explicit-authorization-required). Obtain explicit DBA and incident-owner approval for the backup, post-backup write reconciliation and target. Use a separate MySQL 8 host with no network path or credentials to production/QA/development. On that host the DBA provisions one fresh utf8mb4_0900_ai_ci schema, a new non-root restore-only account scoped to that exact schema and MySQL event scheduling OFF. Verify actual grants and object visibility, plus dump targets, definers, triggers, views, routines and events before import. Keep the dump, its paired media snapshot and their ancestors on trusted read-only storage for this operation. Provision a separate, private, canonical recovery-media parent owned by the restore operator, outside the backup and live media trees.

   Run only on that isolated host. Set these non-secret environment variables from the approved recovery record. RECOVERY_RELEASE is the trusted matching checkout, RECOVERY_PYTHON the absolute path to its virtualenv Python, BACKUP_BUNDLE the absolute completed bundle directory containing manifest.json and database.sql, SOURCE_DATABASE and SOURCE_SERVER the expected manifest identities, MEDIA_SNAPSHOT the absolute path of the approved matching snapshot, and MEDIA_SNAPSHOT_ID the recorded snapshot reference. Confirm the selected snapshot path corresponds to that ID using the backup and snapshot records. The directory name need not equal the ID. RESTORE_SCHEMA is a fresh name matching gn_restore_[a-z0-9]{8,40}, RESTORE_UUID and RESTORE_HOSTNAME are the isolated server identity, RESTORE_ACCOUNT is the exact account including its host, RESTORE_CNF is its private client option file, and RESTORE_MEDIA_PARENT is the dedicated recovery-media parent. Keep credentials in the mode-0600 option file and out of the environment and command arguments.

   The Python function ops.mysql_backup.verify returns the verified manifest dictionary. It checks the size and SHA-256 of database.sql, but does not verify the media snapshot or prove the SQL can be restored. Check the manifest environment, database, server and snapshot reference against the approved record before importing the dump.

   ```bash
   (
   set +x
   set -euo pipefail
   umask 077
   : "${RECOVERY_RELEASE:?}" "${RECOVERY_PYTHON:?}" "${BACKUP_BUNDLE:?}" "${SOURCE_DATABASE:?}" "${SOURCE_SERVER:?}"
   : "${MEDIA_SNAPSHOT:?}" "${MEDIA_SNAPSHOT_ID:?}" "${RESTORE_SCHEMA:?}" "${RESTORE_UUID:?}" "${RESTORE_HOSTNAME:?}"
   : "${RESTORE_ACCOUNT:?}" "${RESTORE_CNF:?}" "${RESTORE_MEDIA_PARENT:?}"

   [[ "$RESTORE_SCHEMA" =~ ^gn_restore_[a-z0-9]{8,40}$ && "$RESTORE_SCHEMA" != "$SOURCE_DATABASE" ]]
   [[ "$RESTORE_HOSTNAME" != "$SOURCE_SERVER" ]]
   [[ "$RESTORE_CNF" == /* && "$(realpath -e -- "$RESTORE_CNF")" == "$RESTORE_CNF" ]]
   test -f "$RESTORE_CNF"
   [[ "$(stat -c %a -- "$RESTORE_CNF")" == 600 ]]
   snapshot=$(realpath -e -- "$MEDIA_SNAPSHOT")
   media_parent=$(realpath -e -- "$RESTORE_MEDIA_PARENT")
   [[ "$snapshot" == "$MEDIA_SNAPSHOT" && "$media_parent" == "$RESTORE_MEDIA_PARENT" ]]
   test -d "$snapshot"
   test -d "$media_parent"
   [[ "$media_parent/" != "$snapshot/"* && "$snapshot/" != "$media_parent/"* ]]
   unexpected=$(find "$snapshot" ! -type f ! -type d -print -quit)
   [[ -z "$unexpected" ]]

   cd -- "$RECOVERY_RELEASE"
   [[ "$RECOVERY_PYTHON" == /* ]]
   "$RECOVERY_PYTHON" -B - "$BACKUP_BUNDLE" "$SOURCE_DATABASE" "$SOURCE_SERVER" "$MEDIA_SNAPSHOT_ID" <<'PY'
   from sys import argv

   from ops.mysql_backup import verify

   bundle, database, server, snapshot_id = argv[1:]
   manifest = verify(bundle)
   if (
       manifest.get("environment") != "production"
       or manifest.get("database") != database
       or manifest.get("server") != server
       or manifest.get("media_snapshot_id") != snapshot_id
   ):
       raise SystemExit("Backup and media identities do not match the approved recovery record.")
   PY

   db=(mysql --defaults-file="$RESTORE_CNF" --no-login-paths --protocol=TCP
       --host=127.0.0.1 --port=3306 --skip-reconnect --skip-force
       --binary-mode --local-infile=0 --batch --skip-column-names --database="$RESTORE_SCHEMA")
   identity=$("${db[@]}" --execute='SELECT DATABASE(), CURRENT_USER(), @@server_uuid, @@hostname, @@port, @@global.event_scheduler;')
   expected=$(printf '%s\t%s\t%s\t%s\t3306\tOFF' "$RESTORE_SCHEMA" "$RESTORE_ACCOUNT" "$RESTORE_UUID" "$RESTORE_HOSTNAME")
   [[ "$identity" == "$expected" ]]
   objects=$("${db[@]}" --execute='SELECT
       (SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE()) +
       (SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=DATABASE()) +
       (SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA=DATABASE()) +
       (SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA=DATABASE());')
   [[ "$objects" == 0 ]]

   media="$media_parent/$RESTORE_SCHEMA"
   mkdir -m 0700 -- "$media"
   "${db[@]}" < "$BACKUP_BUNDLE/database.sql"
   rsync -rpt --chmod=D700,F600 -- "$snapshot/" "$media/"
   diff -qr -- "$snapshot" "$media"
   )
   ```

   Any failure ends this sequence. Preserve the incomplete schema, media and diagnostics for the DBA. Require a fresh target and new approval for a retry. Production writers and timers remain stopped throughout incident recovery. The restore sequence never starts services or changes the live database, media, environment or proxy.

5. **Require a separate activation decision for the selected path.**

   - **Path A:** Record the compatibility decision for the existing schema and media. Confirm the preflight passed against those same targets and the previous release's static assets. Obtain incident-owner approval for the application, environment and static switch and the restricted smoke test. Restored-schema and new-media checks apply to Path B only.
   - **Path B:** Verify the restored object inventory, row counts, relationships, migration history, protected video media keys and checksums against the backup evidence. Run the matching release's production_preflight --database against the exact recovered schema and new PRIVATE_MEDIA_ROOT using a restore-specific private environment. Confirm the targets, secure service identity and static manifest first. Keep rehearsal data and its signing secret isolated. For actual recovery, obtain approval covering target ownership, runtime grants, recovered data, reconciliation of post-backup writes, the code/environment/static switches, Nginx validation and the restricted smoke test.
   - **Both paths:** Keep maintenance enabled for general traffic and schedulers stopped. Under separate activation approval, start only the selected application and run restricted operator smoke checks for health, authentication, hashed assets and authorized media playback. If activation or a smoke check fails, keep maintenance enabled and reapply and verify the writer/timer stop in step 2. Open traffic and re-enable scheduled jobs only after smoke checks pass and the incident owner approves cutover.

---

## J. Final GO / NO-GO Acceptance Checklist

Every item must be explicitly signed off by the release operator before declaring the release active:

- [ ] **1. Code Freeze & Tag:** Git repository is clean; release commit is tagged and CI passes 100%.
- [ ] **2. Environment Security:** `DEBUG=false`, unique 50+ character `DJANGO_SECRET_KEY`, non-root MySQL user.
- [ ] **3. Pre-Deployment Backup Verified:** `ops.mysql_backup` completed with valid `manifest.json` and matching media snapshot.
- [ ] **4. Migrations Applied:** `python manage.py migrate` finished with 0 unapplied migrations.
- [ ] **5. Static Assets Collected:** `STATIC_ROOT` contains `staticfiles.json` with hashed shell and player assets.
- [ ] **6. Production Preflight Passed:** `python manage.py production_preflight --database` exited with status 0.
- [ ] **7. TLS & Security Headers Active:** HTTPS verified, secure cookies confirmed, HSTS header active, direct media URLs blocked.
- [ ] **8. Release APK Signed:** `app-release.apk` signed with production keystore and SHA-256 recorded.
- [ ] **9. Pilot Journey Verified:** Complete login -> video -> assessment -> certificate flow passed on physical test device.
- [ ] **10. Rollback Prepared:** Previous release directory and pre-deployment backup bundle confirmed accessible.
