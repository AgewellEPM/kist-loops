"""Canonical-37 PEEL tile trace for the bio wheel.

The Jeeves wiki wheel writes a full canonical-37 tile per harvested fact plus
a persisted link graph; the bio wheel does the SAME here. One ROOT tile per
protein extraction (depth 0), one CHILD tile per typed fact (depth 1), chained
through parent_tile_id / branch_path / next_step / previous_step — so the
whole extraction is walkable as a tile trace, exactly like we do in Jeeves.

Field list source of truth: kids-brain canonical-37
(copy_harvest_to_jeeves_37fields.py; pinned in test_wiki_wheel_trace.py).
Every field is populated HONESTLY from the bio evidence — a tile with an
empty canonical field is a bug and is rejected at write time (37/37 or
nothing; the wiki wheel's 33/37 regression is the lesson).
"""

from __future__ import annotations

import hashlib
import json

from .schema import ValidationError, utc_now_iso
from .store import Store

# The canonical 37-field PEEL tile (order matters; mirrors Jeeves exactly).
CANONICAL_37 = (
    "id", "conversation_id", "emoji", "words", "sentence", "verb", "action",
    "intent", "emotion", "visual_representation", "entities", "svo_triple",
    "complexity_level", "reading_level", "speech_pattern", "cognitive_load",
    "confidence_score", "learning_objective", "prerequisites",
    "follow_up_suggestions", "audio_tts_hints", "visual_aids", "pet_motion",
    "parent", "subcategory", "related_to", "causes", "requires", "part_of",
    "next_step", "previous_step", "connectors", "depth_level",
    "parent_tile_id", "branch_path", "turn_number", "topic",
)

_RELATION_RENDER = {
    "encodes":            ("🧬", "encodes", ["encodes"]),
    "has_sequence":       ("🔡", "has sequence", ["has", "sequence"]),
    "has_structure":      ("🧱", "has experimental structure", ["has", "structure"]),
    "predicts_structure": ("🔮", "has predicted structure", ["predicts"]),
    "belongs_to":         ("🌍", "belongs to organism", ["belongs", "to"]),
    "located_in":         ("📍", "is located in", ["located", "in"]),
    "affects":            ("🩺", "is involved in", ["affects"]),
    "has_part":           ("🧩", "has domain", ["has", "part"]),
    "supports_claim":     ("✅", "supports claim", ["supports"]),
    "conflicts_with":     ("⚠️", "conflicts with claim", ["conflicts", "with"]),
}


def _tile_id(conversation_id: str, branch_path: str) -> str:
    """Deterministic tile id: re-extraction never duplicates a tile."""
    digest = hashlib.sha256(f"{conversation_id}|{branch_path}".encode()).hexdigest()
    return f"tile:{digest[:32]}"


def _human(node: str) -> str:
    """Cosmetic surface form of a typed node id (labels never drive reasoning)."""
    prefix, _, ident = node.partition(":")
    return ident.replace("_", " ") if prefix in ("organism", "location",
                                                 "disease", "domain") else ident


def write_tile(store: Store, tile: dict) -> tuple[str, bool]:
    """Insert one canonical-37 tile. EVERY canonical field must be present
    and non-empty (confidence/depth/turn are numeric; empty string is a bug)."""
    missing = [f for f in CANONICAL_37 if f not in tile]
    if missing:
        raise ValidationError(f"tile missing canonical fields: {missing}")
    empty = [f for f in CANONICAL_37
             if not isinstance(tile[f], (int, float)) and not str(tile[f]).strip()]
    if empty:
        raise ValidationError(f"tile has EMPTY canonical fields: {empty} (37/37 or nothing)")

    existing = store.db.execute("SELECT id FROM responses WHERE id = ?",
                                (tile["id"],)).fetchone()
    if existing:
        return tile["id"], False
    columns = ", ".join(CANONICAL_37)
    holes = ", ".join("?" for _ in CANONICAL_37)
    store.db.execute(f"INSERT INTO responses ({columns}) VALUES ({holes})",
                     tuple(tile[f] for f in CANONICAL_37))
    store.db.commit()
    return tile["id"], True


def _base_tile(conversation_id: str, acc: str, branch_path: str,
               turn: int, depth: int, parent_tile: str) -> dict:
    """The honest shared scaffolding every bio tile carries."""
    return {
        "conversation_id": conversation_id,
        "intent": "teach",
        "emotion": "neutral",
        "complexity_level": "medium",
        "reading_level": "grade-8",
        "speech_pattern": "declarative",
        "cognitive_load": "low",
        "confidence_score": 1.0,
        "prerequisites": json.dumps([]),
        "follow_up_suggestions": json.dumps([f"evaluate structural consistency of {acc}"]),
        "audio_tts_hints": "plain",
        "pet_motion": "idle",
        "depth_level": depth,
        "parent_tile_id": parent_tile,
        "branch_path": branch_path,
        "turn_number": turn,
        "topic": f"bio-structure:{acc}",
    }


