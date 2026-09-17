"""Connection + migrations for the floor DB.

One SQLite file holds BOTH the project tables (schema.sql: nodes, sequences,
claims, edge_provenance, meta) AND the vendored Peel engine's own tables
(typed_relations, contradictions, inferred_links — created by
RelationSchemaEngine._ensure_tables). The engine's connection is THE connection
for all writes so provenance and facts commit atomically together.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

from .peel.floor import open_engine
from .peel.relation_schema import RelationSchemaEngine

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SCHEMA_SQL = PROJECT_ROOT / "schema.sql"
DEFAULT_DB = PROJECT_ROOT / "data" / "bio_floor.db"

SCHEMA_VERSION = "1"


class SchemaVersionError(RuntimeError):
    """The on-disk DB reports a schema version this code doesn't speak."""


def open_floor_db(db_path: str | Path | None = None) -> RelationSchemaEngine:
    """Open (creating/migrating if needed) the floor DB via the Peel engine.

    Returns the engine; engine.db is the shared sqlite3 connection with
    row_factory=Row. Project DDL is applied idempotently from schema.sql.
    """
    path = Path(db_path) if db_path is not None else DEFAULT_DB
    path.parent.mkdir(parents=True, exist_ok=True)

    engine = open_engine(path)  # registers bio relations + engine DDL
    ddl = SCHEMA_SQL.read_text()
    engine.db.executescript(ddl)
    engine.db.commit()

    row = engine.db.execute(
        "SELECT value FROM meta WHERE key = 'schema_version'"
    ).fetchone()
    found = row["value"] if row else None
    if found != SCHEMA_VERSION:
        raise SchemaVersionError(
            f"floor DB at {path} has schema_version={found!r}; this code speaks {SCHEMA_VERSION!r}"
        )
    return engine


def connect_readonly(db_path: str | Path) -> sqlite3.Connection:
    """Read-only connection for verification/reporting paths."""
    path = Path(db_path).resolve()
    conn = sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA query_only = ON")
    return conn
