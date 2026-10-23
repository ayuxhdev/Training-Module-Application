"""Non-destructive MySQL backup and checksum verification; no restore/delete action."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import uuid


class BackupError(Exception):
    pass


def private_path(value, *, directory=False):
    path = Path(value)
    if not path.is_absolute() or path.is_symlink() or not (path.is_dir() if directory else path.is_file()):
        raise BackupError("Use an existing absolute, non-symlink private path.")
    if os.name != "nt" and path.stat().st_mode & 0o077:
        raise BackupError("Private paths must not grant group/other access.")
    return path.resolve()


def digest_file(path):
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    return size, digest.hexdigest()


def backup(*, defaults_file, database, host, port, expected_server, environment,
           output_dir, media_snapshot_id, timeout=600, mysql="mysql", mysqldump="mysqldump"):
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,63}", database):
        raise BackupError("Database must be an explicit supported identifier.")
    if environment not in {"development", "staging", "production"}:
        raise BackupError("Select an explicit environment.")
    if not 1 <= int(port) <= 65535 or not 1 <= timeout <= 86400 or not host or not expected_server:
        raise BackupError("Invalid connection confirmation or timeout.")
    if not media_snapshot_id or len(media_snapshot_id) > 200 or any(ord(c) < 32 for c in media_snapshot_id):
        raise BackupError("Supply a bounded private-media snapshot reference.")
    options = private_path(defaults_file)
    root = private_path(output_dir, directory=True)
    forbidden = [Path(__file__).resolve().parents[1]]
    forbidden += [Path(os.environ[name]).resolve() for name in ("PRIVATE_MEDIA_ROOT", "STATIC_ROOT") if os.environ.get(name)]
    if any(root.is_relative_to(path) for path in forbidden):
        raise BackupError("Backup output must be outside application, static and private-media trees.")
    client_args = [f"--defaults-file={options}", f"--host={host}", f"--port={port}", "--protocol=TCP"]
    environment_vars = dict(os.environ)
    environment_vars.pop("MYSQL_PWD", None)
    query = (
        "SELECT DATABASE(),@@hostname,(SELECT COUNT(*) FROM information_schema.TABLES "
        "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE' AND ENGINE<>'InnoDB')"
    )
    try:
        result = subprocess.run(
            [mysql, *client_args, "--batch", "--skip-column-names", "--execute=" + query, database],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=min(timeout, 30), check=True, env=environment_vars,
        )
        if result.stdout.decode("utf-8").strip().split("\t") != [database, expected_server, "0"]:
            raise BackupError("Database/server identity or transactional-table verification failed.")
    except (OSError, UnicodeError, subprocess.SubprocessError):
        raise BackupError("MySQL preflight failed; no backup was published. Inspect secure operator diagnostics.") from None
    started = datetime.now(timezone.utc)
    bundle = root / (started.strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex)
    bundle.mkdir(mode=0o700)  # Exclusive directory; never replace an existing backup.
    partial = bundle / "database.sql.partial"
    try:
        with partial.open("xb") as output:
            os.chmod(partial, 0o600)
            subprocess.run(
                [mysqldump, *client_args, "--single-transaction", "--quick", "--skip-lock-tables",
                 "--no-tablespaces", "--set-gtid-purged=OFF", "--hex-blob", "--skip-add-drop-table",
                 "--no-create-db", "--skip-comments", "--routines", "--events", "--triggers",
                 "--skip-force", database],
                stdout=output, stderr=subprocess.PIPE, timeout=timeout, check=True, env=environment_vars,
            )
            output.flush()
            os.fsync(output.fileno())
        size, digest = digest_file(partial)
        if size == 0:
            raise BackupError("Empty dump; incomplete backup retained without a completion manifest.")
        partial.rename(bundle / "database.sql")
        manifest = {
            "format": 1, "database": database, "server": expected_server, "environment": environment,
            "started_at": started.isoformat(), "completed_at": datetime.now(timezone.utc).isoformat(),
            "bytes": size, "sha256": digest, "media_snapshot_id": media_snapshot_id,
        }
        manifest_path = bundle / "manifest.json"
        with manifest_path.open("x", encoding="utf-8") as output:
            os.chmod(manifest_path, 0o600)
            json.dump(manifest, output, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
    except (OSError, subprocess.SubprocessError):
        raise BackupError("Backup failed; incomplete bundle retained. No existing backups were changed.") from None
    return bundle


def verify(bundle):
    root = private_path(bundle, directory=True)
    manifest_path = private_path(root / "manifest.json")
    sql = private_path(root / "database.sql")
    if manifest_path.stat().st_size > 8192:
        raise BackupError("Invalid backup manifest.")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        size, digest = digest_file(sql)
        if (manifest.get("format") != 1 or size <= 0 or manifest.get("bytes") != size
                or manifest.get("sha256") != digest or not manifest.get("media_snapshot_id")):
            raise BackupError("Backup integrity verification failed.")
    except (ValueError, AttributeError):
        raise BackupError("Invalid backup manifest.") from None
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    create = commands.add_parser("create")
    for name in ("defaults-file", "database", "host", "expected-server", "environment", "output-dir", "media-snapshot-id"):
        create.add_argument("--" + name, required=True)
    create.add_argument("--port", type=int, default=3306)
    create.add_argument("--timeout", type=int, default=600)
    check = commands.add_parser("verify")
    check.add_argument("bundle")
    args = vars(parser.parse_args())
    action = args.pop("action")
    try:
        if action == "create":
            print("Backup created:", backup(**args))
        else:
            verify(args["bundle"])
            print("Backup checksum/size verified; SQL restore and media snapshot remain separate rehearsal gates.")
    except BackupError as exc:
        parser.exit(1, str(exc) + "\n")
    except OSError:
        parser.exit(1, "Backup operation failed safely; review private inputs and operator diagnostics.\n")


if __name__ == "__main__":
    main()
