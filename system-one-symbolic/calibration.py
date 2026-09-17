"""Grounded confidence calibration for typed decisions.

Jev's RLCD calibrates against "the average of the largest external models as
reference probabilities" — i.e. LLM consensus. Here calibration is grounded
the only honest way: against RECORDED OUTCOMES. Every decision whose result
becomes known is recorded (confidence, correct?), and calibrated confidence
is the empirical accuracy of past decisions at that confidence level, made
monotone with pool-adjacent-violators (isotonic regression).

No model, no fitting loop, no consensus oracle — receipts in, reliability out.
"""
from __future__ import annotations

import json
import pathlib
from dataclasses import dataclass


class CalibrationError(ValueError):
    pass


@dataclass(frozen=True)
class ReliabilityBin:
    lo: float
    hi: float
    count: int
    mean_confidence: float
    accuracy: float


class OutcomeLog:
    """Append-only (confidence, correct) records, optionally persisted."""

    def __init__(self, path: str | None = None):
        self._records: list[tuple[float, bool]] = []
        self._path = pathlib.Path(path) if path else None
        if self._path and self._path.exists():
            for line in self._path.read_text().splitlines():
                row = json.loads(line)
                self._records.append((float(row["confidence"]), bool(row["correct"])))

    def record(self, confidence: float, correct: bool) -> None:
        if not 0.0 <= confidence <= 1.0:
            raise CalibrationError(f"confidence out of range: {confidence}")
        self._records.append((confidence, correct))
        if self._path:
            with self._path.open("a") as fh:
                fh.write(json.dumps({"confidence": confidence, "correct": correct}) + "\n")

    def __len__(self) -> int:
        return len(self._records)

    def brier_score(self) -> float:
        """Mean squared error of confidence vs outcome. Lower is better."""
        if not self._records:
            raise CalibrationError("no outcomes recorded")
        return sum((c - (1.0 if ok else 0.0)) ** 2 for c, ok in self._records) / len(self._records)

    def reliability(self, bins: int = 10) -> list[ReliabilityBin]:
        """Confidence histogram with per-bin empirical accuracy."""
        if bins < 2:
            raise CalibrationError("need >=2 bins")
        buckets: list[list[tuple[float, bool]]] = [[] for _ in range(bins)]
        for confidence, ok in self._records:
            index = min(int(confidence * bins), bins - 1)
            buckets[index].append((confidence, ok))
        out = []
        for i, bucket in enumerate(buckets):
            if not bucket:
                continue
            out.append(ReliabilityBin(
                lo=i / bins, hi=(i + 1) / bins, count=len(bucket),
                mean_confidence=sum(c for c, _ in bucket) / len(bucket),
                accuracy=sum(1 for _, ok in bucket if ok) / len(bucket),
            ))
        return out

    def isotonic(self) -> list[tuple[float, float]]:
        """(confidence, calibrated) knots via pool-adjacent-violators."""
        if len(self._records) < 10:
            raise CalibrationError("need >=10 outcomes to calibrate")
        # Ties in confidence must be pre-aggregated into one block each, or
        # PAV leaves spurious pure-0/pure-1 blocks at the extremes.
        by_confidence: dict[float, list[float]] = {}
        for confidence, ok in self._records:
            by_confidence.setdefault(confidence, []).append(1.0 if ok else 0.0)
        blocks = [[c * len(oks), sum(oks), len(oks)]  # [conf-sum, acc-sum, n]
                  for c, oks in sorted(by_confidence.items())]
        merged: list[list[float]] = []
        for conf, acc, n in blocks:
            merged.append([conf, acc, n])
            while len(merged) > 1 and merged[-2][1] / merged[-2][2] > merged[-1][1] / merged[-1][2]:
                c2, a2, n2 = merged.pop()
                merged[-1][0] += c2
                merged[-1][1] += a2
                merged[-1][2] += n2
        return [(c / n, a / n) for c, a, n in merged]

    def calibrated(self, confidence: float) -> float:
        """Map a raw confidence to outcome-grounded confidence."""
        knots = self.isotonic()
        result = knots[0][1]
        for knot_conf, knot_acc in knots:
            if confidence >= knot_conf:
                result = knot_acc
            else:
                break
        return result
