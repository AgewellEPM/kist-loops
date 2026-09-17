"""Predicted structure + protein domain/family clients (EBI hosts).

Two EBI resources, both keyless:

- AlphaFold DB: https://alphafold.ebi.ac.uk/api/prediction/{accession}
  Predicted 3D models for a UniProt accession. The endpoint returns a JSON
  *list* of prediction objects (one per fragment/segment — long proteins and
  some entries split into several, so the list is not always length 1).
- InterPro:     https://www.ebi.ac.uk/interpro/api/...
  Signature-integrated protein families, domains, and sites. Its protein
  lookup is paginated (top-level `count` + `next`) and — importantly — answers
  a valid protein with no matches using HTTP 204 (empty body), which we must
  report as returned=0 rather than an error.

Every record carries a `source` block from `citations.source_record` keyed
"alphafold" or "interpro"; a result without a resolvable source is a bug.
"""

from __future__ import annotations

import re

from ..citations import source_record
from ..http import BioAPIError, BioHTTP

ALPHAFOLD = "https://alphafold.ebi.ac.uk/api/prediction"
INTERPRO = "https://www.ebi.ac.uk/interpro/api/entry/interpro"

# InterPro accessions are the literal string "IPR" followed by six digits
# (e.g. IPR002117). We validate against this before spending a request.
_IPR_RE = re.compile(r"^IPR\d{6}$")

# Strip any HTML tags out of InterPro description prose. Descriptions arrive as
# a list of {text: "<p>...</p>", ...} fragments; the text is lightly marked up
# (<p>, <cite>, ...) and also carries reference tokens. Those tokens come in a
# single form ("[[cite:PUB00059264]]") and a grouped form
# ("[[cite:PUBa], [cite:PUBb], [cite:PUBc]]") — the grouped form contains inner
# single brackets, so we match "[[ ... ]]" lazily, forbidding the closing "]]"
# from appearing inside, rather than "no ] at all".
_TAG_RE = re.compile(r"<[^>]+>")
_CITE_TOKEN_RE = re.compile(r"\[\[(?:(?!\]\]).)*?cite:(?:(?!\]\]).)*?\]\]")


def _clean_description(fragments: object) -> str | None:
    """Flatten InterPro's description (a list of ``{"text": "<p>..."}`` dicts)
    into one plain-text string, stripping HTML tags and [[cite:...]] tokens.

    Returns None when there is no usable prose so callers can distinguish
    "no description" from "empty string".
    """
    if not isinstance(fragments, list):
        return None
    texts: list[str] = []
    for frag in fragments:
        raw = frag.get("text") if isinstance(frag, dict) else frag
        if not isinstance(raw, str):
            continue
        stripped = _CITE_TOKEN_RE.sub("", _TAG_RE.sub("", raw)).strip()
        if stripped:
            texts.append(stripped)
    return " ".join(texts) if texts else None


def _ipr_name(name: object) -> str | None:
    """InterPro's ``metadata.name`` is either a plain string or a
    ``{"name": ..., "short": ...}`` dict depending on the endpoint; normalize
    both to the human-readable long name."""
    if isinstance(name, dict):
        return name.get("name") or name.get("short")
    return name if isinstance(name, str) else None


