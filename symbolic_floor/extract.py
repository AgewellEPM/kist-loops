"""The bio wheel: one accession -> typed Peel facts + link edges + a trace.

The analog of the Jeeves wiki wheel (wiki page -> PEEL tiles + wiki_links):
here one UniProt entry fans out into typed relations INSIDE the embedded Peel
engine, every edge provenance-pinned to the exact URL fetched, plus the
slice-1 evidence trio (sequence / experimental structures / prediction).

Extraction relations (schema.EXTRACTION_RELATIONS) map onto the engine's own
vocabulary — located_in even participates in the engine's Rule-1 conflict
scanning. Extraction never invents: a field absent from the payload yields no
edge, and everything written is listed in the returned trace.
"""

from __future__ import annotations

from .connectors import alphafold, uniprot
from .connectors.base import Transport
from .connectors.pdb import RCSB_ENTRY_URL
from .connectors.base import http_get
from .schema import ValidationError, slug, utc_now_iso
from .store import Store

import json

# Politeness cap: confirm at most this many PDB cross-references per protein
# against RCSB (p53 alone lists hundreds). NEVER silent — the trace reports
# pdb_xrefs_total so a capped run is visibly capped.
MAX_CONFIRMED_STRUCTURES = 5


def _entry_facts(entry: dict, acc: str) -> list[tuple[str, str, str, str]]:
    """(source, relation, target, human label) tuples derivable from one
    UniProt entry JSON. Pure function — no I/O, fully unit-testable."""
    protein = f"protein:{acc}"
    facts: list[tuple[str, str, str, str]] = []

    for gene in entry.get("genes") or []:
        symbol = ((gene or {}).get("geneName") or {}).get("value")
        if symbol:
            facts.append((f"gene:{symbol}", "encodes", protein,
                          f"gene {symbol} encodes {acc}"))

    organism = (entry.get("organism") or {}).get("scientificName")
    if organism:
        facts.append((protein, "belongs_to", f"organism:{slug(organism)}",
                      f"{acc} organism: {organism}"))

    seen: set[str] = set()
    for comment in entry.get("comments") or []:
        ctype = (comment or {}).get("commentType")
        if ctype == "SUBCELLULAR LOCATION":
            for loc in comment.get("subcellularLocations") or []:
                value = ((loc or {}).get("location") or {}).get("value")
                if not value:
                    continue
                try:
                    node = f"location:{slug(value)}"
                except ValidationError:
                    continue  # un-sluggable free text -> no edge, never a crash
                if node not in seen:
                    seen.add(node)
                    facts.append((protein, "located_in", node,
                                  f"{acc} located in {value}"))
        elif ctype == "DISEASE":
            disease_id = ((comment or {}).get("disease") or {}).get("diseaseId")
            if disease_id:
                try:
                    node = f"disease:{slug(disease_id)}"
                except ValidationError:
                    continue
                if node not in seen:
                    seen.add(node)
                    # "affects", deliberately NOT "causes": UniProt records
                    # involvement-in-disease, not causation.
                    facts.append((protein, "affects", node,
                                  f"{acc} disease involvement: {disease_id}"))

    for feature in entry.get("features") or []:
        if (feature or {}).get("type") == "Domain":
            desc = feature.get("description")
            if desc:
                try:
                    node = f"domain:{slug(desc)}"
                except ValidationError:
                    continue
                if node not in seen:
                    seen.add(node)
                    facts.append((protein, "has_part", node,
                                  f"{acc} domain: {desc}"))
    return facts


def _pdb_xrefs(entry: dict) -> list[str]:
    ids = []
    for xref in entry.get("uniProtKBCrossReferences") or []:
        if isinstance(xref, dict) and xref.get("database") == "PDB" and xref.get("id"):
            ids.append(str(xref["id"]).strip().upper())
    return ids


# Selectable wheel libraries. "uniprot" is the wheel's root (the entry JSON
# drives every other block) and cannot be disabled.
WHEEL_LIBRARIES = ("uniprot", "sequence", "pdb", "alphafold")


