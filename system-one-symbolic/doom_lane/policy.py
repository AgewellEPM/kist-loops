"""Symbolic Doom policy: named rules -> scores over a closed action space.

Every score contribution is a written-down rule, and scoring is TRACED:
score_actions_traced() returns the exact (rule, action, delta, note) firings
that produced the scores. The receipt of each decision therefore carries the
full justification graph — facts -> rules -> scores -> choice — which is
what the live decision panel and the recorded video render.

v3 (2026-09-17): opportunistic fire + threat tracking + ammo discipline +
scan memory, all rule-traced. Still zero neural.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .perception import EnemyFact, SymbolicState

ACTIONS = ("TURN_LEFT", "TURN_RIGHT", "ATTACK")

# Rule constants — tuned on defend_the_center, all inspectable.
AIM_TOLERANCE_FLOOR = 0.02   # never demand better aim than this
AIM_TOLERANCE_SCALE = 0.55   # tolerance grows with apparent target width
SCAN_BIAS = 1.0              # sweep strength when nothing is visible
ATTACK_ON_TARGET = 4.0
TURN_GAIN = 3.0
NO_AMMO_ATTACK_PENALTY = -6.0
LOW_AMMO_ROUNDS = 5          # below this, only take near-perfect shots
LOW_AMMO_TIGHTEN = 0.5       # aim tolerance multiplier when conserving


@dataclass(frozen=True)
class RuleFiring:
    rule: str
    action: str
    delta: float
    note: str


@dataclass
class TracedScores:
    scores: dict[str, float] = field(
        default_factory=lambda: {action: 0.0 for action in ACTIONS})
    firings: list[RuleFiring] = field(default_factory=list)

    def fire(self, rule: str, action: str, delta: float, note: str) -> None:
        self.scores[action] += delta
        self.firings.append(RuleFiring(rule, action, round(delta, 3), note))


def aim_tolerance(target: EnemyFact, ammo: float) -> float:
    """RULE aim-by-size: big/close sprites forgive coarse aim, far ones don't.
    RULE ammo-discipline: low ammo halves the acceptable error."""
    tolerance = max(AIM_TOLERANCE_FLOOR, AIM_TOLERANCE_SCALE * target.width_norm)
    if ammo <= LOW_AMMO_ROUNDS:
        tolerance *= LOW_AMMO_TIGHTEN
    return tolerance


def fireable(state: SymbolicState) -> EnemyFact | None:
    """RULE opportunistic-fire: any enemy already inside its own aim
    tolerance is a valid kill — never turn away from a free shot."""
    candidates = [e for e in state.enemies
                  if abs(e.dx_norm) <= aim_tolerance(e, state.ammo)]
    if not candidates:
        return None
    return max(candidates, key=lambda e: e.width_norm)


def score_actions_traced(state: SymbolicState,
                         last_seen_side: int = -1) -> TracedScores:
    """last_seen_side: -1 = left, +1 = right; used only when nothing visible."""
    traced = TracedScores()
    threat = state.closest_enemy

    if threat is None:
        side = "TURN_RIGHT" if last_seen_side > 0 else "TURN_LEFT"
        traced.fire("scan-memory", side, SCAN_BIAS,
                    f"no enemy visible; last seen {'right' if last_seen_side > 0 else 'left'}")
        return traced

    target = fireable(state)
    if target is not None:
        traced.fire("opportunistic-fire", "ATTACK", ATTACK_ON_TARGET,
                    f"{target.name} in tolerance "
                    f"(|dx|={abs(target.dx_norm):.2f}<={aim_tolerance(target, state.ammo):.2f})")
        if state.ammo <= LOW_AMMO_ROUNDS:
            traced.fire("ammo-discipline", "ATTACK", 0.0,
                        f"low ammo ({state.ammo:.0f}) — tolerance halved, shot still valid")
    else:
        side = "TURN_RIGHT" if threat.dx_norm > 0 else "TURN_LEFT"
        traced.fire("track-the-threat", side,
                    TURN_GAIN * min(1.0, abs(threat.dx_norm) + 0.2),
                    f"{threat.name} closest (w={threat.width_norm:.2f}) at dx={threat.dx_norm:+.2f}")

    if state.ammo <= 0:
        traced.fire("dry-gun", "ATTACK", NO_AMMO_ATTACK_PENALTY,
                    "no ammo — firing is never preferred")

    return traced


def score_actions(state: SymbolicState, last_seen_side: int = -1) -> dict[str, float]:
    return score_actions_traced(state, last_seen_side).scores
