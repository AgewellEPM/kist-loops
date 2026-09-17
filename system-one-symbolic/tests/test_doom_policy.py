import pathlib
import sys
import unittest
from dataclasses import dataclass

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from doom_lane.perception import EnemyFact, SymbolicState, extract_state
from doom_lane.policy import ACTIONS, AIM_TOLERANCE, score_actions


def state(enemies=(), health=100.0, ammo=26.0, kills=0.0):
    return SymbolicState(health=health, ammo=ammo, kills=kills, enemies=tuple(enemies))


def top(scores):
    return max(scores, key=scores.get)


class PolicyRules(unittest.TestCase):
    """One test per written rule (multi-site discipline)."""

    def test_rule_scan_no_enemy_turns_left(self):
        self.assertEqual(top(score_actions(state())), "TURN_LEFT")

    def test_rule_fire_when_aimed(self):
        aimed = EnemyFact("Zombieman", dx_norm=0.01, width_norm=0.1)
        self.assertEqual(top(score_actions(state([aimed]))), "ATTACK")

    def test_rule_track_enemy_right(self):
        offset = EnemyFact("Zombieman", dx_norm=0.5, width_norm=0.1)
        self.assertEqual(top(score_actions(state([offset]))), "TURN_RIGHT")

    def test_rule_track_enemy_left(self):
        offset = EnemyFact("Zombieman", dx_norm=-0.5, width_norm=0.1)
        self.assertEqual(top(score_actions(state([offset]))), "TURN_LEFT")

    def test_rule_dry_gun_never_prefers_attack(self):
        aimed = EnemyFact("Zombieman", dx_norm=0.0, width_norm=0.1)
        self.assertNotEqual(top(score_actions(state([aimed], ammo=0))), "ATTACK")

    def test_nearest_enemy_drives_tracking(self):
        near = EnemyFact("Imp", dx_norm=0.2, width_norm=0.2)
        far = EnemyFact("Zombieman", dx_norm=-0.9, width_norm=0.05)
        self.assertEqual(top(score_actions(state([near, far]))), "TURN_RIGHT")

    def test_aim_tolerance_boundary_fires(self):
        edge = EnemyFact("Imp", dx_norm=AIM_TOLERANCE, width_norm=0.1)
        self.assertEqual(top(score_actions(state([edge]))), "ATTACK")

    def test_scores_cover_full_action_space(self):
        self.assertEqual(set(score_actions(state())), set(ACTIONS))


@dataclass
class FakeLabel:
    object_name: str
    x: float
    width: float


@dataclass
class FakeVzdState:
    labels: list


class PerceptionTests(unittest.TestCase):
    def test_player_and_effects_filtered_out(self):
        raw = FakeVzdState([FakeLabel("DoomPlayer", 0, 10),
                            FakeLabel("BulletPuff", 5, 2),
                            FakeLabel("Zombieman", 150, 20)])
        facts = extract_state(raw, 320, health=100, ammo=26, kills=0)
        self.assertEqual([e.name for e in facts.enemies], ["Zombieman"])

    def test_dx_is_centered_and_clamped(self):
        raw = FakeVzdState([FakeLabel("Imp", 150, 20)])  # centre exactly at 160/320
        facts = extract_state(raw, 320, health=100, ammo=26, kills=0)
        self.assertAlmostEqual(facts.enemies[0].dx_norm, 0.0)
        raw_far = FakeVzdState([FakeLabel("Imp", 5000, 20)])
        clamped = extract_state(raw_far, 320, health=100, ammo=26, kills=0)
        self.assertEqual(clamped.enemies[0].dx_norm, 1.0)

    def test_evidence_names_the_nearest(self):
        raw = FakeVzdState([FakeLabel("Imp", 100, 20), FakeLabel("Zombieman", 152, 16)])
        facts = extract_state(raw, 320, health=55, ammo=3, kills=2)
        evidence = facts.evidence()
        self.assertEqual(evidence["nearest_name"], "Zombieman")
        self.assertEqual(evidence["enemy_count"], 2)
        self.assertEqual(evidence["health"], 55)


if __name__ == "__main__":
    unittest.main()
