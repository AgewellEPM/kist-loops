"""UniProtKB client (rest.uniprot.org): protein search and accession-pinned entries."""

from __future__ import annotations

from ..citations import source_record
from ..http import BioAPIError, BioHTTP

UNIPROT = "https://rest.uniprot.org/uniprotkb"

_SEARCH_FIELDS = "accession,id,protein_name,gene_names,organism_name,length,reviewed"
_ENTRY_FIELDS = (
    "accession,id,protein_name,gene_names,organism_name,length,sequence,"
    "cc_function,cc_subcellular_location,cc_disease,ft_domain,xref_pdb,reviewed"
)


def _protein_name(entry: dict) -> str | None:
    desc = entry.get("proteinDescription", {})
    rec = desc.get("recommendedName") or (desc.get("submissionNames") or [{}])[0]
    return (rec.get("fullName") or {}).get("value")


def _genes(entry: dict) -> list[str]:
    return [
        g["geneName"]["value"]
        for g in entry.get("genes", [])
        if g.get("geneName", {}).get("value")
    ]


async def search_uniprot(http: BioHTTP, query: str, *, max_results: int = 15, reviewed_only: bool = True) -> dict:
    """Search UniProtKB. reviewed_only=True restricts to Swiss-Prot (curated)."""
    if not query.strip():
        raise ValueError("empty UniProt query")
    q = f"({query}) AND (reviewed:true)" if reviewed_only else query
    data = await http.get_json(
        f"{UNIPROT}/search",
        params={"query": q, "fields": _SEARCH_FIELDS, "size": min(max_results, 50), "format": "json"},
    )
    hits = []
    for entry in data.get("results", []):
        acc = entry.get("primaryAccession")
        if not acc:
            continue
        hits.append(
            {
                "accession": acc,
                "entry_name": entry.get("uniProtkbId"),
                "protein_name": _protein_name(entry),
                "genes": _genes(entry),
                "organism": entry.get("organism", {}).get("scientificName"),
                "length": entry.get("sequence", {}).get("length"),
                "reviewed": entry.get("entryType") == "UniProtKB reviewed (Swiss-Prot)",
                "source": source_record("uniprot", acc),
            }
        )
    return {"query": query, "reviewed_only": reviewed_only, "returned": len(hits), "proteins": hits}


async def fetch_uniprot_entry(http: BioHTTP, accession: str, *, include_sequence: bool = True) -> dict:
    """Full entry for one accession: function, localization, disease, domains, PDB xrefs."""
    acc = accession.strip().upper()
    if not acc:
        raise ValueError("empty UniProt accession")
    entry = await http.get_json(f"{UNIPROT}/{acc}", params={"fields": _ENTRY_FIELDS, "format": "json"})
    if entry.get("primaryAccession") is None:
        raise BioAPIError(f"UniProt returned no entry for {acc}")

    def _comments(ctype: str) -> list[str]:
        out = []
        for c in entry.get("comments", []):
            if c.get("commentType") != ctype:
                continue
            for t in c.get("texts", []):
                if t.get("value"):
                    out.append(t["value"])
            if ctype == "DISEASE" and c.get("disease", {}).get("description"):
                out.append(f"{c['disease'].get('diseaseId', '')}: {c['disease']['description']}")
        return out

    domains = [
        {
            "description": f.get("description"),
            "start": f.get("location", {}).get("start", {}).get("value"),
            "end": f.get("location", {}).get("end", {}).get("value"),
        }
        for f in entry.get("features", [])
        if f.get("type") == "Domain"
    ]
    pdb_ids = [x["id"] for x in entry.get("uniProtKBCrossReferences", []) if x.get("database") == "PDB"]
    seq = entry.get("sequence", {})
    return {
        "accession": entry["primaryAccession"],
        "entry_name": entry.get("uniProtkbId"),
        "protein_name": _protein_name(entry),
        "genes": _genes(entry),
        "organism": entry.get("organism", {}).get("scientificName"),
        "reviewed": entry.get("entryType") == "UniProtKB reviewed (Swiss-Prot)",
        "function": _comments("FUNCTION"),
        "subcellular_location": _comments("SUBCELLULAR LOCATION"),
        "disease": _comments("DISEASE"),
        "domains": domains,
        "pdb_structures": pdb_ids,
        "length": seq.get("length"),
        **({"sequence": seq.get("value")} if include_sequence else {}),
        "source": source_record("uniprot", entry["primaryAccession"]),
    }
