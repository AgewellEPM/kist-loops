"""The critic — a subtraction, not a judgment.

Compares each pre-registered prediction against the receipt for the experiment that declared
it. No model text participates: outcome is computed from (relation, expected, tolerance,
actual) alone. Pre-registration ordering is enforced twice — here by construction (we only
grade predictions the experiment declared) and again inside Ledger.record_verdict, which
refuses to grade any prediction whose registration event does not precede the receipt event
in the hash chain.
"""
from __future__ import annotations

from typing import Any, Dict, List, Optional

from .ledger import INCONCLUSIVE, PASSED, REFUTED, Ledger


def _numeric(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def grade(prediction: Dict[str, Any], actual: Any) -> Dict[str, Any]:
    """Pure grading: (prediction, actual) → {outcome, error}. Raises on malformed relations."""
    relation = prediction["relation"]
    expected = prediction["expected"]
    tolerance = float(prediction.get("tolerance", 0.0))
    if actual is None:
        return {"outcome": INCONCLUSIVE, "error": None}
    expected_number = _numeric(expected)
    actual_number = _numeric(actual)
    if relation == "==":
        if expected_number is not None and actual_number is not None:
            error = actual_number - expected_number
            outcome = PASSED if abs(error) <= tolerance else REFUTED
            return {"outcome": outcome, "error": error}
        outcome = PASSED if actual == expected else REFUTED
        return {"outcome": outcome, "error": None if outcome == PASSED else "mismatch"}
    if actual_number is None or (relation != "in_range" and expected_number is None):
        return {"outcome": INCONCLUSIVE, "error": "non-numeric operand"}
    if relation == "<=":
        return {"outcome": PASSED if actual_number <= expected_number + tolerance else REFUTED,
                "error": actual_number - expected_number}
    if relation == ">=":
        return {"outcome": PASSED if actual_number >= expected_number - tolerance else REFUTED,
                "error": actual_number - expected_number}
    if relation == "in_range":
        low, high = float(expected[0]), float(expected[1])
        inside = (low - tolerance) <= actual_number <= (high + tolerance)
        distance = 0.0 if inside else min(abs(actual_number - low), abs(actual_number - high))
        return {"outcome": PASSED if inside else REFUTED, "error": distance}
    raise ValueError(f"unknown relation {relation!r}")


def judge_experiment(ledger: Ledger, experiment_id: str) -> List[Dict[str, Any]]:
    """Grade every prediction the experiment declared, writing verdicts through the ledger."""
    experiment = ledger.experiments[experiment_id]
    receipt = ledger.receipts[experiment_id]
    verdicts = []
    for prediction_id in experiment["prediction_ids"]:
        prediction = ledger.predictions[prediction_id]
        actual = receipt["observations"].get(prediction["variable"])
        graded = grade(prediction, actual)
        verdicts.append(ledger.record_verdict(
            prediction_id=prediction_id, experiment_id=experiment_id,
            outcome=graded["outcome"], actual=actual, error=graded["error"]))
    return verdicts
