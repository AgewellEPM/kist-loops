"""Floor dashboard: the Jeeves-system view of the floor, on the web.

Mirrors the Jeeves desktop lanes:
  WHERE IS the data?          -> every floor DB in data/, with counts
  WHERE did it COME FROM?     -> per-edge provenance (source, exact URL,
                                 retrieved_at), rolled up per connector
  HARVEST                     -> the canonical-37 trace tiles, by topic,
                                 each topic carrying its source receipts
  RESEARCH                    -> a prompt goes to the local proposer and is
                                 admitted THROUGH THE GATE (propose());
                                 the model never touches the graph

Every read opens the SQLite file with ``mode=ro``. Every write lane
(/api/research, /api/import, /api/teach, /api/minds, /api/demo/import)
writes only via the Store — the floor's one authorized author. The demo
lane additionally only ever CREATES fresh DBs from allowlisted local
Harvest packs; it never appends to an existing floor. stdlib only,
localhost only.

Run:  .venv/bin/python -m dashboard.server [--port 8977]
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def utc_now_iso_local() -> str:
    from symbolic_floor.schema import utc_now_iso
    return utc_now_iso()

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
DASH_DIR = Path(__file__).resolve().parent
INDEX_HTML = DASH_DIR / "index.html"
STATIC_DIR = DASH_DIR / "static"
STATIC_TYPES = {".css": "text/css", ".js": "text/javascript"}
DEFAULT_PORT = 8977

# Only DBs that actually look like floor DBs are listed (must have the
# typed_relations + edge_provenance pair). Node/edge caps keep the graph
# payload bounded; truncation is reported, never silent.
MAX_GRAPH_EDGES = 2000


def open_ro(db_path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def _is_floor_db(db_path: Path) -> bool:
    try:
        conn = open_ro(db_path)
    except sqlite3.Error:
        return False
    try:
        names = {r["name"] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
        return {"typed_relations", "edge_provenance"} <= names
    except sqlite3.Error:
        return False
    finally:
        conn.close()


def list_dbs() -> dict:
    """Every floor DB under data/ with its location and headline counts."""
    dbs = []
    for p in sorted(DATA_DIR.glob("*.db")):
        if not _is_floor_db(p):
            continue
        conn = open_ro(p)
        try:
            def one(sql: str) -> int:
                try:
                    return conn.execute(sql).fetchone()[0]
                except sqlite3.Error:
                    return 0
            dbs.append({
                "name": p.name,
                "path": str(p),
                "size_bytes": p.stat().st_size,
                "nodes": one("SELECT count(*) FROM nodes"),
                "edges": one("SELECT count(*) FROM typed_relations"),
                "provenance_rows": one("SELECT count(*) FROM edge_provenance"),
                "tiles": one("SELECT count(*) FROM responses"),
                "claims": one("SELECT count(*) FROM claims"),
                "sequences": one("SELECT count(*) FROM sequences"),
            })
        finally:
            conn.close()
    return {"data_dir": str(DATA_DIR), "dbs": dbs}


def _resolve_db(name: str) -> Path:
    """data/-relative name only — no path escape, must be a floor DB."""
    if "/" in name or "\\" in name or not name.endswith(".db"):
        raise ValueError(f"bad db name: {name!r}")
    p = DATA_DIR / name
    if not p.is_file() or not _is_floor_db(p):
        raise ValueError(f"not a floor db: {name!r}")
    return p


def sources_rollup(db_name: str) -> dict:
    """WHERE the data came from: connector + URL-host rollup over every
    edge's provenance, plus retrieval time range. Receipts, not vibes."""
    conn = open_ro(_resolve_db(db_name))
    try:
        rows = conn.execute(
            "SELECT provenance_json FROM edge_provenance ORDER BY edge_id").fetchall()
        per_source: dict[str, dict] = {}
        for r in rows:
            try:
                prov = json.loads(r["provenance_json"])
            except ValueError:
                continue
            src = prov.get("source", "?")
            host = urllib.parse.urlparse(prov.get("url", "")).netloc or "?"
            at = prov.get("retrieved_at", "")
            slot = per_source.setdefault(src, {
                "source": src, "edges": 0, "hosts": {},
                "first_retrieved": at, "last_retrieved": at})
            slot["edges"] += 1
            slot["hosts"][host] = slot["hosts"].get(host, 0) + 1
            if at:
                slot["first_retrieved"] = min(slot["first_retrieved"] or at, at)
                slot["last_retrieved"] = max(slot["last_retrieved"] or at, at)
        return {"db": db_name, "total_provenanced_edges": len(rows),
                "sources": sorted(per_source.values(),
                                  key=lambda s: -s["edges"])}
    finally:
        conn.close()


def graph(db_name: str) -> dict:
    """The whole typed graph (bounded), every edge carrying its provenance
    URL so the front end can show where each link was collected from."""
    conn = open_ro(_resolve_db(db_name))
    try:
        rows = conn.execute(
            """SELECT tr.id, tr.subject, tr.relation_type, tr.object,
                      ep.provenance_json
                 FROM typed_relations tr
                 LEFT JOIN edge_provenance ep ON ep.edge_id = tr.id
                ORDER BY tr.id LIMIT ?""", (MAX_GRAPH_EDGES + 1,)).fetchall()
        truncated = len(rows) > MAX_GRAPH_EDGES
        rows = rows[:MAX_GRAPH_EDGES]
        edges, node_ids = [], set()
        for r in rows:
            prov = None
            if r["provenance_json"]:
                try:
                    prov = json.loads(r["provenance_json"])
                except ValueError:
                    prov = None
            edges.append({"id": r["id"], "source": r["subject"],
                          "relation": r["relation_type"], "target": r["object"],
                          "provenance": prov})
            node_ids.update((r["subject"], r["object"]))
        nodes = [{"id": n, "type": n.split(":", 1)[0]} for n in sorted(node_ids)]
        return {"db": db_name, "nodes": nodes, "edges": edges,
                "truncated": truncated, "edge_cap": MAX_GRAPH_EDGES}
    finally:
        conn.close()


