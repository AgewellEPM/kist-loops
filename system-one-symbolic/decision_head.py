"""Typed symbolic decision head — the System-One primitive, grounded.

A DecisionSpace declares every legal option in advance (Jev's type-safety
property). A DecisionHead turns explicit, inspectable feature scores into a
typed choice with a probability distribution and a receipt. There is no model
call anywhere: the scores come from symbolic rules the caller wrote, so every
decision is reproducible and auditable from its receipt alone.

Differences from Jev, on purpose:
- No cardinality-255 cap (scores are a dict, not a token head).
- The receipt carries the full evidence + scores, so a decision is a proof,
  not just a probability.
- Confidence is calibrated against RECORDED OUTCOMES (calibration.py), not
  against a panel of reference LLMs.
"""
from __future__ import annotations

import math
import time
from dataclasses import dataclass, field
from typing import Mapping, Sequence


class DecisionError(ValueError):
    """Raised on any contract violation. Fail fast — never guess."""


@dataclass(frozen=True)
class DecisionSpace:
    """A named, closed set of legal options, declared before any decision."""
    name: str
    options: tuple[str, ...]

    def __post_init__(self):
        if not self.name:
            raise DecisionError("DecisionSpace needs a non-empty name")
        if len(self.options) < 2:
            raise DecisionError(f"space '{self.name}' needs >=2 options")
        if len(set(self.options)) != len(self.options):
            raise DecisionError(f"space '{self.name}' has duplicate options")


@dataclass(frozen=True)
class TypedDecision:
    space: str
    choice: str
    probabilities: dict[str, float]
    evidence: dict
    scores: dict[str, float]
    latency_us: float
    ts: float = field(default_factory=time.time)

    @property
    def confidence(self) -> float:
        return self.probabilities[self.choice]

    def receipt(self) -> dict:
        """Self-contained audit record: replayable and diffable."""
        return {
            "space": self.space,
            "choice": self.choice,
            "confidence": round(self.confidence, 6),
            "probabilities": {k: round(v, 6) for k, v in self.probabilities.items()},
            "scores": {k: round(v, 6) for k, v in self.scores.items()},
            "evidence": self.evidence,
            "latency_us": round(self.latency_us, 1),
            "ts": self.ts,
        }


def _softmax(scores: Sequence[float], temperature: float) -> list[float]:
    if temperature <= 0:
        raise DecisionError("temperature must be > 0")
    peak = max(scores)
    exps = [math.exp((s - peak) / temperature) for s in scores]
    total = sum(exps)
    return [e / total for e in exps]


class DecisionHead:
    """Turns rule-produced scores into a typed decision inside one space."""

    def __init__(self, space: DecisionSpace, temperature: float = 1.0):
        self.space = space
        self.temperature = temperature

    def decide(self, scores: Mapping[str, float], evidence: dict | None = None) -> TypedDecision:
        start = time.perf_counter()
        unknown = set(scores) - set(self.space.options)
        if unknown:
            raise DecisionError(
                f"scores name options outside space '{self.space.name}': {sorted(unknown)}")
        missing = set(self.space.options) - set(scores)
        if missing:
            raise DecisionError(
                f"every option must be scored; missing in '{self.space.name}': {sorted(missing)}")
        for option, value in scores.items():
            if not math.isfinite(value):
                raise DecisionError(f"non-finite score for '{option}'")

        ordered = list(self.space.options)
        probs = _softmax([scores[o] for o in ordered], self.temperature)
        distribution = dict(zip(ordered, probs))
        # Deterministic argmax: ties break by declaration order.
        choice = max(ordered, key=lambda o: (distribution[o], -ordered.index(o)))
        return TypedDecision(
            space=self.space.name,
            choice=choice,
            probabilities=distribution,
            evidence=dict(evidence or {}),
            scores=dict(scores),
            latency_us=(time.perf_counter() - start) * 1e6,
        )
