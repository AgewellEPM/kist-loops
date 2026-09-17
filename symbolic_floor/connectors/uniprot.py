"""UniProt connector: accession -> canonical sequence -> has_sequence edge."""

from __future__ import annotations

import re

from ..schema import ValidationError, utc_now_iso, validate_node_id
from ..store import Store
from .base import ConnectorError, Transport, http_get

FASTA_URL = "https://rest.uniprot.org/uniprotkb/{accession}.fasta"

# One-letter amino-acid alphabet incl. extended codes (U=Sec, O=Pyl, B/Z/X ambiguity).
_RESIDUES = re.compile(r"^[ACDEFGHIKLMNPQRSTVWYUOBZX]+$")


def fetch_sequence(store: Store, accession: str, *, transport: Transport | None = None) -> dict:
    """GET the FASTA, store the content-addressed sequence, emit has_sequence.

    Returns {"status": "OK", "edge_id", "sequence_id", "created"} or
    {"status": "NOT_FOUND"} (404 -> NO edge is written).
    """
    acc = accession.strip().upper()
    validate_node_id(f"protein:{acc}")  # reject malformed before any I/O

    url = FASTA_URL.format(accession=acc)
    status, body = http_get(url, transport=transport)
    if status == 404:
        return {"status": "NOT_FOUND", "accession": acc}
    if status != 200:
        raise ConnectorError(f"UniProt FASTA for {acc}: unexpected HTTP {status}")

    text = body.decode("utf-8", errors="strict").strip()
    if not text:
        # Live UniProt answers a well-formed but NONEXISTENT accession's .fasta
        # with HTTP 200 and an empty body (not 404). Empty == no record.
        return {"status": "NOT_FOUND", "accession": acc}
    if not text.startswith(">"):
        raise ConnectorError(f"UniProt FASTA for {acc}: body is not FASTA: {text[:80]!r}")
    residues = "".join(line.strip() for line in text.splitlines()[1:])
    if not residues or not _RESIDUES.fullmatch(residues):
        raise ConnectorError(f"UniProt FASTA for {acc}: malformed sequence body")

    sequence_id = store.put_sequence(residues)
    edge_id, created = store.add_edge(
        f"protein:{acc}",
        "has_sequence",
        sequence_id,
        provenance={
            "source": "uniprot",
            "url": url,
            "retrieved_at": utc_now_iso(),
            "raw_id": acc,
        },
        label=f"{acc} canonical sequence ({len(residues)} aa)",
    )
    return {"status": "OK", "edge_id": edge_id, "sequence_id": sequence_id,
            "created": created, "accession": acc}
