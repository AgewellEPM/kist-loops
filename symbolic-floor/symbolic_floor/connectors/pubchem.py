"""PubChem connector: molecule name -> CID -> canonical chemistry identifiers.

The chemistry analog of the UniProt connector. PubChem PUG-REST is the curated
small-molecule aggregator; every value we pull (formula, IUPAC name, InChIKey,
weight, synonyms) is provenance-pinned to the exact pubchem URL fetched. No
model, no hallucination: the fact comes from the source or it does not exist.
"""

from __future__ import annotations

import json
from urllib.parse import quote

from ..schema import ValidationError, validate_node_id
from .base import ConnectorError, Transport, http_get

# PUG-REST endpoints (all https on pubchem.ncbi.nlm.nih.gov — the allowlisted host).
NAME_CID_URL = "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/{name}/cids/JSON"
PROPERTY_URL = (
    "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/cid/{cid}"
    "/property/MolecularFormula,IUPACName,InChIKey,MolecularWeight/JSON"
)
SYNONYM_URL = "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/cid/{cid}/synonyms/JSON"

# The four canonical properties we admit to the floor as chemistry identity.
_WANTED_PROPS = ("MolecularFormula", "IUPACName", "InChIKey", "MolecularWeight")


def resolve_cid(name: str, *, transport: Transport | None = None) -> dict:
    """Resolve a common name to a PubChem CID.

    Returns {"status": "OK", "cid": int, "url": str} or
    {"status": "NOT_FOUND", "name": str, "url": str}. The CID is chosen
    deterministically (the smallest returned CID — PubChem lists the parent
    compound first, but sorting makes it reproducible regardless of order).
    """
    clean = (name or "").strip()
    if not clean:
        raise ValidationError("molecule name must be non-empty")
    url = NAME_CID_URL.format(name=quote(clean, safe=""))
    status, body = http_get(url, transport=transport)
    if status == 404 or (status == 200 and not body.strip()):
        return {"status": "NOT_FOUND", "name": clean, "url": url}
    if status != 200:
        raise ConnectorError(f"PubChem name->CID for {clean!r}: unexpected HTTP {status}")
    try:
        parsed = json.loads(body)
    except ValueError as e:
        raise ConnectorError(f"PubChem name->CID for {clean!r}: unparseable body") from e
    if not isinstance(parsed, dict):  # array/string/number/null body — not the API shape
        raise ConnectorError(f"PubChem name->CID for {clean!r}: non-object JSON body")
    cids = (parsed.get("IdentifierList") or {}).get("CID") or []
    # ASCII decimals only: str.isdigit() also passes superscripts (crash int()) and
    # non-ASCII digits (silently become a DIFFERENT integer) — reject both.
    ints = sorted({int(c) for c in cids if str(c).isascii() and str(c).isdigit()})
    if not ints:
        return {"status": "NOT_FOUND", "name": clean, "url": url}
    return {"status": "OK", "cid": ints[0], "url": url}


def fetch_properties(cid: int, *, transport: Transport | None = None) -> dict:
    """Fetch the four canonical identity properties for a CID.

    Returns {"status": "OK", "cid", "url", "props": {MolecularFormula, IUPACName,
    InChIKey, MolecularWeight}} — absent fields are simply omitted (the wheel
    writes only what the source actually returned). {"status": "NOT_FOUND"} for
    an unknown CID.
    """
    validate_node_id(f"molecule:{cid}")  # reject a malformed CID before any I/O
    url = PROPERTY_URL.format(cid=cid)
    status, body = http_get(url, transport=transport)
    if status == 404 or (status == 200 and not body.strip()):
        return {"status": "NOT_FOUND", "cid": cid, "url": url}
    if status != 200:
        raise ConnectorError(f"PubChem properties for CID {cid}: unexpected HTTP {status}")
    try:
        parsed = json.loads(body)
    except ValueError as e:
        raise ConnectorError(f"PubChem properties for CID {cid}: unparseable body") from e
    if not isinstance(parsed, dict):
        raise ConnectorError(f"PubChem properties for CID {cid}: non-object JSON body")
    table = (parsed.get("PropertyTable") or {}).get("Properties") or []
    if not table:
        return {"status": "NOT_FOUND", "cid": cid, "url": url}
    row = table[0]
    props = {k: str(row[k]).strip() for k in _WANTED_PROPS if row.get(k) not in (None, "")}
    return {"status": "OK", "cid": cid, "url": url, "props": props}


def fetch_synonyms(cid: int, *, transport: Transport | None = None, cap: int = 8) -> dict:
    """Fetch up to `cap` synonyms for a CID (deterministic: source order,
    truncated). Returns {"status": "OK", "cid", "url", "synonyms": [...]}
    or {"status": "NOT_FOUND"}."""
    validate_node_id(f"molecule:{cid}")
    url = SYNONYM_URL.format(cid=cid)
    status, body = http_get(url, transport=transport)
    if status == 404 or (status == 200 and not body.strip()):
        return {"status": "NOT_FOUND", "cid": cid, "url": url}
    if status != 200:
        raise ConnectorError(f"PubChem synonyms for CID {cid}: unexpected HTTP {status}")
    try:
        parsed = json.loads(body)
    except ValueError as e:
        raise ConnectorError(f"PubChem synonyms for CID {cid}: unparseable body") from e
    if not isinstance(parsed, dict):
        raise ConnectorError(f"PubChem synonyms for CID {cid}: non-object JSON body")
    info = (parsed.get("InformationList") or {}).get("Information") or []
    names = (info[0].get("Synonym") if info else []) or []
    trimmed = [str(n).strip() for n in names[:cap] if str(n).strip()]
    return {"status": "OK", "cid": cid, "url": url, "synonyms": trimmed}
