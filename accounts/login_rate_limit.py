"""Shared admission for website, Django admin and API password sign-in."""

import logging
import re
from collections import OrderedDict
from dataclasses import dataclass
from datetime import timedelta
from ipaddress import ip_address
from threading import Lock
from time import monotonic

from django.conf import settings
from django.contrib.auth import get_user_model
from django.contrib.auth.forms import UsernameField
from django.core.exceptions import ImproperlyConfigured, ValidationError
from django.db import DatabaseError, connection, transaction
from django.http import HttpResponse
from django.template.loader import render_to_string
from django.utils import timezone
from django.utils.crypto import salted_hmac

from .models import LoginAttemptBucket


LOGIN_VIEWS = frozenset({"accounts:login", "admin:login"})
UNIT = 60_000_000  # Credit units per attempt, so one minute of refill is exact.
logger = logging.getLogger("operations")
_log_lock = Lock()
_last_log = {}
_collation_lock = Lock()
_collations = OrderedDict()
COLLATION_TTL_SECONDS = 60
COLLATION_CACHE_LIMIT = 16


class AdmissionUnavailable(Exception):
    pass


@dataclass(frozen=True)
class Rate:
    burst: int
    per_minute: int

    @classmethod
    def parse(cls, value):
        if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]{0,2}/[1-9][0-9]{0,2}", value):
            raise ImproperlyConfigured("Login limits require positive burst/refill integers.")
        burst, refill = map(int, value.split("/"))
        if burst > 600 or refill > 600 or burst > 60 * refill:
            raise ImproperlyConfigured("Login limit is outside the supported bounds.")
        return cls(burst, refill)


def login_rates():
    return (
        Rate.parse(getattr(settings, "LOGIN_LIMIT_SOURCE", "30/60")),
        Rate.parse(getattr(settings, "LOGIN_LIMIT_SOURCE_ACCOUNT", "5/5")),
        Rate.parse(getattr(settings, "LOGIN_LIMIT_ACCOUNT", "20/4")),
    )


def _ip(value):
    if not isinstance(value, str) or not value or len(value) > 45 or "%" in value:
        raise ValueError("Invalid client address")
    address = ip_address(value)
    return getattr(address, "ipv4_mapped", None) or address


def trusted_proxies(value):
    if not isinstance(value, str) or len(value) > 512:
        raise ImproperlyConfigured("Invalid login proxy configuration.")
    try:
        return frozenset(_ip(item.strip()) for item in value.split(",")) if value else frozenset()
    except ValueError:
        raise ImproperlyConfigured("Login proxies must be explicit IP addresses.") from None


def client_ip(meta, proxies):
    peer = _ip(meta.get("REMOTE_ADDR"))
    if peer not in proxies:
        return str(peer)
    forwarded = meta.get("HTTP_X_FORWARDED_FOR")
    if not isinstance(forwarded, str) or not forwarded or len(forwarded) > 512:
        raise ValueError("Invalid trusted forwarding chain")
    hops = forwarded.split(",")
    if len(hops) > 8:
        raise ValueError("Invalid trusted forwarding chain")
    addresses = [_ip(hop.strip()) for hop in hops]
    for address in reversed(addresses):
        if address not in proxies:
            return str(address)
    raise ValueError("Missing client address")


def cleaned_username(post):
    username = post.get("username", "").strip()
    return normalize_username(username) if username else None


def normalize_username(username):
    model = get_user_model()
    field = model._meta.get_field(model.USERNAME_FIELD)
    return UsernameField(max_length=field.max_length or 254).clean(username)


def _username_collation(cursor, key, table, column):
    now = monotonic()
    with _collation_lock:
        cached = _collations.get(key)
        if cached and cached[2] > now:
            _collations.move_to_end(key)
            return cached
        _collations.pop(key, None)

    cursor.execute(
        "SELECT @@server_uuid, DATABASE(), c.COLLATION_NAME FROM information_schema.COLUMNS c "
        "JOIN information_schema.COLLATIONS x ON x.COLLATION_NAME = c.COLLATION_NAME "
        "WHERE c.TABLE_SCHEMA = DATABASE() AND c.TABLE_NAME = %s "
        "AND c.COLUMN_NAME = %s AND c.CHARACTER_SET_NAME = 'utf8mb4' "
        "AND x.PAD_ATTRIBUTE = 'NO PAD'",
        [table, column],
    )
    row = cursor.fetchone()
    if not row or not all(isinstance(value, str) and value for value in row[:2]) or not re.fullmatch(
        r"utf8mb4_[a-z0-9_]+", row[2] or "",
    ):
        raise AdmissionUnavailable("Unsupported username collation")
    entry = (row[:2], row[2], now + COLLATION_TTL_SECONDS)
    with _collation_lock:
        _collations[key] = entry
        _collations.move_to_end(key)
        if len(_collations) > COLLATION_CACHE_LIMIT:
            _collations.popitem(last=False)
    return entry


def _discard_collation(key, entry):
    with _collation_lock:
        if _collations.get(key) is entry:
            del _collations[key]


