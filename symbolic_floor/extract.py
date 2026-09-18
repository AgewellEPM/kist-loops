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

from .connectors import alphafold, ensembl, pubchem, uniprot
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


def _molecule_facts(props: dict, cid: int) -> list[tuple[str, str, str, str]]:
    """(source, relation, target, label) tuples from PubChem property JSON.
    Pure function — no I/O. Formula/InChIKey/weight are case-kept exactly as the
    source returned them; the IUPAC name is slugged into a compound node."""
    molecule = f"molecule:{cid}"
    facts: list[tuple[str, str, str, str]] = []

    formula = props.get("MolecularFormula")
    if formula:
        facts.append((molecule, "has_formula", f"formula:{formula}",
                      f"CID {cid} molecular formula {formula}"))

    iupac = props.get("IUPACName")
    if iupac:
        try:
            facts.append((molecule, "has_iupac_name", f"compound:{slug(iupac)}",
                          f"CID {cid} IUPAC name {iupac}"))
        except ValidationError:
            pass  # un-sluggable IUPAC string -> no edge, never a crash

    inchikey = props.get("InChIKey")
    if inchikey:
        facts.append((molecule, "has_inchikey", f"inchikey:{inchikey}",
                      f"CID {cid} InChIKey {inchikey}"))

    weight = props.get("MolecularWeight")
    if weight:
        facts.append((molecule, "has_weight", f"weight:{weight}",
                      f"CID {cid} molecular weight {weight} g/mol"))
    return facts


def extract_molecule(store: Store, cid: int, *, name: str | None = None,
                     transport: Transport | None = None,
                     synonym_cap: int = 8) -> dict:
    """The molecule wheel: one PubChem CID -> typed chemistry facts + a PEEL
    trace, every edge pinned to the exact pubchem URL fetched. Deterministic and
    idempotent (re-running writes nothing new). ``name`` is a cosmetic label for
    the trace; the facts come only from PubChem."""
    label_name = (name or f"CID {cid}").strip()
    fetched = pubchem.fetch_properties(cid, transport=transport)
    if fetched["status"] == "NOT_FOUND":
        return {"status": "NOT_FOUND", "cid": cid,
                "edges_written": [], "sources_fetched": [fetched["url"]]}

    prop_url = fetched["url"]
    props = fetched["props"]
    sources = [prop_url]
    written: list[dict] = []
    skipped: list[dict] = []
    existing = 0

    def _add(src: str, rel: str, dst: str, label: str, provenance: dict) -> None:
        nonlocal existing
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

    # 1) Canonical identity facts (formula / IUPAC name / InChIKey / weight).
    prop_prov = {"source": "pubchem", "url": prop_url,
                 "retrieved_at": utc_now_iso(), "raw_id": str(cid)}
    for src, rel, dst, label in _molecule_facts(props, cid):
        _add(src, rel, dst, label, dict(prop_prov))

    # 2) Synonyms (capped, reported). Each is a known_as edge to a compound node.
    syn = pubchem.fetch_synonyms(cid, transport=transport, cap=synonym_cap)
    synonyms_total = 0
    if syn["status"] == "OK":
        sources.append(syn["url"])
        synonyms_total = len(syn["synonyms"])
        syn_prov = {"source": "pubchem", "url": syn["url"],
                    "retrieved_at": utc_now_iso(), "raw_id": str(cid)}
        for name_str in syn["synonyms"]:
            try:
                node = f"compound:{slug(name_str)}"
            except ValidationError:
                continue  # un-sluggable synonym -> skip, never crash
            _add(f"molecule:{cid}", "known_as", node,
                 f"CID {cid} also known as {name_str}", dict(syn_prov))

    # 3) Canonical-37 PEEL trace over the WHOLE evidence base for this molecule.
    from .peel_tiles import write_molecule_extraction_trace
    all_edges = [
        {"edge_id": e["id"], "source": e["subject"],
         "relation": e["relation_type"], "target": e["object"]}
        for e in store.get_edges(source=f"molecule:{cid}")
    ]
    trace = write_molecule_extraction_trace(store, cid, label_name, all_edges, sources)

    return {
        "status": "OK",
        "cid": cid,
        "name": label_name,
        "edges_written": written,
        "edges_already_present": existing,
        "skipped": skipped,
        "synonyms_total": synonyms_total,
        "synonym_cap": synonym_cap,
        "sources_fetched": sources,
        "peel_trace": trace,
    }


