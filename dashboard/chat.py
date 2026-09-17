"""Chat with the Floor: the Jeeves chat lane, grounded.

A chat reply comes from exactly one of two places:
  RECALL  — stored, provenance-pinned facts about a subject (read-only), or
  the GATE — the proposer lane (propose(): model -> strict parse -> floor).

There is no third path. The floor never free-writes prose; every sentence
in a reply is derived from stored edges or an admission result, and the
raw data rides along so the UI can render receipts.

Chats persist as JSONL under data/chats/, one file per conversation:
first line is meta, each further line one turn.
"""

from __future__ import annotations

import json
import re
import uuid
from pathlib import Path

from symbolic_floor.recall import recall_protein
from symbolic_floor.schema import utc_now_iso
from symbolic_floor.store import Store

# UniProt accession shapes (the two canonical patterns, case-insensitive).
ACCESSION_RE = re.compile(
    r"\b([OPQ][0-9][A-Z0-9]{3}[0-9]|[A-NR-Z][0-9][A-Z][A-Z0-9]{2}[0-9])\b",
    re.IGNORECASE)

RECALL_HINTS = ("know", "recall", "show", "tell", "what", "facts", "about")


class ChatStore:
    """JSONL-per-conversation persistence."""

    def __init__(self, chats_dir: Path):
        self.dir = Path(chats_dir)
        self.dir.mkdir(parents=True, exist_ok=True)

    def _path(self, chat_id: str) -> Path:
        if not re.fullmatch(r"[a-f0-9]{12}", chat_id):
            raise ValueError(f"bad chat id: {chat_id!r}")
        return self.dir / f"{chat_id}.jsonl"

    def create(self, title: str) -> str:
        chat_id = uuid.uuid4().hex[:12]
        meta = {"id": chat_id, "title": title[:60] or "New Conversation",
                "created_at": utc_now_iso()}
        self._path(chat_id).write_text(json.dumps(meta) + "\n")
        return chat_id

    def append(self, chat_id: str, turn: dict) -> None:
        with self._path(chat_id).open("a") as f:
            f.write(json.dumps(turn) + "\n")

    def list(self) -> list[dict]:
        out = []
        for p in self.dir.glob("*.jsonl"):
            try:
                meta = json.loads(p.read_text().splitlines()[0])
                out.append(meta)
            except (ValueError, IndexError):
                continue
        return sorted(out, key=lambda m: m.get("created_at", ""), reverse=True)

    def turns(self, chat_id: str) -> list[dict]:
        lines = self._path(chat_id).read_text().splitlines()
        out = []
        for line in lines[1:]:
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
        return out

    def rename(self, chat_id: str, title: str) -> None:
        if not title.strip():
            raise ValueError("empty title")
        p = self._path(chat_id)
        lines = p.read_text().splitlines()
        meta = json.loads(lines[0])
        meta["title"] = title.strip()[:60]
        p.write_text("\n".join([json.dumps(meta)] + lines[1:]) + "\n")

    def delete(self, chat_id: str) -> None:
        self._path(chat_id).unlink(missing_ok=False)


def _recall_reply(db_path: str, acc: str) -> dict:
    store = Store(db_path)
    try:
        r = recall_protein(store, acc)
    finally:
        store.close()
    n = r["counts"]["total_edges"]
    if n == 0:
        return {"kind": "recall", "subject": f"protein:{acc}",
                "text": f"The floor holds no evidence for {acc} yet. Ask me "
                        f"to pull it: “Pull the available evidence for "
                        f"{acc} into the floor.”",
                "data": r}
    parts = []
    for rel, facts in list(r["facts"].items())[:6]:
        vals = ", ".join(f["node"].split(":", 1)[1][:24] for f in facts[:3])
        parts.append(f"{rel}: {vals}" + (" …" if len(facts) > 3 else ""))
    return {"kind": "recall", "subject": f"protein:{acc}",
            "text": f"{acc} — {n} provenanced edges on the floor. "
                    + "; ".join(parts)
                    + ". Every fact carries its receipt (open the node card).",
            "data": r}


def _gate_reply(db_path: str, text: str, model: str = "") -> dict:
    # Imported lazily so chat recall works with no model runtime present.
    from proposer.runtime import DEFAULT_MODEL, ProposerError, propose
    store = Store(db_path)
    try:
        result = propose(store, text, model=model or DEFAULT_MODEL)
    except ProposerError as e:
        return {"kind": "error", "text": f"Local model unavailable: {e}",
                "data": None}
    finally:
        store.close()
    admitted = result.get("admitted")
    p = result.get("proposal") or {}
    if admitted == "extract":
        x = result.get("extraction") or {}
        msg = (f"Pulled evidence for {p.get('subject')}: "
               f"{x.get('edges_written', 0)} new edges "
               f"({x.get('edges_already_present', 0)} already held), "
               f"{x.get('pdb_xrefs_total', 0)} PDB xrefs known."
               if x.get("status") == "OK" else
               f"{p.get('subject')} has no UniProt entry ({x.get('status')}) "
               f"— nothing was written.")
    elif admitted == "claim":
        v = result.get("verdict") or {}
        msg = (f"Floor verdict on {p.get('subject')}: {v.get('verdict')} "
               f"({len(v.get('trace') or [])} evidence edges).")
    elif admitted == "intent":
        plan = result.get("plan") or {}
        msg = (f"Experiment proposed on {p.get('subject')}: {p.get('intent')} "
               f"{p.get('params')} — plan {plan.get('status')}; dispatch "
               f"stays a human hand-off action.")
    elif admitted == "abstain":
        msg = f"I abstain: {p.get('reason')}"
    else:
        msg = f"Proposal was {admitted}: {str(result.get('error', ''))[:160]}"
    return {"kind": admitted or "error", "text": msg, "data": result}


def reply(db_path: str, text: str, model: str = "") -> dict:
    """Route one user message: recall when it names an accession and reads
    like a question about stored knowledge; otherwise the gate."""
    accs = ACCESSION_RE.findall(text)
    lowered = text.lower()
    if accs and any(h in lowered for h in RECALL_HINTS) \
            and "pull" not in lowered and "verify" not in lowered:
        return _recall_reply(db_path, accs[0].upper())
    return _gate_reply(db_path, text, model=model)
