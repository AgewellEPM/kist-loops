"""Scholarly citation graph: OpenAlex + Semantic Scholar.

OpenAlex:         https://api.openalex.org/works        (polite pool via mailto)
Semantic Scholar: https://api.semanticscholar.org/graph/v1/paper/...

Both expose the citation graph — who published what, who cited whom — with
stable identifiers (OpenAlex "W..." ids, S2 40-hex paperIds, DOIs). Every
record pins to `openalex` or `semanticscholar` via `source_record`.

Rate limits live in BioHTTP: OpenAlex is bucketed politely (mailto keeps us in
the fast pool); unauthenticated Semantic Scholar is aggressively throttled and
routinely 429s — we deliberately add NO retry logic here, because BioHTTP
already retries 429/5xx with backoff and then raises BioAPIError. Letting that
propagate is the correct behavior, not a bug.
"""

from __future__ import annotations

import re

from ..citations import source_record
from ..http import BioAPIError, BioHTTP
from ..pathseg import path_segment

OPENALEX = "https://api.openalex.org"
SEMANTIC_SCHOLAR = "https://api.semanticscholar.org/graph/v1"

# Canonical short OpenAlex WORK ids: "W" + ASCII digits (what remains after the
# "https://openalex.org/" prefix is stripped). Anything else must never reach
# source_record, where it would render a nonsense (double-URL) citation link.
_OPENALEX_WORK_ID_RE = re.compile(r"W[0-9]+")

# Sent on every OpenAlex request to stay in the polite (faster, more reliable)
# request pool. OpenAlex asks for a contact address rather than an API key.
OPENALEX_MAILTO = "bio-mcp@perslis.com"

# Fields requested from the Semantic Scholar graph API. S2 returns only what is
# explicitly asked for, so this list is the contract for the shapes below.
_S2_SEARCH_FIELDS = "title,year,abstract,citationCount,authors,externalIds,venue"
_S2_CITATION_FIELDS = "title,year,authors,externalIds"


def _strip_prefix(value: str | None, prefix: str) -> str | None:
    """Return `value` with a leading `prefix` removed (case-insensitive on the
    scheme), else `value` unchanged. Used to turn OpenAlex's full-URL ids/DOIs
    into the bare identifiers `source_record` expects (e.g.
    "https://openalex.org/W123" -> "W123", "https://doi.org/10.x" -> "10.x").
    """
    if value is None:
        return None
    if value.lower().startswith(prefix.lower()):
        return value[len(prefix):]
    return value


def _openalex_short_id(work: dict) -> str | None:
    """The short OpenAlex work id (e.g. "W2556159813"), stripped of the
    "https://openalex.org/" prefix. `source_record("openalex", ...)` builds the
    URL back from this short form, so we must NOT pass the full URL — and a
    non-canonical id (nothing to strip, or not W+digits) returns None rather
    than passing through to make a garbage citation URL."""
    short = _strip_prefix(work.get("id"), "https://openalex.org/")
    if short is None or not _OPENALEX_WORK_ID_RE.fullmatch(short):
        return None
    return short


def _openalex_doi(work: dict) -> str | None:
    """OpenAlex stores DOIs as full "https://doi.org/10.x" URLs; return the bare
    "10.x/..." form (or None)."""
    return _strip_prefix(work.get("doi"), "https://doi.org/")


def _openalex_authors(work: dict) -> list[str]:
    """Ordered list of author display names from OpenAlex `authorships`.

    `authorships` can be present-but-null, and rows can be null — skip those
    rather than crash the whole work.
    """
    names: list[str] = []
    for authorship in work.get("authorships") or []:
        if not isinstance(authorship, dict):
            continue
        name = (authorship.get("author") or {}).get("display_name")
        if name:
            names.append(name)
    return names


def _openalex_venue(work: dict) -> str | None:
    """Publication venue name. OpenAlex nests it under
    primary_location.source.display_name (the legacy top-level `host_venue`
    field is gone)."""
    source = (work.get("primary_location") or {}).get("source") or {}
    return source.get("display_name")


