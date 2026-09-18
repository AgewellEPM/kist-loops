"""Pins for the science recorder (science_list).

Everything runs against tmp dirs: a fake floor db, a tmp Notebook, the
recorder's own catalog. The critical pin is the SELF-ECHO guard — the
recorder must never observe its own auto-notes or digests, or tick N
feeds tick N+1 forever.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest

from dogfood.notebook import Notebook
from symbolic_floor.science_list import (
    DAILY_SESSION,
    SESSION,
    activity_summary,
    catch_up,
    daily_digest,
    observe_scientist,
    open_catalog,
    tick,
    write_partner_note,
)

# ---------------- helpers ----------------

_FLOOR_DDL = """
CREATE TABLE typed_relations (
    id INTEGER PRIMARY KEY, subject TEXT, relation_type TEXT, object TEXT);
CREATE TABLE responses (id TEXT PRIMARY KEY, payload TEXT);
CREATE TABLE claims (claim_id TEXT PRIMARY KEY);
CREATE TABLE nodes (node_id TEXT PRIMARY KEY);
"""


def make_floor_db(path: Path, edges: int = 0, tiles: int = 0,
                  claims: int = 0, nodes: int = 0) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(_FLOOR_DDL)
    add_rows(conn, edges=edges, tiles=tiles, claims=claims, nodes=nodes)
    conn.commit()
    conn.close()


def add_rows(conn: sqlite3.Connection, *, edges: int = 0, tiles: int = 0,
             claims: int = 0, nodes: int = 0) -> None:
    for _ in range(edges):
        conn.execute("INSERT INTO typed_relations (subject, relation_type, object) "
                     "VALUES ('a', 'binds', 'b')")
    for _ in range(tiles):
        conn.execute("INSERT INTO responses (id, payload) "
                     "VALUES (hex(randomblob(8)), 'tile')")
    for _ in range(claims):
        conn.execute("INSERT INTO claims (claim_id) VALUES (hex(randomblob(8)))")
    for _ in range(nodes):
        conn.execute("INSERT INTO nodes (node_id) VALUES (hex(randomblob(8)))")


def grow_floor(path: Path, **kwargs) -> None:
    conn = sqlite3.connect(path)
    add_rows(conn, **kwargs)
    conn.commit()
    conn.close()


def all_observations(conn: sqlite3.Connection) -> list[dict]:
    return [dict(r) for r in conn.execute(
        "SELECT * FROM observations ORDER BY id")]


def line_count(path: Path) -> int:
    return len(path.read_text().splitlines()) if path.is_file() else 0


@pytest.fixture()
def world(tmp_path):
    """Catalog conn + data dir with one floor + notebook + cursor path."""
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    make_floor_db(data_dir / "bio_floor.db", edges=3, tiles=2, claims=1, nodes=2)
    conn = open_catalog(tmp_path / "catalog.db")
    notebook = Notebook(tmp_path / "notebook.jsonl")
    yield {
        "conn": conn,
        "data_dir": data_dir,
        "notebook": notebook,
        "notebook_path": tmp_path / "notebook.jsonl",
        "cursor": tmp_path / "note_cursor.json",
        "tmp": tmp_path,
    }
    conn.close()


def run_tick(w) -> dict:
    return tick(w["conn"], w["data_dir"], w["notebook_path"], [])


# ---------------- (1) baseline, then deltas, then quiet ----------------

def test_baseline_then_delta_then_quiet(world):
    r1 = run_tick(world)
    assert r1["by_source"]["floor"] == 1 and r1["errors"] == []
    obs = all_observations(world["conn"])
    assert obs[0]["event_type"] == "baseline"
    assert obs[0]["subject"] == "bio_floor.db"
    assert obs[0]["detail"] == "baseline: 3 edges, 2 tiles, 1 claims, 2 nodes"

    grow_floor(world["data_dir"] / "bio_floor.db", edges=2, tiles=5)
    r2 = run_tick(world)
    assert r2["by_source"]["floor"] == 2
    new = all_observations(world["conn"])[1:]
    by_detail = {o["detail"]: o for o in new}
    assert by_detail["edges +2"]["delta"] == 2
    assert by_detail["tiles +5"]["delta"] == 5

    r3 = run_tick(world)
    assert r3["observations"] == 0


def test_churn_detected_when_count_unchanged(world):
    run_tick(world)
    # delete the OLDEST edge row, insert a fresh one: count same, max rowid
    # advances (deleting the max row would let sqlite reuse its id)
    conn = sqlite3.connect(world["data_dir"] / "bio_floor.db")
    conn.execute("DELETE FROM typed_relations WHERE id = "
                 "(SELECT MIN(id) FROM typed_relations)")
    conn.execute("INSERT INTO typed_relations (subject, relation_type, object) "
                 "VALUES ('c', 'binds', 'd')")
    conn.commit()
    conn.close()
    r = run_tick(world)
    assert r["by_source"]["floor"] == 1
    last = all_observations(world["conn"])[-1]
    assert last["detail"] == "edges churn: max rowid +1, count unchanged"
    assert last["delta"] == 0


# ---------------- (2) SELF-ECHO guard ----------------

def test_self_echo_guard(world):
    world["notebook"].note("discovery", "shared hub node found",
                           session="probe-1", refs=["edge:1"])
    run_tick(world)  # baseline + the probe note observed
    assert write_partner_note(world["notebook"], world["conn"],
                              world["cursor"]) is None  # cursor init only

    grow_floor(world["data_dir"] / "bio_floor.db", edges=1)
    run_tick(world)
    entry = write_partner_note(world["notebook"], world["conn"], world["cursor"])
    assert entry is not None
    assert entry["session"] == SESSION
    assert entry["text"].startswith("science recorder: 1 change")
    assert "bio_floor.db edges +1" in entry["text"]
    ref = entry["refs"][0]
    assert ref.startswith("science-list:observations:")

    # THE pin: the auto-note just written must NOT be observed next tick,
    # and with nothing new the partner has nothing to say.
    r = run_tick(world)
    assert r["observations"] == 0
    assert all("science recorder" not in o["detail"]
               for o in all_observations(world["conn"]))
    assert write_partner_note(world["notebook"], world["conn"],
                              world["cursor"]) is None


# ---------------- (3) first-call cursor init writes nothing ----------------

def test_partner_note_first_call_writes_no_history(world):
    run_tick(world)  # baseline observation exists in the catalog
    before = line_count(world["notebook_path"])
    assert write_partner_note(world["notebook"], world["conn"],
                              world["cursor"]) is None
    assert line_count(world["notebook_path"]) == before  # no history dump
    max_id = world["conn"].execute(
        "SELECT MAX(id) FROM observations").fetchone()[0]
    assert json.loads(world["cursor"].read_text()) == {"last_id": max_id}


# ---------------- (4) daily digest idempotent ----------------

def _raw_note(path: Path, at: str, kind: str, text: str, session: str,
              refs: list[str] | None = None) -> None:
    with path.open("a") as f:
        f.write(json.dumps({"at": at, "session": session, "kind": kind,
                            "text": text, "refs": refs or []}) + "\n")


def test_daily_digest_idempotent(world):
    nb_path = world["notebook_path"]
    _raw_note(nb_path, "2026-01-02T09:00:00.000Z", "observation",
              "wheel pulled 4 edges", "probe-1", ["edge:7"])
    _raw_note(nb_path, "2026-01-02T10:00:00.000Z", "discovery",
              "tetramer co-complex", "probe-1", ["edge:8", "edge:9"])
    _raw_note(nb_path, "2026-01-03T10:00:00.000Z", "learning",
              "other day, must not leak in", "probe-2")

    d1 = daily_digest(world["notebook"], world["conn"], "2026-01-02")
    assert d1["kind"] == "reflection" and d1["session"] == DAILY_SESSION
    assert d1["text"].startswith("Daily digest 2026-01-02: 2 notes")
    assert "tetramer co-complex" in d1["text"]
    assert "must not leak in" not in d1["text"]
    assert d1["refs"] == ["edge:7", "edge:8", "edge:9"]

    count = line_count(nb_path)
    d2 = daily_digest(world["notebook"], world["conn"], "2026-01-02")
    assert d2["text"] == d1["text"]
    assert line_count(nb_path) == count  # second call wrote nothing


# ---------------- (5) catch_up: missing prior days only, never today ----------------

def test_catch_up_prior_days_only(world):
    daily_digest(world["notebook"], world["conn"], "2026-01-03")  # pre-exists
    created = catch_up(world["notebook"], world["conn"], "2026-01-05",
                       days_back=3)
    dates = [e["text"].split(":")[0] for e in created]
    assert dates == ["Daily digest 2026-01-02", "Daily digest 2026-01-04"]
    text = world["notebook_path"].read_text()
    assert "Daily digest 2026-01-05" not in text  # never today
    assert catch_up(world["notebook"], world["conn"], "2026-01-05",
                    days_back=3) == []  # nothing missing now


# ---------------- (6) unreadable / non-floor files ----------------

def test_unreadable_and_nonfloor_db(world):
    (world["data_dir"] / "garbage.db").write_bytes(b"this is not sqlite at all")
    side = sqlite3.connect(world["data_dir"] / "notafloor.db")
    side.execute("CREATE TABLE other (x)")
    side.commit()
    side.close()

    r = run_tick(world)
    assert len(r["errors"]) == 1 and "garbage.db" in r["errors"][0]
    subjects = {o["subject"] for o in all_observations(world["conn"])}
    assert subjects == {"bio_floor.db"}  # non-floor skipped silently, floor fine


# ---------------- (7) activity_summary window bounds ----------------

def test_activity_summary_window_bounds(world):
    conn = world["conn"]
    rows = [
        ("2026-01-01T23:59:59.999Z", "floor", "a.db", "edges", "edges +1", 1),
        ("2026-01-02T00:00:00.000Z", "floor", "a.db", "edges", "edges +2", 2),
        ("2026-01-02T23:59:59.999Z", "notebook", "probe", "discovery", "hub", 0),
        ("2026-01-03T00:00:00.000Z", "floor", "b.db", "edges", "edges +9", 9),
    ]
    conn.executemany(
        "INSERT INTO observations (observed_at, source, subject, event_type, "
        "detail, delta) VALUES (?, ?, ?, ?, ?, ?)", rows)
    conn.commit()

    s = activity_summary(conn, "2026-01-02T00:00:00", "2026-01-03T00:00:00")
    assert s["total"] == 2  # since inclusive, until exclusive
    assert s["first_at"] == "2026-01-02T00:00:00.000Z"
    assert s["last_at"] == "2026-01-02T23:59:59.999Z"
    assert s["by_event_type"] == {"edges": 1, "discovery": 1}
    assert s["by_subject"] == {"a.db": 1, "probe": 1}


# ---------------- scientist ledgers ----------------

def test_observe_scientist_ledger_deltas(world, tmp_path):
    run_dir = tmp_path / "runs" / "P69905"
    run_dir.mkdir(parents=True)
    ledger = run_dir / "ledger.jsonl"
    ledger.write_text('{"e": 1}\n{"e": 2}\n{"e": 3}\n')

    missing = tmp_path / "runs" / "nope"  # nonexistent dir must be skipped
    conn = world["conn"]
    assert observe_scientist(conn, [run_dir, missing]) == 1
    first = all_observations(conn)[-1]
    assert first["detail"] == "scientist run P69905: +3 chained events"
    assert first["delta"] == 3

    with ledger.open("a") as f:
        f.write('{"e": 4}\n')
    assert observe_scientist(conn, [run_dir, missing]) == 1
    assert all_observations(conn)[-1]["detail"] == \
        "scientist run P69905: +1 chained events"
    assert observe_scientist(conn, [run_dir, missing]) == 0  # quiet
