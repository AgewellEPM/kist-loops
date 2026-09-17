"""Pathway knowledge: KEGG REST + Reactome ContentService.

KEGG:     https://rest.kegg.jp/{find,get}/...   (flat-text protocol)
Reactome: https://reactome.org/ContentService/search/query
"""

from __future__ import annotations

from ..citations import source_record
from ..http import BioAPIError, BioHTTP

KEGG = "https://rest.kegg.jp"
REACTOME = "https://reactome.org/ContentService"


async def search_kegg(http: BioHTTP, query: str, *, database: str = "pathway", max_results: int = 20) -> dict:
    """KEGG find: pathway | ko | genes | compound | enzyme | disease | drug."""
    allowed = ("pathway", "ko", "genes", "compound", "enzyme", "disease", "drug", "module")
    if database not in allowed:
        raise ValueError(f"database must be one of {allowed}, got {database!r}")
    if not query.strip():
        raise ValueError("empty KEGG query")
    text = await http.get_text(f"{KEGG}/find/{database}/{query}")
    hits = []
    for line in text.strip().splitlines():
        if not line.strip():
            continue
        ident, _, desc = line.partition("\t")
        ident = ident.strip()
        hits.append({"kegg_id": ident, "description": desc.strip(), "source": source_record("kegg", ident)})
        if len(hits) >= max_results:
            break
    return {"query": query, "database": database, "returned": len(hits), "entries": hits}


async def fetch_kegg_entry(http: BioHTTP, kegg_id: str, *, max_chars: int = 30_000) -> dict:
    """KEGG get: full flat-file entry (pathway maps, gene lists, orthology...)."""
    ident = kegg_id.strip()
    if not ident:
        raise ValueError("empty KEGG ID")
    text = await http.get_text(f"{KEGG}/get/{ident}")
    if not text.strip():
        raise BioAPIError(f"KEGG returned empty entry for {ident}")
    # Parse the NAME/DESCRIPTION headers out of the flat file for convenience.
    name = None
    for line in text.splitlines():
        if line.startswith("NAME"):
            name = line[4:].strip()
            break
    return {
        "kegg_id": ident,
        "name": name,
        "truncated": len(text) > max_chars,
        "entry_text": text[:max_chars],
        "source": source_record("kegg", ident),
    }


async def search_reactome(http: BioHTTP, query: str, *, species: str = "Homo sapiens", max_results: int = 15) -> dict:
    """Reactome search: pathways/reactions/proteins with stable IDs."""
    if not query.strip():
        raise ValueError("empty Reactome query")
    data = await http.get_json(
        f"{REACTOME}/search/query",
        params={"query": query, "species": species, "cluster": "true"},
    )
    hits = []
    for group in data.get("results", []):
        for e in group.get("entries", []):
            st_id = e.get("stId")
            if not st_id:
                continue
            hits.append(
                {
                    "stable_id": st_id,
                    "name": (e.get("name") or "").replace("<span class='highlighting' >", "").replace("</span>", ""),
                    "type": e.get("exactType") or group.get("typeName"),
                    "species": e.get("species"),
                    "source": source_record("reactome", st_id),
                }
            )
            if len(hits) >= max_results:
                return {"query": query, "species": species, "returned": len(hits), "entries": hits}
    return {"query": query, "species": species, "returned": len(hits), "entries": hits}
