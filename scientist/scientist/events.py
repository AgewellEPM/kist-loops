"""Append-only, hash-chained event log — the substrate that makes history rewriting detectable.

Every mutation in the scientist is an appended event; all state is DERIVED by replay. An event
carries the sha256 of its predecessor, so editing or deleting any past line breaks every hash
after it. Nothing in this module interprets events — it only guarantees order and integrity.
"""
from __future__ import annotations

import hashlib
import json
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional

GENESIS_SHA = "0" * 64


class LedgerIntegrityError(RuntimeError):
    """The on-disk chain does not verify — history was edited, truncated, or corrupted."""


@dataclass(frozen=True)
class Event:
    seq: int
    ts: float                # wall-clock; ORDER authority is seq + hash chain, never ts
    kind: str
    payload: Dict[str, Any]
    prev_sha: str
    sha: str

    def to_json(self) -> str:
        return canonical_json({"seq": self.seq, "ts": self.ts, "kind": self.kind,
                               "payload": self.payload, "prev_sha": self.prev_sha,
                               "sha": self.sha})


def canonical_json(value: Any) -> str:
    """One byte-stable encoding for everything that gets hashed. No spaces, sorted keys."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def content_sha(seq: int, ts: float, kind: str, payload: Dict[str, Any], prev_sha: str) -> str:
    body = canonical_json({"seq": seq, "ts": ts, "kind": kind,
                           "payload": payload, "prev_sha": prev_sha})
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


class EventLog:
    """A JSONL file of chained events. Fail-fast: any verification problem raises, never skips."""

    def __init__(self, path: Path, now: Optional[Any] = None) -> None:
        self.path = Path(path)
        self._now = now or time.time
        self._events: List[Event] = []
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if self.path.exists():
            self._events = list(self._verify_and_load())

    def _verify_and_load(self) -> Iterator[Event]:
        prev = GENESIS_SHA
        with self.path.open("r", encoding="utf-8") as handle:
            for line_number, line in enumerate(handle):
                line = line.strip()
                if not line:
                    raise LedgerIntegrityError(f"blank line at {self.path}:{line_number + 1}")
                try:
                    raw = json.loads(line)
                except json.JSONDecodeError as error:
                    raise LedgerIntegrityError(
                        f"unparseable event at {self.path}:{line_number + 1}: {error}") from error
                event = Event(seq=raw["seq"], ts=raw["ts"], kind=raw["kind"],
                              payload=raw["payload"], prev_sha=raw["prev_sha"], sha=raw["sha"])
                if event.seq != line_number:
                    raise LedgerIntegrityError(
                        f"sequence gap at {self.path}:{line_number + 1}: "
                        f"expected seq {line_number}, found {event.seq}")
                if event.prev_sha != prev:
                    raise LedgerIntegrityError(
                        f"broken chain at {self.path}:{line_number + 1}: history was edited")
                expected = content_sha(event.seq, event.ts, event.kind, event.payload,
                                       event.prev_sha)
                if event.sha != expected:
                    raise LedgerIntegrityError(
                        f"content hash mismatch at {self.path}:{line_number + 1}")
                prev = event.sha
                yield event

    @property
    def head_sha(self) -> str:
        return self._events[-1].sha if self._events else GENESIS_SHA

    def append(self, kind: str, payload: Dict[str, Any]) -> Event:
        # Canonical-encode up front so an unencodable payload fails BEFORE touching the file.
        canonical_json(payload)
        seq = len(self._events)
        ts = float(self._now())
        prev = self.head_sha
        sha = content_sha(seq, ts, kind, payload, prev)
        event = Event(seq=seq, ts=ts, kind=kind, payload=payload, prev_sha=prev, sha=sha)
        line = event.to_json() + "\n"
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(line)
            handle.flush()
            os.fsync(handle.fileno())
        self._events.append(event)
        return event

    def events(self) -> List[Event]:
        return list(self._events)

    def __len__(self) -> int:
        return len(self._events)
