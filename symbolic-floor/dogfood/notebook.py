"""The lab notebook: the system dictates what it sees, finds, and learns.

Append-only JSONL journal, one note per line. Notes are SESSION ARTIFACTS,
not floor facts — they never enter the typed graph, and the graph never
depends on them. What keeps them honest is the refs discipline: every note
cites the edge ids / node ids / accessions it is about, so any sentence in
the journal can be walked back to provenance-pinned evidence.

Note kinds:
  observation  something the wheel did (edges pulled, sources hit)
  discovery    a traversal convergence (shared node, with paths)
  learning     a floor verdict or a confirmed expectation
  anomaly      a probe failure, a NOT_FOUND, a rejected proposal
  reflection   the proposer's own pondering (its predicted_outcome /
               reason text — model prose, labeled as model prose)

Cross-learning: a new session loads recent notes and hands them to the
proposer as context, so what was discovered before shapes what is proposed
next. The gate still decides what actually happens.
"""

from __future__ import annotations

import json
from pathlib import Path

from symbolic_floor.schema import utc_now_iso

KINDS = ("observation", "discovery", "learning", "anomaly", "reflection")


class Notebook:
    """Append-only journal bound to one JSONL file."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def note(self, kind: str, text: str, *, session: str,
             refs: list[str] | None = None) -> dict:
        if kind not in KINDS:
            raise ValueError(f"note kind must be one of {KINDS}, got {kind!r}")
        if not text.strip():
            raise ValueError("empty note")
        entry = {"at": utc_now_iso(), "session": session, "kind": kind,
                 "text": text.strip(), "refs": sorted(set(refs or []))}
        with self.path.open("a") as f:
            f.write(json.dumps(entry) + "\n")
        return entry

    def entries(self, *, limit: int | None = None,
                kind: str | None = None) -> list[dict]:
        """Newest last. Malformed lines are skipped, never fatal — but
        counted, so corruption is visible to the caller."""
        if not self.path.is_file():
            return []
        out, bad = [], 0
        for line in self.path.read_text().splitlines():
            if not line.strip():
                continue
            try:
                e = json.loads(line)
            except ValueError:
                bad += 1
                continue
            if kind and e.get("kind") != kind:
                continue
            out.append(e)
        if bad:
            out.append({"at": None, "session": None, "kind": "anomaly",
                        "text": f"notebook has {bad} malformed line(s)",
                        "refs": []})
        return out[-limit:] if limit else out

    def digest(self, *, limit: int = 12) -> str:
        """Compact plain-text digest of recent notes — the cross-learning
        context handed to the proposer at the start of a session."""
        recent = self.entries(limit=limit)
        if not recent:
            return "No prior notes."
        return "\n".join(
            f"- [{e['kind']}] {e['text']}" for e in recent)