def account_weight(username):
    """Use MySQL's comparison weights without looking up an account."""
    model = get_user_model()
    field = model._meta.get_field(model.USERNAME_FIELD)
    table, column = field.model._meta.db_table, field.column
    config = connection.settings_dict
    key = (connection.alias, table, column, *(config.get(name) for name in ("ENGINE", "NAME", "HOST", "PORT")))
    with connection.cursor() as cursor:
        for _ in range(2):
            entry = _username_collation(cursor, key, table, column)
            origin, collation, _ = entry
            # Only a validated metadata identifier enters SQL text. Bind the name.
            try:
                cursor.execute(
                    "SELECT @@server_uuid, DATABASE(), "
                    f"CONVERT(HEX(WEIGHT_STRING(CONVERT(%s USING utf8mb4) COLLATE {collation})) USING ascii)",
                    [username],
                )
                result = cursor.fetchone()
            except DatabaseError:
                _discard_collation(key, entry)
                raise
            if not result or not isinstance(result[2], str) or len(result[2]) > 16384:
                _discard_collation(key, entry)
                raise AdmissionUnavailable("Invalid username weight")
            if result[:2] == origin:
                return result[2]
            # A newly connected worker may now be on a different server/schema.
            # Discard the weight and verify the new column before proceeding.
            _discard_collation(key, entry)
    raise AdmissionUnavailable("Username collation origin changed")


def bucket_key(purpose, *parts):
    return salted_hmac(
        "accounts.login-admission.v1." + purpose, "\0".join(parts), algorithm="sha256",
    ).hexdigest()


def available_credit(credit, refreshed, now, rate):
    elapsed = max(now - refreshed, timedelta())
    micros = elapsed // timedelta(microseconds=1)
    return min(rate.burst * UNIT, credit + micros * rate.per_minute)


def _reserve(budgets):
    # Use the primary key to acquire the insert/update lock even on first use.
    # All callers take locks in digest order. A rejected transaction rolls back
    # any brand-new rows, and leaves existing counters and expiry untouched.
    table = connection.ops.quote_name(LoginAttemptBucket._meta.db_table)
    with transaction.atomic(durable=True):
        rows = []
        for key, rate in sorted(budgets):
            with connection.cursor() as cursor:
                now = timezone.now()
                cursor.execute(
                    f"INSERT INTO {table} (`key`, credit, refreshed_at, expires_at) "
                    "VALUES (%s, %s, %s, %s) ON DUPLICATE KEY UPDATE `key` = `key`",
                    [key, rate.burst * UNIT, connection.ops.adapt_datetimefield_value(now),
                     connection.ops.adapt_datetimefield_value(now + timedelta(hours=1))],
                )
            row = LoginAttemptBucket.objects.select_for_update().get(pk=key)
            rows.append((row, rate))
        now = timezone.now()
        credits = [available_credit(row.credit, row.refreshed_at, now, rate) for row, rate in rows]
        waits = [
            (UNIT - credit + rate.per_minute * 1_000_000 - 1) // (rate.per_minute * 1_000_000)
            for (_, rate), credit in zip(rows, credits) if credit < UNIT
        ]
        if waits:
            transaction.set_rollback(True)
            return max(waits)
        for (row, _), credit in zip(rows, credits):
            refreshed = max(now, row.refreshed_at)
            LoginAttemptBucket.objects.filter(pk=row.pk).update(
                credit=credit - UNIT, refreshed_at=refreshed, expires_at=refreshed + timedelta(hours=1),
            )
    return 0


def _require_commit_boundary():
    if connection.vendor != "mysql" or connection.in_atomic_block or not connection.get_autocommit():
        raise AdmissionUnavailable("Login admission requires committed MySQL reservations")


def reserve_login_source(source, rate):
    _require_commit_boundary()
    # Charge source capacity even for invalid usernames and exhausted account
    # budgets. Oversized/random usernames cannot create unlimited bucket rows.
    return _reserve([(bucket_key("source", source), rate)])


def reserve_login_account(source, username, pair_rate, account_rate):
    _require_commit_boundary()
    weight = account_weight(username)
    return _reserve([
        (bucket_key("source-account", source, weight), pair_rate),
        (bucket_key("account", weight), account_rate),
    ])


def reserve_login(source, username, source_rate, pair_rate, account_rate):
    wait = reserve_login_source(source, source_rate)
    if wait or username is None:
        return wait
    return reserve_login_account(source, username, pair_rate, account_rate)


def _log_admission_event(event, status):
    with _log_lock:
        now = monotonic()
        if now - _last_log.get(event, float("-inf")) < 30:
            return
        _last_log[event] = now
    logger.warning("login admission", extra={"event": event, "status_code": status})


class LoginAdmissionMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response
        self.proxies = trusted_proxies(getattr(settings, "LOGIN_LIMIT_TRUSTED_PROXIES", ""))
        self.rates = login_rates()

    def __call__(self, request):
        return self.get_response(request)

    def process_view(self, request, view_func, view_args, view_kwargs):
        if request.method != "POST" or request.resolver_match.view_name not in LOGIN_VIEWS:
            return None

        status, wait = 503, None
        if getattr(request, "csrf_processing_done", False):
            try:
                if request.resolver_match.view_name == "accounts:login" and request.user.is_authenticated:
                    # SignInView redirects authenticated users without checking credentials.
                    return None
                source = client_ip(request.META, self.proxies)
                try:
                    username = cleaned_username(request.POST)
                except ValidationError:
                    # Invalid nonempty names must not reach authentication with
                    # only a source reservation (e.g. excessive ignorable characters).
                    wait = reserve_login(source, None, *self.rates)
                    return self.denial(429 if wait else 400, wait)
                wait = reserve_login(source, username, *self.rates)
                if not wait:
                    return None
                status = 429
            except (AdmissionUnavailable, DatabaseError, ValueError):
                pass
        return self.denial(status, wait)

    @staticmethod
    def denial(status, wait):
        if status != 400:
            event = "login_admission_limited" if status == 429 else "login_admission_unavailable"
            _log_admission_event(event, status)
        # Render without a request so no context processor can query the store.
        response = HttpResponse(render_to_string(
            "accounts/login_limited.html", {"invalid_credentials": status == 400},
        ), status=status)
        response["Cache-Control"] = "no-store"
        if status == 429:
            response["Retry-After"] = str(wait)
        return response
