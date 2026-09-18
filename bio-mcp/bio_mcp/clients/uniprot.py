"""UniProtKB client (rest.uniprot.org): protein search and accession-pinned entries."""

from __future__ import annotations

from ..citations import source_record
from ..http import BioAPIError, BioHTTP
from ..pathseg import path_segment

UNIPROT = "https://rest.uniprot.org/uniprotkb"

_SEARCH_FIELDS = "accession,id,protein_name,gene_names,organism_name,length,reviewed"
_ENTRY_FIELDS = (
    "accession,id,protein_name,gene_names,organism_name,length,sequence,"
    "cc_function,cc_subcellular_location,cc_disease,ft_domain,xref_pdb,reviewed"
)


# UniProt JSON distinguishes missing keys from present-but-null values; every
# accessor below guards BOTH (`or {}` / `or []`), so a null field degrades to
# "absent" instead of crashing.


def _protein_name(entry: dict) -> str | None:
    desc = entry.get("proteinDescription") or {}
    rec = desc.get("recommendedName") or (desc.get("submissionNames") or [{}])[0] or {}
    return (rec.get("fullName") or {}).get("value")


def _genes(entry: dict) -> list[str]:
    return [
        g["geneName"]["value"]
        for g in entry.get("genes") or []
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
                "organism": (entry.get("organism") or {}).get("scientificName"),
                "length": (entry.get("sequence") or {}).get("length"),
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
    # Encode the accession so a crafted value ("P04637/../../uniparc/X") can't
    # escape /uniprotkb; isoform accessions ("P04637-2") pass through unchanged.
    entry = await http.get_json(
        f"{UNIPROT}/{path_segment(acc, what='UniProt accession')}",
        params={"fields": _ENTRY_FIELDS, "format": "json"},
    )
    if entry.get("primaryAccession") is None:
        raise BioAPIError(f"UniProt returned no entry for {acc}")

    def _comments(ctype: str) -> list[str]:
        out = []
        for c in entry.get("comments") or []:
            if c.get("commentType") != ctype:
                continue
            for t in c.get("texts") or []:
                if t.get("value"):
                    out.append(t["value"])
            disease = c.get("disease") or {}
            if ctype == "DISEASE" and disease.get("description"):
                out.append(f"{disease.get('diseaseId', '')}: {disease['description']}")
        return out

    domains = [
        {
            "description": f.get("description"),
            "start": ((f.get("location") or {}).get("start") or {}).get("value"),
            "end": ((f.get("location") or {}).get("end") or {}).get("value"),
        }
        for f in entry.get("features") or []
        if f.get("type") == "Domain"
    ]
    pdb_ids = [
        x.get("id")
        for x in entry.get("uniProtKBCrossReferences") or []
        if x.get("database") == "PDB" and x.get("id")
    ]
    seq = entry.get("sequence") or {}
    return {
        "accession": entry["primaryAccession"],
        "entry_name": entry.get("uniProtkbId"),
        "protein_name": _protein_name(entry),
        "genes": _genes(entry),
        "organism": (entry.get("organism") or {}).get("scientificName"),
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