def _reconstruct_abstract(inverted_index: dict[str, list[int]] | None) -> str | None:
    """Rebuild plain-text abstract from OpenAlex's `abstract_inverted_index`.

    OpenAlex ships abstracts as an inverted index — a {word: [positions]} map,
    e.g. {"Despite": [0], "growing": [1], "interest": [2], ...} — for copyright
    reasons. To recover reading order we scatter each word into every position
    it occupies, then join in ascending position order. Missing/empty index
    (many records have no abstract) yields None rather than an empty string, so
    the caller can distinguish "no abstract" from "".
    """
    if not inverted_index or not isinstance(inverted_index, dict):
        return None
    # Place each token at all of its positions, then read left-to-right.
    # Malformed entries (null/string positions, non-int members) are skipped —
    # a broken index entry must not crash the whole work.
    positioned: list[tuple[int, str]] = []
    for word, positions in inverted_index.items():
        if not isinstance(positions, list):
            continue
        for pos in positions:
            if isinstance(pos, int):
                positioned.append((pos, word))
    if not positioned:
        return None
    positioned.sort(key=lambda pair: pair[0])
    return " ".join(word for _pos, word in positioned)


def _s2_authors(paper: dict) -> list[str]:
    """Author names from a Semantic Scholar paper object ({authorId, name}).

    `authors` can be present-but-null, and rows can be null — skip those.
    """
    return [
        a["name"]
        for a in (paper.get("authors") or [])
        if isinstance(a, dict) and a.get("name")
    ]


def _s2_doi(paper: dict) -> str | None:
    """Bare DOI from S2 `externalIds.DOI` (already prefix-free), else None."""
    return (paper.get("externalIds") or {}).get("DOI")


async def search_openalex(http: BioHTTP, query: str, *, max_results: int = 15) -> dict:
    """Search OpenAlex works (title/abstract/fulltext relevance).

    Returns {query, returned, works: [...]} where each work carries its short
    OpenAlex id, bibliographic metadata, author display names, and a pinned
    `source`. `max_results` is capped at OpenAlex's 200/page limit.
    """
    if not query.strip():
        raise ValueError("empty OpenAlex query")
    data = await http.get_json(
        f"{OPENALEX}/works",
        params={
            "search": query,
            "per-page": min(max_results, 200),
            "mailto": OPENALEX_MAILTO,  # polite pool — required by our rate-limit budget
        },
    )
    works = []
    for work in data.get("results") or []:  # `results` can be present-but-null
        short_id = _openalex_short_id(work)
        if not short_id:
            continue  # no stable id -> cannot pin a source -> skip (never emit unpinned)
        works.append(
            {
                "openalex_id": short_id,
                "title": work.get("title"),
                "publication_year": work.get("publication_year"),
                "doi": _openalex_doi(work),
                "cited_by_count": work.get("cited_by_count"),
                "authors": _openalex_authors(work),
                "venue": _openalex_venue(work),
                "source": source_record("openalex", short_id),
            }
        )
    return {"query": query, "returned": len(works), "works": works}


async def openalex_work(http: BioHTTP, work_id: str) -> dict:
    """Fetch a single OpenAlex work by id or DOI.

    `work_id` may be a short id ("W2741809807"), a DOI-qualified id
    ("doi:10.1038/nrn3241"), or a full DOI URL ("https://doi.org/10.1038/...").
    OpenAlex resolves all three at the /works/{id} path. Includes the
    reconstructed abstract (from `abstract_inverted_index`), referenced-works
    count, and top related concepts.
    """
    ident = work_id.strip()
    if not ident:
        raise ValueError("empty OpenAlex work id")
    # /works/{id} is a RESOLVER: "W...", "doi:10.1038/nrn3241", and full
    # "https://doi.org/..." URLs are all legitimate ids, so ':' and '/' are id
    # characters here — but a literal '/' would let '../' climb out of /works/
    # into a different OpenAlex entity family. OpenAlex resolves percent-encoded
    # ids identically (live-verified 2026-09-17: /works/doi:10.7717%2Fpeerj.4375
    # and the %2F-encoded https-URL form both → W2741809807), so we encode '/'
    # as well: safe=":" keeps only the scheme/qualifier colon literal, and
    # path_segment rejects non-printables outright.
    encoded = path_segment(ident, what="OpenAlex work id", safe=":")
    work = await http.get_json(f"{OPENALEX}/works/{encoded}", params={"mailto": OPENALEX_MAILTO})
    short_id = _openalex_short_id(work)
    if not short_id:
        raise BioAPIError(f"OpenAlex returned no work for {ident!r}")
    concepts = [
        {"name": c.get("display_name"), "score": c.get("score")}
        for c in (work.get("concepts") or [])
        if c.get("display_name")
    ]
    return {
        "openalex_id": short_id,
        "title": work.get("title"),
        "publication_year": work.get("publication_year"),
        "doi": _openalex_doi(work),
        "cited_by_count": work.get("cited_by_count"),
        "authors": _openalex_authors(work),
        "venue": _openalex_venue(work),
        "abstract": _reconstruct_abstract(work.get("abstract_inverted_index")),
        # OpenAlex exposes the count directly; the full `referenced_works` list
        # is large, so we surface the count (and let a caller drill in if needed).
        "referenced_works_count": work.get("referenced_works_count"),
        "related_concepts": concepts,
        "source": source_record("openalex", short_id),
    }


