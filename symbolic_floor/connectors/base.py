"""Allowlisted HTTP GET helper: timeouts, bounded retries, injectable transport.

The allowlist check runs BEFORE any network I/O — a non-allowlisted host (or a
non-https scheme) raises AllowlistError without the transport ever being
called. Tests inject a stub transport; the default transport is stdlib
urllib.request (no third-party HTTP dependency; see requirements.txt).
"""

from __future__ import annotations

import time
import urllib.error
import urllib.request
from typing import Callable
from urllib.parse import urlsplit

from ..schema import ALLOWED_HOSTS

TIMEOUT_S = 10.0
MAX_RETRIES = 2          # retry only on 5xx / transport errors
BACKOFF_S = 0.5
USER_AGENT = "symbolic-floor/0.1 (deterministic bio evidence store)"

# transport(url, timeout) -> (status_code, body_bytes)
Transport = Callable[[str, float], tuple[int, bytes]]


class ConnectorError(RuntimeError):
    """Upstream failure the connector cannot interpret (non-404 error, bad body)."""


class AllowlistError(ConnectorError):
    """URL refused before any network I/O."""


def _default_transport(url: str, timeout: float) -> tuple[int, bytes]:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT}, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        # Non-2xx still has a status + body; the caller decides (404 is a signal).
        return e.code, e.read()


def check_allowed(url: str) -> None:
    """Raise AllowlistError unless url is https on an allowlisted host."""
    parts = urlsplit(url)
    if parts.scheme != "https":
        raise AllowlistError(f"only https is allowed, got {parts.scheme!r} in {url}")
    host = (parts.hostname or "").lower()
    if host not in ALLOWED_HOSTS:
        raise AllowlistError(
            f"host {host!r} is not allowlisted; allowed: {sorted(ALLOWED_HOSTS)}"
        )


def http_get(url: str, *, transport: Transport | None = None,
             timeout: float = TIMEOUT_S) -> tuple[int, bytes]:
    """Allowlist-checked GET with bounded retries on 5xx/transport errors.

    Returns (status, body). 4xx is returned to the caller (404 is a meaningful
    signal, not an exception); repeated 5xx/transport failure raises
    ConnectorError.
    """
    check_allowed(url)
    send = transport or _default_transport

    last_err: str | None = None
    for attempt in range(MAX_RETRIES + 1):
        try:
            status, body = send(url, timeout)
        except AllowlistError:
            raise
        except Exception as e:  # transport-level failure (DNS, timeout, reset)
            last_err = f"{type(e).__name__}: {e}"
            if attempt < MAX_RETRIES:
                time.sleep(BACKOFF_S * (2 ** attempt))
            continue
        if status >= 500:
            last_err = f"HTTP {status}: {body[:120]!r}"
            if attempt < MAX_RETRIES:
                time.sleep(BACKOFF_S * (2 ** attempt))
            continue
        return status, body
    raise ConnectorError(f"GET {url} failed after {MAX_RETRIES + 1} attempts: {last_err}")
