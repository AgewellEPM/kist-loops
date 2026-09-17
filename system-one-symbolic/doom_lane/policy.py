"""Symbolic Doom policy: named rules -> scores over a closed action space.

Every score contribution is a written-down rule. The receipt of each decision
contains the facts and the scores, so any action can be replayed and audited:
this is the 'path is the justification' property applied to motor control.
"""
from __future__ import annotations

from .perception import SymbolicState

ACTIONS = ("TURN_LEFT", "TURN_RIGHT", "ATTACK")

# Rule constants — tuned on defend_the_center, all inspectable.
AIM_TOLERANCE = 0.06     # |dx| under this = on target
SCAN_BIAS = 1.0          # keep turning one way when nothing is visible
ATTACK_ON_TARGET = 4.0
TURN_GAIN = 3.0
NO_AMMO_ATTACK_PENALTY = -6.0


def score_actions(state: SymbolicState) -> dict[str, float]:
    scores = {action: 0.0 for action in ACTIONS}
    nearest = state.nearest_enemy

    if nearest is None:
        # RULE scan: nothing visible -> sweep left until something appears.
        scores["TURN_LEFT"] += SCAN_BIAS
        return scores

    if abs(nearest.dx_norm) <= AIM_TOLERANCE:
        # RULE fire-when-aimed: crosshair is on the nearest enemy.
        scores["ATTACK"] += ATTACK_ON_TARGET
    else:
        # RULE track: turn toward the nearest enemy, harder when further off.
        side = "TURN_RIGHT" if nearest.dx_norm > 0 else "TURN_LEFT"
        scores[side] += TURN_GAIN * min(1.0, abs(nearest.dx_norm) + 0.2)

    if state.ammo <= 0:
        # RULE dry-gun: never prefer ATTACK with an empty weapon.
        scores["ATTACK"] += NO_AMMO_ATTACK_PENALTY

    return scores
