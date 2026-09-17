"""Bio-structure floor: mounts the vendored Peel engine for this domain.

Mirrors the jeeves-mcp floor pattern (one explicitly identified graph with an
authority string carried in every trace) and registers the slice-1 bio
relations into the engine's module-level RELATION_TYPES registry — the same
extension mechanism the Perslis legacy-ops relations (means/packs_to/class_of)
used upstream.

Functional flags are the Peel hard-veto doing real work here:
- has_sequence is functional: a protein has exactly one canonical sequence, so
  two different sequence objects for one protein is a contradiction the engine
  itself detects (_are_compatible -> False), no exclusive-set needed.
- predicts_structure is functional: AlphaFold publishes one prediction per
  accession, so two different predicted structures for one protein contradict.
- has_structure is NOT functional: many experimental structures per protein is
  normal (crystal forms, complexes) and must never be vetoed.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from . import relation_schema
from .relation_schema import RELATION_TYPES, RelationSchemaEngine

FLOOR_ID = "bio-structure-floor"
AUTHORITY = "uniprot-pdb-alphafold-evidence"

BIO_RELATIONS = {
    "encodes":            {"inverse": "encoded_by",             "transitive": False, "category": "bio_genomic"},
    "has_sequence":       {"inverse": "sequence_of",            "transitive": False, "category": "bio_structural", "functional": True},
    "has_structure":      {"inverse": "structure_of",           "transitive": False, "category": "bio_structural"},
    "predicts_structure": {"inverse": "predicted_structure_of", "transitive": False, "category": "bio_structural", "functional": True},
    "supports_claim":     {"inverse": "supported_by",           "transitive": False, "category": "bio_evidential"},
    "conflicts_with":     {"inverse": "conflicted_by",          "transitive": False, "category": "bio_evidential"},
}


@dataclass(frozen=True)
class BioFloor:
    """The one graph mounted behind this slice (identity travels in traces)."""

    floor_id: str
    path: Path
    authority: str


def register_bio_relations() -> None:
    """Idempotently add the six bio relations to the engine's registry."""
    for name, spec in BIO_RELATIONS.items():
        RELATION_TYPES.setdefault(name, spec)


def open_engine(db_path: str | Path) -> RelationSchemaEngine:
    """Open the Peel engine on the floor DB with bio relations registered."""
    register_bio_relations()
    return RelationSchemaEngine(str(db_path))


def bio_floor(db_path: str | Path) -> BioFloor:
    return BioFloor(floor_id=FLOOR_ID, path=Path(db_path), authority=AUTHORITY)


def is_functional(relation: str) -> bool:
    """Expose the engine's functional flag (the hard-veto semantics source)."""
    return bool(RELATION_TYPES.get(relation, {}).get("functional"))


def are_compatible(engine: RelationSchemaEngine, obj_a: str, obj_b: str, relation: str) -> bool:
    """Delegate compatibility to the REAL engine (functional flags + exclusive
    sets live there; the reasoner must not re-implement them)."""
    return engine._are_compatible(obj_a, obj_b, relation)


# Sanity: the vendored engine must still expose what we depend on. Fail loudly
# at import time if a re-vendor ever changes the contract.
for _name in ("RELATION_TYPES", "RelationSchemaEngine", "Relation"):
    if not hasattr(relation_schema, _name):
        raise ImportError(f"vendored Peel engine missing expected symbol: {_name}")
