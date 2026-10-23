"""Production logs deliberately allow only non-sensitive diagnostic fields."""

from datetime import datetime, timezone
import hashlib
import json
import logging
import traceback


EVENTS = {"readiness_failed", "reminders_started", "reminders_completed", "reminders_failed"}


class OperationalJSONFormatter(logging.Formatter):
    def format(self, record):
        event = getattr(record, "event", None)
        event = event if isinstance(event, str) and event in EVENTS else None
        payload = {
            "timestamp": datetime.fromtimestamp(record.created, timezone.utc).isoformat(),
            "level": record.levelname,
            "event": event or "application_log",
        }
        status = getattr(record, "status_code", None)
        if isinstance(status, int) and 100 <= status <= 599:
            payload["status"] = status
        if event in EVENTS:
            for name in ("created_count", "duration_ms"):
                value = getattr(record, name, None)
                if type(value) is int and value >= 0:
                    payload[name] = value
        if record.exc_info and record.exc_info[0]:
            payload["exception_type"] = record.exc_info[0].__name__
            # Code locations aid diagnosis; exception text, locals and paths do not.
            frames = traceback.extract_tb(record.exc_info[2])[-8:]
            locations = [(frame.name, frame.lineno) for frame in frames]
            payload["fingerprint"] = hashlib.sha256(repr((payload["exception_type"], locations)).encode()).hexdigest()[:16]
        # Never format record.msg/args, request, SQL, stack text or arbitrary extras.
        return json.dumps(payload, separators=(",", ":"))
