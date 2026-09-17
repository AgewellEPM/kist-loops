import math
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from decision_head import DecisionError, DecisionHead, DecisionSpace


class DecisionSpaceContracts(unittest.TestCase):
    def test_rejects_single_option(self):
        with self.assertRaises(DecisionError):
            DecisionSpace("s", ("only",))

    def test_rejects_duplicate_options(self):
        with self.assertRaises(DecisionError):
            DecisionSpace("s", ("a", "a"))

    def test_rejects_empty_name(self):
        with self.assertRaises(DecisionError):
            DecisionSpace("", ("a", "b"))


class DecisionHeadContracts(unittest.TestCase):
    def setUp(self):
        self.head = DecisionHead(DecisionSpace("s", ("left", "right", "fire")))

    def test_every_option_must_be_scored(self):
        with self.assertRaises(DecisionError):
            self.head.decide({"left": 1.0, "right": 0.0})

    def test_out_of_space_option_rejected(self):
        with self.assertRaises(DecisionError):
            self.head.decide({"left": 1, "right": 0, "fire": 0, "jump": 9})

    def test_non_finite_score_rejected(self):
        with self.assertRaises(DecisionError):
            self.head.decide({"left": 1.0, "right": float("nan"), "fire": 0.0})

    def test_probabilities_sum_to_one_and_argmax_wins(self):
        decision = self.head.decide({"left": 0.0, "right": 3.0, "fire": 1.0})
        self.assertAlmostEqual(sum(decision.probabilities.values()), 1.0, places=9)
        self.assertEqual(decision.choice, "right")
        self.assertEqual(decision.confidence, decision.probabilities["right"])

    def test_tie_breaks_by_declaration_order(self):
        decision = self.head.decide({"left": 2.0, "right": 2.0, "fire": 0.0})
        self.assertEqual(decision.choice, "left")

    def test_receipt_is_self_contained(self):
        decision = self.head.decide(
            {"left": 1.0, "right": 0.0, "fire": 0.0}, evidence={"why": "test"})
        receipt = decision.receipt()
        for key in ("space", "choice", "confidence", "probabilities",
                    "scores", "evidence", "latency_us", "ts"):
            self.assertIn(key, receipt)
        self.assertEqual(receipt["evidence"], {"why": "test"})

    def test_temperature_must_be_positive(self):
        head = DecisionHead(DecisionSpace("s", ("a", "b")), temperature=0)
        with self.assertRaises(DecisionError):
            head.decide({"a": 1.0, "b": 0.0})

    def test_large_cardinality_no_255_cap(self):
        options = tuple(f"option{i}" for i in range(1000))
        head = DecisionHead(DecisionSpace("big", options))
        decision = head.decide({o: (1.0 if o == "option777" else 0.0) for o in options})
        self.assertEqual(decision.choice, "option777")


if __name__ == "__main__":
    unittest.main()
