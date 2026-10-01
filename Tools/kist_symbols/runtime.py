"""Observe registered runtime endpoints. No UI, VM lifecycle or process injection."""
from __future__ import annotations

import csv
import io
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone

from store import CAP, decode, digest, need


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError("Runtime redirects are refused.")


def pointer(value, path):
    need(isinstance(path, str) and (path == "" or path.startswith("/")), "Use a JSON Pointer, e.g. /perception.")
    for token in path.split("/")[1:]:
        token = token.replace("~1", "/").replace("~0", "~")
        if isinstance(value, list):
            need(token.isdigit() and int(token) < len(value), "Array index is absent.")
            value = value[int(token)]
        else:
            need(isinstance(value, dict) and token in value, "Runtime field is absent: " + token)
            value = value[token]
    return value


def fields(value, path="", depth=0):
    need(depth <= 48, "Runtime nesting exceeds 48 levels.")
    if isinstance(value, (dict, list)) and value:
        items = value.items() if isinstance(value, dict) else enumerate(value)
        for key, child in items:
            token = str(key).replace("~", "~0").replace("/", "~1")
            yield from fields(child, path + "/" + token, depth + 1)
    else:
        kind = ("null" if value is None else "boolean" if isinstance(value, bool) else
                "number" if isinstance(value, (int, float)) else "string" if isinstance(value, str)
                else "empty_object" if isinstance(value, dict) else "empty_array")
        yield {"path": path, "kind": kind, "value": value if kind not in ("empty_object", "empty_array") else None}


def flatten(value):
    out = []
    for row in fields(value):
        need(len(out) < 15000, "Runtime exceeds 15,000 fields; configure a narrower endpoint.")
        out.append(row)
    return out


def csv_bytes(rows):
    stream = io.StringIO(newline="")
    extra = sorted({k for row in rows for k in row} - {"path", "kind", "value"})
    writer = csv.DictWriter(stream, fieldnames=["path", "kind", "value", *extra])
    writer.writeheader()
    for row in rows:
        # Neutralize formulas without changing the canonical JSON evidence.
        writer.writerow({k: "'" + v if isinstance(v, str) and v.startswith(("=", "+", "-", "@", "\t", "\r"))
                         else v for k, v in row.items()})
    return stream.getvalue().encode()


class Observer:
    def __init__(self, targets):
        self.targets = targets
        self.last = {}

    def fetch(self, target):
        need(target in self.targets, "Unknown runtime target; call capabilities for registered targets.")
        cfg = self.targets[target]
        url = cfg["url"]
        u = urllib.parse.urlsplit(url)
        need(u.scheme == "http" and u.hostname == "127.0.0.1" and u.port
             and not u.username and not u.password and not u.fragment,
             "Runtime adapters must name an explicit loopback HTTP endpoint.")
        need(time.monotonic() - self.last.get(target, -1e9) >= 1,
             "Wait one second between runtime reads; no busy polling.")
        self.last[target] = time.monotonic()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(url, timeout=5) as response:
            need(response.status == 200 and response.geturl() == url, "Runtime did not return the registered endpoint.")
            raw = response.read(CAP + 1)
        value = decode(raw)
        need(isinstance(value, dict) and value, "Runtime returned no state object.")
        # Identity is a host-configured predicate, never guessed from a port number.
        need(isinstance(cfg.get("identity_prefix"), str) and cfg["identity_prefix"],
             "Runtime adapter needs a nonempty identity prefix.")
        actual = pointer(value, cfg["identity_pointer"])
        need(isinstance(actual, str) and actual.startswith(cfg["identity_prefix"]),
             "Runtime identity mismatch; the port may now belong to another application.")
        meta = {"target": target, "identity": actual, "observed_at": datetime.now(timezone.utc).isoformat(),
                "source": url, "sha256": digest(raw), "transport": "live_endpoint_read",
                "sample_freshness": "unknown unless the source supplies its own clock",
                "coverage": cfg["coverage"], "complete_runtime_coverage": False,
                "paused": value.get("paused"), "model_calls": 0}
        return raw, value, meta


def page(value, offset=0, limit=30):
    need(type(offset) is int and offset >= 0 and type(limit) is int and 1 <= limit <= 100,
         "Use offset >= 0 and limit 1–100.")
    rows = flatten(value)
    selected = rows[offset:offset + limit]
    for row in selected:
        if isinstance(row["value"], str) and len(row["value"]) > 500:
            row["value"] = row["value"][:500]
            row["truncated"] = True
    return {"fields": selected, "total_fields": len(rows),
            "next_offset": offset + len(selected) if offset + len(selected) < len(rows) else None}