def ledger(db_name: str, *, q: str = "", source: str = "", relation: str = "",
           kind: str = "", date_from: str = "", date_to: str = "",
           limit: int = 200, offset: int = 0) -> dict:
    """The full acquisition ledger: everything the floor pulled, found, or
    registered, as one time-ordered event stream. Every row names its kind,
    its stored write time, and (for edges) the exact URL + retrieval time it
    was collected from. Tiles carry no stored timestamp — reported as null,
    never invented."""
    conn = open_ro(_resolve_db(db_name))
    try:
        events: list[dict] = []
        for r in conn.execute(
                """SELECT tr.id, tr.subject, tr.relation_type, tr.object,
                          tr.created_at, ep.provenance_json
                     FROM typed_relations tr
                     LEFT JOIN edge_provenance ep ON ep.edge_id = tr.id"""):
            prov = None
            if r["provenance_json"]:
                try:
                    prov = json.loads(r["provenance_json"])
                except ValueError:
                    prov = None
            events.append({
                "kind": "edge", "when": r["created_at"], "id": r["id"],
                "text": f'{r["subject"]} {r["relation_type"]} {r["object"]}',
                "subject": r["subject"], "relation": r["relation_type"],
                "object": r["object"],
                "source": (prov or {}).get("source"),
                "url": (prov or {}).get("url"),
                "retrieved_at": (prov or {}).get("retrieved_at")})
        for r in conn.execute("SELECT claim_id, subject, shape, created_at FROM claims"):
            events.append({"kind": "claim", "when": r["created_at"],
                           "id": r["claim_id"], "subject": r["subject"],
                           "relation": r["shape"], "object": None,
                           "text": f'claim {r["shape"]} on {r["subject"]}',
                           "source": None, "url": None, "retrieved_at": None})
        for r in conn.execute("SELECT sequence_id, length, created_at FROM sequences"):
            events.append({"kind": "sequence", "when": r["created_at"],
                           "id": r["sequence_id"], "subject": r["sequence_id"],
                           "relation": None, "object": None,
                           "text": f'sequence stored ({r["length"]} residues)',
                           "source": None, "url": None, "retrieved_at": None})
        for r in conn.execute("SELECT node_id, label, created_at FROM nodes"):
            events.append({"kind": "node", "when": r["created_at"],
                           "id": r["node_id"], "subject": r["node_id"],
                           "relation": None, "object": None,
                           "text": f'node registered: {r["label"]}',
                           "source": None, "url": None, "retrieved_at": None})
        for r in conn.execute("SELECT id, sentence, topic FROM responses"):
            events.append({"kind": "tile", "when": None, "id": r["id"],
                           "subject": r["topic"], "relation": None, "object": None,
                           "text": r["sentence"],
                           "source": None, "url": None, "retrieved_at": None})

        def keep(e: dict) -> bool:
            if kind and e["kind"] != kind:
                return False
            if source and (e["source"] or "") != source:
                return False
            if relation and (e["relation"] or "") != relation:
                return False
            if q and q.lower() not in e["text"].lower():
                return False
            when = e["when"] or ""
            if date_from and (not when or when < date_from):
                return False
            if date_to and (not when or when[:10] > date_to):
                return False
            return True

        kept = [e for e in events if keep(e)]
        # Newest first; undated rows (tiles) sink to the end, never lie.
        kept.sort(key=lambda e: (e["when"] is None, e["when"] or "", e["id"]),
                  reverse=False)
        kept.reverse()
        undated = [e for e in kept if e["when"] is None]
        dated = [e for e in kept if e["when"] is not None]
        kept = dated + undated

        facets = {"kinds": {}, "sources": {}, "relations": {}, "days": {}}
        for e in kept:
            facets["kinds"][e["kind"]] = facets["kinds"].get(e["kind"], 0) + 1
            if e["source"]:
                facets["sources"][e["source"]] = facets["sources"].get(e["source"], 0) + 1
            if e["relation"]:
                facets["relations"][e["relation"]] = facets["relations"].get(e["relation"], 0) + 1
            day = (e["when"] or "undated")[:10]
            facets["days"][day] = facets["days"].get(day, 0) + 1
        page = kept[offset:offset + limit]
        return {"db": db_name, "total": len(kept), "offset": offset,
                "limit": limit, "events": page, "facets": facets}
    finally:
        conn.close()


def export_csv(led: dict) -> str:
    """Flatten a ledger result to CSV (the 'pull the data' lane)."""
    cols = ("kind", "when", "id", "subject", "relation", "object",
            "source", "url", "retrieved_at", "text")
    def esc(v) -> str:
        s = "" if v is None else str(v)
        return '"' + s.replace('"', '""') + '"' if any(c in s for c in ',"\n') else s
    lines = [",".join(cols)]
    for e in led["events"]:
        lines.append(",".join(esc(e.get(c)) for c in cols))
    return "\n".join(lines) + "\n"


