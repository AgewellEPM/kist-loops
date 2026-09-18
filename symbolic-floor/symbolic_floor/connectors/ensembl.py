"""Ensembl connector: gene symbol -> gene metadata + UniProt xrefs.

The genomics analog of the UniProt/PubChem connectors. Ensembl REST is the
curated gene aggregator; a symbol resolves to its biotype, chromosome, and the
proteins it encodes, every edge provenance-pinned to the exact ensembl URL.
"""

from __future__ import annotations

import json
from urllib.parse import quote

from ..schema import ValidationError
from .base import ConnectorError, Transport, http_get

LOOKUP_URL = ("https://rest.ensembl.org/lookup/symbol/{species}/{symbol}"
              "?content-type=application/json")
XREF_URL = ("https://rest.ensembl.org/xrefs/symbol/{species}/{symbol}"
            "?content-type=application/json")

# UniProt xref dbnames Ensembl returns (reviewed + unreviewed).
_UNIPROT_DBS = ("Uniprot/SWISSPROT", "Uniprot/SPTREMBL", "UniProtKB/Swiss-Prot",
                "UniProtKB/TrEMBL")


def lookup_symbol(symbol: str, *, species: str = "homo_sapiens",
                  transport: Transport | None = None) -> dict:
    """Resolve a gene symbol to its Ensembl record.

    Returns {"status": "OK", "symbol", "url", "ensembl_id", "biotype",
    "chromosome"} or {"status": "NOT_FOUND"}. Absent fields are omitted."""
    clean = (symbol or "").strip()
    if not clean:
        raise ValidationError("gene symbol must be non-empty")
    url = LOOKUP_URL.format(species=quote(species, safe=""), symbol=quote(clean, safe=""))
    status, body = http_get(url, transport=transport)
    if status in (400, 404) or (status == 200 and not body.strip()):
        return {"status": "NOT_FOUND", "symbol": clean, "url": url}
    if status != 200:
        raise ConnectorError(f"Ensembl lookup for {clean!r}: unexpected HTTP {status}")
    try:
        rec = json.loads(body)
    except ValueError as e:
        raise ConnectorError(f"Ensembl lookup for {clean!r}: unparseable body") from e
    if not isinstance(rec, dict):  # array/scalar body — not the lookup shape
        raise ConnectorError(f"Ensembl lookup for {clean!r}: non-object JSON body")
    out = {"status": "OK", "symbol": clean, "url": url}
    if rec.get("id"):
        out["ensembl_id"] = str(rec["id"])
    if rec.get("biotype"):
        out["biotype"] = str(rec["biotype"])
    # seq_region_name is the chromosome (e.g. "11", "X"); Ensembl also returns
    # patch/scaffold names we deliberately do not admit as a chromosome node.
    if rec.get("seq_region_name"):
        out["chromosome"] = str(rec["seq_region_name"])
    return out


def xref_uniprot(symbol: str, *, species: str = "homo_sapiens",
                 transport: Transport | None = None, cap: int = 5) -> dict:
    """The UniProt accessions this gene encodes (Ensembl xref lane).

    Returns {"status": "OK", "symbol", "url", "accessions": [...]}. Deterministic
    (sorted, capped). {"status": "NOT_FOUND"} when the symbol is unknown."""
    clean = (symbol or "").strip()
    if not clean:
        raise ValidationError("gene symbol must be non-empty")
    url = XREF_URL.format(species=quote(species, safe=""), symbol=quote(clean, safe=""))
    status, body = http_get(url, transport=transport)
    if status in (400, 404) or (status == 200 and not body.strip()):
        return {"status": "NOT_FOUND", "symbol": clean, "url": url}
    if status != 200:
        raise ConnectorError(f"Ensembl xrefs for {clean!r}: unexpected HTTP {status}")
    try:
        rows = json.loads(body)
    except ValueError as e:
        raise ConnectorError(f"Ensembl xrefs for {clean!r}: unparseable body") from e
    if not isinstance(rows, list):  # xrefs is an ARRAY; a dict/scalar is a wrong shape
        raise ConnectorError(f"Ensembl xrefs for {clean!r}: non-array JSON body")
    accs = sorted({str(r.get("primary_id")).strip()
                   for r in rows if isinstance(r, dict)
                   and r.get("dbname") in _UNIPROT_DBS and r.get("primary_id")})
    return {"status": "OK", "symbol": clean, "url": url, "accessions": accs[:cap]}
