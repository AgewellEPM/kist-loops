"""Science recorder: the notes write themselves.

A LIST-style always-on observer scoped to ONE world: the science system in
this workspace. It watches floor databases (strictly read-only), the lab
notebook, and scientist ledgers; diffs each against its own snapshots; and
turns the diffs into catalog observations, partner notes, and daily digests.

Hard boundaries, stated plainly:

  * Deterministic rollups, model-free. Every note and digest is composed by
    string formatting over SQL aggregates — no model ever writes here.
  * The catalog sqlite (open_catalog) is this module's file: this module is
    its ONLY author. Floor DBs are opened via file: URI with mode=ro and are
    never mutated. Besides the catalog there are exactly two other write
    targets, both at caller-handed paths: the Notebook handed in by the
    caller, and the partner-note cursor JSON (written by _write_cursor via a
    temp file + os.replace in the cursor's own directory). open_catalog and
    _write_cursor also mkdir the parent directories of the paths they are
    handed. Nothing outside those handed-in paths is ever written.
  * Auto-notes ref their exact observation range
    ("science-list:observations:<first>-<last>"), so every sentence can be
    walked back to the catalog rows it summarizes.
  * Self-echo guard: notebook lines whose session starts with "science-list"
    are never observed — the recorder must not feed on its own auto-notes or
    digests, or tick N would feed tick N+1 forever.
  * The personal LIST system (~/.file_memory, personal catalogs) is NEVER
    opened, referenced, or read. This module's world is exactly the paths it
    is handed.

Mechanism only: every path and connection is handed in by the caller; no
globals holding state, no threads. The server schedules ticks.
"""

from __future__ import annotations

import json
import os
import sqlite3
from datetime import date, timedelta
from pathlib import Path

from symbolic_floor.schema import utc_now_iso

# Session names this module signs its notebook writes with. Anything whose
# session starts with SELF_SESSION_PREFIX is invisible to the observers.
SESSION = "science-list"
DAILY_SESSION = "science-list-daily"
SELF_SESSION_PREFIX = "science-list"

DETAIL_MAX = 120      # notebook-text truncation inside an observation detail
SNIPPET_MAX = 90      # discovery/anomaly snippet length inside a digest
DIGEST_REFS_MAX = 20  # refs carried by a daily digest
NOTE_PARTS_MAX = 8    # change fragments spelled out in one partner note

# (metric name, table it counts). Fixed internal tuples — never user input —
# so interpolating the table name into SQL below is safe.
_COUNT_METRICS = (
    ("edges", "typed_relations"),
    ("tiles", "responses"),
    ("claims", "claims"),
    ("nodes", "nodes"),
)
_MAXROW_METRICS = (
    ("edges", "typed_relations"),
    ("tiles", "responses"),
)

_CATALOG_DDL = """
CREATE TABLE IF NOT EXISTS observations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    observed_at TEXT NOT NULL,
    source TEXT NOT NULL,
    subject TEXT NOT NULL,
    event_type TEXT NOT NULL,
    detail TEXT NOT NULL,
    delta INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_observations_observed_at
    ON observations (observed_at);
CREATE TABLE IF NOT EXISTS snapshots (
    subject TEXT PRIMARY KEY,
    state_json TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
"""


# ---------------- catalog ----------------

def open_catalog(path: str | Path) -> sqlite3.Connection:
    """Open (creating schema if missing) the recorder's own catalog sqlite.

    Creates the catalog's parent directory if missing. This file belongs to
    the recorder alone; nothing else writes it, and the recorder writes
    nothing else except the Notebook it is handed and the partner-note
    cursor JSON (see _write_cursor).
    """
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(p)
    conn.row_factory = sqlite3.Row
    conn.executescript(_CATALOG_DDL)
    conn.commit()
    return conn


def _record(conn: sqlite3.Connection, source: str, subject: str,
            event_type: str, detail: str, delta: int = 0) -> None:
    conn.execute(
        "INSERT INTO observations (observed_at, source, subject, event_type, detail, delta) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (utc_now_iso(), source, subject, event_type, detail, delta),
    )


def _get_snapshot(conn: sqlite3.Connection, subject: str) -> dict | None:
    row = conn.execute(
        "SELECT state_json FROM snapshots WHERE subject = ?", (subject,)
    ).fetchone()
    return json.loads(row["state_json"]) if row else None


