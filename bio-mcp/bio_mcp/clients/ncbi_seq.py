"""NCBI sequence access: GenBank/Nucleotide + Protein via E-utilities efetch.

Returns FASTA or GenBank flat-file text pinned to accession IDs, and can save
to the bio-mcp workspace so run_python analyses can pick files up directly.
"""

from __future__ import annotations

from pathlib import Path

from ..citations import source_record
from ..http import BioAPIError, BioHTTP

EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"

_DBS = ("nuccore", "protein")
_FORMATS = {"fasta": "fasta", "genbank": "gb"}
MAX_INLINE_CHARS = 200_000  # sequences longer than this must go to a file


async def fetch_sequence(
    http: BioHTTP,
    accession: str,
    *,
    db: str = "nuccore",
    fmt: str = "fasta",
    save_path: str | None = None,
) -> dict:
    """efetch one accession as FASTA or GenBank text.

    save_path: optional absolute path (or path under the workspace) to write
    the record to; required when the record exceeds MAX_INLINE_CHARS.
    """
    acc = accession.strip()
    if not acc:
        raise ValueError("empty accession")
    if db not in _DBS:
        raise ValueError(f"db must be one of {_DBS}, got {db!r}")
    if fmt not in _FORMATS:
        raise ValueError(f"fmt must be one of {sorted(_FORMATS)}, got {fmt!r}")

    text = await http.get_text(
        f"{EUTILS}/efetch.fcgi",
        params={"db": db, "id": acc, "rettype": _FORMATS[fmt], "retmode": "text"},
    )
    text = text.strip()
    if not text or text.lower().startswith("error"):
        raise BioAPIError(f"NCBI {db} returned no record for {acc!r}: {text[:200]}")

    result: dict = {
        "accession": acc,
        "db": db,
        "format": fmt,
        "chars": len(text),
        "source": source_record(db, acc),
    }
    if save_path:
        p = Path(save_path).expanduser()
        if not p.is_absolute():
            raise ValueError(f"save_path must be absolute, got {save_path!r}")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text + "\n")
        result["saved_to"] = str(p)
        result["preview"] = text[:500]
    elif len(text) > MAX_INLINE_CHARS:
        raise ValueError(
            f"record for {acc} is {len(text):,} chars (> {MAX_INLINE_CHARS:,}); "
            "pass save_path to write it to a file instead of inlining"
        )
    else:
        result["text"] = text
    return result


async def search_ncbi_sequences(http: BioHTTP, query: str, *, db: str = "nuccore", max_results: int = 20) -> dict:
    """esearch + esummary over nuccore/protein → accession-pinned hit list."""
    if not query.strip():
        raise ValueError("empty sequence-search query")
    if db not in _DBS:
        raise ValueError(f"db must be one of {_DBS}, got {db!r}")
    data = await http.get_json(
        f"{EUTILS}/esearch.fcgi",
        params={"db": db, "term": query, "retmax": min(max_results, 50), "retmode": "json"},
    )
    result = data.get("esearchresult", {})
    uids = result.get("idlist", [])
    hits = []
    if uids:
        summaries = await http.get_json(
            f"{EUTILS}/esummary.fcgi",
            params={"db": db, "id": ",".join(uids), "retmode": "json"},
        )
        for uid in uids:
            doc = summaries.get("result", {}).get(uid, {})
            acc = doc.get("accessionversion") or doc.get("caption")
            if not acc:
                continue
            hits.append(
                {
                    "accession": acc,
                    "title": doc.get("title"),
                    "organism": doc.get("organism"),
                    "length": doc.get("slen"),
                    "source": source_record(db, acc),
                }
            )
    return {"query": query, "db": db, "total_matches": int(result.get("count", 0)), "returned": len(hits), "records": hits}