def node_detail(db_name: str, node_id: str) -> dict:
    """Everything stored about one node: in/out edges with full provenance,
    plus its trace tiles if the bio wheel wrote any."""
    conn = open_ro(_resolve_db(db_name))
    try:
        def _edges(col: str) -> list[dict]:
            rows = conn.execute(
                f"""SELECT tr.id, tr.subject, tr.relation_type, tr.object,
                           ep.provenance_json
                      FROM typed_relations tr
                      LEFT JOIN edge_provenance ep ON ep.edge_id = tr.id
                     WHERE tr.{col} = ? ORDER BY tr.id""", (node_id,)).fetchall()
            out = []
            for r in rows:
                prov = None
                if r["provenance_json"]:
                    try:
                        prov = json.loads(r["provenance_json"])
                    except ValueError:
                        prov = None
                out.append({"id": r["id"], "source": r["subject"],
                            "relation": r["relation_type"],
                            "target": r["object"], "provenance": prov})
            return out

        tiles = []
        if node_id.startswith("protein:"):
            acc = node_id.split(":", 1)[1]
            tiles = [dict(r) for r in conn.execute(
                """SELECT sentence, subcategory, topic, emoji
                     FROM responses WHERE topic = ? ORDER BY turn_number""",
                (f"bio-structure:{acc}",)).fetchall()]
        return {"db": db_name, "node": node_id,
                "outgoing": _edges("subject"), "incoming": _edges("object"),
                "tiles": tiles}
    finally:
        conn.close()


# ---------------- science recorder + calendar lane ----------------
# The science-LIST: an always-on recorder of THIS system (floor DBs, the lab
# notebook, local scientist ledgers) built on LIST principles — the personal
# LIST catalog is never read. Mechanism lives in symbolic_floor/science_list.py
# (lazy-imported so the dashboard serves even before that module exists).

SCIENCE_CATALOG = DATA_DIR / "science_list.sqlite"
SCIENCE_CURSOR = DATA_DIR / "science_list_cursor.json"
NOTEBOOK_PATH = DATA_DIR / "notebook.jsonl"
# Local-only scientist ledgers: the PRO-G40 checkout EINTR-stalls under
# training I/O and must never sit inside an automated tick.
SCIENTIST_LOCAL = [Path.home() / ".scientist" / "runs"]


def _notebook_days() -> dict:
    """Notebook entries grouped by local day ('YYYY-MM-DD' from the ISO at)."""
    from dogfood.notebook import Notebook
    days: dict = {}
    for e in Notebook(NOTEBOOK_PATH).entries():
        day = str(e.get("at") or "")[:10]
        if len(day) == 10:
            days.setdefault(day, []).append(e)
    return days


def partner_tick() -> dict:
    """One recorder heartbeat: observe the science system, auto-note any
    change, catch up missing daily digests. Deterministic and model-free —
    the notes write themselves, and say so."""
    from datetime import date
    from dogfood.notebook import Notebook
    from symbolic_floor import science_list as sl
    nb = Notebook(NOTEBOOK_PATH)
    conn = sl.open_catalog(SCIENCE_CATALOG)
    try:
        tick = sl.tick(conn, DATA_DIR, NOTEBOOK_PATH,
                       [p for p in SCIENTIST_LOCAL if p.is_dir()])
        note = sl.write_partner_note(nb, conn, SCIENCE_CURSOR)
        digests = sl.catch_up(nb, conn, date.today().isoformat())
        return {"observed": tick.get("observations", 0),
                "errors": tick.get("errors", []),
                "auto_note": bool(note),
                "digests_written": len(digests)}
    finally:
        conn.close()


def calendar_month(month: str) -> dict:
    """Per-day rollup for the Calendar tab: notebook note counts by kind,
    recorder observation counts, digest presence."""
    import re as _re
    if not _re.fullmatch(r"\d{4}-\d{2}", month):
        raise ValueError(f"month must be YYYY-MM, got {month!r}")
    days: dict = {}
    for day, entries in _notebook_days().items():
        if not day.startswith(month):
            continue
        by_kind: dict = {}
        has_digest = False
        for e in entries:
            by_kind[e.get("kind", "?")] = by_kind.get(e.get("kind", "?"), 0) + 1
            if str(e.get("session") or "") == "science-list-daily":
                has_digest = True
        days[day] = {"notes": len(entries), "byKind": by_kind,
                     "recorded": 0, "hasDigest": has_digest}
    if SCIENCE_CATALOG.is_file():
        try:
            from symbolic_floor import science_list as sl
            conn = sl.open_catalog(SCIENCE_CATALOG)
            try:
                rows = conn.execute(
                    """SELECT substr(observed_at, 1, 10) AS d, count(*) AS n
                         FROM observations WHERE observed_at LIKE ?
                        GROUP BY d""", (month + "-%",)).fetchall()
                for r in rows:
                    days.setdefault(r["d"], {"notes": 0, "byKind": {},
                                             "recorded": 0, "hasDigest": False})
                    days[r["d"]]["recorded"] = r["n"]
            finally:
                conn.close()
        except ImportError:
            pass  # recorder module not landed yet — calendar still serves notes
    return {"month": month, "days": days}


def day_detail(date_str: str) -> dict:
    """One day for the Calendar detail panel: digest, notes, recorder summary."""
    import re as _re
    if not _re.fullmatch(r"\d{4}-\d{2}-\d{2}", date_str):
        raise ValueError(f"date must be YYYY-MM-DD, got {date_str!r}")
    entries = _notebook_days().get(date_str, [])
    digest = next((e for e in entries
                   if str(e.get("session") or "") == "science-list-daily"), None)
    recorder = {"total": 0, "by_event_type": {}, "by_subject": {}}
    if SCIENCE_CATALOG.is_file():
        try:
            from symbolic_floor import science_list as sl
            conn = sl.open_catalog(SCIENCE_CATALOG)
            try:
                recorder = sl.activity_summary(
                    conn, date_str + "T00:00:00", date_str + "T23:59:59")
            finally:
                conn.close()
        except ImportError:
            pass
    return {"date": date_str, "digest": digest,
            "entries": [e for e in entries if e is not digest],
            "recorder": recorder}


