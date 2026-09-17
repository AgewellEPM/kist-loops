"""Rules for controlling REAL DOOM through the guest — traced, zero neural.

The action space adds OBSERVE: standing still for one capture pair is the
price of honest motion-based perception, so the policy explicitly budgets
for it instead of pretending it can see while turning.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .real_perception import RealDoomState

REAL_ACTIONS = ("TURN_LEFT", "TURN_RIGHT", "FORWARD", "ATTACK", "OBSERVE")

AIM_TOLERANCE = 0.14        # coarse: one key-tap of turn is ~15 degrees
ATTACK_ON_TARGET = 4.0
TURN_GAIN = 3.0
OBSERVE_WHEN_BLIND = 2.5    # camera moved last tic -> look before acting
EXPLORE_FORWARD = 1.2
EXPLORE_OBSERVE = 0.8       # periodic stop-and-look while exploring
DRY_GUN_PENALTY = -6.0
AMMO_MASS_EMPTY = 0.004     # red-mass below this ~= no ammo digits lit


@dataclass(frozen=True)
class RealRuleFiring:
    rule: str
    action: str
    delta: float
    note: str


@dataclass
class RealTraced:
    scores: dict[str, float] = field(
        default_factory=lambda: {action: 0.0 for action in REAL_ACTIONS})
    firings: list[RealRuleFiring] = field(default_factory=list)

    def fire(self, rule, action, delta, note):
        self.scores[action] += delta
        self.firings.append(RealRuleFiring(rule, action, round(delta, 3), note))


SCAN_EVERY = 3              # every Nth explore step sweeps instead of walking
SCAN_SWEEP = 2.0


def score_real_actions(state: RealDoomState, ticks_since_observe: int,
                       explore_steps: int = 0) -> RealTraced:
    traced = RealTraced()

    if not state.observed:
        # RULE look-before-acting: the last action moved the camera, so the
        # motion diff is invalid — stand still one tic and actually see.
        traced.fire("look-before-acting", "OBSERVE", OBSERVE_WHEN_BLIND,
                    "camera moved last tic; diff invalid until we hold still")
        return traced

    target = state.primary_blob
    if target is not None:
        if abs(target.dx_norm) <= AIM_TOLERANCE:
            traced.fire("fire-on-motion", "ATTACK", ATTACK_ON_TARGET,
                        f"animated blob centered (dx={target.dx_norm:+.2f}, "
                        f"strength={target.strength:.2f})")
        else:
            side = "TURN_RIGHT" if target.dx_norm > 0 else "TURN_LEFT"
            traced.fire("face-the-motion", side,
                        TURN_GAIN * min(1.0, abs(target.dx_norm) + 0.2),
                        f"blob at dx={target.dx_norm:+.2f}")
        if state.ammo_mass < AMMO_MASS_EMPTY:
            traced.fire("dry-gun", "ATTACK", DRY_GUN_PENALTY,
                        f"ammo cell red-mass {state.ammo_mass:.4f} ~ empty")
        return traced

    # RULE explore: nothing animate in view — advance, sweep the view every
    # SCAN_EVERY steps, and stop to look so walking never outruns perception.
    if ticks_since_observe >= 2:
        traced.fire("stop-and-look", "OBSERVE", EXPLORE_OBSERVE + 1.0,
                    f"{ticks_since_observe} ticks since a clean observation")
    elif explore_steps % SCAN_EVERY == SCAN_EVERY - 1:
        traced.fire("scan-sweep", "TURN_RIGHT", SCAN_SWEEP,
                    f"explore step {explore_steps}: sweep the view for movers")
    else:
        traced.fire("explore-forward", "FORWARD", EXPLORE_FORWARD,
                    "no animated blobs; advancing")
        traced.fire("explore-look-bias", "OBSERVE", EXPLORE_OBSERVE,
                    "standing look stays cheap")
    return traced
