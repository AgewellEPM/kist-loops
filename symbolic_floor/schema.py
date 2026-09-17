"""Field-level validation: node IDs, the six relations, direction, provenance.

Everything here rejects loudly with ValidationError. A wrongly-directed edge is
a validation error, not a silent fix; an edge without provenance never reaches
the store. The reasoner never reads labels — these typed IDs are the contract.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone

ALLOWED_HOSTS = frozenset({
    "rest.uniprot.org",
    "data.rcsb.org",
    "alphafold.ebi.ac.uk",
    "files.rcsb.org",
    "www.ebi.ac.uk",
    "search.rcsb.org",
})

PROVENANCE_SOURCES = frozenset({"uniprot", "pdb", "alphafold", "manual"})

# UniProt accession (official regex), optional isoform suffix.
_UNIPROT_ACC = (
    r"(?:[OPQ][0-9][A-Z0-9]{3}[0-9]|[A-NR-Z][0-9](?:[A-Z][A-Z0-9]{2}[0-9]){1,2})"
    r"(?:-\d+)?"
)

# Slugged concept identifiers extracted from bio-site payloads (lowercase,
# underscore-joined; produced by slug()).
_SLUG = re.compile(r"^[a-z0-9][a-z0-9_.+-]{0,127}$")

# Node ID shape per prefix. structure: covers experimental PDB (4 alnum) and
# AlphaFold predicted entries (AF-<accession>-F<n>).
_NODE_SHAPES: dict[str, re.Pattern[str]] = {
    "protein":   re.compile(rf"^{_UNIPROT_ACC}$"),
    "structure": re.compile(r"^(?:[A-Z0-9]{4}|AF-[A-Z0-9]+(?:-\d+)?-F\d+)$"),
    "sequence":  re.compile(r"^[0-9a-f]{64}$"),
    "claim":     re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"),
    # gene: appears in the `encodes` relation. The brief's node list omits it;
    # DECISIONS.md records why it must still be a valid prefix.
    "gene":      re.compile(r"^[A-Za-z0-9_.:-]{1,128}$"),
    # Extraction concept nodes (slice 1.5 — the bio wiki-wheel analog).
    "organism":  _SLUG,
    "location":  _SLUG,
    "disease":   _SLUG,
    "domain":    _SLUG,
}

# relation -> (source prefix, target prefix). Directionality is FIXED.
# The slice-1 verification six:
CORE_RELATIONS: dict[str, tuple[str, str]] = {
    "encodes":            ("gene", "protein"),
    "has_sequence":       ("protein", "sequence"),
    "has_structure":      ("protein", "structure"),
    "predicts_structure": ("protein", "structure"),
    "supports_claim":     ("structure", "claim"),
    "conflicts_with":     ("structure", "claim"),
}

# Slice-1.5 extraction relations (DECISIONS.md #13). Every one maps onto a
# relation the vendored Peel engine ALREADY knows (located_in participates in
# the engine's own Rule-1 conflict checking; belongs_to/affects/has_part are
# native vocabulary) — extraction feeds the engine, it does not fork it.
EXTRACTION_RELATIONS: dict[str, tuple[str, str]] = {
    "belongs_to": ("protein", "organism"),   # organism of origin
    "located_in": ("protein", "location"),   # subcellular location
    "affects":    ("protein", "disease"),    # disease involvement (NOT causation)
    "has_part":   ("protein", "domain"),     # sequence domain/region
}

RELATION_DIRECTIONS: dict[str, tuple[str, str]] = {**CORE_RELATIONS, **EXTRACTION_RELATIONS}

ALLOWED_RELATIONS = frozenset(RELATION_DIRECTIONS)


def slug(text: str) -> str:
    """Deterministic concept slug: lowercase, runs of non-alphanumerics -> '_'.
    Raises if nothing identifier-like survives (never emit an empty node)."""
    s = re.sub(r"[^a-z0-9.+-]+", "_", (text or "").lower()).strip("_")
    if not s or not _SLUG.fullmatch(s):
        raise ValidationError(f"cannot slug {text!r} into a concept id")
    return s


class ValidationError(ValueError):
    """Raised for any schema violation. Nothing is written after this."""


def validate_node_id(node_id: str) -> str:
    """Return the node id if well-formed, else raise. IDs are typed:
    <prefix>:<shape-checked identifier>."""
    if not isinstance(node_id, str) or ":" not in node_id:
        raise ValidationError(f"node id must be '<type>:<id>', got {node_id!r}")
    prefix, _, ident = node_id.partition(":")
    shape = _NODE_SHAPES.get(prefix)
    if shape is None:
        raise ValidationError(
            f"unknown node type {prefix!r} in {node_id!r}; "
            f"allowed: {sorted(_NODE_SHAPES)}"
        )
    if not shape.fullmatch(ident):
        raise ValidationError(f"malformed {prefix} id: {node_id!r}")
    return node_id


def validate_edge(source: str, relation: str, target: str) -> None:
    """Relation allowlist + fixed direction + node shapes. Reject, never fix."""
    if relation not in RELATION_DIRECTIONS:
        raise ValidationError(
            f"unknown relation {relation!r}; allowed: {sorted(ALLOWED_RELATIONS)}"
        )
    validate_node_id(source)
    validate_node_id(target)
    want_src, want_dst = RELATION_DIRECTIONS[relation]
    src_prefix = source.partition(":")[0]
    dst_prefix = target.partition(":")[0]
    if (src_prefix, dst_prefix) != (want_src, want_dst):
        raise ValidationError(
            f"wrong direction for {relation}: expected {want_src}:* -> {want_dst}:*, "
            f"got {source} -> {target}"
        )


def validate_provenance(provenance: dict) -> str:
    """Validate the provenance object; return canonical JSON for storage.

    Required keys: source, url, retrieved_at, raw_id.
    - source must be one of PROVENANCE_SOURCES.
    - non-manual: url must be an https URL on an allowlisted host.
    - manual: url may be null, but raw_id must then hold a citation string.
    - retrieved_at must be timezone-aware UTC ISO-8601.
    """
    if not isinstance(provenance, dict):
        raise ValidationError(f"provenance must be a dict, got {type(provenance).__name__}")
    missing = {"source", "url", "retrieved_at", "raw_id"} - set(provenance)
    if missing:
        raise ValidationError(f"provenance missing required keys: {sorted(missing)}")

    source = provenance["source"]
    if source not in PROVENANCE_SOURCES:
        raise ValidationError(
            f"provenance.source must be one of {sorted(PROVENANCE_SOURCES)}, got {source!r}"
        )

    url = provenance["url"]
    raw_id = provenance["raw_id"]
    if source == "manual":
        if url is not None and not isinstance(url, str):
            raise ValidationError("manual provenance url must be a string or null")
        if not isinstance(raw_id, str) or not raw_id.strip():
            raise ValidationError("manual provenance requires raw_id to hold a citation string")
    else:
        if not isinstance(url, str) or not url.startswith("https://"):
            raise ValidationError(f"provenance.url must be an https URL, got {url!r}")
        host = url.removeprefix("https://").split("/", 1)[0].split(":", 1)[0]
        if host not in ALLOWED_HOSTS:
            raise ValidationError(f"provenance.url host {host!r} is not allowlisted")
        if not isinstance(raw_id, str) or not raw_id.strip():
            raise ValidationError("provenance.raw_id must be a non-empty string")

    retrieved_at = provenance["retrieved_at"]
    if not isinstance(retrieved_at, str):
        raise ValidationError("provenance.retrieved_at must be an ISO-8601 string")
    try:
        parsed = datetime.fromisoformat(retrieved_at.replace("Z", "+00:00"))
    except ValueError as e:
        raise ValidationError(f"provenance.retrieved_at not ISO-8601: {retrieved_at!r}") from e
    if parsed.tzinfo is None or parsed.utcoffset() != timezone.utc.utcoffset(None):
        raise ValidationError(
            f"provenance.retrieved_at must be timezone-aware UTC, got {retrieved_at!r}"
        )

    return json.dumps(provenance, sort_keys=True)


def utc_now_iso() -> str:
    """UTC ISO-8601 with Z suffix (the storage timestamp convention)."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