def extract_protein(store: Store, accession: str, *,
                    transport: Transport | None = None,
                    max_structures: int = MAX_CONFIRMED_STRUCTURES,
                    enabled: set[str] | None = None) -> dict:
    """Run the wheel for one accession. Returns the extraction trace:
    every edge written (id + triple), everything skipped, sources fetched.

    ``enabled`` selects which libraries the wheel collects from (subset of
    WHEEL_LIBRARIES; None = all). Disabled libraries are simply not
    fetched — and the trace names them, so a narrowed run is never
    mistaken for a full one."""
    if enabled is None:
        enabled = set(WHEEL_LIBRARIES)
    unknown = enabled - set(WHEEL_LIBRARIES)
    if unknown:
        raise ValidationError(f"unknown wheel libraries: {sorted(unknown)}")
    if "uniprot" not in enabled:
        raise ValidationError("the uniprot library is the wheel's root and "
                              "cannot be disabled")
    disabled = sorted(set(WHEEL_LIBRARIES) - enabled)
    fetched = uniprot.fetch_entry_json(accession, transport=transport)
    acc = fetched["accession"]
    if fetched["status"] == "NOT_FOUND":
        return {"status": "NOT_FOUND", "accession": acc,
                "edges_written": [], "sources_fetched": [fetched["url"]]}

    entry = fetched["entry"]
    entry_url = fetched["url"]
    sources = [entry_url]
    written: list[dict] = []
    skipped: list[dict] = []
    existing = 0

    def _add(src: str, rel: str, dst: str, label: str, provenance: dict) -> None:
        nonlocal existing
        # One un-typeable fact (a gene symbol with spaces, an over-long id)
        # must not kill the whole wheel: skip it, report it, keep going. The
        # skip list in the trace keeps this honest — dropped is never silent.
        try:
            edge_id, created = store.add_edge(src, rel, dst, provenance, label=label)
        except ValidationError as e:
            skipped.append({"source": src, "relation": rel, "target": dst,
                            "reason": str(e)})
            return
        if created:
            written.append({"edge_id": edge_id, "source": src,
                            "relation": rel, "target": dst})
        else:
            existing += 1

    # 1) Entry-derived typed facts (gene/organism/location/disease/domain).
    entry_prov = {"source": "uniprot", "url": entry_url,
                  "retrieved_at": utc_now_iso(), "raw_id": acc}
    for src, rel, dst, label in _entry_facts(entry, acc):
        _add(src, rel, dst, label, dict(entry_prov))

    # 2) Sequence (FASTA route, content-addressed).
    if "sequence" in enabled:
        seq = uniprot.fetch_sequence(store, acc, transport=transport)
        if seq["status"] == "OK":
            sources.append(uniprot.FASTA_URL.format(accession=acc))
            if seq["created"]:
                written.append({"edge_id": seq["edge_id"], "source": f"protein:{acc}",
                                "relation": "has_sequence", "target": seq["sequence_id"]})
            else:
                existing += 1

    # 3) Experimental structures: ALL xrefs are the link graph; confirm the
    #    first max_structures against RCSB (each confirmed one becomes an edge
    #    with RCSB provenance). The cap is reported, never silent.
    xrefs = _pdb_xrefs(entry)
    confirmed = 0
    for pdb_id in (xrefs[:max_structures] if "pdb" in enabled else []):
        entry_url_rcsb = RCSB_ENTRY_URL.format(pdb_id=pdb_id)
        status, body = http_get(entry_url_rcsb, transport=transport)
        sources.append(entry_url_rcsb)
        if status != 200 or not body.strip():
            continue
        try:
            rcsb = json.loads(body)
        except ValueError:
            continue
        if ((rcsb.get("rcsb_entry_info") or {}).get("experimental_method")) is None:
            continue
        _add(f"protein:{acc}", "has_structure", f"structure:{pdb_id}",
             f"{pdb_id} experimental structure",
             {"source": "pdb", "url": entry_url_rcsb,
              "retrieved_at": utc_now_iso(), "raw_id": pdb_id})
        confirmed += 1

    # 4) Predicted structure (AlphaFold).
    if "alphafold" in enabled:
        pred = alphafold.fetch_prediction(store, acc, transport=transport)
        if pred["status"] == "OK":
            sources.append(alphafold.PREDICTION_URL.format(accession=acc))
            if pred["created"]:
                written.append({"edge_id": pred["edge_id"], "source": f"protein:{acc}",
                                "relation": "predicts_structure", "target": pred["structure_id"]})
            else:
                existing += 1

    # Canonical-37 PEEL trace: root + one tile per fact currently stored for
    # this protein (both newly-written AND already-present edges belong to the
    # trace — the wheel traces the WHOLE evidence base, idempotently).
    from .peel_tiles import write_extraction_trace
    all_edges = [
        {"edge_id": e["id"], "source": e["subject"],
         "relation": e["relation_type"], "target": e["object"]}
        for e in store.get_edges(source=f"protein:{acc}")
    ] + [
        {"edge_id": e["id"], "source": e["subject"],
         "relation": e["relation_type"], "target": e["object"]}
        for e in store.get_edges(target=f"protein:{acc}")
        if e["relation_type"] == "encodes"
    ]
    trace = write_extraction_trace(store, acc, all_edges, sources)

    return {
        "status": "OK",
        "accession": acc,
        "edges_written": written,
        "edges_already_present": existing,
        "skipped": skipped,
        "pdb_xrefs_total": len(xrefs),
        "pdb_confirmed": confirmed,
        "pdb_confirm_cap": max_structures,
        "libraries_disabled": disabled,
        "sources_fetched": sources,
        "peel_trace": trace,
    }
