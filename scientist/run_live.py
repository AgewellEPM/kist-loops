#!/usr/bin/env python3
"""Live proof of the scientist loop over a real question, twice around.

Question: how long is human hemoglobin subunit alpha (UniProt P69905)?
Two competing hypotheses go in (141 — the mature-chain number, vs 142 — the full translated
sequence). Cycle 1 settles it against a real UniProt receipt, REJECTS the loser, and the
loser's failure spawns a follow-up hypothesis about the blamed assumption. Cycle 2 then
tests THAT (is the initiator methionine removed?) against a second real receipt.

Every claim below ends up receipt-backed in an append-only, hash-chained ledger.

Usage:  python3 run_live.py [output-directory]
The output directory must not already exist — history is never overwritten.
"""
import json
import sys
from pathlib import Path

from scientist.adapters import uniprot
from scientist.ledger import Ledger
from scientist.loop import run_cycle
from scientist.roles import propose_competing

ACC = "P69905"


def show(title, result):
    print(f"\n=== {title} ===")
    print(f"experiment: {result['experiment_id']}  observable: {result['selection']['variable']}"
          f"  discrimination: {result['selection']['discrimination']}")
    for verdict in result["verdicts"]:
        print(f"  prediction {verdict['predicted']!r} vs actual {verdict['actual']!r}"
              f"  → {verdict['outcome']} (error {verdict['error']!r})")
    for hypothesis_id, state in result["states"].items():
        print(f"  {hypothesis_id} → {state}")
    for generated in result["generated_hypotheses"]:
        print(f"  ✦ failure generated {generated['hypothesis_id']} "
              f"(blames {generated['blamed_assumption']})")
    print(f"  knowledge: {'CREDITED' if result['knowledge']['credited'] else 'withheld'}"
          f" — {result['knowledge']['reason']}")


def main() -> int:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "dogfood/hemoglobin-P69905")
    if out.exists():
        print(f"refusing to touch existing run at {out} — history is append-only; "
              "pick a fresh directory", file=sys.stderr)
        return 2
    ledger = Ledger(out / "ledger.jsonl")
    adapters = {"uniprot": uniprot.observe}

    h141, h142 = propose_competing(ledger, [
        {"statement": f"{ACC} sequence length is 141",
         "rationale": "classic hemoglobin alpha chain length quoted in textbooks",
         "assumptions": [{"text": "UniProt sequence length excludes the initiator methionine"}]},
        {"statement": f"{ACC} sequence length is 142",
         "rationale": "UniProt canonical sequences include the initiator methionine",
         "assumptions": [{"text": "UniProt counts the full translated sequence"}]},
    ])
    ledger.register_prediction(h141.id, f"uniprot:{ACC}:sequence_length", "==", 141,
                               discriminating=True)
    ledger.register_prediction(h142.id, f"uniprot:{ACC}:sequence_length", "==", 142,
                               discriminating=True)

    first = run_cycle(ledger, adapters)
    show("cycle 1 — which length is it?", first)

    generated = first["generated_hypotheses"]
    if not generated:
        print("no follow-up generated — nothing failed?", file=sys.stderr)
        return 1
    follow_up = ledger.hypotheses[generated[0]["hypothesis_id"]]
    # The scientist-meta step made a claim about the blamed assumption; make it testable and
    # give it a live competitor so cycle 2 also discriminates.
    rival = ledger.propose_hypothesis(
        statement=f"the initiator methionine of {ACC} is retained in the mature protein",
        rationale="devil's advocate for the generated hypothesis",
        assumptions=[{"text": "no post-translational Met removal on hemoglobin alpha"}],
        origin="operator")
    ledger.register_prediction(follow_up.id, f"uniprot:{ACC}:initiator_met_removed", "==",
                               True, discriminating=True)
    ledger.register_prediction(rival.id, f"uniprot:{ACC}:initiator_met_removed", "==",
                               False, discriminating=True)

    second = run_cycle(ledger, adapters)
    show("cycle 2 — was the blamed assumption actually false?", second)

    print("\n=== final ledger ===")
    for hypothesis in ledger.hypotheses.values():
        print(f"  {hypothesis.id}  {hypothesis.state:<12} conf {hypothesis.confidence(ledger):<8}"
              f" [{hypothesis.origin}] {hypothesis.statement}")
    credited = sum(1 for credit in ledger.knowledge_credits if credit["credited"])
    print(f"  knowledge credited: {credited}/{len(ledger.knowledge_credits)} experiments"
          f"  ·  events: {len(ledger.log.events())}  ·  head {ledger.log.head_sha[:16]}…")
    (out / "summary.json").write_text(json.dumps(
        {"cycles": [first, second],
         "head_sha": ledger.log.head_sha,
         "hypotheses": {h.id: {"state": h.state, "confidence": h.confidence(ledger),
                                "statement": h.statement, "origin": h.origin}
                        for h in ledger.hypotheses.values()}},
        indent=2, default=str) + "\n")
    print(f"\nledger: {out / 'ledger.jsonl'}\nsummary: {out / 'summary.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