async def search_semantic_scholar(http: BioHTTP, query: str, *, max_results: int = 15) -> dict:
    """Search Semantic Scholar papers by relevance.

    Returns {query, returned, papers: [...]}. Unauthenticated S2 is heavily
    rate-limited and may 429 — BioHTTP retries then raises BioAPIError, which we
    let propagate (no swallow, no extra retry).
    """
    if not query.strip():
        raise ValueError("empty Semantic Scholar query")
    data = await http.get_json(
        f"{SEMANTIC_SCHOLAR}/paper/search",
        params={"query": query, "limit": min(max_results, 100), "fields": _S2_SEARCH_FIELDS},
    )
    papers = []
    for paper in data.get("data") or []:  # `data` can be present-but-null
        paper_id = paper.get("paperId")
        if not paper_id:
            continue  # no stable id -> cannot pin a source -> skip
        papers.append(
            {
                "paper_id": paper_id,
                "title": paper.get("title"),
                "year": paper.get("year"),
                # requested in _S2_SEARCH_FIELDS, so emit it (None when S2 has none)
                "abstract": paper.get("abstract"),
                "citation_count": paper.get("citationCount"),
                "authors": _s2_authors(paper),
                "venue": paper.get("venue"),
                "doi": _s2_doi(paper),
                "source": source_record("semanticscholar", paper_id),
            }
        )
    return {"query": query, "returned": len(papers), "papers": papers}


async def semantic_scholar_citations(http: BioHTTP, paper_id: str, *, max_results: int = 25) -> dict:
    """Papers that CITE the given paper (forward citation edges).

    `paper_id` may be an S2 id (40-hex) or a DOI-qualified id
    ("DOI:10.1038/nrn3241"). Returns {paper_id, returned, citing_papers: [...]}.
    Each citing paper is unwrapped from the S2 `citingPaper` envelope and pinned.
    Rate-limit 429s propagate as BioAPIError (see module docstring).
    """
    ident = paper_id.strip()
    if not ident:
        raise ValueError("empty Semantic Scholar paper id")
    # Qualified S2 ids ("DOI:10.1038/nrn3241", "ARXIV:...", "URL:https://...")
    # carry ':' and '/'. ':' must stay literal (safe=":"); '/' is percent-
    # encoded so '../' can never climb out of /paper/ — S2 resolves the encoded
    # form to the same paper (live-verified 2026-09-17: /paper/DOI:10.1038%2F
    # nrn3241 → da82f8e6...). path_segment also rejects non-printables, which
    # previously surfaced as an opaque httpx.InvalidURL crash.
    encoded = path_segment(ident, what="Semantic Scholar paper id", safe=":")
    data = await http.get_json(
        f"{SEMANTIC_SCHOLAR}/paper/{encoded}/citations",
        params={"limit": min(max_results, 1000), "fields": _S2_CITATION_FIELDS},
    )
    citing = []
    for edge in data.get("data") or []:  # `data` can be present-but-null
        # Each row wraps the citing paper under `citingPaper`; the row itself
        # can be null.
        paper = (edge or {}).get("citingPaper") or {}
        cid = paper.get("paperId")
        if not cid:
            continue  # citing paper lacks a stable id -> cannot pin -> skip
        citing.append(
            {
                "paper_id": cid,
                "title": paper.get("title"),
                "year": paper.get("year"),
                "authors": _s2_authors(paper),
                "doi": _s2_doi(paper),
                "source": source_record("semanticscholar", cid),
            }
        )
    return {"paper_id": ident, "returned": len(citing), "citing_papers": citing}
