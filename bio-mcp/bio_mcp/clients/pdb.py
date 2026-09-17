"""RCSB PDB client: full-text structure search + entry metadata.

Search:  https://search.rcsb.org/rcsbsearch/v2/query (POST-style JSON via GET param)
Entry:   https://data.rcsb.org/rest/v1/core/entry/{pdb_id}
"""

from __future__ import annotations

import json

from ..citations import source_record
from ..http import BioAPIError, BioHTTP

RCSB_SEARCH = "https://search.rcsb.org/rcsbsearch/v2/query"
RCSB_DATA = "https://data.rcsb.org/rest/v1/core/entry"


async def search_pdb(http: BioHTTP, query: str, *, max_results: int = 15) -> dict:
    """Full-text search over RCSB PDB. Returns PDB IDs with relevance scores."""
    if not query.strip():
        raise ValueError("empty PDB query")
    payload = {
        "query": {
            "type": "terminal",
            "service": "full_text",
            "parameters": {"value": query},
        },
        "return_type": "entry",
        "request_options": {"paginate": {"start": 0, "rows": min(max_results, 50)}},
    }
    data = await http.get_json(RCSB_SEARCH, params={"json": json.dumps(payload)})
    hits = [
        {
            "pdb_id": h["identifier"],
            "score": round(h.get("score", 0.0), 3),
            "source": source_record("pdb", h["identifier"]),
        }
        for h in data.get("result_set", [])
        if h.get("identifier")
    ]
    return {"query": query, "total_matches": data.get("total_count", len(hits)), "returned": len(hits), "structures": hits}


async def fetch_pdb_entry(http: BioHTTP, pdb_id: str) -> dict:
    """Entry metadata: title, method, resolution, organisms, citation, download URLs."""
    ident = pdb_id.strip().upper()
    if len(ident) != 4:
        raise ValueError(f"PDB IDs are 4 characters (e.g. 6VXX), got {pdb_id!r}")
    entry = await http.get_json(f"{RCSB_DATA}/{ident}")
    if not entry.get("rcsb_id"):
        raise BioAPIError(f"RCSB returned no entry for {ident}")

    info = entry.get("rcsb_entry_info", {})
    # rcsb_primary_citation carries the PMID; the citation[] list often omits it.
    citation = entry.get("rcsb_primary_citation") or next(iter(entry.get("citation", [])), {})
    return {
        "pdb_id": ident,
        "title": entry.get("struct", {}).get("title"),
        "experimental_method": (info.get("experimental_method") or "").strip() or None,
        "resolution_angstrom": (info.get("resolution_combined") or [None])[0],
        "deposited": entry.get("rcsb_accession_info", {}).get("deposit_date", "")[:10] or None,
        "polymer_entity_count": info.get("polymer_entity_count_total"),
        "molecular_weight_kda": info.get("molecular_weight"),
        "primary_citation": {
            "title": citation.get("title"),
            "journal": citation.get("rcsb_journal_abbrev"),
            "year": citation.get("year"),
            # RCSB's exact key casing: ..._DOI / ..._PubMed (PubMed value is an int)
            "doi": citation.get("pdbx_database_id_DOI"),
            "pmid": str(citation["pdbx_database_id_PubMed"]) if citation.get("pdbx_database_id_PubMed") else None,
        },
        "download": {
            "pdb": f"https://files.rcsb.org/download/{ident}.pdb",
            "cif": f"https://files.rcsb.org/download/{ident}.cif",
        },
        "source": source_record("pdb", ident),
    }