def research_molecule(store: Store, query: str, *,
                      transport: Transport | None = None,
                      synonym_cap: int = 8) -> dict:
    """Native 'research this molecule' path: resolve a common NAME to a PubChem
    CID, then run the molecule wheel. No model, no MCP — the name resolves and
    the facts pull deterministically from the curated PubChem aggregator, or the
    query is honestly NOT_FOUND. This is what makes `research water` return real
    chemistry (H2O, oxidane, InChIKey, 18.015 g/mol) instead of nothing."""
    resolved = pubchem.resolve_cid(query, transport=transport)
    if resolved["status"] == "NOT_FOUND":
        return {"status": "NOT_FOUND", "query": query,
                "sources_fetched": [resolved["url"]]}
    cid = resolved["cid"]
    result = extract_molecule(store, cid, name=query.strip(),
                              transport=transport, synonym_cap=synonym_cap)
    result["query"] = query.strip()
    result["resolved_cid"] = cid
    result.setdefault("sources_fetched", []).insert(0, resolved["url"])
    return result


def extract_gene(store: Store, symbol: str, *, species: str = "homo_sapiens",
                 transport: Transport | None = None) -> dict:
    """The gene wheel: one gene symbol -> typed genomics facts (chromosome,
    biotype, encoded proteins) + a PEEL trace, every edge pinned to the exact
    ensembl URL. Deterministic and idempotent."""
    sym = symbol.strip()
    lookup = ensembl.lookup_symbol(sym, species=species, transport=transport)
    if lookup["status"] == "NOT_FOUND":
        return {"status": "NOT_FOUND", "symbol": sym,
                "edges_written": [], "sources_fetched": [lookup["url"]]}

    gene = f"gene:{sym}"
    sources = [lookup["url"]]
    written: list[dict] = []
    skipped: list[dict] = []
    existing = 0

    def _add(src: str, rel: str, dst: str, label: str, provenance: dict) -> None:
        nonlocal existing
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

    # 1) Gene metadata (chromosome, biotype) from the lookup record.
    lk_prov = {"source": "ensembl", "url": lookup["url"],
               "retrieved_at": utc_now_iso(), "raw_id": sym}
    if lookup.get("chromosome"):
        _add(gene, "on_chromosome", f"chromosome:{lookup['chromosome']}",
             f"{sym} on chromosome {lookup['chromosome']}", dict(lk_prov))
    if lookup.get("biotype"):
        try:
            bt = f"biotype:{slug(lookup['biotype'])}"
            _add(gene, "has_biotype", bt, f"{sym} biotype {lookup['biotype']}", dict(lk_prov))
        except ValidationError:
            pass

    # 2) Encoded proteins (Ensembl -> UniProt xrefs).
    xref = ensembl.xref_uniprot(sym, species=species, transport=transport)
    if xref["status"] == "OK" and xref["accessions"]:
        sources.append(xref["url"])
        xr_prov = {"source": "ensembl", "url": xref["url"],
                   "retrieved_at": utc_now_iso(), "raw_id": sym}
        for acc in xref["accessions"]:
            _add(gene, "encodes", f"protein:{acc}",
                 f"{sym} encodes {acc}", dict(xr_prov))

    # 3) Canonical-37 PEEL trace over the gene's whole evidence base.
    from .peel_tiles import write_gene_extraction_trace
    all_edges = [
        {"edge_id": e["id"], "source": e["subject"],
         "relation": e["relation_type"], "target": e["object"]}
        for e in store.get_edges(source=gene)
    ]
    trace = write_gene_extraction_trace(store, sym, all_edges, sources)

    return {
        "status": "OK",
        "symbol": sym,
        "ensembl_id": lookup.get("ensembl_id"),
        "edges_written": written,
        "edges_already_present": existing,
        "skipped": skipped,
        "sources_fetched": sources,
        "peel_trace": trace,
    }


def research_gene(store: Store, symbol: str, *, species: str = "homo_sapiens",
                  transport: Transport | None = None) -> dict:
    """Native 'research this gene' path: a bare gene symbol -> the gene wheel.
    No model, no MCP — Ensembl resolves the symbol and the facts pull
    deterministically, or the symbol is honestly NOT_FOUND."""
    result = extract_gene(store, symbol, species=species, transport=transport)
    result["query"] = symbol.strip()
    return result
