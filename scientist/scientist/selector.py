"""Experiment selection — "what action reduces my uncertainty the most?", computed, not felt.

The information-gain proxy is DISCRIMINATION COUNT: how many distinct active hypotheses make
predictions on the same observable that cannot all be true at once. An experiment that can
only confirm what everyone already agrees on scores zero; an experiment on which two active
hypotheses disagree scores by how much disagreement it settles. Ties break toward the
observable with the fewest prior receipts (prefer un-probed territory), then lexically
(determinism — same ledger, same choice, always).

This score comes FROM THE LEDGER, never from a model's self-report of how informative it
expects to feel. That is what keeps "maximize knowledge per experiment" ungameable.
"""
from __future__ import annotations

from typing import Any, Dict, List, Tuple

from .events import canonical_json
from .ledger import Ledger

SELECTOR_RULE_VERSION = 1


def _mutually_exclusive(predictions: List[Dict[str, Any]]) -> bool:
    """Conservative: only `==` claims with different expected values are provably exclusive."""
    exact = {canonical_json(p["expected"]) for p in predictions if p["relation"] == "=="}
    return len(exact) > 1


def candidate_scores(ledger: Ledger) -> List[Dict[str, Any]]:
    """Score every observable variable that has pending (unjudged) predictions."""
    active_ids = {h.id for h in ledger.active_hypotheses()}
    judged = {v["prediction_id"] for v in ledger.verdicts.values()}
    by_variable: Dict[str, List[Dict[str, Any]]] = {}
    for prediction in ledger.predictions.values():
        if prediction["id"] in judged or prediction["hypothesis_id"] not in active_ids:
            continue
        by_variable.setdefault(prediction["variable"], []).append(prediction)
    receipts_per_variable: Dict[str, int] = {}
    for receipt in ledger.receipts.values():
        for variable in receipt["observations"]:
            receipts_per_variable[variable] = receipts_per_variable.get(variable, 0) + 1
    scored = []
    for variable, predictions in by_variable.items():
        hypotheses = {p["hypothesis_id"] for p in predictions}
        discrimination = len(hypotheses) if _mutually_exclusive(predictions) else 0
        scored.append({"variable": variable,
                       "prediction_ids": sorted(p["id"] for p in predictions),
                       "hypothesis_ids": sorted(hypotheses),
                       "discrimination": discrimination,
                       "prior_receipts": receipts_per_variable.get(variable, 0)})
    return scored


def select(ledger: Ledger) -> Dict[str, Any]:
    """Pick the most informative observable. Raises when nothing is worth testing."""
    scored = candidate_scores(ledger)
    if not scored:
        raise LookupError("no pending predictions — nothing to select")
    ranked = sorted(scored, key=lambda s: (-s["discrimination"], s["prior_receipts"],
                                           s["variable"]))
    best: Tuple[int, str] = (ranked[0]["discrimination"], ranked[0]["variable"])
    if best[0] == 0:
        # Still allow confirmation runs, but the caller can see the score is zero and the
        # knowledge gate will withhold credit if the result discriminates nothing.
        pass
    return ranked[0]
