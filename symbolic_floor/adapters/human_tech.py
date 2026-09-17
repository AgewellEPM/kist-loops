"""Human-tech environment: the plan becomes a work order; the human is the
hands, and their result file is the data coming back.

submit() writes into the outbox (default <project>/data/outbox):
  <ref>.json         — contract + plan, verbatim (machine copy)
  <ref>.md           — numbered, capability-level instructions for a person
check() looks for <ref>.result.json — the human "sends data back" by writing:
  {"observed": "confirmed" | "refuted" | "inconclusive",
   "notes": "...", "readings": [...]}          (readings optional)
collect() parses and returns it. evidence_grade "physical": a confirmed /
refuted result from here CAN become graph evidence (supports_claim /
conflicts_with) — a human actually did the thing.
"""

from __future__ import annotations

import json
from pathlib import Path

_PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_OUTBOX = _PROJECT_ROOT / "data" / "outbox"

# Human-executable rendering of each capability call.
_VERBS = {
    "aspirate": lambda p: f"Draw {p['volume_ul']:g} µl from {p['source']}",
    "dispense": lambda p: f"Dispense {p['volume_ul']:g} µl into {p['dest']}",
    "mix": lambda p: f"Mix {p['target']} gently, {p['cycles']} cycles",
    "heat": lambda p: f"Hold {p['target']} at {p['temp_c']:g} °C for {p['duration_s']} s",
    "measure_absorbance": lambda p: f"Read absorbance of {p['target']} at {p['wavelength_nm']} nm and RECORD it",
    "read_sensor": lambda p: f"Read sensor {p['sensor']} and RECORD it",
    "label": lambda p: f"Label {p['target']}: {p['text']}",
}


class Env:
    env_id = "human_tech"
    evidence_grade = "physical"

    def __init__(self, outbox: str | Path | None = None):
        self.outbox = Path(outbox) if outbox else DEFAULT_OUTBOX

    def capabilities(self) -> set[str]:
        return set(_VERBS)  # a person can perform every affordance we can render

    # ---------------- lifecycle ----------------

    def submit(self, contract: dict, plan: dict) -> dict:
        self.outbox.mkdir(parents=True, exist_ok=True)
        ref = contract["contract_id"].replace(":", "_")
        (self.outbox / f"{ref}.json").write_text(
            json.dumps({"contract": contract, "plan": plan}, indent=2, sort_keys=True) + "\n"
        )
        (self.outbox / f"{ref}.md").write_text(self._render(contract, plan, ref))
        return {"status": "submitted", "executor_ref": ref}

    def check(self, executor_ref: str) -> dict:
        result = self.outbox / f"{executor_ref}.result.json"
        if result.exists():
            return {"status": "completed"}
        if (self.outbox / f"{executor_ref}.json").exists():
            return {"status": "pending"}
        return {"status": "failed", "notes": "work order not found in outbox"}

    def collect(self, executor_ref: str) -> dict:
        result = self.outbox / f"{executor_ref}.result.json"
        if not result.exists():
            return {"observed": "inconclusive",
                    "notes": "no result file yet — human has not reported back",
                    "readings": []}
        data = json.loads(result.read_text())
        return {"observed": data.get("observed", "inconclusive"),
                "notes": data.get("notes", ""),
                "readings": data.get("readings", [])}

    # ---------------- rendering ----------------

    @staticmethod
    def _render(contract: dict, plan: dict, ref: str) -> str:
        v = contract["verified_result"]
        lines = [
            f"# Work order {contract['contract_id']}",
            "",
            f"- **Subject:** {contract['claim']['subject']}",
            f"- **Floor verdict:** {v['verdict']} (execution class: {contract['execution_class']})",
            f"- **Intent:** {plan['intent']} — {plan['trace']['rule']}",
            "",
            "## Predicted outcome (supplied by the proposer, NOT the floor)",
            "",
            contract["predicted_outcome"]["statement"],
            "",
            f"## Steps ({len(plan['steps'])})",
            "",
        ]
        for s in plan["steps"]:
            verb = _VERBS[s["capability"]](s["params"])
            lines.append(f"{s['step']}. {verb}")
        lines += [
            "",
            f"## Evidence backing this order ({len(contract['evidence'])} edges)",
            "",
        ]
        for e in contract["evidence"]:
            prov = e["provenance"]
            lines.append(f"- `{e['source']}` —{e['relation']}→ `{e['target']}` "
                         f"[{prov['source']}: {prov.get('url') or prov['raw_id']}]")
        lines += [
            "",
            "## When done — send the data back",
            "",
            f"Write `{ref}.result.json` next to this file:",
            "",
            '```json',
            '{"observed": "confirmed" | "refuted" | "inconclusive",',
            ' "notes": "what you saw",',
            ' "readings": [{"target": "well:D3", "absorbance": 0.12}]}',
            '```',
            "",
            "The floor ingests confirmed/refuted as typed evidence; inconclusive",
            "is recorded but never becomes a graph fact.",
            "",
        ]
        return "\n".join(lines)
