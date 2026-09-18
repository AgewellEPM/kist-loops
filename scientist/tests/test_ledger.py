import tempfile
import unittest
from pathlib import Path

from scientist.confidence import HARD_VETO_CEILING
from scientist.ledger import (CONTESTED, EXPERIMENTING, Ledger, PASSED, REFUTED, REJECTED,
                              REVISED, RuleViolation, SUPPORTED, TESTABLE)


def make_ledger(path):
    return Ledger(Path(path) / "ledger.jsonl")


class LedgerRuleTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.ledger = make_ledger(self.dir.name)

    def _hypothesis(self, statement="A causes B", origin="operator"):
        return self.ledger.propose_hypothesis(
            statement=statement, rationale="because",
            assumptions=[{"text": "the meter is calibrated"}], origin=origin)

    def _experimented(self, expected=41, actual=37, discriminating=True):
        hypothesis = self._hypothesis()
        prediction = self.ledger.register_prediction(
            hypothesis.id, "lab:sample:mass", "==", expected, tolerance=0.0,
            discriminating=discriminating)
        experiment = self.ledger.design_experiment(
            "weigh it", "lab", {"key": "sample"}, [prediction["id"]])
        self.ledger.transition(hypothesis.id, TESTABLE, {"r": "predictions exist"})
        self.ledger.transition(hypothesis.id, EXPERIMENTING, {"r": "experiment designed"})
        self.ledger.record_receipt(experiment["id"], {"lab:sample:mass": actual},
                                   raw_digest="0" * 64, adapter_meta={})
        return hypothesis, prediction, experiment

    def test_testable_requires_a_registered_prediction(self):
        hypothesis = self._hypothesis()
        with self.assertRaises(RuleViolation):
            self.ledger.transition(hypothesis.id, TESTABLE, {})

    def test_experimenting_requires_a_designed_experiment(self):
        hypothesis = self._hypothesis()
        self.ledger.register_prediction(hypothesis.id, "lab:sample:mass", "==", 5)
        self.ledger.transition(hypothesis.id, TESTABLE, {})
        with self.assertRaises(RuleViolation):
            self.ledger.transition(hypothesis.id, EXPERIMENTING, {})

    def test_prediction_after_receipt_cannot_be_graded(self):
        # Reachable guard: a prediction the experiment never declared is refused outright.
        hypothesis, prediction, experiment = self._experimented()
        late = self.ledger.register_prediction(
            hypothesis.id, "lab:sample:mass", "==", 37)      # matches the known answer
        with self.assertRaises(RuleViolation) as caught:
            self.ledger.record_verdict(late["id"], experiment["id"], PASSED, 37, 0)
        self.assertIn("storytelling", str(caught.exception))
        # Defense-in-depth armor: even a prediction the experiment DID declare is refused if
        # its registration event does not precede the receipt event in the chain. Unreachable
        # through the public API today (design precedes receipt by construction) — pinned
        # white-box so a future API change cannot silently drop pre-registration.
        self.ledger._seq_of[prediction["id"]] = 10_000
        with self.assertRaises(RuleViolation) as armored:
            self.ledger.record_verdict(prediction["id"], experiment["id"], PASSED, 37, 0)
        self.assertIn("postdiction", str(armored.exception))

    def test_verdict_requires_experiment_declared_the_prediction(self):
        hypothesis, prediction, experiment = self._experimented()
        other = self.ledger.propose_hypothesis("C causes D", "why not", [], "operator")
        stray = self.ledger.register_prediction(other.id, "lab:sample:mass", "==", 37)
        other_experiment = self.ledger.design_experiment(
            "weigh again", "lab", {"key": "sample", "n": 2}, [stray["id"]])
        with self.assertRaises(RuleViolation) as caught:
            self.ledger.record_verdict(stray["id"], experiment["id"], PASSED, 37, 0)
        self.assertIn("storytelling", str(caught.exception))

    def test_supported_requires_passed_and_no_refuted(self):
        hypothesis, prediction, experiment = self._experimented(expected=41, actual=37)
        self.ledger.record_verdict(prediction["id"], experiment["id"], REFUTED, 37, -4)
        with self.assertRaises(RuleViolation):
            self.ledger.transition(hypothesis.id, SUPPORTED, {})
        self.ledger.transition(hypothesis.id, REJECTED, {"verdicts": "on record"})
        self.assertEqual(self.ledger.hypotheses[hypothesis.id].state, REJECTED)

    def test_rejected_requires_discriminating_refutation(self):
        hypothesis, prediction, experiment = self._experimented(discriminating=False)
        self.ledger.record_verdict(prediction["id"], experiment["id"], REFUTED, 37, -4)
        with self.assertRaises(RuleViolation):
            self.ledger.transition(hypothesis.id, REJECTED, {})
        self.ledger.transition(hypothesis.id, CONTESTED, {"r": "non-discriminating miss"})
        self.assertEqual(self.ledger.hypotheses[hypothesis.id].state, CONTESTED)

    def test_confidence_is_mechanical_with_hard_veto(self):
        hypothesis, prediction, experiment = self._experimented()
        self.assertEqual(hypothesis.confidence(self.ledger), 0.5)   # prior
        self.ledger.record_verdict(prediction["id"], experiment["id"], REFUTED, 37, -4)
        self.assertLessEqual(hypothesis.confidence(self.ledger), HARD_VETO_CEILING)

    def test_terminal_states_freeze_the_hypothesis(self):
        hypothesis, prediction, experiment = self._experimented()
        self.ledger.record_verdict(prediction["id"], experiment["id"], REFUTED, 37, -4)
        self.ledger.transition(hypothesis.id, REJECTED, {})
        with self.assertRaises(RuleViolation):
            self.ledger.register_prediction(hypothesis.id, "lab:sample:volume", "==", 1)

    def test_state_survives_replay(self):
        hypothesis, prediction, experiment = self._experimented()
        self.ledger.record_verdict(prediction["id"], experiment["id"], REFUTED, 37, -4)
        self.ledger.transition(hypothesis.id, REJECTED, {})
        replayed = Ledger(self.ledger.log.path)
        self.assertEqual(replayed.hypotheses[hypothesis.id].state, REJECTED)
        self.assertEqual(replayed.hypotheses[hypothesis.id].confidence(replayed),
                         hypothesis.confidence(self.ledger))

    def test_rerun_needs_a_new_experiment(self):
        hypothesis, prediction, experiment = self._experimented()
        with self.assertRaises(RuleViolation):
            self.ledger.record_receipt(experiment["id"], {"lab:sample:mass": 38},
                                       raw_digest="1" * 64, adapter_meta={})

    def test_contested_is_a_one_way_gate(self):
        # Review finding 2026-09-17: (CONTESTED → SUPPORTED) was listed but unreachable —
        # a refutation on record never un-happens in an append-only ledger. Pin the removal.
        hypothesis, prediction, experiment = self._experimented(discriminating=False)
        self.ledger.record_verdict(prediction["id"], experiment["id"], REFUTED, 37, -4)
        self.ledger.transition(hypothesis.id, CONTESTED, {})
        with self.assertRaises(RuleViolation) as caught:
            self.ledger.transition(hypothesis.id, SUPPORTED, {})
        self.assertIn("illegal transition", str(caught.exception))

    def test_revised_successor_must_be_alive_and_not_self(self):
        hypothesis, prediction, experiment = self._experimented(discriminating=False)
        self.ledger.record_verdict(prediction["id"], experiment["id"], REFUTED, 37, -4)
        self.ledger.transition(hypothesis.id, CONTESTED, {})
        dead = self.ledger.propose_hypothesis("dead end", "r", [], "operator")
        dead_prediction = self.ledger.register_prediction(
            dead.id, "lab:sample:mass2", "==", 1, discriminating=True)
        dead_experiment = self.ledger.design_experiment(
            "weigh 2", "lab", {"key": "sample2"}, [dead_prediction["id"]])
        self.ledger.transition(dead.id, TESTABLE, {})
        self.ledger.transition(dead.id, EXPERIMENTING, {})
        self.ledger.record_receipt(dead_experiment["id"], {"lab:sample:mass2": 9},
                                   raw_digest="2" * 64, adapter_meta={})
        self.ledger.record_verdict(dead_prediction["id"], dead_experiment["id"],
                                   REFUTED, 9, 8)
        self.ledger.transition(dead.id, REJECTED, {})
        with self.assertRaises(RuleViolation) as terminal:
            self.ledger.transition(hypothesis.id, REVISED, {"successor_id": dead.id})
        self.assertIn("non-terminal", str(terminal.exception))
        with self.assertRaises(RuleViolation) as own:
            self.ledger.transition(hypothesis.id, REVISED,
                                   {"successor_id": hypothesis.id})
        self.assertIn("own revision successor", str(own.exception))


if __name__ == "__main__":
    unittest.main()
