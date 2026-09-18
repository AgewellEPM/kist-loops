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
    "interacts_with":     ("🤝", "interacts with", ["interacts", "with"]),
    # Slice-2 chemistry (the molecule wheel).
    "has_formula":        ("⚗️", "has molecular formula", ["has", "formula"]),
    "has_iupac_name":     ("🏷️", "has IUPAC name", ["iupac", "name"]),
    "known_as":           ("💬", "is also known as", ["known", "as"]),
    "has_inchikey":       ("🔑", "has InChIKey", ["inchikey"]),
    "has_weight":         ("⚖️", "has molecular weight", ["has", "weight"]),
    # Slice-3 genomics (the gene wheel).
    "on_chromosome":      ("📌", "is on chromosome", ["on", "chromosome"]),
    "has_biotype":        ("🏷️", "has biotype", ["biotype"]),
}


def _tile_id(conversation_id: str, branch_path: str) -> str:
    """Deterministic tile id: re-extraction never duplicates a tile."""
    digest = hashlib.sha256(f"{conversation_id}|{branch_path}".encode()).hexdigest()
    return f"tile:{digest[:32]}"


def _human(node: str) -> str:
    """Cosmetic surface form of a typed node id (labels never drive reasoning)."""
    prefix, _, ident = node.partition(":")
    if prefix in ("organism", "location", "disease", "domain", "compound"):
        return ident.replace("_", " ")
    if prefix == "molecule":
        return f"CID {ident}"
    if prefix == "gene":
        return f"gene {ident}"
    return ident  # chromosome/biotype/formula/inchikey/weight: bare ident


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


def _base_molecule_tile(conversation_id: str, cid: int, name: str, branch_path: str,
                        turn: int, depth: int, parent_tile: str) -> dict:
    """Shared scaffolding for chemistry tiles (molecule wheel). Mirrors
    _base_tile but topics under chemistry:<cid> and suggests a chemistry
    follow-up rather than a protein structural-consistency one."""
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
        "follow_up_suggestions": json.dumps([f"compare {name} to related molecules"]),
        "audio_tts_hints": "plain",
        "pet_motion": "idle",
        "depth_level": depth,
        "parent_tile_id": parent_tile,
        "branch_path": branch_path,
        "turn_number": turn,
        "topic": f"chemistry:{cid}",
    }


def write_molecule_extraction_trace(store: Store, cid: int, name: str,
                                    edges: list[dict], sources: list[str]) -> dict:
    """Canonical-37 tile trace for one molecule wheel run: root + one tile per
    chemistry fact, chained. Same determinism/idempotency contract as the
    protein trace; keyed under conversation `chem-wheel:<cid>`."""
    conversation_id = f"chem-wheel:{cid}"
    molecule = f"molecule:{cid}"
    written: list[str] = []

    root_path = f"{molecule}/root"
    root_id = _tile_id(conversation_id, root_path)
    ordered = sorted(edges, key=lambda e: (e["relation"], e["target"]))

    root = {
        **_base_molecule_tile(conversation_id, cid, name, root_path, 0, 0, "root"),
        "id": root_id,
        "emoji": "🧪",
        "words": json.dumps([name, "molecule", "chemistry"]),
        "sentence": f"{name} (PubChem CID {cid}) chemistry gathered from "
                    f"{len(sources)} allowlisted source(s).",
        "verb": "gather",
        "action": "extract",
        "visual_representation": molecule,
        "entities": json.dumps([molecule]),
        "svo_triple": json.dumps({"s": "chem-wheel", "v": "extracted", "o": molecule}),
        "learning_objective": f"ground the chemistry of {name}",
        "visual_aids": sources[0] if sources else "none",
        "parent": "chemistry",
        "subcategory": "extraction-root",
        "related_to": json.dumps(sorted({e["relation"] for e in ordered})),
        "causes": "none",
        "requires": "allowlisted chemistry sources",
        "part_of": "symbolic-floor molecule wheel",
        "next_step": _tile_id(conversation_id,
                              f"{molecule}/{ordered[0]['relation']}/1") if ordered else "none",
        "previous_step": "none",
        "connectors": json.dumps(["chemistry", "from"]),
    }
    tid, created = write_tile(store, root)
    if created:
        written.append(tid)

    for n, edge in enumerate(ordered, start=1):
        emoji, verb_phrase, connectors = _RELATION_RENDER.get(
            edge["relation"], ("🔗", edge["relation"].replace("_", " "), ["relates"]))
        subj_h, obj_h = _human(edge["source"]), _human(edge["target"])
        branch = f"{molecule}/{edge['relation']}/{n}"
        prev_branch = (f"{molecule}/{ordered[n - 2]['relation']}/{n - 1}"
                       if n > 1 else root_path)
        next_branch = (f"{molecule}/{ordered[n]['relation']}/{n + 1}"
                       if n < len(ordered) else None)
        tile = {
            **_base_molecule_tile(conversation_id, cid, name, branch, n, 1, root_id),
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
            "learning_objective": f"pin {edge['relation']} for {name}",
            "visual_aids": edge["edge_id"],
            "parent": molecule,
            "subcategory": edge["relation"],
            "related_to": json.dumps([edge["source"], edge["target"]]),
            "causes": "none",
            "requires": f"edge:{edge['edge_id']}",
            "part_of": f"{name} chemistry trace",
            "next_step": _tile_id(conversation_id, next_branch) if next_branch else "none",
            "previous_step": _tile_id(conversation_id, prev_branch) if n > 1 else root_id,
            "connectors": json.dumps(connectors),
        }
        tid, created = write_tile(store, tile)
        if created:
            written.append(tid)

    return {"conversation_id": conversation_id, "root_tile": root_id,
            "tiles_written": len(written), "tiles_total": 1 + len(ordered)}


