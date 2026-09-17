"""Read-only bridge to scientist hypothesis ledgers (the terminal feeds the dashboard).

The scientist package (science-loops/scientist) writes append-only, hash-chained JSONL
ledgers wherever it runs. This module DISCOVERS those runs, INDEPENDENTLY re-verifies the
chain + head sidecar (format-level check, no rule logic duplicated), and flattens events
into display state. It never writes — the terminal is the only author; the dashboard is a
window. Rule outcomes (states, verdicts, credits) are shown exactly as the events recorded
them; nothing is recomputed here, so viewer and engine can never disagree.

Run roots: $SCIENTIST_RUN_ROOTS (colon-separated) or the defaults below. Any directory
containing a `ledger.jsonl` under a root is one run.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

GENESIS_SHA = "0" * 64
DEFAULT_ROOTS = [
    Path("/Volumes/PRO-G40/science-loops/scientist/dogfood"),
    Path.home() / ".scientist" / "runs",
]
MAX_LEDGER_BYTES = 16 * 1024 * 1024


def run_roots() -> list[Path]:
    configured = os.environ.get("SCIENTIST_RUN_ROOTS", "")
    if configured.strip():
        return [Path(p).expanduser() for p in configured.split(":") if p.strip()]
    return DEFAULT_ROOTS


def _canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _verify_chain(path: Path) -> tuple[list[dict], str]:
    """Replay + verify. Returns (events, "ok") or ([], reason). Mirrors the engine's
    format checks only — sequence, prev-links, content hashes, head sidecar."""
    if path.stat().st_size > MAX_LEDGER_BYTES:
        return [], "ledger exceeds the viewer size bound"
    events, prev = [], GENESIS_SHA
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines()):
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            return [], f"unparseable event at line {number + 1}"
        if event.get("seq") != number or event.get("prev_sha") != prev:
            return [], f"broken chain at line {number + 1}"
        body = _canonical({"seq": event["seq"], "ts": event["ts"], "kind": event["kind"],
                           "payload": event["payload"], "prev_sha": event["prev_sha"]})
        if hashlib.sha256(body.encode()).hexdigest() != event.get("sha"):
            return [], f"content hash mismatch at line {number + 1}"
        prev = event["sha"]
        events.append(event)
    head_path = path.with_name(path.name + ".head")
    if not head_path.exists():
        return [], "missing head sidecar — cannot rule out end-truncation"
    recorded = head_path.read_text(encoding="utf-8").strip()
    replayed = events[-1]["sha"] if events else GENESIS_SHA
    if recorded != replayed and not (events and events[-1]["prev_sha"] == recorded):
        return [], "head mismatch — events truncated from the end or sidecar edited"
    return events, "ok"


def _flatten(events: list[dict]) -> dict:
    hypotheses: dict[str, dict] = {}
    experiments: dict[str, dict] = {}
    credits: list[dict] = []
    for event in events:
        kind, payload = event["kind"], event["payload"]
        if kind == "hypothesis_proposed":
            hypotheses[payload["id"]] = {
                "id": payload["id"], "statement": payload["statement"],
                "origin": payload["origin"], "state": "PROPOSED",
                "assumptions": [a["text"] for a in payload["assumptions"]],
                "passed": 0, "refuted": 0, "inconclusive": 0}
        elif kind == "state_changed":
            hypotheses[payload["hypothesis_id"]]["state"] = payload["to"]
        elif kind == "experiment_designed":
            experiments[payload["id"]] = {
                "id": payload["id"], "question": payload["question"],
                "adapter": payload["adapter"], "verdicts": [], "receipt": None}
        elif kind == "receipt_recorded":
            experiments[payload["experiment_id"]]["receipt"] = {
                "raw_digest": payload["raw_digest"],
                "observations": payload["observations"],
                "meta": payload.get("adapter_meta", {})}
        elif kind == "verdict_recorded":
            experiments[payload["experiment_id"]]["verdicts"].append({
                "outcome": payload["outcome"], "predicted": payload["predicted"],
                "actual": payload["actual"], "error": payload["error"]})
        elif kind == "prediction_registered":
            hypotheses[payload["hypothesis_id"]].setdefault(
                "prediction_ids", []).append(payload["id"])
        elif kind == "knowledge_credited":
            credits.append(payload)
    # Verdict counts per hypothesis, via the prediction → hypothesis mapping.
    prediction_owner = {}
    for event in events:
        if event["kind"] == "prediction_registered":
            prediction_owner[event["payload"]["id"]] = event["payload"]["hypothesis_id"]
    for event in events:
        if event["kind"] == "verdict_recorded":
            owner = prediction_owner.get(event["payload"]["prediction_id"])
            if owner and owner in hypotheses:
                key = event["payload"]["outcome"].lower()
                if key in ("passed", "refuted", "inconclusive"):
                    hypotheses[owner][key] += 1
    return {"hypotheses": list(hypotheses.values()),
            "experiments": list(experiments.values()),
            "knowledge_credits": credits}


def list_runs() -> dict:
    runs = []
    for root in run_roots():
        if not root.is_dir():
            continue
        for ledger_path in sorted(root.glob("*/ledger.jsonl")):
            try:
                events, integrity = _verify_chain(ledger_path)
            except OSError as error:
                events, integrity = [], f"unreadable: {error}"
            entry = {"name": ledger_path.parent.name, "root": str(root),
                     "path": str(ledger_path), "events": len(events),
                     "integrity": integrity,
                     "modified": ledger_path.stat().st_mtime}
            if integrity == "ok":
                flat = _flatten(events)
                entry["hypotheses"] = len(flat["hypotheses"])
                entry["credited"] = sum(1 for c in flat["knowledge_credits"] if c["credited"])
                entry["experiments"] = len(flat["experiments"])
            runs.append(entry)
    runs.sort(key=lambda r: -r["modified"])
    return {"roots": [str(r) for r in run_roots()], "runs": runs}


def run_detail(name: str) -> dict:
    for root in run_roots():
        ledger_path = root / name / "ledger.jsonl"
        if not ledger_path.is_file():
            continue
        events, integrity = _verify_chain(ledger_path)
        if integrity != "ok":
            return {"name": name, "integrity": integrity}
        flat = _flatten(events)
        flat.update({"name": name, "integrity": "ok", "events": len(events),
                     "head_sha": events[-1]["sha"] if events else GENESIS_SHA,
                     "path": str(ledger_path)})
        return flat
    return {"name": name, "integrity": "run not found"}
