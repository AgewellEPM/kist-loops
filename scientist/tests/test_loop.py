"""Full-cycle tests over a fake adapter — the whole loop, no network."""
import hashlib
import tempfile
import unittest
from pathlib import Path

from scientist.ledger import CONTESTED, Ledger, REJECTED, SUPPORTED
from scientist.loop import run_cycle
from scientist.roles import propose_competing
from scientist.selector import select


def fake_adapter(truth):
    def observe(request):
        observations = {f"lab:{request['key']}:{field}": truth.get(field)
                        for field in request["fields"]}
        digest = hashlib.sha256(repr(sorted(observations.items())).encode()).hexdigest()
        return observations, digest, {"adapter": "fake"}
    return observe


class LoopTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.ledger = Ledger(Path(self.dir.name) / "ledger.jsonl")

    def _competing_pair(self):
        first, second = propose_competing(self.ledger, [
            {"statement": "mass is 41", "rationale": "old datasheet",
             "assumptions": [{"text": "datasheet reflects current batch"}]},
            {"statement": "mass is 37", "rationale": "recent recalibration",
             "assumptions": [{"text": "recalibration was applied"}]},
        ])
        self.ledger.register_prediction(first.id, "lab:sample:mass", "==", 41,
                                        discriminating=True)
        self.ledger.register_prediction(second.id, "lab:sample:mass", "==", 37,
                                        discriminating=True)
        return first, second

    def test_selector_prefers_discriminating_observables(self):
        first, second = self._competing_pair()
        lone = self.ledger.propose_hypothesis("volume is 5", "guess", [], "operator")
        self.ledger.register_prediction(lone.id, "lab:sample:volume", "==", 5)
        selection = select(self.ledger)
        self.assertEqual(selection["variable"], "lab:sample:mass")
        self.assertEqual(selection["discrimination"], 2)

    def test_full_cycle_settles_states_blames_and_credits(self):
        first, second = self._competing_pair()
        result = run_cycle(self.ledger, {"lab": fake_adapter({"mass": 37})})
        self.assertEqual(result["states"][first.id], REJECTED)
        self.assertEqual(result["states"][second.id], SUPPORTED)
        self.assertTrue(result["knowledge"]["credited"])
        # Failure became a hypothesis generator: the loser's assumption is now on trial.
        generated = result["generated_hypotheses"]
        self.assertEqual(len(generated), 1)
        statement = self.ledger.hypotheses[generated[0]["hypothesis_id"]].statement
        self.assertIn("datasheet reflects current batch", statement)
        origin = self.ledger.hypotheses[generated[0]["hypothesis_id"]].origin
        self.assertTrue(origin.startswith("generator:"),
                        "generated hypotheses must be labeled as such")
        # The winner's assumption was exonerated, the loser's blamed.
        suspicions = {a["text"]: a["suspicion"] for a in self.ledger.assumptions.values()}
        self.assertEqual(suspicions["datasheet reflects current batch"], 1)
        self.assertEqual(suspicions["recalibration was applied"], -1)

    def test_repeat_experiment_earns_no_knowledge(self):
        self._competing_pair()
        run_cycle(self.ledger, {"lab": fake_adapter({"mass": 37})})
        # New hypothesis re-registers the same claim on the same observable.
        again = self.ledger.propose_hypothesis("mass is 37 (again)", "copycat", [], "operator")
        self.ledger.register_prediction(again.id, "lab:sample:mass", "==", 37.0,
                                        discriminating=False)
        result = run_cycle(self.ledger, {"lab": fake_adapter({"mass": 37})})
        self.assertFalse(result["knowledge"]["credited"])
        self.assertIn("earns nothing", result["knowledge"]["reason"])

    def test_missing_observable_is_inconclusive_not_a_verdict(self):
        first, second = self._competing_pair()
        result = run_cycle(self.ledger, {"lab": fake_adapter({})})   # world said nothing
        self.assertEqual({v["outcome"] for v in result["verdicts"]}, {"INCONCLUSIVE"})
        self.assertEqual(result["states"][first.id], "TESTABLE")
        self.assertFalse(result["knowledge"]["credited"])

    def test_hypothesizer_refuses_a_battery_of_one(self):
        from scientist.ledger import RuleViolation
        with self.assertRaises(RuleViolation):
            propose_competing(self.ledger, [{"statement": "only one idea"}])

    def test_multi_prediction_refutation_blames_once_per_hypothesis(self):
        # Review finding 2026-09-17: suspicion moved once per VERDICT, so a hypothesis with
        # two refuted predictions blamed its assumption twice in one experiment.
        loser, winner = propose_competing(self.ledger, [
            {"statement": "sample is heavy and wide", "rationale": "",
             "assumptions": [{"text": "one shared gauge"}]},
            {"statement": "sample is light", "rationale": "", "assumptions": []},
        ])
        self.ledger.register_prediction(loser.id, "lab:sample:mass", "==", 41,
                                        discriminating=True)
        self.ledger.register_prediction(loser.id, "lab:sample:mass", "==", 43,
                                        discriminating=True)
        self.ledger.register_prediction(winner.id, "lab:sample:mass", "==", 37,
                                        discriminating=True)
        run_cycle(self.ledger, {"lab": fake_adapter({"mass": 37})})
        suspicions = {a["text"]: a["suspicion"] for a in self.ledger.assumptions.values()}
        self.assertEqual(suspicions["one shared gauge"], 1,
                         "two refuted predictions = ONE failed hypothesis = suspicion 1")

    def test_bool_claim_never_equals_a_number(self):
        # Review finding 2026-09-17: Python's True == 1 leaked into grading.
        from scientist.critic import grade
        refuted = grade({"relation": "==", "expected": True, "tolerance": 0}, 1)
        self.assertEqual(refuted["outcome"], "REFUTED")
        also_refuted = grade({"relation": "==", "expected": 1, "tolerance": 0}, True)
        self.assertEqual(also_refuted["outcome"], "REFUTED")
        passed = grade({"relation": "==", "expected": True, "tolerance": 0}, True)
        self.assertEqual(passed["outcome"], "PASSED")


if __name__ == "__main__":
    unittest.main()
