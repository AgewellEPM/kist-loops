import pathlib
import sys
import unittest
from dataclasses import dataclass

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from doom_lane.perception import EnemyFact, SymbolicState, extract_state
from doom_lane.policy import (
    ACTIONS, AIM_TOLERANCE_FLOOR, LOW_AMMO_ROUNDS, aim_tolerance, score_actions,
)


def state(enemies=(), health=100.0, ammo=26.0, kills=0.0):
    return SymbolicState(health=health, ammo=ammo, kills=kills, enemies=tuple(enemies))


def top(scores):
    return max(scores, key=scores.get)


class PolicyRules(unittest.TestCase):
    """One test per written rule (multi-site discipline)."""

    def test_rule_scan_no_enemy_turns_left_by_default(self):
        self.assertEqual(top(score_actions(state())), "TURN_LEFT")

    def test_rule_scan_memory_sweeps_toward_last_seen_side(self):
        self.assertEqual(top(score_actions(state(), last_seen_side=1)), "TURN_RIGHT")
        self.assertEqual(top(score_actions(state(), last_seen_side=-1)), "TURN_LEFT")

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

    def test_rule_opportunistic_fire_never_turns_away_from_free_shot(self):
        # A centered (fireable) enemy is taken even when a bigger threat looms.
        centered_far = EnemyFact("Zombieman", dx_norm=0.0, width_norm=0.03)
        close_right = EnemyFact("Imp", dx_norm=0.6, width_norm=0.30)
        self.assertEqual(top(score_actions(state([centered_far, close_right]))),
                         "ATTACK")

    def test_rule_track_the_threat_when_nothing_fireable(self):
        # Neither is lined up -> face the big one, even though the small one
        # is nearer the crosshair.
        near_angle = EnemyFact("Zombieman", dx_norm=0.1, width_norm=0.03)
        big_left = EnemyFact("Imp", dx_norm=-0.7, width_norm=0.30)
        self.assertEqual(top(score_actions(state([near_angle, big_left]))),
                         "TURN_LEFT")

    def test_rule_aim_by_size_scales_with_width(self):
        small = EnemyFact("Imp", dx_norm=0.0, width_norm=0.02)
        big = EnemyFact("Imp", dx_norm=0.0, width_norm=0.4)
        self.assertLess(aim_tolerance(small, ammo=26), aim_tolerance(big, ammo=26))
        self.assertGreaterEqual(aim_tolerance(small, ammo=26), AIM_TOLERANCE_FLOOR)

    def test_rule_ammo_discipline_tightens_aim(self):
        target = EnemyFact("Imp", dx_norm=0.0, width_norm=0.2)
        self.assertLess(aim_tolerance(target, ammo=LOW_AMMO_ROUNDS),
                        aim_tolerance(target, ammo=26))

    def test_rule_ammo_discipline_skips_marginal_shot(self):
        # Marginal aim on a big target: fine with full ammo, not when low.
        marginal = EnemyFact("Imp", dx_norm=0.08, width_norm=0.2)
        self.assertEqual(top(score_actions(state([marginal], ammo=26))), "ATTACK")
        self.assertNotEqual(top(score_actions(state([marginal], ammo=3))), "ATTACK")

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

    def test_nearest_vs_closest_are_distinct_selectors(self):
        near_angle = EnemyFact("A", dx_norm=0.05, width_norm=0.05)
        near_body = EnemyFact("B", dx_norm=0.7, width_norm=0.4)
        facts = state([near_angle, near_body])
        self.assertEqual(facts.nearest_enemy.name, "A")
        self.assertEqual(facts.closest_enemy.name, "B")

    def test_evidence_names_the_nearest(self):
        raw = FakeVzdState([FakeLabel("Imp", 100, 20), FakeLabel("Zombieman", 152, 16)])
        facts = extract_state(raw, 320, health=55, ammo=3, kills=2)
        evidence = facts.evidence()
        self.assertEqual(evidence["nearest_name"], "Zombieman")
        self.assertEqual(evidence["enemy_count"], 2)
        self.assertEqual(evidence["health"], 55)




