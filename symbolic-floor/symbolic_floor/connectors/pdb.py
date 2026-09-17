"""PDB connector: accession -> UniProt PDB cross-reference -> confirmed
experimental entry -> has_structure edge.

Route (deterministic): UniProt entry JSON lists PDB cross-references; take the
FIRST one (their order), then confirm against RCSB that the entry exists and
carries a non-null experimental_method (EM counts as experimental). Discovery
comes from UniProt but the edge's provenance pins the RCSB confirmation fetch
(DECISIONS.md #6).
"""

from __future__ import annotations

import json

from ..schema import utc_now_iso, validate_node_id
from ..store import Store
from .base import ConnectorError, Transport, http_get
from .uniprot import fetch_entry_json

RCSB_ENTRY_URL = "https://data.rcsb.org/rest/v1/core/entry/{pdb_id}"


def fetch_experimental_structure(store: Store, accession: str, *,
                                 transport: Transport | None = None) -> dict:
    """Emit has_structure for the first confirmed experimental PDB entry.

    Returns status OK | NOT_FOUND (accession unknown to UniProt) |
    NO_EXPERIMENTAL_STRUCTURE (no usable PDB cross-reference). 404/absence
    writes NO edge.
    """
    fetched = fetch_entry_json(accession, transport=transport)
    acc = fetched["accession"]
    if fetched["status"] == "NOT_FOUND":
        return {"status": "NOT_FOUND", "accession": acc}
    entry = fetched["entry"]

    pdb_id = None
    for xref in entry.get("uniProtKBCrossReferences") or []:
        if isinstance(xref, dict) and xref.get("database") == "PDB" and xref.get("id"):
            pdb_id = str(xref["id"]).strip().upper()
            break
    if not pdb_id:
        return {"status": "NO_EXPERIMENTAL_STRUCTURE", "accession": acc}

    entry_url = RCSB_ENTRY_URL.format(pdb_id=pdb_id)
    status, body = http_get(entry_url, transport=transport)
    if status != 200:
        # The xref promised an entry RCSB won't confirm — no edge, honest signal.
        return {"status": "NO_EXPERIMENTAL_STRUCTURE", "accession": acc,
                "unconfirmed_pdb_id": pdb_id, "rcsb_status": status}
    try:
        rcsb = json.loads(body)
    except ValueError as e:
        raise ConnectorError(f"RCSB entry {pdb_id}: unparseable body") from e
    method = (rcsb.get("rcsb_entry_info") or {}).get("experimental_method")
    if method is None:
        # Key absent/None -> cannot confirm the entry is experimental.
        return {"status": "NO_EXPERIMENTAL_STRUCTURE", "accession": acc,
                "unconfirmed_pdb_id": pdb_id, "reason": "experimental_method missing"}

    edge_id, created = store.add_edge(
        f"protein:{acc}",
        "has_structure",
        f"structure:{pdb_id}",
        provenance={
            "source": "pdb",
            "url": entry_url,
            "retrieved_at": utc_now_iso(),
            "raw_id": pdb_id,
        },
        label=f"{pdb_id} experimental structure ({method})",
    )
    return {"status": "OK", "edge_id": edge_id, "pdb_id": pdb_id,
            "experimental_method": method, "created": created, "accession": acc}