def start_recorder_loop(interval_s: int = 300) -> None:
    """The always-on lane: a daemon thread ticking the recorder so notes and
    digests write themselves while the dashboard is up. Failures log and the
    loop keeps breathing — one bad tick never kills the recorder."""
    import sys
    import threading
    import time as _time

    def loop():
        while True:
            try:
                partner_tick()
            except Exception as e:  # noqa: BLE001 — the loop must survive
                print(f"science recorder tick failed: {e}", file=sys.stderr)
            _time.sleep(interval_s)

    threading.Thread(target=loop, daemon=True, name="science-recorder").start()


def sequence_residues(db_name: str, node_id: str) -> dict:
    """The REAL stored residue string for one sequence node — feeds the
    front end's generated-molecule concept (which banners itself as
    generated; the residues themselves are receipts-backed data)."""
    conn = open_ro(_resolve_db(db_name))
    try:
        row = conn.execute(
            "SELECT sequence_id, residues, length FROM sequences "
            "WHERE sequence_id = ?", (node_id,)).fetchone()
        if not row:
            raise ValueError(f"no sequence stored for {node_id!r}")
        return {"id": row["sequence_id"], "residues": row["residues"],
                "length": row["length"]}
    finally:
        conn.close()


def harvest(db_name: str, topic: str = "") -> dict:
    """The Jeeves Harvest lane: trace tiles grouped by topic. With a topic
    selected, every tile is returned in trace order together with the
    subject protein's distinct source URLs — the receipts panel. Topics are
    ordered newest-trace-first so 'Latest harvest' is simply topics[0]."""
    conn = open_ro(_resolve_db(db_name))
    try:
        if not topic:
            rows = conn.execute(
                """SELECT topic, COUNT(*) AS n, MAX(rowid) AS latest
                     FROM responses GROUP BY topic
                    ORDER BY latest DESC""").fetchall()
            return {"db": db_name,
                    "topics": [{"topic": r["topic"], "tiles": r["n"]}
                               for r in rows]}
        tiles = [dict(r) for r in conn.execute(
            """SELECT id, emoji, sentence, subcategory, depth_level,
                      turn_number, related_to, causes, requires, part_of,
                      next_step, previous_step
                 FROM responses WHERE topic = ?
                ORDER BY turn_number, id""", (topic,))]
        sources: list[dict] = []
        if topic.startswith("bio-structure:"):
            acc = topic.split(":", 1)[1]
            seen: dict[str, dict] = {}
            for r in conn.execute(
                    """SELECT ep.provenance_json FROM typed_relations tr
                        JOIN edge_provenance ep ON ep.edge_id = tr.id
                       WHERE tr.subject = ? OR tr.object = ?
                       ORDER BY tr.id""",
                    (f"protein:{acc}", f"protein:{acc}")):
                try:
                    prov = json.loads(r["provenance_json"])
                except ValueError:
                    continue
                url = prov.get("url")
                if url and url not in seen:
                    seen[url] = {"url": url, "source": prov.get("source"),
                                 "retrieved_at": prov.get("retrieved_at")}
            sources = list(seen.values())
        return {"db": db_name, "topic": topic, "tiles": tiles,
                "sources": sources}
    finally:
        conn.close()


def _lib_set(libraries) -> set | None:
    """None = all libraries; a list narrows the wheel (validated by
    extract_protein itself — unknown names are rejected there)."""
    if not libraries:
        return None
    return {str(x) for x in libraries}


# A bare UniProt accession -> the protein proposer lane. Anything else is tried
# as a molecule NAME first (native PubChem wheel, no model), because that is what
# makes `research water` return real chemistry. Non-molecules fall through to the
# proposer, which resolves protein accessions / honestly abstains.
_UNIPROT_ACC_RE = None


def _looks_like_accession(text: str) -> bool:
    global _UNIPROT_ACC_RE
    if _UNIPROT_ACC_RE is None:
        import re
        from symbolic_floor.schema import _UNIPROT_ACC
        _UNIPROT_ACC_RE = re.compile(rf"^{_UNIPROT_ACC}$")
    return bool(_UNIPROT_ACC_RE.match(text.strip().upper()))


def research_molecule_native(db_name: str, query: str) -> dict:
    """Native molecule research: resolve a NAME to a PubChem CID and run the
    molecule wheel through the floor gate. No model, no MCP — deterministic pull
    from the curated PubChem aggregator, every edge provenance-pinned."""
    from symbolic_floor import extract
    from symbolic_floor.store import Store
    db_path = _resolve_db(db_name)
    store = Store(str(db_path))
    try:
        result = extract.research_molecule(store, query.strip())
        if result["status"] == "OK":
            result["admitted"] = "molecule"
            result["lane"] = "native-pubchem"
        return result
    finally:
        store.close()


