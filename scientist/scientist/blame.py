"""Failure becomes a hypothesis generator — the scientist-meta step, done mechanically.

When a hypothesis is refuted, the interesting question is not "punish it" but "which
ASSUMPTION absorbs the blame?" The rule here is deliberately simple and inspectable:

  * every assumption of a REFUTED hypothesis gains +1 suspicion,
  * every assumption of a hypothesis that PASSED a verdict in the same experiment gains -1
    (an assumption shared with a surviving sibling is less likely to be the culprit),
  * any assumption whose suspicion reaches SUSPICION_THRESHOLD spawns a new PROPOSED
    hypothesis — "assumption X is false" — flagged as generator-origin so an operator can
    always tell invented follow-ups from human questions.

Credit assignment to assumptions is the hardest part of the loop to receipt; this rule is
version-tagged so a smarter (learned) blame model can replace it WITHOUT touching the ledger
contract: whatever assigns blame, it may only speak through adjust_suspicion events.
"""
from __future__ import annotations

from typing import Dict, List

from .ledger import Hypothesis, Ledger, PASSED, REFUTED, RuleViolation

BLAME_RULE_VERSION = 1
SUSPICION_THRESHOLD = 1


def assign_blame(ledger: Ledger, experiment_id: str) -> List[Dict[str, str]]:
    """Update assumption suspicion from one experiment's verdicts; spawn follow-up hypotheses.

    Returns the list of generated hypotheses (possibly empty)."""
    # Deduplicate by hypothesis: suspicion moves once per HYPOTHESIS per experiment, not once
    # per verdict — a hypothesis with three refuted predictions in one experiment failed once,
    # not three times (review finding, 2026-09-17).
    refuted_by_id: Dict[str, Hypothesis] = {}
    passed_by_id: Dict[str, Hypothesis] = {}
    for verdict in ledger.verdicts.values():
        if verdict["experiment_id"] != experiment_id:
            continue
        hypothesis = ledger.hypotheses[
            ledger.predictions[verdict["prediction_id"]]["hypothesis_id"]]
        if verdict["outcome"] == REFUTED:
            refuted_by_id[hypothesis.id] = hypothesis
        elif verdict["outcome"] == PASSED:
            passed_by_id[hypothesis.id] = hypothesis
    refuted_hypotheses = [refuted_by_id[k] for k in sorted(refuted_by_id)]
    passed_hypotheses = [passed_by_id[k] for k in sorted(passed_by_id)]

    exonerated = {aid for h in passed_hypotheses for aid in h.assumption_ids}
    for hypothesis in refuted_hypotheses:
        for assumption_id in hypothesis.assumption_ids:
            ledger.adjust_suspicion(
                assumption_id, +1,
                reason=f"blame-v{BLAME_RULE_VERSION}: {hypothesis.id} refuted in {experiment_id}")
    for assumption_id in exonerated:
        ledger.adjust_suspicion(
            assumption_id, -1,
            reason=f"blame-v{BLAME_RULE_VERSION}: sibling passed in {experiment_id}")

    generated = []
    for hypothesis in refuted_hypotheses:
        for assumption_id in hypothesis.assumption_ids:
            assumption = ledger.assumptions[assumption_id]
            if assumption["suspicion"] < SUSPICION_THRESHOLD:
                continue
            statement = f"Assumption is false: {assumption['text']}"
            try:
                new_hypothesis = ledger.propose_hypothesis(
                    statement=statement,
                    rationale=(f"Generated from failure of {hypothesis.id} in "
                               f"{experiment_id}; suspicion {assumption['suspicion']}"),
                    assumptions=[],
                    origin=f"generator:{hypothesis.id}")
            except RuleViolation:
                continue    # already generated for this assumption — dedup by statement digest;
                            # anything else (disk, encoding) must propagate, not vanish
            generated.append({"hypothesis_id": new_hypothesis.id,
                              "blamed_assumption": assumption_id,
                              "source_hypothesis": hypothesis.id})
    return generated