def _put_snapshot(conn: sqlite3.Connection, subject: str, state: dict) -> None:
    conn.execute(
        "INSERT INTO snapshots (subject, state_json, updated_at) VALUES (?, ?, ?) "
        "ON CONFLICT(subject) DO UPDATE SET state_json = excluded.state_json, "
        "updated_at = excluded.updated_at",
        (subject, json.dumps(state, sort_keys=True), utc_now_iso()),
    )


# ---------------- floor observer ----------------

def _floor_state(ro: sqlite3.Connection) -> dict | None:
    """Cheap counts only. Returns None when the file is not a floor
    (no typed_relations table)."""
    tables = {
        r[0] for r in ro.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    if "typed_relations" not in tables:
        return None
    state: dict = {}
    for metric, table in _COUNT_METRICS:
        state[metric] = (
            ro.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            if table in tables else 0
        )
    for metric, table in _MAXROW_METRICS:
        state[f"{metric}_maxrow"] = (
            (ro.execute(f"SELECT MAX(rowid) FROM {table}").fetchone()[0] or 0)
            if table in tables else 0
        )
    return state


def observe_floors(conn: sqlite3.Connection, data_dir: str | Path,
                   errors: list[str] | None = None) -> int:
    """Diff every floor *.db in data_dir against its snapshot; record deltas.

    Floors are opened STRICTLY read-only (file: URI, mode=ro). Valid sqlite
    files without a typed_relations table are not floors and are skipped
    silently. Unreadable files are appended to `errors` (when given) and
    never abort the sweep. Returns observations written.
    """
    errors = errors if errors is not None else []
    root = Path(data_dir)
    if not root.is_dir():
        return 0  # no floors yet — a fresh workspace, not an error
    written = 0
    for db_file in sorted(root.glob("*.db")):
        try:
            ro = sqlite3.connect(f"{db_file.resolve().as_uri()}?mode=ro", uri=True)
            try:
                ro.execute("PRAGMA query_only = ON")
                state = _floor_state(ro)
            finally:
                ro.close()
        except sqlite3.Error as exc:
            errors.append(f"{db_file.name}: {exc}")
            continue
        if state is None:
            continue  # not a floor
        subject = db_file.name
        prev = _get_snapshot(conn, subject)
        if prev is None:
            _record(conn, "floor", subject, "baseline",
                    f"baseline: {state['edges']} edges, {state['tiles']} tiles, "
                    f"{state['claims']} claims, {state['nodes']} nodes")
            written += 1
        else:
            for metric, _ in _COUNT_METRICS:
                delta = state[metric] - prev.get(metric, 0)
                if delta:
                    _record(conn, "floor", subject, metric,
                            f"{metric} {delta:+d}", delta)
                    written += 1
            for metric, _ in _MAXROW_METRICS:
                key = f"{metric}_maxrow"
                row_delta = state[key] - prev.get(key, 0)
                count_delta = state[metric] - prev.get(metric, 0)
                if row_delta and not count_delta:
                    # rows churned without the count moving: rewrite, not growth
                    _record(conn, "floor", subject, metric,
                            f"{metric} churn: max rowid {row_delta:+d}, "
                            "count unchanged")
                    written += 1
        _put_snapshot(conn, subject, state)
    conn.commit()
    return written


# ---------------- notebook observer ----------------

def observe_notebook(conn: sqlite3.Connection, notebook_path: str | Path) -> int:
    """Observe new lab-notebook JSONL lines past the line-count cursor.

    SELF-ECHO GUARD: lines whose session starts with "science-list" are the
    recorder's own auto-notes/digests and are skipped (the cursor still
    advances past them). Without this, tick N feeds tick N+1 forever.
    """
    path = Path(notebook_path)
    snap = _get_snapshot(conn, "notebook") or {"lines": 0}
    lines = path.read_text().splitlines() if path.is_file() else []
    total = len(lines)
    cursor = snap["lines"]
    written = 0
    if total < cursor:
        # file shrank underneath us — record the reset, do not re-observe
        _record(conn, "notebook", "notebook", "reset",
                f"notebook shrank: {cursor} -> {total} lines")
        written += 1
        cursor = total
    for line in lines[cursor:total]:
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            _record(conn, "notebook", "notebook", "malformed",
                    line[:DETAIL_MAX])
            written += 1
            continue
        session = str(entry.get("session") or "")
        if session.startswith(SELF_SESSION_PREFIX):
            continue  # never observe our own notes
        _record(conn, "notebook", session or "notebook",
                str(entry.get("kind") or "note"),
                str(entry.get("text") or "")[:DETAIL_MAX])
        written += 1
    _put_snapshot(conn, "notebook", {"lines": total})
    conn.commit()
    return written


# ---------------- scientist observer ----------------

def observe_scientist(conn: sqlite3.Connection,
                      dirs: list[str | Path]) -> int:
    """Diff each existing dir's ledger.jsonl line count against its snapshot."""
    written = 0
    for d in dirs:
        d = Path(d)
        ledger = d / "ledger.jsonl"
        if not d.is_dir() or not ledger.is_file():
            continue
        subject = f"scientist:{d.name}"
        count = len(ledger.read_text().splitlines())
        prev = _get_snapshot(conn, subject)
        delta = count - (prev["lines"] if prev else 0)
        if delta > 0:
            _record(conn, "scientist", subject, "ledger",
                    f"scientist run {d.name}: +{delta} chained events", delta)
            written += 1
        elif delta < 0:
            _record(conn, "scientist", subject, "ledger",
                    f"scientist run {d.name}: ledger shrank by {-delta} events",
                    delta)
            written += 1
        _put_snapshot(conn, subject, {"lines": count})
    conn.commit()
    return written


# ---------------- tick ----------------

def tick(conn: sqlite3.Connection, data_dir: str | Path,
         notebook_path: str | Path,
         scientist_dirs: list[str | Path]) -> dict:
    """One observation sweep across all three sources.

    An unreadable floor file never aborts the tick: it lands in "errors" and
    the sweep keeps going.
    """
    errors: list[str] = []
    floors = observe_floors(conn, data_dir, errors=errors)
    notebook = observe_notebook(conn, notebook_path)
    scientist = observe_scientist(conn, scientist_dirs)
    return {
        "observations": floors + notebook + scientist,
        "by_source": {"floor": floors, "notebook": notebook,
                      "scientist": scientist},
        "errors": errors,
    }


# ---------------- rollups ----------------

def activity_summary(conn: sqlite3.Connection, since_iso: str,
                     until_iso: str) -> dict:
    """SQL aggregates over observations in [since_iso, until_iso).

    Half-open window on the observed_at strings (fixed-width UTC ISO, so
    lexicographic compare IS chronological compare).
    """
    where = "observed_at >= ? AND observed_at < ?"
    bounds = (since_iso, until_iso)
    total, first_at, last_at = conn.execute(
        f"SELECT COUNT(*), MIN(observed_at), MAX(observed_at) "
        f"FROM observations WHERE {where}", bounds).fetchone()
    by_event_type = {
        r[0]: r[1] for r in conn.execute(
            f"SELECT event_type, COUNT(*) FROM observations WHERE {where} "
            f"GROUP BY event_type ORDER BY COUNT(*) DESC, event_type", bounds)
    }
    by_subject = {
        r[0]: r[1] for r in conn.execute(
            f"SELECT subject, COUNT(*) FROM observations WHERE {where} "
            f"GROUP BY subject ORDER BY COUNT(*) DESC, subject LIMIT 8", bounds)
    }
    return {"total": total, "by_event_type": by_event_type,
            "by_subject": by_subject, "first_at": first_at, "last_at": last_at}


# ---------------- partner note ----------------

def _read_cursor(cursor_path: Path) -> int | None:
    if not cursor_path.is_file():
        return None
    return int(json.loads(cursor_path.read_text())["last_id"])


def _write_cursor(cursor_path: Path, last_id: int) -> None:
    """Atomic cursor advance: temp file in the same dir, then os.replace."""
    cursor_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = cursor_path.with_name(cursor_path.name + ".tmp")
    tmp.write_text(json.dumps({"last_id": last_id}))
    os.replace(tmp, cursor_path)


def write_partner_note(notebook, conn: sqlite3.Connection,
                       cursor_path: str | Path) -> dict | None:
    """Turn observations past the cursor into ONE deterministic auto-note.

    First call initializes the cursor to MAX(id) and returns None — the
    recorder never dumps history into the notebook. Later calls with no new
    observations also return None. The note is model-free, signed session
    "science-list" (so the observers skip it), and refs its exact
    observation range so it can be walked back to catalog rows.
    """
    cursor_path = Path(cursor_path)
    last = _read_cursor(cursor_path)
    if last is None:
        max_id = conn.execute(
            "SELECT COALESCE(MAX(id), 0) FROM observations").fetchone()[0]
        _write_cursor(cursor_path, max_id)
        return None
    rows = conn.execute(
        "SELECT id, source, subject, detail FROM observations "
        "WHERE id > ? ORDER BY id", (last,)).fetchall()
    if not rows:
        return None

    parts: list[str] = []
    notebook_new = 0
    for r in rows:
        if r["source"] == "notebook":
            notebook_new += 1  # rolled up into one fragment below
        elif r["source"] == "scientist":
            parts.append(r["detail"])
        else:
            parts.append(f"{r['subject']} {r['detail']}")
    if notebook_new:
        parts.append(f"notebook {notebook_new} new "
                     f"note{'s' if notebook_new != 1 else ''}")
    if len(parts) > NOTE_PARTS_MAX:
        parts = parts[:NOTE_PARTS_MAX] + [f"+{len(parts) - NOTE_PARTS_MAX} more"]

    n = len(rows)
    first_id, last_id = rows[0]["id"], rows[-1]["id"]
    text = (f"science recorder: {n} change{'s' if n != 1 else ''} — "
            + ", ".join(parts))
    entry = notebook.note(
        "observation", text, session=SESSION,
        refs=[f"science-list:observations:{first_id}-{last_id}"])
    _write_cursor(cursor_path, last_id)
    return entry


# ---------------- daily digest ----------------

def _find_digest(notebook, date_str: str) -> dict | None:
    prefix = f"Daily digest {date_str}:"
    for e in notebook.entries():
        if (e.get("session") == DAILY_SESSION
                and str(e.get("text") or "").startswith(prefix)):
            return e
    return None


def daily_digest(notebook, conn: sqlite3.Connection, date_str: str) -> dict:
    """Idempotent, deterministic, model-free digest of one UTC day.

    If a digest for date_str already exists in the notebook it is returned
    unchanged. Otherwise one is composed from that day's notebook entries
    (the recorder's own science-list* notes excluded — the digest is about
    the science, not the recorder) plus that day's activity_summary.
    """
    existing = _find_digest(notebook, date_str)
    if existing is not None:
        return existing

    day_entries = [
        e for e in notebook.entries()
        if str(e.get("at") or "").startswith(date_str)
        and not str(e.get("session") or "").startswith(SELF_SESSION_PREFIX)
    ]
    counts: dict[str, int] = {}
    for e in day_entries:
        k = str(e.get("kind") or "note")
        counts[k] = counts.get(k, 0) + 1
    snippets = [
        str(e.get("text") or "")[:SNIPPET_MAX]
        for e in day_entries if e.get("kind") in ("discovery", "anomaly")
    ][:3]

    next_day = (date.fromisoformat(date_str) + timedelta(days=1)).isoformat()
    summary = activity_summary(conn, f"{date_str}T00:00:00",
                               f"{next_day}T00:00:00")

    n = len(day_entries)
    kind_bits = ", ".join(f"{v} {k}" for k, v in sorted(counts.items()))
    notes_bit = f"{n} note{'s' if n != 1 else ''}"
    if kind_bits:
        notes_bit += f" ({kind_bits})"
    text = (f"Daily digest {date_str}: {notes_bit}, "
            f"{summary['total']} recorded changes")
    if snippets:
        text += "; notable: " + " | ".join(snippets)

    refs = sorted({r for e in day_entries
                   for r in e.get("refs") or []})[:DIGEST_REFS_MAX]
    return notebook.note("reflection", text, session=DAILY_SESSION, refs=refs)


def catch_up(notebook, conn: sqlite3.Connection, today_str: str,
             days_back: int = 7) -> list[dict]:
    """Write digests for missing PRIOR days only — never today (today is
    still accumulating). Returns only the digests actually created, oldest
    first; days already digested are left untouched."""
    today = date.fromisoformat(today_str)
    created: list[dict] = []
    for back in range(days_back, 0, -1):
        day = (today - timedelta(days=back)).isoformat()
        if _find_digest(notebook, day) is None:
            created.append(daily_digest(notebook, conn, day))
    return created