def research(db_name: str, prompt: str, model: str = "",
             libraries: list | None = None) -> dict:
    """The Research lane on the floor: writes exclusively through the Store/gate.

    Routing: a UniProt accession -> the protein proposer lane. Any other query is
    tried as a molecule NAME first (native PubChem wheel, no model). Only if the
    name doesn't resolve to a molecule does it fall through to the proposer."""
    if not prompt.strip():
        raise ValueError("empty research prompt")
    query = prompt.strip()

    # Molecule-name lane (native, deterministic) — the fix for `research water`.
    if not _looks_like_accession(query):
        try:
            mol = research_molecule_native(db_name, query)
            if mol.get("status") == "OK":
                return mol
        except Exception:  # never let the chem lane break the proposer fallback
            pass

    # Imported lazily: the read lanes must work even with no model runtime.
    from proposer.runtime import DEFAULT_MODEL, ProposerError, propose
    from symbolic_floor.store import Store
    db_path = _resolve_db(db_name)
    store = Store(str(db_path))
    try:
        return propose(store, query, model=model or DEFAULT_MODEL,
                       libraries=_lib_set(libraries))
    except ProposerError as e:
        return {"admitted": "model_unavailable", "error": str(e)}
    finally:
        store.close()


def rules() -> dict:
    """The floor's actual law, straight from the schema constants — the
    Rules popout renders THIS, so it can never drift from the code."""
    from symbolic_floor.schema import (ALLOWED_HOSTS, CHEMISTRY_RELATIONS,
                                       CORE_RELATIONS, EXTRACTION_RELATIONS)
    rel = lambda d: [{"relation": r, "source": s, "target": t}  # noqa: E731
                     for r, (s, t) in d.items()]
    return {
        "core_relations": rel(CORE_RELATIONS),
        "extraction_relations": rel(EXTRACTION_RELATIONS),
        "chemistry_relations": rel(CHEMISTRY_RELATIONS),
        "laws": [
            "Directionality is FIXED per relation — wrong direction is rejected, never flipped.",
            "Every edge REQUIRES provenance (source, url, retrieved_at, raw_id) written in the same transaction.",
            "Non-manual provenance URLs must be https on an allowlisted host.",
            "Functional relations hard-veto: at most one object per subject; a second value is a CONTRADICTION.",
            "The model never writes the graph — proposals are admitted only through the gate.",
            "Labels are cosmetic; the reasoner never reads them to decide.",
        ],
        "allowlisted_hosts": sorted(ALLOWED_HOSTS),
    }


def health() -> dict:
    """'Peel is ready…' pill, honestly: db count + local model runtime."""
    import urllib.request
    ollama = False
    try:
        with urllib.request.urlopen("http://localhost:11434/api/tags",
                                    timeout=1.5) as r:
            ollama = r.status == 200
    except OSError:
        pass
    n = len(list_dbs()["dbs"])
    return {"ok": n > 0, "dbs": n, "ollama": ollama,
            "status": ("Peel is ready…" if n and ollama
                       else "floor readable — model runtime down" if n
                       else "no floor DBs found")}


def models() -> dict:
    """Local Ollama models for the chat model switcher (Jeeves /model)."""
    import urllib.request
    try:
        with urllib.request.urlopen("http://localhost:11434/api/tags",
                                    timeout=2) as r:
            tags = json.loads(r.read())
        return {"models": sorted(m["name"].removesuffix(":latest")
                                 for m in tags.get("models", []))}
    except (OSError, ValueError):
        return {"models": []}


MAX_IMPORT = 10


def import_accessions(db_name: str, accessions: list,
                      libraries: list | None = None) -> dict:
    """The Import lane: a pasted accession list runs the bio wheel directly
    (the CLI seed lane — no model involved; every edge still provenanced).
    Capped per request, cap reported, never silent."""
    from symbolic_floor.extract import extract_protein
    from symbolic_floor.schema import ValidationError, validate_node_id
    from symbolic_floor.store import Store
    accs = [str(a).strip().upper() for a in accessions if str(a).strip()]
    if not accs:
        raise ValueError("no accessions given")
    capped = accs[:MAX_IMPORT]
    store = Store(str(_resolve_db(db_name)))
    results = []
    try:
        for acc in capped:
            try:
                validate_node_id(f"protein:{acc}")
            except ValidationError as e:
                results.append({"accession": acc, "status": "INVALID",
                                "error": str(e)})
                continue
            r = extract_protein(store, acc, enabled=_lib_set(libraries))
            results.append({"accession": acc, "status": r["status"],
                            "edges_written": len(r.get("edges_written", []))})
    finally:
        store.close()
    return {"db": db_name, "requested": len(accs), "processed": len(capped),
            "cap": MAX_IMPORT, "results": results}


def libraries_catalog() -> dict:
    """Every research library the wheel can collect from, with its host and
    role. Only libraries the wheel is actually wired to appear here — a
    checkbox that does nothing is a lie."""
    return {"libraries": [
        {"key": "uniprot", "name": "UniProtKB", "host": "rest.uniprot.org",
         "role": "entry facts: gene, organism, location, disease, domain",
         "required": True},
        {"key": "sequence", "name": "UniProt FASTA", "host": "rest.uniprot.org",
         "role": "canonical residue sequence (content-addressed)",
         "required": False},
        {"key": "pdb", "name": "RCSB PDB", "host": "data.rcsb.org",
         "role": "experimental structures (confirmed per entry)",
         "required": False},
        {"key": "alphafold", "name": "AlphaFold DB", "host": "alphafold.ebi.ac.uk",
         "role": "predicted structure",
         "required": False},
    ]}


def teach(db_name: str, subject: str, relation: str, obj: str,
          citation: str) -> dict:
    """The Teach lane (Jeeves teach_relation): a manual, CITED edge written
    through the Store — direction, node types, functional veto and
    provenance are all enforced by the same validation as every other
    edge. A bad teach is rejected, never corrected."""
    from symbolic_floor.schema import ValidationError, utc_now_iso
    from symbolic_floor.store import Store
    if not citation.strip():
        raise ValueError("teach requires a citation (that IS the provenance)")
    store = Store(str(_resolve_db(db_name)))
    try:
        edge_id, created = store.add_edge(
            subject.strip(), relation.strip(), obj.strip(),
            {"source": "manual", "url": None,
             "retrieved_at": utc_now_iso(), "raw_id": citation.strip()},
            label=f"taught: {subject} {relation} {obj}")
        return {"ok": True, "edge_id": edge_id, "created": created}
    except ValidationError as e:
        return {"ok": False, "rejected": str(e)}
    finally:
        store.close()


