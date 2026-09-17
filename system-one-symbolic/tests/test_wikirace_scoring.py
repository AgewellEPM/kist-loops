import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from wikirace_lane.scoring import score_candidate, tokens


class TokenTests(unittest.TestCase):
    def test_stopwords_dropped(self):
        self.assertEqual(tokens("The History of the Volcano"), {"history", "volcano"})

    def test_case_and_punctuation_normalized(self):
        self.assertEqual(tokens("Quantum-Mechanics!"), {"quantum", "mechanics"})


class ScoringRules(unittest.TestCase):
    TARGET_TITLE = tokens("Quantum mechanics")
    TARGET_INTRO = tokens("physics theory describing matter energy atomic particles")

    def score(self, title):
        return score_candidate(title, self.TARGET_TITLE, self.TARGET_INTRO)

    def test_title_overlap_beats_unrelated(self):
        self.assertGreater(self.score("Matrix mechanics"), self.score("Potato salad"))

    def test_full_title_overlap_beats_partial(self):
        self.assertGreater(self.score("Quantum mechanics history"),
                           self.score("Mechanics"))

    def test_intro_mentions_help(self):
        self.assertGreater(self.score("Particle physics"), self.score("Cheese"))

    def test_generic_list_pages_penalized(self):
        self.assertLess(self.score("List of physics topics"), self.score("Physics"))

    def test_bare_year_pages_penalized(self):
        self.assertLess(self.score("1927"), self.score("Physics"))

    def test_empty_tokens_get_floor_penalty(self):
        self.assertLess(self.score("Of The"), 0)


if __name__ == "__main__":
    unittest.main()