class TracedScoringPins(unittest.TestCase):
    """The justification graph: every rule that fires must say so by name."""

    def _rules(self, traced):
        return [f.rule for f in traced.firings]

    def test_scan_memory_traces(self):
        from doom_lane.policy import score_actions_traced
        traced = score_actions_traced(state(), last_seen_side=1)
        self.assertEqual(self._rules(traced), ["scan-memory"])
        self.assertIn("right", traced.firings[0].note)

    def test_opportunistic_fire_traces_target_and_tolerance(self):
        from doom_lane.policy import score_actions_traced
        aimed = EnemyFact("Zombieman", dx_norm=0.01, width_norm=0.1)
        traced = score_actions_traced(state([aimed]))
        self.assertIn("opportunistic-fire", self._rules(traced))
        self.assertIn("Zombieman", traced.firings[0].note)

    def test_track_the_threat_traces(self):
        from doom_lane.policy import score_actions_traced
        offset = EnemyFact("Imp", dx_norm=0.5, width_norm=0.1)
        traced = score_actions_traced(state([offset]))
        self.assertEqual(self._rules(traced), ["track-the-threat"])

    def test_dry_gun_traces(self):
        from doom_lane.policy import score_actions_traced
        aimed = EnemyFact("Imp", dx_norm=0.0, width_norm=0.1)
        traced = score_actions_traced(state([aimed], ammo=0))
        self.assertIn("dry-gun", self._rules(traced))

    def test_ammo_discipline_traces_when_low_and_firing(self):
        from doom_lane.policy import score_actions_traced
        aimed = EnemyFact("Imp", dx_norm=0.0, width_norm=0.3)
        traced = score_actions_traced(state([aimed], ammo=3))
        self.assertIn("ammo-discipline", self._rules(traced))

    def test_traced_scores_equal_plain_scores(self):
        from doom_lane.policy import score_actions, score_actions_traced
        for enemies, ammo in (((), 26.0),
                              ((EnemyFact("Imp", 0.0, 0.2),), 26.0),
                              ((EnemyFact("Imp", 0.5, 0.2),), 0.0)):
            s = state(list(enemies), ammo=ammo)
            self.assertEqual(score_actions(s), score_actions_traced(s).scores)


class GraphPanelPins(unittest.TestCase):
    """The traversal graph must show exactly what the receipt records."""

    def _decision_and_traced(self, enemies, ammo=26.0):
        from decision_head import DecisionHead, DecisionSpace
        from doom_lane.policy import ACTIONS, score_actions_traced
        facts = state(list(enemies), ammo=ammo)
        traced = score_actions_traced(facts)
        decision = DecisionHead(DecisionSpace("s", ACTIONS)).decide(
            traced.scores, evidence=facts.evidence())
        return facts, traced, decision

    def test_graph_state_lights_the_fired_rule_and_choice(self):
        from doom_lane.graph_panel import build_graph_state
        aimed = EnemyFact("Zombieman", dx_norm=0.01, width_norm=0.1)
        facts, traced, decision = self._decision_and_traced([aimed])
        graph = build_graph_state(
            facts.evidence(), traced.firings, decision, kills=4, decisions_so_far=7)
        self.assertIn("opportunistic-fire", graph.fired_rules)
        self.assertEqual(graph.choice, "ATTACK")
        self.assertEqual(graph.decisions_so_far, 7)

    def test_graph_state_fact_tiles_carry_enemy_and_ammo(self):
        from doom_lane.graph_panel import build_graph_state
        aimed = EnemyFact("Zombieman", dx_norm=0.01, width_norm=0.1)
        facts, traced, decision = self._decision_and_traced([aimed], ammo=3)
        graph = build_graph_state(
            facts.evidence(), traced.firings, decision, kills=0, decisions_so_far=1)
        texts = " | ".join(text for _, text in graph.fact_tiles)
        self.assertIn("Zombieman", texts)
        self.assertIn("ammo 3", texts)

    def test_every_rule_has_wiring_and_renders(self):
        from doom_lane.graph_panel import (
            RULE_INPUTS, RULES, GraphRenderer, build_graph_state,
        )
        for rule in RULES:  # one wiring assertion per rule node (multi-site)
            self.assertIn(rule, RULE_INPUTS)
        moving = EnemyFact("Imp", dx_norm=0.4, width_norm=0.1)
        facts, traced, decision = self._decision_and_traced([moving])
        graph = build_graph_state(
            facts.evidence(), traced.firings, decision, kills=2, decisions_so_far=3)
        image = GraphRenderer().render(graph)
        self.assertEqual((image.width, image.height), (800, 480))


if __name__ == "__main__":
    unittest.main()
