"""Mechanical confidence — arithmetic over verdicts, never a model-asserted number.

If the neural side could write `"confidence": 0.61`, the ledger's immutability would be
cosmetic: history-rewriting would sneak back in through the number. So confidence is a pure
function of the verdict record. The model proposes; arithmetic disposes.

Rule (documented so it can be criticized, versioned so it can evolve):
  confidence = (1 + passed) / (2 + passed + refuted)        # Laplace-smoothed support ratio
  any refuted DISCRIMINATING prediction caps it at HARD_VETO_CEILING (a hypothesis whose
  distinguishing claim failed cannot ride to high confidence on unrelated easy passes).
Inconclusive verdicts move nothing: absence of evidence is not evidence.
"""
from __future__ import annotations

from dataclasses import dataclass

CONFIDENCE_RULE_VERSION = 1
HARD_VETO_CEILING = 0.05
PRIOR_CONFIDENCE = 0.5


@dataclass(frozen=True)
class VerdictCounts:
    passed: int = 0
    refuted: int = 0
    inconclusive: int = 0
    discriminating_refuted: int = 0


def confidence(counts: VerdictCounts) -> float:
    if min(counts.passed, counts.refuted, counts.inconclusive,
           counts.discriminating_refuted) < 0:
        raise ValueError("verdict counts must be non-negative")
    value = (1 + counts.passed) / (2 + counts.passed + counts.refuted)
    if counts.discriminating_refuted > 0:
        value = min(value, HARD_VETO_CEILING)
    return round(value, 6)
