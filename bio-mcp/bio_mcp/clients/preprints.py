"""Preprint clients: arXiv (Atom API) and bioRxiv/medRxiv (REST).

arXiv:    https://export.arxiv.org/api/query  (Atom XML; ≤1 req/3 s politeness)
bioRxiv:  https://api.biorxiv.org/details/{server}/{doi}  and
          https://api.biorxiv.org/details/{server}/{start}/{end}/{cursor}
bioRxiv has no free-text search API — search goes through their details-by-DOI
endpoint; for discovery we say so honestly instead of scraping.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET

from ..citations import format_citation, source_record
from ..http import BioAPIError, BioHTTP

ARXIV_API = "https://export.arxiv.org/api/query"
BIORXIV_API = "https://api.biorxiv.org"
_ATOM = "{http://www.w3.org/2005/Atom}"


async def search_arxiv(http: BioHTTP, query: str, *, max_results: int = 20, category: str | None = None) -> dict:
    """arXiv Atom search. category e.g. 'q-bio' or 'q-bio.GN' scopes the query."""
    if not query.strip():
        raise ValueError("empty arXiv query")
    term = f"({query}) AND cat:{category}*" if category else query
    text = await http.get_text(
        ARXIV_API,
        params={
            "search_query": f"all:{term}",
            "max_results": min(max_results, 50),
            "sortBy": "relevance",
        },
    )
    try:
        root = ET.fromstring(text)
    except ET.ParseError as e:
        raise BioAPIError(f"unparseable arXiv Atom feed: {e}") from e

    papers = []
    for entry in root.findall(f"{_ATOM}entry"):
        raw_id = entry.findtext(f"{_ATOM}id") or ""
        arxiv_id = raw_id.rsplit("/abs/", 1)[-1]
        if not arxiv_id:
            continue
        title = " ".join((entry.findtext(f"{_ATOM}title") or "").split())
        summary = " ".join((entry.findtext(f"{_ATOM}summary") or "").split())
        authors = [a.findtext(f"{_ATOM}name") for a in entry.findall(f"{_ATOM}author") if a.findtext(f"{_ATOM}name")]
        published = (entry.findtext(f"{_ATOM}published") or "")[:10]
        doi = entry.findtext("{http://arxiv.org/schemas/atom}doi")
        ids = {"arxiv": arxiv_id, **({"doi": doi} if doi else {})}
        papers.append(
            {
                "arxiv_id": arxiv_id,
                "title": title,
                "abstract": summary,
                "authors": authors,
                "published": published,
                "doi": doi,
                "pdf_url": f"https://arxiv.org/pdf/{arxiv_id}",
                "citation": format_citation(authors=authors, title=title, venue="arXiv", year=published[:4] or None, ids=ids),
                "source": source_record("arxiv", arxiv_id),
            }
        )
    return {"query": query, "returned": len(papers), "papers": papers}


async def fetch_biorxiv_preprint(http: BioHTTP, doi: str, *, server: str = "biorxiv") -> dict:
    """Fetch bioRxiv/medRxiv preprint metadata by DOI (10.1101/...)."""
    server = server.lower()
    if server not in ("biorxiv", "medrxiv"):
        raise ValueError(f"server must be 'biorxiv' or 'medrxiv', got {server!r}")
    doi = doi.strip()
    if not doi.startswith("10.1101/"):
        raise ValueError(f"bioRxiv/medRxiv DOIs start with 10.1101/, got {doi!r}")
    data = await http.get_json(f"{BIORXIV_API}/details/{server}/{doi}")
    entries = data.get("collection", [])
    if not entries:
        raise BioAPIError(f"no {server} record for DOI {doi}", url=f"{BIORXIV_API}/details/{server}/{doi}")
    versions = []
    for e in entries:
        versions.append(
            {
                "version": e.get("version"),
                "title": e.get("title"),
                "authors": (e.get("authors") or "").split("; "),
                "date": e.get("date"),
                "category": e.get("category"),
                "abstract": e.get("abstract"),
                "published_journal_doi": e.get("published") if e.get("published") not in (None, "NA") else None,
            }
        )
    latest = versions[-1]
    suffix = doi.split("10.1101/", 1)[1]
    return {
        "doi": doi,
        "server": server,
        "latest": latest,
        "n_versions": len(versions),
        "peer_reviewed_version": latest["published_journal_doi"],
        "citation": format_citation(
            authors=latest["authors"],
            title=latest["title"] or "(untitled preprint)",
            venue=f"{server} (preprint, v{latest['version']})",
            year=(latest["date"] or "")[:4] or None,
            ids={"doi": doi},
        ),
        "source": source_record(server, suffix),
    }


async def recent_biorxiv(http: BioHTTP, *, server: str = "biorxiv", days: int = 7, category: str | None = None, max_results: int = 30) -> dict:
    """List recent preprints via the details/{server}/{start}/{end} window endpoint.

    Honest limitation: bioRxiv's public API has no keyword search; this is a
    date-window listing optionally filtered by category client-side.
    """
    from datetime import date, timedelta

    server = server.lower()
    if server not in ("biorxiv", "medrxiv"):
        raise ValueError(f"server must be 'biorxiv' or 'medrxiv', got {server!r}")
    end = date.today()
    start = end - timedelta(days=max(1, min(days, 30)))
    base = f"{BIORXIV_API}/details/{server}/{start.isoformat()}/{end.isoformat()}"
    want = category.lower() if category else None

    def _keep(e: dict) -> bool:
        if want and (e.get("category") or "").lower() != want:
            return False
        return (e.get("doi") or "").startswith("10.1101/")

    # The window endpoint pages OLDEST-first in fixed pages of 100, so cursor 0
    # is the stale start of the window. "Recent" must come from the tail: read
    # the total, then walk the last pages backwards until we have enough.
    first = await http.get_json(f"{base}/0")
    msg = (first.get("messages") or [{}])[0]
    try:
        total = int(msg.get("total") or 0)
    except (TypeError, ValueError):
        total = 0
    page = 100
    entries = list(first.get("collection") or [])
    if total > len(entries):
        entries = []
        cursor = ((total - 1) // page) * page
        for _ in range(5):  # bounded backwards walk: 500 newest entries max
            data = await http.get_json(f"{base}/{cursor}")
            entries = (data.get("collection") or []) + entries
            if cursor == 0 or sum(1 for e in entries if _keep(e)) >= max_results:
                break
            cursor -= page

    newest_first = sorted((e for e in entries if _keep(e)), key=lambda e: e.get("date") or "", reverse=True)
    out = [
        {
            "doi": e["doi"],
            "title": e.get("title"),
            "category": e.get("category"),
            "date": e.get("date"),
            "source": source_record(server, e["doi"].split("10.1101/", 1)[1]),
        }
        for e in newest_first[:max_results]
    ]
    return {
        "server": server,
        "window": f"{start.isoformat()}..{end.isoformat()}",
        "category_filter": category,
        "returned": len(out),
        "note": "bioRxiv API is date-window only (no keyword search); filter is client-side on category. Listed newest-first from the window tail.",
        "preprints": out,
    }
