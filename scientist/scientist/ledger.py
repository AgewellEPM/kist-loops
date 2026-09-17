"""The hypothesis ledger — typed state machine over the append-only event log.

This is the SYMBOLIC layer of the scientist. The neural side (or an operator) may only
PROPOSE things through these methods; the ledger owns what may be claimed, what counts as
evidence, and when a hypothesis changes state. Every rule violation raises — there is no
"best effort" path that quietly records an unjustified transition.

States and the only legal moves between them:

    PROPOSED ──→ TESTABLE ──→ EXPERIMENTING ──→ SUPPORTED | CONTESTED | REJECTED
    SUPPORTED ──→ CONTESTED            (new conflicting receipt-backed verdict)
    CONTESTED ──→ REJECTED | REVISED   (one-way: a refutation on record never un-happens
                                        in an append-only ledger, so SUPPORTED — which
                                        requires zero refutations — is unreachable from
                                        here; rehabilitation is a REVISED successor)
    EXPERIMENTING ──→ TESTABLE         (experiment concluded; more tests still possible)
    REVISED, REJECTED are terminal. REVISED must name a non-terminal successor hypothesis.

Preconditions the ledger enforces (the "WHAT MUST BE TESTED / WHAT COUNTS AS EVIDENCE" rules):
  → TESTABLE       requires ≥1 registered prediction for the hypothesis.
  → EXPERIMENTING  requires a designed experiment covering ≥1 of its registered predictions.
  → SUPPORTED      requires ≥1 PASSED verdict and 0 REFUTED verdicts on record.
  → CONTESTED      requires ≥1 REFUTED verdict on record.
  → REJECTED       requires ≥1 REFUTED verdict on a DISCRIMINATING prediction.
Verdicts themselves can only be written by the critic path (receipt-diff), and a verdict must
name a receipt that exists EARLIER in the chain than the prediction's registration? No — the
other way round: the prediction must exist earlier in the chain than the receipt (see
critic.py: pre-registration is what makes "no storytelling" mechanical).
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from .confidence import CONFIDENCE_RULE_VERSION, VerdictCounts, confidence
from .events import EventLog, canonical_json

PROPOSED = "PROPOSED"
TESTABLE = "TESTABLE"
EXPERIMENTING = "EXPERIMENTING"
SUPPORTED = "SUPPORTED"
CONTESTED = "CONTESTED"
REJECTED = "REJECTED"
REVISED = "REVISED"

STATES = {PROPOSED, TESTABLE, EXPERIMENTING, SUPPORTED, CONTESTED, REJECTED, REVISED}
TERMINAL_STATES = {REJECTED, REVISED}
ALLOWED_TRANSITIONS = {
    (PROPOSED, TESTABLE),
    (TESTABLE, EXPERIMENTING),
    (EXPERIMENTING, TESTABLE),
    (EXPERIMENTING, SUPPORTED),
    (EXPERIMENTING, CONTESTED),
    (EXPERIMENTING, REJECTED),
    (SUPPORTED, CONTESTED),
    (CONTESTED, REJECTED),
    (CONTESTED, REVISED),
}

PASSED = "PASSED"
REFUTED = "REFUTED"
INCONCLUSIVE = "INCONCLUSIVE"
VERDICT_OUTCOMES = {PASSED, REFUTED, INCONCLUSIVE}

RELATIONS = {"==", "<=", ">=", "in_range"}


class RuleViolation(RuntimeError):
    """A proposal broke a symbolic rule. The event was NOT recorded."""


@dataclass
class Hypothesis:
    id: str
    statement: str
    rationale: str
    assumption_ids: List[str]
    origin: str                      # "operator" | "generator:<source>" | "revision:<source>"
    state: str = PROPOSED
    prediction_ids: List[str] = field(default_factory=list)
    verdict_ids: List[str] = field(default_factory=list)
    successor_id: Optional[str] = None

    def verdict_counts(self, ledger: "Ledger") -> VerdictCounts:
        passed = refuted = inconclusive = discriminating_refuted = 0
        for verdict_id in self.verdict_ids:
            verdict = ledger.verdicts[verdict_id]
            if verdict["outcome"] == PASSED:
                passed += 1
            elif verdict["outcome"] == REFUTED:
                refuted += 1
                if verdict["discriminating"]:
                    discriminating_refuted += 1
            else:
                inconclusive += 1
        return VerdictCounts(passed=passed, refuted=refuted, inconclusive=inconclusive,
                             discriminating_refuted=discriminating_refuted)

    def confidence(self, ledger: "Ledger") -> float:
        return confidence(self.verdict_counts(ledger))


class Ledger:
    """Derived state over the event log. Construct-from-replay; mutate only via propose_* APIs."""

    def __init__(self, path: Path, now: Optional[Any] = None) -> None:
        self.log = EventLog(Path(path), now=now)
        self.hypotheses: Dict[str, Hypothesis] = {}
        self.assumptions: Dict[str, Dict[str, Any]] = {}
        self.predictions: Dict[str, Dict[str, Any]] = {}
        self.experiments: Dict[str, Dict[str, Any]] = {}
        self.receipts: Dict[str, Dict[str, Any]] = {}
        self.verdicts: Dict[str, Dict[str, Any]] = {}
        self.knowledge_credits: List[Dict[str, Any]] = []
        self._seq_of: Dict[str, int] = {}       # object id -> event seq that created it
        for event in self.log.events():
            self._apply(event.kind, event.payload, event.seq)

    # ---------------- proposals (the ONLY writers) ----------------

    def propose_hypothesis(self, statement: str, rationale: str,
                           assumptions: Sequence[Dict[str, str]],
                           origin: str = "operator") -> Hypothesis:
        statement = statement.strip()
        if not statement:
            raise RuleViolation("a hypothesis needs a non-empty statement")
        hypothesis_id = "hyp-" + self._digest(statement, origin)[:12]
        if hypothesis_id in self.hypotheses:
            raise RuleViolation(f"duplicate hypothesis (same statement+origin): {hypothesis_id}")
        assumption_ids = []
        for assumption in assumptions:
            text = assumption["text"].strip()
            if not text:
                raise RuleViolation("assumptions need non-empty text")
            assumption_id = assumption.get("id") or "asm-" + self._digest(text)[:12]
            assumption_ids.append(assumption_id)
        payload = {"id": hypothesis_id, "statement": statement, "rationale": rationale,
                   "assumptions": [{"id": aid, "text": a["text"].strip()}
                                    for aid, a in zip(assumption_ids, assumptions)],
                   "origin": origin}
        self._record("hypothesis_proposed", payload)
        return self.hypotheses[hypothesis_id]

    def register_prediction(self, hypothesis_id: str, variable: str, relation: str,
                            expected: Any, tolerance: float = 0.0,
                            discriminating: bool = False) -> Dict[str, Any]:
        hypothesis = self._active_hypothesis(hypothesis_id)
        if relation not in RELATIONS:
            raise RuleViolation(f"unknown relation {relation!r}; allowed: {sorted(RELATIONS)}")
        if relation == "in_range" and not (isinstance(expected, (list, tuple))
                                           and len(expected) == 2):
            raise RuleViolation("in_range expects [low, high]")
        prediction_id = "prd-" + self._digest(hypothesis_id, variable, relation,
                                              canonical_json(expected))[:12]
        if prediction_id in self.predictions:
            raise RuleViolation(f"duplicate prediction {prediction_id} — already registered; "
                                "re-registering the same claim earns no new knowledge")
        payload = {"id": prediction_id, "hypothesis_id": hypothesis.id, "variable": variable,
                   "relation": relation, "expected": expected, "tolerance": tolerance,
                   "discriminating": discriminating}
        self._record("prediction_registered", payload)
        return self.predictions[prediction_id]

    def design_experiment(self, question: str, adapter: str, request: Dict[str, Any],
                          prediction_ids: Sequence[str]) -> Dict[str, Any]:
        if not prediction_ids:
            raise RuleViolation("an experiment must name the predictions it will test")
        for prediction_id in prediction_ids:
            if prediction_id not in self.predictions:
                raise RuleViolation(f"unknown prediction {prediction_id}")
        # Identity includes a ledger-derived run index: repeating the same request is a NEW
        # experiment (new receipt, new verdicts) — reruns must never overwrite history.
        run_index = len(self.experiments)
        experiment_id = "exp-" + self._digest(question, adapter, canonical_json(request),
                                              str(run_index))[:12]
        if experiment_id in self.experiments:
            raise RuleViolation(f"duplicate experiment {experiment_id}")
        payload = {"id": experiment_id, "question": question, "adapter": adapter,
                   "request": request, "prediction_ids": list(prediction_ids),
                   "run_index": run_index}
        self._record("experiment_designed", payload)
        return self.experiments[experiment_id]

    def record_receipt(self, experiment_id: str, observations: Dict[str, Any],
                       raw_digest: str, adapter_meta: Dict[str, Any]) -> Dict[str, Any]:
        if experiment_id not in self.experiments:
            raise RuleViolation(f"unknown experiment {experiment_id}")
        if experiment_id in self.receipts:
            raise RuleViolation(f"experiment {experiment_id} already has a receipt; "
                                "a rerun is a NEW experiment")
        if len(raw_digest) != 64:
            raise RuleViolation("receipts must carry the sha256 of the raw observation")
        payload = {"experiment_id": experiment_id, "observations": observations,
                   "raw_digest": raw_digest, "adapter_meta": adapter_meta}
        self._record("receipt_recorded", payload)
        return self.receipts[experiment_id]

    def record_verdict(self, prediction_id: str, experiment_id: str, outcome: str,
                       actual: Any, error: Any) -> Dict[str, Any]:
        """Only critic.py should call this — and the ledger still re-checks the mechanics."""
        if outcome not in VERDICT_OUTCOMES:
            raise RuleViolation(f"unknown outcome {outcome!r}")
        prediction = self.predictions.get(prediction_id)
        if prediction is None:
            raise RuleViolation(f"unknown prediction {prediction_id}")
        receipt = self.receipts.get(experiment_id)
        if receipt is None:
            raise RuleViolation(f"no receipt for experiment {experiment_id}")
        if prediction_id not in self.experiments[experiment_id]["prediction_ids"]:
            raise RuleViolation("verdict pairs a prediction with an experiment that never "
                                "declared it — post-hoc matching is storytelling")
        # PRE-REGISTRATION, mechanically: the prediction's creation event must precede the
        # receipt's creation event in the hash chain. A prediction registered after the result
        # existed can never be judged.
        if self._seq_of[prediction_id] >= self._seq_of["receipt:" + experiment_id]:
            raise RuleViolation("prediction was registered after the receipt — refusing to "
                                "grade a postdiction")
        verdict_id = "vrd-" + self._digest(prediction_id, experiment_id)[:12]
        if verdict_id in self.verdicts:
            raise RuleViolation(f"duplicate verdict {verdict_id}")
        payload = {"id": verdict_id, "prediction_id": prediction_id,
                   "experiment_id": experiment_id, "outcome": outcome,
                   "predicted": prediction["expected"], "actual": actual, "error": error,
                   "discriminating": prediction["discriminating"],
                   "confidence_rule_version": CONFIDENCE_RULE_VERSION}
        self._record("verdict_recorded", payload)
        return self.verdicts[verdict_id]

    def transition(self, hypothesis_id: str, to_state: str,
                   justification: Dict[str, Any]) -> Hypothesis:
        hypothesis = self.hypotheses.get(hypothesis_id)
        if hypothesis is None:
            raise RuleViolation(f"unknown hypothesis {hypothesis_id}")
        if to_state not in STATES:
            raise RuleViolation(f"unknown state {to_state!r}")
        move = (hypothesis.state, to_state)
        if move not in ALLOWED_TRANSITIONS:
            raise RuleViolation(f"illegal transition {hypothesis.state} → {to_state}")
        counts = hypothesis.verdict_counts(self)
        if to_state == TESTABLE and hypothesis.state == PROPOSED and not hypothesis.prediction_ids:
            raise RuleViolation("TESTABLE requires at least one registered prediction")
        if to_state == EXPERIMENTING:
            covered = any(pid in experiment["prediction_ids"]
                          for experiment in self.experiments.values()
                          for pid in hypothesis.prediction_ids)
            if not covered:
                raise RuleViolation("EXPERIMENTING requires a designed experiment covering "
                                    "one of this hypothesis's predictions")
        if to_state == SUPPORTED and (counts.passed < 1 or counts.refuted > 0):
            raise RuleViolation("SUPPORTED requires ≥1 PASSED and 0 REFUTED verdicts")
        if to_state == CONTESTED and counts.refuted < 1:
            raise RuleViolation("CONTESTED requires a REFUTED verdict on record")
        if to_state == REJECTED and counts.discriminating_refuted < 1:
            raise RuleViolation("REJECTED requires a REFUTED verdict on a DISCRIMINATING "
                                "prediction — easy-miss refutations only contest")
        if to_state == REVISED:
            successor_id = justification.get("successor_id")
            if not successor_id:
                raise RuleViolation("REVISED must name the successor hypothesis")
            successor = self.hypotheses.get(successor_id)
            if successor is None:
                raise RuleViolation("REVISED successor must already be proposed")
            if successor.state in TERMINAL_STATES:
                raise RuleViolation("REVISED successor must be a non-terminal hypothesis — "
                                    "a revision chain must end in something alive")
            if successor_id == hypothesis_id:
                raise RuleViolation("a hypothesis cannot be its own revision successor")
        payload = {"hypothesis_id": hypothesis_id, "from": hypothesis.state, "to": to_state,
                   "justification": justification}
        self._record("state_changed", payload)
        return self.hypotheses[hypothesis_id]

    def record_knowledge_credit(self, experiment_id: str, credited: bool,
                                reason: str) -> Dict[str, Any]:
        if experiment_id not in self.receipts:
            raise RuleViolation("knowledge credit needs a receipted experiment")
        payload = {"experiment_id": experiment_id, "credited": credited, "reason": reason}
        self._record("knowledge_credited", payload)
        return payload

    def adjust_suspicion(self, assumption_id: str, delta: int, reason: str) -> Dict[str, Any]:
        if assumption_id not in self.assumptions:
            raise RuleViolation(f"unknown assumption {assumption_id}")
        payload = {"assumption_id": assumption_id, "delta": delta, "reason": reason}
        self._record("assumption_suspicion", payload)
        return self.assumptions[assumption_id]

    # ---------------- replay ----------------

    def _record(self, kind: str, payload: Dict[str, Any]) -> None:
        event = self.log.append(kind, payload)
        self._apply(kind, payload, event.seq)

    def _apply(self, kind: str, payload: Dict[str, Any], seq: int) -> None:
        if kind == "hypothesis_proposed":
            hypothesis = Hypothesis(
                id=payload["id"], statement=payload["statement"],
                rationale=payload["rationale"],
                assumption_ids=[a["id"] for a in payload["assumptions"]],
                origin=payload["origin"])
            self.hypotheses[hypothesis.id] = hypothesis
            self._seq_of[hypothesis.id] = seq
            for assumption in payload["assumptions"]:
                entry = self.assumptions.setdefault(
                    assumption["id"], {"id": assumption["id"], "text": assumption["text"],
                                       "suspicion": 0, "hypothesis_ids": []})
                entry["hypothesis_ids"].append(hypothesis.id)
        elif kind == "prediction_registered":
            self.predictions[payload["id"]] = payload
            self._seq_of[payload["id"]] = seq
            self.hypotheses[payload["hypothesis_id"]].prediction_ids.append(payload["id"])
        elif kind == "experiment_designed":
            self.experiments[payload["id"]] = payload
            self._seq_of[payload["id"]] = seq
        elif kind == "receipt_recorded":
            self.receipts[payload["experiment_id"]] = payload
            self._seq_of["receipt:" + payload["experiment_id"]] = seq
        elif kind == "verdict_recorded":
            self.verdicts[payload["id"]] = payload
            self._seq_of[payload["id"]] = seq
            prediction = self.predictions[payload["prediction_id"]]
            self.hypotheses[prediction["hypothesis_id"]].verdict_ids.append(payload["id"])
        elif kind == "state_changed":
            hypothesis = self.hypotheses[payload["hypothesis_id"]]
            hypothesis.state = payload["to"]
            if payload["to"] == REVISED:
                hypothesis.successor_id = payload["justification"]["successor_id"]
        elif kind == "assumption_suspicion":
            self.assumptions[payload["assumption_id"]]["suspicion"] += payload["delta"]
        elif kind == "knowledge_credited":
            self.knowledge_credits.append(payload)
        else:
            raise RuleViolation(f"unknown event kind {kind!r} — refusing to half-replay")

    # ---------------- helpers ----------------

    def _active_hypothesis(self, hypothesis_id: str) -> Hypothesis:
        hypothesis = self.hypotheses.get(hypothesis_id)
        if hypothesis is None:
            raise RuleViolation(f"unknown hypothesis {hypothesis_id}")
        if hypothesis.state in TERMINAL_STATES:
            raise RuleViolation(f"hypothesis {hypothesis_id} is {hypothesis.state} (terminal)")
        return hypothesis

    def active_hypotheses(self) -> List[Hypothesis]:
        return [h for h in self.hypotheses.values() if h.state not in TERMINAL_STATES]

    @staticmethod
    def _digest(*parts: str) -> str:
        joined = "\x1f".join(parts)
        return hashlib.sha256(joined.encode("utf-8")).hexdigest()
