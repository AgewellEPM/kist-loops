"""Symbolic perception for REAL DOOM frames (640x480 guest captures).

No labels buffer here and NO neural net either: enemies are found by frame
differencing between two captures taken while standing still — sprites
idle-animate and wander, walls don't. That is pure arithmetic, and it is
honest: when the previous action moved the camera, the diff is invalid and
we say so (facts carry observed=False) instead of hallucinating enemies.

HUD ammo/health are read as red-pixel mass in their fixed status-bar cells —
a coarse but rule-based signal (enough for dry-gun / low-ammo rules without
pretending we OCR'd exact digits).
"""
from __future__ import annotations

from dataclasses import dataclass

# 640x480 frame geometry (DOOM 320x200 doubled: status bar = bottom 64px*2).
VIEW = (0, 16, 640, 336)          # 3D viewport crop (skips demo text row)
AMMO_CELL = (18, 340, 118, 390)   # big red ammo digits
HEALTH_CELL = (128, 340, 260, 390)
DIFF_THRESHOLD = 22               # per-pixel abs delta that counts as motion
GRID = 16                         # motion accumulated into 16px columns
MIN_BLOB_COLUMNS = 2              # ignore single-column flicker
RED_MIN = 120                     # HUD digit redness gate


@dataclass(frozen=True)
class BlobFact:
    dx_norm: float    # blob centre offset from crosshair, [-1, 1]
    width_norm: float # blob width fraction of viewport
    strength: float   # fraction of changed pixels inside the blob columns


@dataclass(frozen=True)
class RealDoomState:
    observed: bool               # True only when the diff pair was still
    blobs: tuple[BlobFact, ...]
    ammo_mass: float             # red-pixel fraction in the ammo cell
    health_mass: float           # red-pixel fraction in the health cell

    @property
    def primary_blob(self) -> BlobFact | None:
        if not self.blobs:
            return None
        return max(self.blobs, key=lambda b: b.strength * (1 + b.width_norm))

    def evidence(self) -> dict:
        primary = self.primary_blob
        return {
            "observed": self.observed,
            "blob_count": len(self.blobs),
            "primary_dx": round(primary.dx_norm, 3) if primary else None,
            "primary_width": round(primary.width_norm, 3) if primary else None,
            "ammo_mass": round(self.ammo_mass, 4),
            "health_mass": round(self.health_mass, 4),
        }


def _red_mass(image, cell) -> float:
    region = image.crop(cell)
    pixels = region.load()
    width, height = region.size
    lit = 0
    for y in range(0, height, 2):
        for x in range(0, width, 2):
            r, g, b = pixels[x, y][:3]
            if r >= RED_MIN and g < r // 2 and b < r // 2:
                lit += 1
    return lit / ((width // 2) * (height // 2))


def _motion_columns(before, after) -> list[float]:
    """Fraction of changed pixels per GRID-px viewport column."""
    view_a = before.crop(VIEW).convert("L")
    view_b = after.crop(VIEW).convert("L")
    pixels_a, pixels_b = view_a.load(), view_b.load()
    width, height = view_a.size
    columns = [0] * (width // GRID)
    samples_per_column = (GRID // 2) * (height // 2)
    for x in range(0, width - 1, 2):
        column = x // GRID
        for y in range(0, height, 2):
            if abs(pixels_a[x, y] - pixels_b[x, y]) > DIFF_THRESHOLD:
                columns[column] += 1
    return [count / samples_per_column for count in columns]


def blobs_from_columns(columns: list[float],
                       floor: float = 0.04) -> tuple[BlobFact, ...]:
    """Group adjacent hot columns into blob facts. Pure function (tested)."""
    blobs, run = [], []
    for index, value in enumerate(columns + [0.0]):
        if value >= floor:
            run.append((index, value))
            continue
        if len(run) >= MIN_BLOB_COLUMNS:
            centre = sum(i for i, _ in run) / len(run) + 0.5
            blobs.append(BlobFact(
                dx_norm=max(-1.0, min(1.0, (centre / len(columns)) * 2 - 1)),
                width_norm=len(run) / len(columns),
                strength=sum(v for _, v in run) / len(run),
            ))
        run = []
    return tuple(blobs)


def perceive_images(before_image, after_image, camera_moved: bool) -> RealDoomState:
    """Perceive from two in-memory PIL RGB frames (no file round-trip)."""
    ammo = _red_mass(after_image, AMMO_CELL)
    health = _red_mass(after_image, HEALTH_CELL)
    if camera_moved:
        return RealDoomState(False, (), ammo, health)
    columns = _motion_columns(before_image, after_image)
    return RealDoomState(True, blobs_from_columns(columns), ammo, health)


def perceive(before_path, after_path, camera_moved: bool) -> RealDoomState:
    from PIL import Image
    after = Image.open(after_path).convert("RGB")
    if camera_moved:
        return RealDoomState(False, (), _red_mass(after, AMMO_CELL),
                             _red_mass(after, HEALTH_CELL))
    before = Image.open(before_path).convert("RGB")
    return perceive_images(before, after, camera_moved=False)
