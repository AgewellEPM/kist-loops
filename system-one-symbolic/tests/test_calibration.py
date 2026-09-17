import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from calibration import CalibrationError, OutcomeLog


class OutcomeLogTests(unittest.TestCase):
    def test_confidence_range_enforced(self):
        log = OutcomeLog()
        with self.assertRaises(CalibrationError):
            log.record(1.2, True)

    def test_brier_requires_records(self):
        with self.assertRaises(CalibrationError):
            OutcomeLog().brier_score()

    def test_brier_perfect_and_worst(self):
        good, bad = OutcomeLog(), OutcomeLog()
        good.record(1.0, True)
        bad.record(1.0, False)
        self.assertEqual(good.brier_score(), 0.0)
        self.assertEqual(bad.brier_score(), 1.0)

    def test_reliability_bins_show_overconfidence(self):
        log = OutcomeLog()
        for i in range(100):  # claims 0.95, right only 60% of the time
            log.record(0.95, i % 10 < 6)
        (bin_,) = log.reliability(bins=10)
        self.assertAlmostEqual(bin_.mean_confidence, 0.95, places=6)
        self.assertAlmostEqual(bin_.accuracy, 0.6, places=6)

    def test_isotonic_corrects_overconfidence(self):
        log = OutcomeLog()
        for i in range(50):
            log.record(0.99, i % 10 < 6)   # overconfident: 60% real
        for i in range(50):
            log.record(0.30, i % 10 < 3)   # honest: 30% real
        self.assertAlmostEqual(log.calibrated(0.99), 0.6, places=6)
        self.assertAlmostEqual(log.calibrated(0.30), 0.3, places=6)

    def test_isotonic_output_is_monotone(self):
        log = OutcomeLog()
        for i in range(200):
            log.record((i % 100) / 100, (i * 7) % 10 < (i % 100) / 12)
        knots = log.isotonic()
        accuracies = [acc for _, acc in knots]
        self.assertEqual(accuracies, sorted(accuracies))

    def test_isotonic_needs_minimum_data(self):
        log = OutcomeLog()
        log.record(0.5, True)
        with self.assertRaises(CalibrationError):
            log.isotonic()

    def test_persistence_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = str(pathlib.Path(tmp) / "outcomes.jsonl")
            first = OutcomeLog(path)
            first.record(0.8, True)
            first.record(0.4, False)
            reloaded = OutcomeLog(path)
            self.assertEqual(len(reloaded), 2)
            self.assertAlmostEqual(reloaded.brier_score(), first.brier_score())


if __name__ == "__main__":
    unittest.main()