def _base_gene_tile(conversation_id: str, symbol: str, branch_path: str,
                    turn: int, depth: int, parent_tile: str) -> dict:
    """Shared scaffolding for gene tiles (the gene wheel), topicked genomics:<symbol>."""
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
        "follow_up_suggestions": json.dumps([f"research the proteins {symbol} encodes"]),
        "audio_tts_hints": "plain",
        "pet_motion": "idle",
        "depth_level": depth,
        "parent_tile_id": parent_tile,
        "branch_path": branch_path,
        "turn_number": turn,
        "topic": f"genomics:{symbol}",
    }


def write_gene_extraction_trace(store: Store, symbol: str, edges: list[dict],
                                sources: list[str]) -> dict:
    """Canonical-37 tile trace for one gene wheel run — same contract as the
    protein/molecule traces, keyed under `gene-wheel:<symbol>`."""
    conversation_id = f"gene-wheel:{symbol}"
    gene = f"gene:{symbol}"
    written: list[str] = []

    root_path = f"{gene}/root"
    root_id = _tile_id(conversation_id, root_path)
    ordered = sorted(edges, key=lambda e: (e["relation"], e["target"]))

    root = {
        **_base_gene_tile(conversation_id, symbol, root_path, 0, 0, "root"),
        "id": root_id,
        "emoji": "🧬",
        "words": json.dumps([symbol, "gene", "genomics"]),
        "sentence": f"Gene {symbol} evidence gathered from {len(sources)} "
                    f"allowlisted source(s).",
        "verb": "gather",
        "action": "extract",
        "visual_representation": gene,
        "entities": json.dumps([gene]),
        "svo_triple": json.dumps({"s": "gene-wheel", "v": "extracted", "o": gene}),
        "learning_objective": f"ground the genomics of {symbol}",
        "visual_aids": sources[0] if sources else "none",
        "parent": "genomics",
        "subcategory": "extraction-root",
        "related_to": json.dumps(sorted({e["relation"] for e in ordered})),
        "causes": "none",
        "requires": "allowlisted genomics sources",
        "part_of": "symbolic-floor gene wheel",
        "next_step": _tile_id(conversation_id,
                              f"{gene}/{ordered[0]['relation']}/1") if ordered else "none",
        "previous_step": "none",
        "connectors": json.dumps(["genomics", "from"]),
    }
    tid, created = write_tile(store, root)
    if created:
        written.append(tid)

    for n, edge in enumerate(ordered, start=1):
        emoji, verb_phrase, connectors = _RELATION_RENDER.get(
            edge["relation"], ("🔗", edge["relation"].replace("_", " "), ["relates"]))
        subj_h, obj_h = _human(edge["source"]), _human(edge["target"])
        branch = f"{gene}/{edge['relation']}/{n}"
        prev_branch = (f"{gene}/{ordered[n - 2]['relation']}/{n - 1}"
                       if n > 1 else root_path)
        next_branch = (f"{gene}/{ordered[n]['relation']}/{n + 1}"
                       if n < len(ordered) else None)
        tile = {
            **_base_gene_tile(conversation_id, symbol, branch, n, 1, root_id),
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
            "learning_objective": f"pin {edge['relation']} for {symbol}",
            "visual_aids": edge["edge_id"],
            "parent": gene,
            "subcategory": edge["relation"],
            "related_to": json.dumps([edge["source"], edge["target"]]),
            "causes": "none",
            "requires": f"edge:{edge['edge_id']}",
            "part_of": f"{symbol} genomics trace",
            "next_step": _tile_id(conversation_id, next_branch) if next_branch else "none",
            "previous_step": _tile_id(conversation_id, prev_branch) if n > 1 else root_id,
            "connectors": json.dumps(connectors),
        }
        tid, created = write_tile(store, tile)
        if created:
            written.append(tid)

    return {"conversation_id": conversation_id, "root_tile": root_id,
            "tiles_written": len(written), "tiles_total": 1 + len(ordered)}
