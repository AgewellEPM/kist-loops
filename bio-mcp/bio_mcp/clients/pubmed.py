"""NCBI E-utilities client: PubMed search/abstracts, PMC open-access full text.

Endpoints: https://eutils.ncbi.nlm.nih.gov/entrez/eutils/{esearch,efetch,elink}.fcgi
Rate limiting + api_key injection live in bio_mcp.http.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET

from ..citations import format_citation, source_record
from ..http import BioAPIError, BioHTTP

EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"


async def search_pubmed(http: BioHTTP, query: str, *, max_results: int = 20, sort: str = "relevance") -> dict:
    """esearch → PMIDs, then efetch → abstracts. Returns citation-pinned records."""
    if not query.strip():
        raise ValueError("empty PubMed query")
    data = await http.get_json(
        f"{EUTILS}/esearch.fcgi",
        params={
            "db": "pubmed",
            "term": query,
            "retmax": min(max_results, 100),
            "sort": sort,
            "retmode": "json",
        },
    )
    result = data.get("esearchresult", {})
    pmids = result.get("idlist", [])
    total = int(result.get("count", 0))
    articles = await fetch_abstracts(http, pmids) if pmids else []
    return {"query": query, "total_matches": total, "returned": len(articles), "articles": articles}


async def fetch_abstracts(http: BioHTTP, pmids: list[str]) -> list[dict]:
    """efetch PubMed XML for up to 100 PMIDs → structured records with abstracts."""
    if not pmids:
        return []
    if len(pmids) > 100:
        raise ValueError(f"fetch_abstracts capped at 100 PMIDs per call, got {len(pmids)}")
    text = await http.get_text(
        f"{EUTILS}/efetch.fcgi",
        params={"db": "pubmed", "id": ",".join(pmids), "retmode": "xml"},
    )
    try:
        root = ET.fromstring(text)
    except ET.ParseError as e:
        raise BioAPIError(f"unparseable PubMed XML for PMIDs {pmids[:5]}...: {e}") from e

    articles = []
    for art in root.iter("PubmedArticle"):
        pmid = art.findtext(".//PMID")
        if not pmid:
            continue
        title = "".join((art.find(".//ArticleTitle") is not None and art.find(".//ArticleTitle").itertext()) or []) or "(no title)"
        abstract = "\n".join(
            ("" if not seg.get("Label") else f"{seg.get('Label')}: ") + "".join(seg.itertext())
            for seg in art.findall(".//Abstract/AbstractText")
        )
        authors = [
            f"{a.findtext('LastName', '')} {a.findtext('Initials', '')}".strip()
            for a in art.findall(".//AuthorList/Author")
            if a.findtext("LastName")
        ]
        journal = art.findtext(".//Journal/ISOAbbreviation") or art.findtext(".//Journal/Title")
        year = art.findtext(".//JournalIssue/PubDate/Year") or art.findtext(".//JournalIssue/PubDate/MedlineDate")
        doi = next(
            (el.text for el in art.findall(".//ArticleIdList/ArticleId") if el.get("IdType") == "doi" and el.text),
            None,
        )
        pmcid = next(
            (el.text for el in art.findall(".//ArticleIdList/ArticleId") if el.get("IdType") == "pmc" and el.text),
            None,
        )
        ids = {"pmid": pmid, **({"doi": doi} if doi else {})}
        articles.append(
            {
                "pmid": pmid,
                "title": title,
                "abstract": abstract or "(no abstract available)",
                "authors": authors,
                "journal": journal,
                "year": year,
                "doi": doi,
                "pmcid": pmcid,
                "citation": format_citation(authors=authors, title=title, venue=journal, year=year, ids=ids),
                "source": source_record("pubmed", pmid),
            }
        )
    return articles


async def fetch_pmc_fulltext(http: BioHTTP, pmcid: str, *, max_chars: int = 60_000) -> dict:
    """efetch PMC XML → plain-text full body for open-access articles.

    Not every PMC article exposes full text (publisher embargo); we say so
    explicitly rather than returning an empty string.
    """
    ident = pmcid.strip().upper()
    if not ident.startswith("PMC"):
        raise ValueError(f"expected a PMCID like 'PMC1234567', got {pmcid!r}")
    text = await http.get_text(
        f"{EUTILS}/efetch.fcgi",
        params={"db": "pmc", "id": ident, "retmode": "xml"},
    )
    try:
        root = ET.fromstring(text)
    except ET.ParseError as e:
        raise BioAPIError(f"unparseable PMC XML for {ident}: {e}") from e

    body = root.find(".//body")
    if body is None:
        return {
            "pmcid": ident,
            "full_text_available": False,
            "note": "PMC record has no machine-readable body (embargoed or publisher-restricted). Abstract-level access only.",
            "source": source_record("pmc", ident),
        }
    paragraphs = []
    for sec in body.iter():
        if sec.tag == "title" and sec.text:
            paragraphs.append(f"\n## {''.join(sec.itertext()).strip()}")
        elif sec.tag == "p":
            paragraphs.append("".join(sec.itertext()).strip())
    full = "\n\n".join(p for p in paragraphs if p)
    truncated = len(full) > max_chars
    return {
        "pmcid": ident,
        "full_text_available": True,
        "truncated": truncated,
        "text": full[:max_chars],
        "source": source_record("pmc", ident),
    }