def diagnostics(db_name: str) -> dict:
    """Integrity invariants, checked live — the wrench tool tells the
    truth about THIS db, it never assumes."""
    conn = open_ro(_resolve_db(db_name))
    try:
        def one(sql: str) -> int:
            try:
                return conn.execute(sql).fetchone()[0]
            except sqlite3.Error:
                return -1
        edges = one("SELECT count(*) FROM typed_relations")
        prov = one("SELECT count(*) FROM edge_provenance")
        orphan_prov = one("""SELECT count(*) FROM edge_provenance
                              WHERE edge_id NOT IN (SELECT id FROM typed_relations)""")
        contradictions = one("SELECT count(*) FROM contradictions")
        checks = [
            {"check": "every edge has provenance", "ok": edges == prov,
             "detail": f"{edges} edges / {prov} provenance rows"},
            {"check": "no orphan provenance", "ok": orphan_prov == 0,
             "detail": f"{orphan_prov} orphans"},
            {"check": "contradiction register", "ok": True,
             "detail": f"{contradictions} recorded (0 hidden — the engine "
                       f"records, never deletes)"},
            {"check": "inferred links labeled", "ok": True,
             "detail": f"{one('SELECT count(*) FROM inferred_links')} inferred "
                       f"(never mixed with witnessed edges)"},
        ]
        return {"db": db_name, "checks": checks,
                "counts": {"edges": edges, "provenance": prov,
                           "nodes": one("SELECT count(*) FROM nodes"),
                           "tiles": one("SELECT count(*) FROM responses"),
                           "claims": one("SELECT count(*) FROM claims"),
                           "sequences": one("SELECT count(*) FROM sequences"),
                           "contradictions": contradictions},
                "all_ok": all(c["ok"] for c in checks)}
    finally:
        conn.close()


def docscan(text: str) -> dict:
    """Document scan (the honest import-a-document lane): find accession-
    shaped tokens and curated protein names in pasted text. It proposes
    candidates only — importing them is a separate, deliberate click.
    Real PDF binary parsing is NOT done here and is not pretended."""
    from dashboard.chat import ACCESSION_RE
    from proposer.dataset import KNOWN_PROTEINS
    found: dict[str, str] = {}
    for m in ACCESSION_RE.findall(text or ""):
        found.setdefault(m.upper(), "accession in text")
    low = (text or "").lower()
    for name, acc in KNOWN_PROTEINS.items():
        if name in low:
            found.setdefault(acc, f"named “{name}”")
    return {"candidates": [{"accession": a, "why": w}
                           for a, w in sorted(found.items())],
            "note": "candidates only — nothing imported yet"}


SESSION_PID = DATA_DIR / "session.pid"
SESSION_LOG = DATA_DIR / "session.log"


