"""Verification layer: every bio claim pins to an accession/PMID/DOI + resolvable URL.

The contract enforced across bio-mcp:
- Every tool result includes a `source` dict built by `source_record()`.
- A record without a resolvable URL is a bug, not a degraded answer —
  `source_record` raises rather than emitting an unpinned source.
- `format_citation` renders a consistent Vancouver-style string so answers
  cite identically across sessions (see docs/CITATION_STYLE.md).
"""

from __future__ import annotations

from datetime import date

# Canonical URL builders per database. Single source of truth — clients must
# not hand-roll citation URLs.
_URL_BUILDERS = {
    "pubmed": lambda i: f"https://pubmed.ncbi.nlm.nih.gov/{i}/",
    "pmc": lambda i: f"https://www.ncbi.nlm.nih.gov/pmc/articles/{i}/",
    "doi": lambda i: f"https://doi.org/{i}",
    "arxiv": lambda i: f"https://arxiv.org/abs/{i}",
    "biorxiv": lambda i: f"https://www.biorxiv.org/content/10.1101/{i}",
    "medrxiv": lambda i: f"https://www.medrxiv.org/content/10.1101/{i}",
    "uniprot": lambda i: f"https://www.uniprot.org/uniprotkb/{i}/entry",
    "pdb": lambda i: f"https://www.rcsb.org/structure/{i}",
    "nuccore": lambda i: f"https://www.ncbi.nlm.nih.gov/nuccore/{i}",
    "protein": lambda i: f"https://www.ncbi.nlm.nih.gov/protein/{i}",
    "gene": lambda i: f"https://www.ncbi.nlm.nih.gov/gene/{i}",
    "ensembl": lambda i: f"https://www.ensembl.org/id/{i}",
    "kegg": lambda i: f"https://www.kegg.jp/entry/{i}",
    "reactome": lambda i: f"https://reactome.org/content/detail/{i}",
}

SUPPORTED_DATABASES = sorted(_URL_BUILDERS)


class UnpinnedSourceError(ValueError):
    """A tool tried to emit a result without a verifiable identifier."""


def source_record(database: str, identifier: str, *, label: str | None = None) -> dict:
    """Build the mandatory `source` block for a tool result.

    database: one of SUPPORTED_DATABASES.
    identifier: the accession/PMID/DOI — must be non-empty.
    """
    db = database.lower()
    if db not in _URL_BUILDERS:
        raise UnpinnedSourceError(
            f"unknown database {database!r}; supported: {', '.join(SUPPORTED_DATABASES)}"
        )
    ident = (identifier or "").strip()
    if not ident:
        raise UnpinnedSourceError(f"empty identifier for database {database!r}")
    return {
        "database": db,
        "id": ident,
        "url": _URL_BUILDERS[db](ident),
        "retrieved": date.today().isoformat(),
        **({"label": label} if label else {}),
    }


def format_citation(
    *,
    authors: list[str] | None,
    title: str,
    venue: str | None,
    year: str | int | None,
    ids: dict[str, str],
) -> str:
    """Vancouver-style one-liner: Authors. Title. Venue. Year. IDs.

    ids: e.g. {"pmid": "12345", "doi": "10.1000/xyz"} — at least one required.
    """
    if not ids:
        raise UnpinnedSourceError(f"citation for {title!r} has no identifiers")
    auth = ""
    if authors:
        shown = ", ".join(authors[:6])
        auth = f"{shown}{', et al' if len(authors) > 6 else ''}. "
    parts = [f"{auth}{title.rstrip('.')}."]
    if venue:
        parts.append(f" {venue}.")
    if year:
        parts.append(f" {year}.")
    parts.append(" " + "; ".join(f"{k.upper()}: {v}" for k, v in sorted(ids.items())) + ".")
    return "".join(parts)
