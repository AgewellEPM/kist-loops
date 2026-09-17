"""Write/read edge API with provenance enforcement.

This is the ONLY write path to the floor. Every edge:
  1. passes schema.validate_edge (six relations, fixed direction, typed IDs),
  2. passes schema.validate_provenance (required keys, allowlisted URL, UTC),
  3. is stored as a Peel typed relation via the VENDORED engine (which owns
     dedup-by-hash and category assignment),
  4. gets its provenance row written in the SAME transaction.

An edge without provenance cannot exist: validation happens before any insert,
and both inserts share one connection/commit.
"""

from __future__ import annotations

import hashlib
import uuid

from .db import open_floor_db
from .peel.floor import AUTHORITY, FLOOR_ID
from .peel.relation_schema import Relation, RelationSchemaEngine
from .schema import (
    ValidationError,
    validate_edge,
    validate_node_id,
    validate_provenance,
    utc_now_iso,
)

CLAIM_SHAPE_STRUCTURAL = "structural-consistency-v1"
_TOPIC = "bio-structure"


class Store:
    """Provenance-enforcing facade over the Peel engine on one floor DB."""

    def __init__(self, db_path=None):
        self.engine: RelationSchemaEngine = open_floor_db(db_path)
        self.db = self.engine.db  # shared connection: atomic fact+provenance
        self.floor_id = FLOOR_ID
        self.authority = AUTHORITY

    # ---------------- nodes ----------------

    def ensure_node(self, node_id: str, label: str | None = None) -> str:
        validate_node_id(node_id)
        self.db.execute(
            "INSERT OR IGNORE INTO nodes (node_id, label, created_at) VALUES (?, ?, ?)",
            (node_id, label or node_id, utc_now_iso()),
        )
        return node_id

    # ---------------- sequences ----------------

    @staticmethod
    def sequence_node_id(residues: str) -> str:
        """Content-addressed sequence ID: sha256 over the exact residue string
        (no whitespace). Same sequence -> same ID, always."""
        if not residues or any(c.isspace() for c in residues):
            raise ValidationError("sequence must be non-empty with no whitespace")
        digest = hashlib.sha256(residues.encode("ascii")).hexdigest()
        return f"sequence:{digest}"

    def put_sequence(self, residues: str) -> str:
        node_id = self.sequence_node_id(residues)
        self.ensure_node(node_id, label=f"sequence[{len(residues)} aa]")
        self.db.execute(
            "INSERT OR IGNORE INTO sequences (sequence_id, residues, length, created_at) "
            "VALUES (?, ?, ?, ?)",
            (node_id, residues, len(residues), utc_now_iso()),
        )
        self.db.commit()
        return node_id

    # ---------------- edges ----------------

    def add_edge(
        self,
        source: str,
        relation: str,
        target: str,
        provenance: dict,
        label: str | None = None,
    ) -> tuple[str, bool]:
        """Validated, provenance-attached edge write through the Peel engine.

        Returns (edge_id, created). A duplicate triple returns the existing
        edge id with created=False and keeps the ORIGINAL provenance (first
        write wins; re-seeding is idempotent).
        """
        validate_edge(source, relation, target)
        provenance_json = validate_provenance(provenance)

        self.ensure_node(source)
        self.ensure_node(target)

        # The engine dedups by this exact hash; compute it to find the row id.
        # NOTE: the engine's _store_relation uses INSERT OR IGNORE and returns
        # True even when the row already existed — existence must be checked
        # HERE to keep first-write-wins provenance and idempotent re-seeding.
        rel_hash = hashlib.sha256(
            f"{source.lower()}||{relation}||{target.lower()}".encode()
        ).hexdigest()
        existing = self.db.execute(
            "SELECT id FROM typed_relations WHERE hash = ?", (rel_hash,)
        ).fetchone()
        if existing is not None:
            self.db.commit()  # the ensure_node writes above are still wanted
            return existing["id"], False

        self.engine._store_relation(
            Relation(
                subject=source,
                relation_type=relation,
                object=target,
                confidence=1.0,
                source_tile_id=f"provenance:{provenance['source']}",
                source_sentence=label or "",  # cosmetic only
                topic=_TOPIC,
            )
        )
        row = self.db.execute(
            "SELECT id FROM typed_relations WHERE hash = ?", (rel_hash,)
        ).fetchone()
        if row is None:  # engine refused silently — surface loudly, never mask
            self.db.rollback()
            raise ValidationError(
                f"engine did not store edge {source} -{relation}-> {target}"
            )
        edge_id = row["id"]
        self.db.execute(
            "INSERT INTO edge_provenance (edge_id, provenance_json, created_at) "
            "VALUES (?, ?, ?)",
            (edge_id, provenance_json, utc_now_iso()),
        )
        self.db.commit()
        return edge_id, True

    def get_edges(self, source: str | None = None, relation: str | None = None,
                  target: str | None = None) -> list[dict]:
        """Deterministically ordered edges with provenance attached."""
        clauses, params = [], []
        if source is not None:
            clauses.append("t.subject = ?"); params.append(source)
        if relation is not None:
            clauses.append("t.relation_type = ?"); params.append(relation)
        if target is not None:
            clauses.append("t.object = ?"); params.append(target)
        where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
        rows = self.db.execute(
            f"""
            SELECT t.id, t.subject, t.relation_type, t.object, t.confidence,
                   t.category, t.created_at, p.provenance_json
            FROM typed_relations t
            LEFT JOIN edge_provenance p ON p.edge_id = t.id
            {where}
            ORDER BY t.id
            """,
            params,
        ).fetchall()
        return [dict(r) for r in rows]

    # ---------------- claims ----------------

    def get_or_create_claim(self, subject: str, shape: str = CLAIM_SHAPE_STRUCTURAL) -> str:
        validate_node_id(subject)
        if not subject.startswith("protein:"):
            raise ValidationError(f"claim subject must be a protein node, got {subject!r}")
        row = self.db.execute(
            "SELECT claim_id FROM claims WHERE subject = ? AND shape = ?",
            (subject, shape),
        ).fetchone()
        if row:
            return row["claim_id"]
        claim_id = f"claim:{uuid.uuid4()}"
        validate_node_id(claim_id)
        self.ensure_node(claim_id, label=f"{shape} for {subject}")
        self.db.execute(
            "INSERT INTO claims (claim_id, subject, shape, created_at) VALUES (?, ?, ?, ?)",
            (claim_id, subject, shape, utc_now_iso()),
        )
        self.db.commit()
        return claim_id

    def get_claim(self, claim_id: str) -> dict | None:
        row = self.db.execute(
            "SELECT claim_id, subject, shape, created_at FROM claims WHERE claim_id = ?",
            (claim_id,),
        ).fetchone()
        return dict(row) if row else None

    def close(self) -> None:
        self.db.close()