def write_extraction_trace(store: Store, acc: str, edges: list[dict],
                           sources: list[str]) -> dict:
    """Write the full tile trace for one wheel run: root + one tile per fact.

    `edges` are the extraction's written-edge dicts ({edge_id, source,
    relation, target}). Chaining: root -> fact1 -> fact2 ... via
    next_step/previous_step; branch paths are protein:<acc>/<relation>/<n>.
    Deterministic and idempotent (same facts -> same tile ids -> 0 new).
    """
    conversation_id = f"bio-wheel:{acc}"
    protein = f"protein:{acc}"
    written: list[str] = []

    root_path = f"{protein}/root"
    root_id = _tile_id(conversation_id, root_path)
    ordered = sorted(edges, key=lambda e: (e["relation"], e["target"]))

    root = {
        **_base_tile(conversation_id, acc, root_path, 0, 0, "root"),
        "id": root_id,
        "emoji": "🧬",
        "words": json.dumps([acc, "protein", "evidence"]),
        "sentence": f"{acc} evidence gathered from {len(sources)} allowlisted bio sources.",
        "verb": "gather",
        "action": "extract",
        "visual_representation": protein,
        "entities": json.dumps([protein]),
        "svo_triple": json.dumps({"s": "bio-wheel", "v": "extracted", "o": protein}),
        "learning_objective": f"ground the evidence base for {acc}",
        "visual_aids": sources[0] if sources else "none",
        "parent": "bio-structure",
        "subcategory": "extraction-root",
        "related_to": json.dumps(sorted({e["relation"] for e in ordered})),
        "causes": "none",
        "requires": "allowlisted bio sources",
        "part_of": "symbolic-floor bio wheel",
        "next_step": _tile_id(conversation_id,
                              f"{protein}/{ordered[0]['relation']}/1") if ordered else "none",
        "previous_step": "none",
        "connectors": json.dumps(["evidence", "from"]),
    }
    tid, created = write_tile(store, root)
    if created:
        written.append(tid)

    for n, edge in enumerate(ordered, start=1):
        emoji, verb_phrase, connectors = _RELATION_RENDER.get(
            edge["relation"], ("🔗", edge["relation"].replace("_", " "), ["relates"]))
        subj_h, obj_h = _human(edge["source"]), _human(edge["target"])
        branch = f"{protein}/{edge['relation']}/{n}"
        prev_branch = (f"{protein}/{ordered[n - 2]['relation']}/{n - 1}"
                       if n > 1 else root_path)
        next_branch = (f"{protein}/{ordered[n]['relation']}/{n + 1}"
                       if n < len(ordered) else None)
        tile = {
            **_base_tile(conversation_id, acc, branch, n, 1, root_id),
            "id": _tile_id(conversation_id, branch),
            "emoji": emoji,
            "words": json.dumps([subj_h, verb_phrase, obj_h]),
            "sentence": f"{subj_h} {verb_phrase} {obj_h}.",
            "verb": verb_phrase.split()[0],
            "action": edge["relation"],
            "visual_representation": edge["target"],
            "entities": json.dumps([edge["source"], edge["target"]]),
            "svo_triple": json.dumps({"s": edge["source"], "v": edge["relation"],
                                      "o": edge["target"]}),
            "learning_objective": f"pin {edge['relation']} evidence for {acc}",
            "visual_aids": edge["edge_id"],  # the typed edge IS the visual anchor
            "parent": protein,
            "subcategory": edge["relation"],
            "related_to": json.dumps([edge["source"], edge["target"]]),
            "causes": "none",
            "requires": f"edge:{edge['edge_id']}",
            "part_of": f"{protein} evidence trace",
            "next_step": _tile_id(conversation_id, next_branch) if next_branch else "none",
            "previous_step": _tile_id(conversation_id, prev_branch) if n > 1 else root_id,
            "connectors": json.dumps(connectors),
        }
        tid, created = write_tile(store, tile)
        if created:
            written.append(tid)

    return {"conversation_id": conversation_id, "root_tile": root_id,
            "tiles_written": len(written), "tiles_total": 1 + len(ordered)}


def tile_trace(store: Store, acc: str) -> list[dict]:
    """Walk the tile chain for one protein, root-first — the readable trace."""
    rows = store.db.execute(
        "SELECT * FROM responses WHERE conversation_id = ? "
        "ORDER BY depth_level, turn_number",
        (f"bio-wheel:{acc.strip().upper()}",),
    ).fetchall()
    return [dict(r) for r in rows]