async def alphafold_prediction(http: BioHTTP, uniprot_accession: str) -> dict:
    """AlphaFold DB predicted structure(s) for one UniProt accession.

    The endpoint returns a JSON list of prediction objects; we surface the
    first (the primary model) in detail and report how many exist via
    `model_count`. An empty list means AlphaFold has no model for the
    accession — raised as BioAPIError, since the caller asked for a structure
    that does not exist. A malformed accession is rejected by AlphaFold with
    HTTP 400, which the shared client already turns into a BioAPIError.
    """
    acc = uniprot_accession.strip().upper()
    if not acc:
        raise ValueError("empty UniProt accession for AlphaFold lookup")

    predictions = await http.get_json(f"{ALPHAFOLD}/{acc}")
    if not isinstance(predictions, list):
        raise BioAPIError(f"AlphaFold returned an unexpected shape for {acc}: {type(predictions).__name__}")
    if not predictions:
        raise BioAPIError(f"AlphaFold has no prediction for {acc}")

    top = predictions[0]
    # Downloadable model artifacts — only include the URLs the API actually
    # returned so we never hand back a fabricated link.
    downloads = {
        key: top[field]
        for key, field in (
            ("cif", "cifUrl"),
            ("bcif", "bcifUrl"),
            ("pdb", "pdbUrl"),
            ("pae_image", "paeImageUrl"),
            ("pae_doc", "paeDocUrl"),
        )
        if top.get(field)
    }
    model = {
        "uniprot_accession": top.get("uniprotAccession"),
        "uniprot_id": top.get("uniprotId"),
        "organism": top.get("organismScientificName"),
        "model_version": top.get("latestVersion"),
        "downloads": downloads,
        # globalMetricValue is the mean pLDDT (per-residue confidence, 0-100).
        **({"mean_plddt": top["globalMetricValue"]} if top.get("globalMetricValue") is not None else {}),
    }
    return {
        "uniprot_accession": acc,
        "model_count": len(predictions),
        "model": model,
        "source": source_record("alphafold", acc),
    }


async def interpro_protein_domains(http: BioHTTP, uniprot_accession: str) -> dict:
    """InterPro entries (families/domains/sites/...) matching a UniProt protein.

    First page only for v1, but `total` is exposed from the top-level `count`
    so callers know whether more pages exist. InterPro answers a valid protein
    with no matches using HTTP 204 (empty body) — handled honestly as
    returned=0, not an error.

    NOTE: we call `http.get` (not `http.get_json`) here because `get_json`
    raises on the 204's empty body; using the raw response lets us treat "no
    matches" as a real, empty result while still going through the shared,
    rate-limited client.
    """
    acc = uniprot_accession.strip().upper()
    if not acc:
        raise ValueError("empty UniProt accession for InterPro protein lookup")

    resp = await http.get(f"{INTERPRO}/protein/uniprot/{acc}")
    # 204 (or any empty body) == no InterPro signatures for this protein.
    if resp.status_code == 204 or not resp.content:
        return {"uniprot_accession": acc, "returned": 0, "total": 0, "entries": []}
    try:
        data = resp.json()
    except ValueError as e:
        raise BioAPIError(f"non-JSON InterPro response for {acc}: {resp.text[:200]}", url=str(resp.url)) from e

    entries = []
    for result in data.get("results", []):
        meta = result.get("metadata", {})
        ipr_id = meta.get("accession")
        if not ipr_id:
            # A result with no InterPro accession can't be pinned to a source;
            # skipping it keeps the source contract intact.
            continue
        entries.append(
            {
                "interpro_id": ipr_id,
                "name": _ipr_name(meta.get("name")),
                "type": meta.get("type"),
                "member_database": meta.get("source_database"),
                "source": source_record("interpro", ipr_id),
            }
        )
    return {
        "uniprot_accession": acc,
        "returned": len(entries),
        "total": data.get("count", len(entries)),
        "entries": entries,
    }


async def interpro_entry(http: BioHTTP, interpro_id: str) -> dict:
    """Metadata for one InterPro entry (IPR + six digits).

    Returns the entry's name, type, cleaned description, the member databases
    that contribute signatures to it, and its aggregate counters.
    """
    ipr = interpro_id.strip().upper()
    if not _IPR_RE.match(ipr):
        raise ValueError(f"malformed InterPro ID {interpro_id!r}; expected 'IPR' + 6 digits (e.g. IPR002117)")

    data = await http.get_json(f"{INTERPRO}/{ipr}")
    meta = data.get("metadata")
    if not meta:
        raise BioAPIError(f"InterPro returned no metadata for {ipr}")

    return {
        "interpro_id": meta.get("accession", ipr),
        "name": _ipr_name(meta.get("name")),
        "type": meta.get("type"),
        "description": _clean_description(meta.get("description")),
        # Signature source databases (PANTHER, PRINTS, Pfam, ...) folded into
        # this entry — just the DB names, not their full payloads.
        "member_databases": sorted((meta.get("member_databases") or {}).keys()),
        # Aggregate tallies live under `counters` (proteins, structures, taxa, ...).
        "counts": meta.get("counters"),
        "source": source_record("interpro", meta.get("accession", ipr)),
    }
