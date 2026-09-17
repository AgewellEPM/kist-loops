import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from doom_lane.real_perception import BlobFact, RealDoomState, blobs_from_columns
from doom_lane.real_policy import (
    AIM_TOLERANCE, REAL_ACTIONS, score_real_actions,
)


def state(blobs=(), observed=True, ammo_mass=0.05, health_mass=0.05):
    return RealDoomState(observed=observed, blobs=tuple(blobs),
                         ammo_mass=ammo_mass, health_mass=health_mass)


def top(traced):
    return max(traced.scores, key=traced.scores.get)


class BlobExtractionPins(unittest.TestCase):
    def test_adjacent_hot_columns_group_into_one_blob(self):
        columns = [0, 0, 0.2, 0.3, 0.25, 0, 0, 0, 0, 0]
        (blob,) = blobs_from_columns(columns)
        self.assertLess(blob.dx_norm, 0)          # left of centre
        self.assertAlmostEqual(blob.width_norm, 0.3)

    def test_single_column_flicker_ignored(self):
        self.assertEqual(blobs_from_columns([0, 0.5, 0, 0, 0, 0, 0, 0]), ())

    def test_two_separate_blobs(self):
        columns = [0.2, 0.2, 0, 0, 0, 0, 0.3, 0.3]
        blobs = blobs_from_columns(columns)
        self.assertEqual(len(blobs), 2)
        self.assertLess(blobs[0].dx_norm, blobs[1].dx_norm)

    def test_dx_clamped_to_unit_range(self):
        columns = [0.4] * 8
        (blob,) = blobs_from_columns(columns)
        self.assertGreaterEqual(blob.dx_norm, -1.0)
        self.assertLessEqual(blob.dx_norm, 1.0)


class RealPolicyPins(unittest.TestCase):
    """One pin per rule."""

    def test_rule_look_before_acting_dominates_when_blind(self):
        traced = score_real_actions(state(observed=False), ticks_since_observe=0)
        self.assertEqual(top(traced), "OBSERVE")
        self.assertEqual([f.rule for f in traced.firings], ["look-before-acting"])

    def test_rule_fire_on_motion_when_centered(self):
        blob = BlobFact(dx_norm=0.05, width_norm=0.1, strength=0.4)
        traced = score_real_actions(state([blob]), ticks_since_observe=0)
        self.assertEqual(top(traced), "ATTACK")

    def test_rule_face_the_motion_turns_toward_blob(self):
        blob = BlobFact(dx_norm=-0.6, width_norm=0.1, strength=0.4)
        traced = score_real_actions(state([blob]), ticks_since_observe=0)
        self.assertEqual(top(traced), "TURN_LEFT")

    def test_rule_dry_gun_blocks_attack_on_empty_hud(self):
        blob = BlobFact(dx_norm=0.0, width_norm=0.1, strength=0.4)
        traced = score_real_actions(state([blob], ammo_mass=0.0), ticks_since_observe=0)
        self.assertNotEqual(top(traced), "ATTACK")

    def test_rule_stop_and_look_after_two_moving_ticks(self):
        traced = score_real_actions(state(), ticks_since_observe=2)
        self.assertEqual(top(traced), "OBSERVE")

    def test_rule_explore_forward_when_recently_observed(self):
        traced = score_real_actions(state(), ticks_since_observe=0, explore_steps=0)
        self.assertEqual(top(traced), "FORWARD")

    def test_rule_scan_sweep_every_third_explore_step(self):
        traced = score_real_actions(state(), ticks_since_observe=0, explore_steps=2)
        self.assertEqual(top(traced), "TURN_RIGHT")
        self.assertEqual([f.rule for f in traced.firings], ["scan-sweep"])

    def test_aim_tolerance_boundary_fires(self):
        blob = BlobFact(dx_norm=AIM_TOLERANCE, width_norm=0.1, strength=0.3)
        traced = score_real_actions(state([blob]), ticks_since_observe=0)
        self.assertEqual(top(traced), "ATTACK")

    def test_scores_cover_full_real_action_space(self):
        traced = score_real_actions(state(), ticks_since_observe=0)
        self.assertEqual(set(traced.scores), set(REAL_ACTIONS))


class RealGraphPins(unittest.TestCase):
    def test_real_graph_state_carries_tiles_rules_choice(self):
        from decision_head import DecisionHead, DecisionSpace
        from doom_lane.real_doom98 import (
            REAL_RULE_INPUTS, REAL_RULES, build_real_graph_state,
        )
        for rule in REAL_RULES:  # every rule node wired (multi-site)
            self.assertIn(rule, REAL_RULE_INPUTS)
        blob = BlobFact(dx_norm=0.1, width_norm=0.2, strength=0.5)
        facts = state([blob])
        traced = score_real_actions(facts, ticks_since_observe=0)
        decision = DecisionHead(DecisionSpace("s", REAL_ACTIONS)).decide(
            traced.scores, evidence=facts.evidence())
        graph = build_real_graph_state(facts, traced.firings, decision, cycle=9)
        keys = [key for key, _ in graph.fact_tiles]
        self.assertEqual(keys, ["observed", "blobs", "ammo", "health"])
        self.assertEqual(graph.decisions_so_far, 9)
        self.assertIn(graph.choice, REAL_ACTIONS)


if __name__ == "__main__":
    unittest.main()
