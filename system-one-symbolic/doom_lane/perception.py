"""ViZDoom state -> typed symbolic facts. ZERO neural.

The engine's labels buffer identifies every visible actor with pixel-exact
bounds — grounded state straight from the simulator, the same footing as
TypeSafe's Doom demo ("structured state as a data structure with text, not
on images (yet…)"). Perception here is pure arithmetic over that state; the
neural question only arises when input degrades to raw pixels (see README).
"""
from __future__ import annotations

from dataclasses import dataclass

NON_ENEMY_NAMES = frozenset({"DoomPlayer", "TeleportFog", "Blood", "BulletPuff"})


@dataclass(frozen=True)
class EnemyFact:
    name: str
    dx_norm: float   # horizontal offset of enemy centre from crosshair, in [-1, 1]
    width_norm: float  # apparent width fraction — a symbolic proximity proxy


@dataclass(frozen=True)
class SymbolicState:
    health: float
    ammo: float
    kills: float
    enemies: tuple[EnemyFact, ...]

    @property
    def nearest_enemy(self) -> EnemyFact | None:
        if not self.enemies:
            return None
        return min(self.enemies, key=lambda e: abs(e.dx_norm))

    def evidence(self) -> dict:
        nearest = self.nearest_enemy
        return {
            "health": self.health,
            "ammo": self.ammo,
            "kills": self.kills,
            "enemy_count": len(self.enemies),
            "nearest_dx": round(nearest.dx_norm, 4) if nearest else None,
            "nearest_name": nearest.name if nearest else None,
        }


def extract_state(vzd_state, screen_width: int,
                  health: float, ammo: float, kills: float) -> SymbolicState:
    """Map a raw ViZDoom state object to symbolic facts."""
    half = screen_width / 2.0
    enemies = []
    for label in getattr(vzd_state, "labels", []) or []:
        if label.object_name in NON_ENEMY_NAMES:
            continue
        centre = label.x + label.width / 2.0
        enemies.append(EnemyFact(
            name=label.object_name,
            dx_norm=max(-1.0, min(1.0, (centre - half) / half)),
            width_norm=label.width / screen_width,
        ))
    return SymbolicState(health=health, ammo=ammo, kills=kills, enemies=tuple(enemies))
