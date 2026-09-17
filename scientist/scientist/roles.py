"""The five learning jobs, as explicit seams.

Day one every role is deterministic or operator-driven; each seam is where a learned model
can later be plugged WITHOUT changing the ledger contract, because a role can only speak
through ledger proposals (which enforce the rules) — never write state directly.

  Perception   — adapter extraction: raw world → typed observations   (adapters/*)
  Hypothesizer — observations + history → COMPETING hypotheses        (propose_competing)
  Designer     — which observable settles the most disagreement       (selector + ExperimentPlanner)
  Critic       — registered prediction vs receipt, arithmetic only    (critic.py)
  Scientist    — why was the model wrong; blame + revision            (blame.py)
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, List, Sequence

from .ledger import Hypothesis, Ledger, RuleViolation


def propose_competing(ledger: Ledger, proposals: Sequence[Dict[str, Any]],
                      origin: str = "operator") -> List[Hypothesis]:
    """The Hypothesizer contract: never fall in love with the first idea.

    Requires ≥2 hypotheses whose statements differ; records all of them. A single-hypothesis
    'battery of one' is refused — that is how confirmation bias gets encoded as architecture."""
    if len(proposals) < 2:
        raise RuleViolation("the hypothesizer must offer at least two competing hypotheses")
    statements = {p["statement"].strip() for p in proposals}
    if len(statements) < 2:
        raise RuleViolation("competing hypotheses must actually differ")
    return [ledger.propose_hypothesis(
                statement=p["statement"], rationale=p.get("rationale", ""),
                assumptions=p.get("assumptions", []), origin=origin)
            for p in proposals]


@dataclass(frozen=True)
class ExperimentPlan:
    question: str
    adapter: str
    request: Dict[str, Any]


class ExperimentPlanner:
    """Designer seam: maps a selected observable to a concrete, runnable request.

    The default planner understands `namespace:key:field` variables where the namespace names
    an adapter (e.g. `uniprot:P69905:sequence_length` → adapter `uniprot`, accession P69905)."""

    def plan(self, variable: str) -> ExperimentPlan:
        parts = variable.split(":")
        if len(parts) != 3:
            raise RuleViolation(
                f"cannot plan for variable {variable!r}; expected namespace:key:field")
        namespace, key, field = parts
        return ExperimentPlan(
            question=f"observe {field} of {key} via {namespace}",
            adapter=namespace, request={"key": key, "fields": [field]})
