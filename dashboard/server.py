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

Every read opens the SQLite file with ``mode=ro``. The single write lane
is /api/research, and it writes only via the Store — the floor's one
authorized author. stdlib only, localhost only.

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


def harvest(db_name: str, topic: str = "") -> dict:
    """The Jeeves Harvest lane: trace tiles grouped by topic. With a topic
    selected, every tile is returned in trace order together with the
    subject protein's distinct source URLs — the receipts panel."""
    conn = open_ro(_resolve_db(db_name))
    try:
        if not topic:
            rows = conn.execute(
                """SELECT topic, COUNT(*) AS n FROM responses
                    GROUP BY topic ORDER BY topic""").fetchall()
            return {"db": db_name,
                    "topics": [{"topic": r["topic"], "tiles": r["n"]}
                               for r in rows]}
        tiles = [dict(r) for r in conn.execute(
            """SELECT emoji, sentence, subcategory, depth_level, turn_number,
                      related_to, causes, requires, part_of, next_step,
                      previous_step
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


def research(db_name: str, prompt: str) -> dict:
    """The Jeeves Research lane on the floor: prompt -> local proposer ->
    strict parse -> floor admission. This is the dashboard's ONLY write
    path, and it writes exclusively through the Store/gate."""
    if not prompt.strip():
        raise ValueError("empty research prompt")
    # Imported lazily: the read lanes must work even with no model runtime.
    from proposer.runtime import ProposerError, propose
    from symbolic_floor.store import Store
    db_path = _resolve_db(db_name)
    store = Store(str(db_path))
    try:
        return propose(store, prompt.strip())
    except ProposerError as e:
        return {"admitted": "model_unavailable", "error": str(e)}
    finally:
        store.close()


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
            elif url.path == "/api/dbs":
                self._json(list_dbs())
            elif url.path == "/api/sources":
                self._json(sources_rollup(db))
            elif url.path == "/api/graph":
                self._json(graph(db))
            elif url.path == "/api/node":
                self._json(node_detail(db, (q.get("id") or [""])[0]))
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
                                    str(body.get("prompt") or "")))
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
                r = reply(str(db_path), text)
                cs.append(chat_id, {"role": "floor", "at": utc_now_iso_local(),
                                    **r})
                self._json({"chat_id": chat_id, "reply": r})
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
    print(f"floor dashboard (read-only) -> http://127.0.0.1:{args.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