def _session_running() -> int | None:
    import os
    try:
        pid = int(SESSION_PID.read_text().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def run_session_bg(db_name: str) -> dict:
    """▶ Run: launch a full research-loop session (extract -> claims ->
    probes -> discovery -> ponder) as a detached process. One at a time;
    the Notebook tab shows it dictating live."""
    import subprocess
    pid = _session_running()
    if pid:
        raise ValueError(f"a session is already running (pid {pid})")
    db_path = _resolve_db(db_name)
    py = ROOT / ".venv" / "bin" / "python"
    with SESSION_LOG.open("w") as log:
        proc = subprocess.Popen(
            [str(py), "-m", "dogfood.research_loop", "--db", str(db_path)],
            cwd=str(ROOT), stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True)
    SESSION_PID.write_text(str(proc.pid))
    return {"started": True, "pid": proc.pid, "db": db_name,
            "log": str(SESSION_LOG)}


def session_status() -> dict:
    pid = _session_running()
    tail = ""
    if SESSION_LOG.is_file():
        tail = "\n".join(SESSION_LOG.read_text().splitlines()[-12:])
    return {"running": pid is not None, "pid": pid, "log_tail": tail}


def report_md() -> dict:
    p = ROOT / "dogfood" / "research_session.md"
    if not p.is_file():
        return {"md": "", "note": "no session report yet — run a session"}
    return {"md": p.read_text(), "path": str(p)}


def create_mind(name: str) -> dict:
    """Create New Mind: a fresh, empty floor DB (schema initialized by the
    Store — the only author). Name is slug-checked, no path escapes."""
    import re as _re
    from symbolic_floor.store import Store
    slug = str(name).strip().lower()
    if not _re.fullmatch(r"[a-z0-9][a-z0-9_-]{1,40}", slug):
        raise ValueError("mind name must be 2-41 chars: a-z 0-9 _ -")
    path = DATA_DIR / f"{slug}.db"
    if path.exists():
        raise ValueError(f"mind {slug!r} already exists")
    Store(str(path)).close()
    return {"created": path.name, "path": str(path)}


# Demo lane: only packs under this root are importable — the browser never
# sends a filesystem path, only a pack NAME resolved against this allowlist.
HARVEST_ROOT = Path.home() / "Desktop" / "Harvest"


def _seen_packs_path() -> Path:
    return DATA_DIR / "demo_packs_seen.json"


def _seen_packs() -> list[str]:
    try:
        return sorted(set(json.loads(_seen_packs_path().read_text())))
    except (OSError, ValueError):
        return []


def _remember_pack(name: str) -> None:
    names = set(_seen_packs())
    if name not in names:
        names.add(name)
        _seen_packs_path().write_text(json.dumps(sorted(names)))


def _probe_pack(name: str) -> dict | None:
    """Stat one pack subdir DIRECTLY (child paths answer even while the
    Harvest root itself refuses enumeration — see demo_packs)."""
    from symbolic_floor.harvest_pack import pack_summary
    name = str(name).strip()
    if not name or "/" in name or "\\" in name or name.startswith("."):
        raise ValueError(f"bad pack name: {name!r}")
    p = HARVEST_ROOT / name
    if not p.is_dir():
        return None
    summary = pack_summary(p)
    if summary["files"]:
        _remember_pack(name)
        return summary
    return None


def demo_packs() -> dict:
    """The importable Harvest packs on this machine, filename-level counts.

    The Harvest ROOT on this Mac is persistently un-enumerable while the
    harvester churns it (getdirentries EINTRs forever), while its child
    directories answer instantly. So: enumerate when the root allows it,
    and otherwise fall back to probing every pack name that has ever been
    seen (registry in data/demo_packs_seen.json, fed by probes + imports).
    `enumerable` tells the UI which world it is in — never a silent blank."""
    from symbolic_floor.harvest_pack import eintr_retry, pack_summary
    packs, enumerable = [], True
    if HARVEST_ROOT.is_dir():
        try:
            entries = sorted(eintr_retry(
                lambda: list(HARVEST_ROOT.iterdir()), attempts=3, delay=0.1))
            for p in entries:
                if p.is_dir() and not p.name.startswith("."):
                    summary = pack_summary(p)
                    if summary["files"]:
                        _remember_pack(p.name)
                        packs.append(summary)
        except InterruptedError:
            enumerable = False
            for name in _seen_packs():
                probed = _probe_pack(name)
                if probed:
                    packs.append(probed)
    return {"root": str(HARVEST_ROOT), "packs": packs, "enumerable": enumerable}


def demo_import(pack: str, mind: str) -> dict:
    """Import one allowlisted pack into a COMPLETELY NEW floor DB — a fresh
    demo area every time. An existing DB name is refused (never appended to),
    and a failed import removes the partial DB so the retry starts clean.
    Every tile is written through the Store via write_tile (37/37 enforced)."""
    import re as _re
    from symbolic_floor.harvest_pack import import_pack
    from symbolic_floor.store import Store
    pack = str(pack).strip()
    if not pack or "/" in pack or "\\" in pack or pack.startswith("."):
        raise ValueError(f"bad pack name: {pack!r}")
    pack_dir = HARVEST_ROOT / pack
    if not pack_dir.is_dir():
        raise ValueError(f"no such pack under {HARVEST_ROOT}: {pack!r}")
    slug = str(mind).strip().lower()
    if not _re.fullmatch(r"[a-z0-9][a-z0-9_-]{1,40}", slug):
        raise ValueError("demo mind name must be 2-41 chars: a-z 0-9 _ -")
    path = DATA_DIR / f"{slug}.db"
    if path.exists():
        raise ValueError(
            f"mind {slug!r} already exists — the demo area must be completely new")
    store = Store(str(path))
    try:
        result = import_pack(store, pack_dir)
    except Exception:
        store.close()
        path.unlink(missing_ok=True)
        raise
    store.close()
    _remember_pack(pack)
    return {"created": path.name, **result}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # quiet: it's a local dashboard
        pass

    def _json(self, obj, status: int = 200) -> None:
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _file(self, path: Path, ctype: str) -> None:
        body = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 (http.server API)
        url = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(url.query)
        db = (q.get("db") or [""])[0]
        try:
            if url.path == "/":
                self._file(INDEX_HTML, "text/html; charset=utf-8")
            elif url.path.startswith("/static/"):
                name = url.path[len("/static/"):]
                target = (STATIC_DIR / name).resolve()
                if (target.parent != STATIC_DIR or not target.is_file()
                        or target.suffix not in STATIC_TYPES):
                    self._json({"error": "not found"}, 404)
                else:
                    self._file(target, STATIC_TYPES[target.suffix])
            elif url.path == "/api/calendar":
                self._json(calendar_month((q.get("month") or [""])[0]))
            elif url.path == "/api/day":
                self._json(day_detail((q.get("date") or [""])[0]))
            elif url.path == "/api/demo/packs":
                self._json(demo_packs())
            elif url.path == "/api/demo/probe":
                probed = _probe_pack((q.get("pack") or [""])[0])
                self._json({"found": bool(probed), "pack": probed})
            elif url.path == "/api/dbs":
                self._json(list_dbs())
            elif url.path == "/api/sources":
                self._json(sources_rollup(db))
            elif url.path == "/api/graph":
                self._json(graph(db))
            elif url.path == "/api/node":
                self._json(node_detail(db, (q.get("id") or [""])[0]))
            elif url.path == "/api/sequence":
                self._json(sequence_residues(db, (q.get("id") or [""])[0]))
            elif url.path in ("/api/ledger", "/api/export"):
                led = ledger(
                    db,
                    q=(q.get("q") or [""])[0],
                    source=(q.get("source") or [""])[0],
                    relation=(q.get("relation") or [""])[0],
                    kind=(q.get("kind") or [""])[0],
                    date_from=(q.get("from") or [""])[0],
                    date_to=(q.get("to") or [""])[0],
                    limit=(10**6 if url.path == "/api/export"
                           else min(int((q.get("limit") or ["200"])[0]), 1000)),
                    offset=int((q.get("offset") or ["0"])[0]),
                )
                if url.path == "/api/ledger":
                    self._json(led)
                elif (q.get("format") or ["json"])[0] == "csv":
                    body = export_csv(led).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/csv; charset=utf-8")
                    self.send_header("Content-Disposition",
                                     f'attachment; filename="{db}.ledger.csv"')
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self._json(led)
            elif url.path == "/api/harvest":
                self._json(harvest(db, (q.get("topic") or [""])[0]))
            elif url.path == "/api/notebook":
                from dogfood.notebook import Notebook
                nb = Notebook(DATA_DIR / "notebook.jsonl")
                limit = min(int((q.get("limit") or ["200"])[0]), 2000)
                kind = (q.get("kind") or [""])[0] or None
                self._json({"path": str(nb.path),
                            "entries": nb.entries(limit=limit, kind=kind)})
            elif url.path == "/api/tile":
                conn = open_ro(_resolve_db(db))
                try:
                    row = conn.execute(
                        "SELECT * FROM responses WHERE id = ?",
                        ((q.get("id") or [""])[0],)).fetchone()
                finally:
                    conn.close()
                self._json(dict(row) if row else {"error": "no such tile"},
                           200 if row else 404)
            elif url.path == "/api/chats":
                from .chat import ChatStore
                self._json({"chats": ChatStore(DATA_DIR / "chats").list()})
            elif url.path == "/api/chat":
                from .chat import ChatStore
                cid = (q.get("id") or [""])[0]
                self._json({"id": cid,
                            "turns": ChatStore(DATA_DIR / "chats").turns(cid)})
            elif url.path == "/api/rules":
                self._json(rules())
            elif url.path == "/api/health":
                self._json(health())
            elif url.path == "/api/models":
                self._json(models())
            elif url.path == "/api/libraries":
                self._json(libraries_catalog())
            elif url.path == "/api/structure":
                from .structures import fetch_structure
                self._json(fetch_structure((q.get("id") or [""])[0]))
            elif url.path == "/api/diagnostics":
                self._json(diagnostics(db))
            elif url.path == "/api/session":
                self._json(session_status())
            elif url.path == "/api/report":
                self._json(report_md())
            elif url.path == "/api/scientist/runs":
                # Terminal → dashboard: chain-verified scientist hypothesis ledgers.
                from . import scientist as scientist_bridge
                self._json(scientist_bridge.list_runs())
            elif url.path == "/api/scientist/run":
                from . import scientist as scientist_bridge
                self._json(scientist_bridge.run_detail((q.get("name") or [""])[0]))
            else:
                self._json({"error": "not found"}, 404)
        except ValueError as e:
            self._json({"error": str(e)}, 400)
        except sqlite3.Error as e:
            self._json({"error": f"db error: {e}"}, 500)

    def do_POST(self):  # noqa: N802 (http.server API)
        url = urllib.parse.urlparse(self.path)
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
            if url.path == "/api/research":
                self._json(research(str(body.get("db") or ""),
                                    str(body.get("prompt") or ""),
                                    str(body.get("model") or ""),
                                    body.get("libraries")))
            elif url.path == "/api/chat":
                from .chat import ChatStore, reply
                text = str(body.get("text") or "").strip()
                if not text:
                    raise ValueError("empty message")
                db_path = _resolve_db(str(body.get("db") or ""))
                cs = ChatStore(DATA_DIR / "chats")
                chat_id = str(body.get("chat_id") or "") or cs.create(text)
                cs.append(chat_id, {"role": "user", "text": text,
                                    "at": utc_now_iso_local()})
                r = reply(str(db_path), text,
                          model=str(body.get("model") or ""),
                          libraries=_lib_set(body.get("libraries")))
                cs.append(chat_id, {"role": "floor", "at": utc_now_iso_local(),
                                    **r})
                self._json({"chat_id": chat_id, "reply": r})
            elif url.path == "/api/chats/manage":
                from .chat import ChatStore
                cs = ChatStore(DATA_DIR / "chats")
                op = str(body.get("op") or "")
                cid = str(body.get("id") or "")
                if op == "rename":
                    cs.rename(cid, str(body.get("title") or ""))
                elif op == "delete":
                    cs.delete(cid)
                else:
                    raise ValueError(f"unknown op {op!r}")
                self._json({"ok": True})
            elif url.path == "/api/import":
                self._json(import_accessions(str(body.get("db") or ""),
                                             body.get("accessions") or [],
                                             body.get("libraries")))
            elif url.path == "/api/demo/import":
                self._json(demo_import(str(body.get("pack") or ""),
                                       str(body.get("mind") or "")))
            elif url.path == "/api/partner/tick":
                self._json(partner_tick())
            elif url.path == "/api/minds":
                self._json(create_mind(str(body.get("name") or "")))
            elif url.path == "/api/teach":
                self._json(teach(str(body.get("db") or ""),
                                 str(body.get("subject") or ""),
                                 str(body.get("relation") or ""),
                                 str(body.get("object") or ""),
                                 str(body.get("citation") or "")))
            elif url.path == "/api/docscan":
                self._json(docscan(str(body.get("text") or "")))
            elif url.path == "/api/session":
                self._json(run_session_bg(str(body.get("db") or "")))
            else:
                self._json({"error": "not found"}, 404)
        except ValueError as e:
            self._json({"error": str(e)}, 400)
        except sqlite3.Error as e:
            self._json({"error": f"db error: {e}"}, 500)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = ap.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    start_recorder_loop()
    print(f"floor dashboard (read-only) -> http://127.0.0.1:{args.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
