"""Perception adapter: UniProtKB REST → typed observations, with the raw bytes receipted.

The adapter is the only place raw world touches the system. It returns
  (observations, raw_sha256, meta)
where observations map fully-qualified variables (`uniprot:<ACC>:<field>`) to values, the
digest pins the exact bytes observed, and meta records URL + HTTP status for the receipt.

⚠️ UniProt returns 200 with an empty/absent body for some nonexistent accessions (seen live
2026-09-17 on the symbolic-floor work): an empty or undecodable body is an ERROR here, never
an observation. Missing FIELDS on a real entry become None (→ INCONCLUSIVE at the critic),
because "the database does not state it" is an observation about the database, not a failure.
"""
from __future__ import annotations

import hashlib
import json
import urllib.error
import urllib.request
from typing import Any, Dict, Tuple

BASE_URL = "https://rest.uniprot.org/uniprotkb"
TIMEOUT_SECONDS = 30
SUPPORTED_FIELDS = {"sequence_length", "mature_chain_length", "initiator_met_removed",
                    "protein_name"}


class AdapterError(RuntimeError):
    """The world could not be observed. No receipt should be written from this."""


def _extract(entry: Dict[str, Any], field: str) -> Any:
    if field == "sequence_length":
        return entry.get("sequence", {}).get("length")
    if field == "protein_name":
        return (entry.get("proteinDescription", {}).get("recommendedName", {})
                .get("fullName", {}).get("value"))
    if field == "initiator_met_removed":
        for feature in entry.get("features", []):
            if feature.get("type") == "Initiator methionine":
                return "removed" in feature.get("description", "").lower()
        return False
    if field == "mature_chain_length":
        for feature in entry.get("features", []):
            if feature.get("type") == "Chain":
                location = feature.get("location", {})
                start = location.get("start", {}).get("value")
                end = location.get("end", {}).get("value")
                if isinstance(start, int) and isinstance(end, int):
                    return end - start + 1
        return None
    raise AdapterError(f"unsupported field {field!r}; supported: {sorted(SUPPORTED_FIELDS)}")


def observe(request: Dict[str, Any],
            urlopen: Any = urllib.request.urlopen) -> Tuple[Dict[str, Any], str, Dict[str, Any]]:
    accession = request.get("key", "").strip()
    fields = request.get("fields", [])
    if not accession or not fields:
        raise AdapterError("uniprot adapter needs {key: accession, fields: [...]}")
    unsupported = [f for f in fields if f not in SUPPORTED_FIELDS]
    if unsupported:
        raise AdapterError(f"unsupported fields {unsupported}")
    url = f"{BASE_URL}/{accession}.json"
    try:
        with urlopen(url, timeout=TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            body = response.read()
    except urllib.error.URLError as error:
        raise AdapterError(f"uniprot fetch failed for {accession}: {error}") from error
    if status != 200:
        raise AdapterError(f"uniprot returned HTTP {status} for {accession}")
    if not body:
        raise AdapterError(f"uniprot returned an EMPTY 200 body for {accession} — "
                           "known landmine for nonexistent accessions; refusing to observe")
    raw_sha256 = hashlib.sha256(body).hexdigest()
    try:
        entry = json.loads(body)
    except json.JSONDecodeError as error:
        raise AdapterError(f"uniprot body for {accession} is not JSON: {error}") from error
    if entry.get("primaryAccession") not in (accession, None) and \
            accession not in entry.get("secondaryAccessions", []):
        raise AdapterError(f"uniprot answered for {entry.get('primaryAccession')!r}, "
                           f"not the requested {accession}")
    observations = {f"uniprot:{accession}:{field}": _extract(entry, field)
                    for field in fields}
    meta = {"url": url, "http_status": status, "bytes": len(body),
            "primary_accession": entry.get("primaryAccession")}
    return observations, raw_sha256, meta
