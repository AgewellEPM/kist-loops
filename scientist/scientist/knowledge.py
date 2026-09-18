"""The knowledge-value gate — what counts as "validated knowledge gained per experiment".

An objective of "maximize validated knowledge" is gameable by farming trivially-verifiable
micro-facts (a thousand cheap confirmations of the undisputed). So knowledge credit is a
SYMBOLIC judgment computed from the ledger, with the rules in one place where they can be
criticized:

  credit is granted iff the experiment
    1. produced at least one non-INCONCLUSIVE verdict            (it touched reality), and
    2. discriminated: at least one REFUTED verdict, OR verdicts across ≥2 distinct
       hypotheses on the same variable                            (it settled a disagreement),
  and is withheld when
    3. every graded prediction duplicates an observable+relation+expected combination that
       was already judged by an earlier experiment                (novelty check — re-proving
       the proven earns nothing).

The credit itself is recorded as a ledger event, so "how much did we actually learn" is an
auditable count, not a vibe.
"""
from __future__ import annotations

from typing import Any, Dict

from .events import canonical_json
from .ledger import INCONCLUSIVE, Ledger, REFUTED

KNOWLEDGE_RULE_VERSION = 1


def _normalize(value: Any) -> Any:
    # 37 and 37.0 are the same claim; JSON would key them differently. Bools stay bools.
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, (list, tuple)):
        return [_normalize(v) for v in value]
    return value


def _claim_key(prediction: Dict[str, Any]) -> str:
    return canonical_json([prediction["variable"], prediction["relation"],
                           _normalize(prediction["expected"])])


def grant_or_withhold(ledger: Ledger, experiment_id: str) -> Dict[str, Any]:
    verdicts = [v for v in ledger.verdicts.values() if v["experiment_id"] == experiment_id]
    if not verdicts:
        return ledger.record_knowledge_credit(
            experiment_id, credited=False,
            reason=f"kn-v{KNOWLEDGE_RULE_VERSION}: no verdicts — receipt judged nothing")
    conclusive = [v for v in verdicts if v["outcome"] != INCONCLUSIVE]
    if not conclusive:
        return ledger.record_knowledge_credit(
            experiment_id, credited=False,
            reason=f"kn-v{KNOWLEDGE_RULE_VERSION}: all verdicts inconclusive")

    earlier_claims = set()
    for verdict in ledger.verdicts.values():
        if verdict["experiment_id"] == experiment_id:
            continue
        earlier_claims.add(_claim_key(ledger.predictions[verdict["prediction_id"]]))
    novel = [v for v in conclusive
             if _claim_key(ledger.predictions[v["prediction_id"]]) not in earlier_claims]
    if not novel:
        return ledger.record_knowledge_credit(
            experiment_id, credited=False,
            reason=f"kn-v{KNOWLEDGE_RULE_VERSION}: every claim was already judged — "
                   "re-proving the proven earns nothing")

    hypotheses = {ledger.predictions[v["prediction_id"]]["hypothesis_id"] for v in novel}
    refuted_any = any(v["outcome"] == REFUTED for v in novel)
    if refuted_any or len(hypotheses) >= 2:
        return ledger.record_knowledge_credit(
            experiment_id, credited=True,
            reason=f"kn-v{KNOWLEDGE_RULE_VERSION}: "
                   + ("a refutation" if refuted_any else "settled a live disagreement")
                   + f" across {len(hypotheses)} hypothesis(es)")
    return ledger.record_knowledge_credit(
        experiment_id, credited=False,
        reason=f"kn-v{KNOWLEDGE_RULE_VERSION}: lone confirmation of an uncontested claim")
