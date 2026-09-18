"""NCBI sequence access: GenBank/Nucleotide + Protein via E-utilities efetch.

Returns FASTA or GenBank flat-file text pinned to accession IDs, and can save
to the bio-mcp workspace so run_python analyses can pick files up directly.
"""

from __future__ import annotations

from pathlib import Path

from ..citations import source_record
from ..http import BioAPIError, BioHTTP, BioOversizeError

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
    dest: Path | None = None
    if save_path:  # validate BEFORE fetching — never download just to reject the path
        dest = Path(save_path).expanduser()
        if not dest.is_absolute():
            raise ValueError(f"save_path must be absolute, got {save_path!r}")
        if dest.is_dir():
            raise ValueError(f"save_path is a directory: {save_path!r}")

    params = {"db": db, "id": acc, "rettype": _FORMATS[fmt], "retmode": "text"}
    if dest is not None:
        text = (await http.get_text(f"{EUTILS}/efetch.fcgi", params=params)).strip()
    else:
        try:
            # Stream with an early abort: a chromosome-scale record must not be
            # buffered for a minute just to be refused at the end.
            text = (
                await http.get_text_capped(
                    f"{EUTILS}/efetch.fcgi", params=params, max_bytes=MAX_INLINE_CHARS + 1024
                )
            ).strip()
        except BioOversizeError as e:
            raise ValueError(
                f"record for {acc} exceeds the {MAX_INLINE_CHARS:,}-char inline cap; "
                "pass save_path (absolute) to write it to a file instead"
            ) from e
    # Positive head check: efetch failures often arrive as HTTP 200 bodies
    # ("Error: ...", XML <ERROR>, HTML maintenance pages) — only a well-formed
    # record head proves we actually got sequence text.
    head_ok = text.startswith(">") if fmt == "fasta" else "LOCUS" in text[:200]
    if not head_ok:
        raise BioAPIError(f"NCBI {db} returned no usable {fmt} record for {acc!r}: {text[:200] or '(empty body)'}")

    result: dict = {
        "accession": acc,
        "db": db,
        "format": fmt,
        "chars": len(text),
        "source": source_record(db, acc),
    }
    if dest is not None:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text + "\n")
        result["saved_to"] = str(dest)
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
        by_uid = summaries.get("result") or {}
        if not by_uid:
            # esearch said the uids exist; a missing/empty esummary result block
            # is an upstream fault, not "zero matches".
            raise BioAPIError(
                f"NCBI esummary returned no result block for {len(uids)} {db} uids (esearch total {result.get('count')})"
            )
        for uid in uids:
            doc = by_uid.get(uid, {})
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
