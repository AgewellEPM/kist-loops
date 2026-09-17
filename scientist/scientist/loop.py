"""One full cycle of the scientist loop, orchestrated deterministically.

    select observable → design experiment → EXPERIMENTING → run adapter → receipt →
    critic verdicts → mechanical state transitions → blame/generation → knowledge credit

The loop itself contains no cleverness: every decision it makes is a call into a rule module
(selector, critic, blame, knowledge) or a ledger proposal. Swapping any role for a learned
model changes none of this file's control flow — that is the point.
"""
from __future__ import annotations

from typing import Any, Callable, Dict, Optional, Tuple

from . import blame, critic, knowledge, selector
from .ledger import (CONTESTED, EXPERIMENTING, Ledger, PROPOSED, REJECTED, SUPPORTED,
                     TESTABLE)
from .roles import ExperimentPlanner

# adapter name → observe(request) -> (observations, raw_sha256, meta)
AdapterMap = Dict[str, Callable[[Dict[str, Any]], Tuple[Dict[str, Any], str, Dict[str, Any]]]]


def _advance_to_experimenting(ledger: Ledger, experiment: Dict[str, Any]) -> None:
    for prediction_id in experiment["prediction_ids"]:
        hypothesis = ledger.hypotheses[ledger.predictions[prediction_id]["hypothesis_id"]]
        if hypothesis.state == PROPOSED:
            ledger.transition(hypothesis.id, TESTABLE,
                              {"reason": "predictions registered", "loop": "auto"})
        if hypothesis.state == TESTABLE:
            ledger.transition(hypothesis.id, EXPERIMENTING,
                              {"experiment_id": experiment["id"], "loop": "auto"})


def _settle_states(ledger: Ledger, experiment_id: str) -> Dict[str, str]:
    """Mechanical post-verdict transitions, justified by the verdict ids on record."""
    outcomes: Dict[str, str] = {}
    touched = {ledger.predictions[pid]["hypothesis_id"]
               for pid in ledger.experiments[experiment_id]["prediction_ids"]}
    for hypothesis_id in sorted(touched):
        hypothesis = ledger.hypotheses[hypothesis_id]
        if hypothesis.state != EXPERIMENTING:
            continue
        counts = hypothesis.verdict_counts(ledger)
        justification = {"experiment_id": experiment_id,
                         "verdict_ids": list(hypothesis.verdict_ids), "loop": "auto"}
        if counts.discriminating_refuted > 0:
            ledger.transition(hypothesis_id, REJECTED, justification)
        elif counts.refuted > 0:
            ledger.transition(hypothesis_id, CONTESTED, justification)
        elif counts.passed > 0:
            ledger.transition(hypothesis_id, SUPPORTED, justification)
        else:
            ledger.transition(hypothesis_id, TESTABLE,
                              {**justification, "reason": "all verdicts inconclusive"})
        outcomes[hypothesis_id] = ledger.hypotheses[hypothesis_id].state
    return outcomes


def run_cycle(ledger: Ledger, adapters: AdapterMap,
              planner: Optional[ExperimentPlanner] = None) -> Dict[str, Any]:
    planner = planner or ExperimentPlanner()
    selection = selector.select(ledger)
    plan = planner.plan(selection["variable"])
    if plan.adapter not in adapters:
        raise LookupError(f"no adapter registered for {plan.adapter!r}")
    experiment = ledger.design_experiment(
        question=plan.question, adapter=plan.adapter, request=plan.request,
        prediction_ids=selection["prediction_ids"])
    _advance_to_experimenting(ledger, experiment)
    observations, raw_sha256, meta = adapters[plan.adapter](plan.request)
    ledger.record_receipt(experiment["id"], observations=observations,
                          raw_digest=raw_sha256, adapter_meta=meta)
    verdicts = critic.judge_experiment(ledger, experiment["id"])
    states = _settle_states(ledger, experiment["id"])
    generated = blame.assign_blame(ledger, experiment["id"])
    credit = knowledge.grant_or_withhold(ledger, experiment["id"])
    return {"experiment_id": experiment["id"],
            "selection": selection,
            "observations": observations,
            "verdicts": [{"id": v["id"], "outcome": v["outcome"],
                          "predicted": v["predicted"], "actual": v["actual"],
                          "error": v["error"]} for v in verdicts],
            "states": states,
            "generated_hypotheses": generated,
            "knowledge": credit}
