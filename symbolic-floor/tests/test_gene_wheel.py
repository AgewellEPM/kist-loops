"""Gene wheel (Ensembl, slice 3) against canned transports — symbol lookup,
chromosome/biotype/encodes edges, PEEL tiles, idempotency. No live net.

Fixture: HBB (hemoglobin subunit beta) — chromosome 11, protein_coding, encodes
UniProt P68871.
"""

import json

from symbolic_floor import extract
from symbolic_floor.connectors import ensembl

from conftest import transport_for

LOOKUP_URL = ("https://rest.ensembl.org/lookup/symbol/homo_sapiens/HBB"
              "?content-type=application/json")
XREF_URL = ("https://rest.ensembl.org/xrefs/symbol/homo_sapiens/HBB"
            "?content-type=application/json")

LOOKUP_BODY = json.dumps({
    "id": "ENSG00000244734", "biotype": "protein_coding",
    "seq_region_name": "11", "species": "homo_sapiens",
}).encode()
XREF_BODY = json.dumps([
    {"dbname": "Uniprot/SWISSPROT", "primary_id": "P68871"},
    {"dbname": "Uniprot/SPTREMBL", "primary_id": "A0A0J9YWK4"},
    {"dbname": "EntrezGene", "primary_id": "3043"},  # non-UniProt: ignored
]).encode()


def _hbb_transport():
    return transport_for({LOOKUP_URL: (200, LOOKUP_BODY),
                          XREF_URL: (200, XREF_BODY)})


def test_lookup_symbol(store):
    t = transport_for({LOOKUP_URL: (200, LOOKUP_BODY)})
    got = ensembl.lookup_symbol("HBB", transport=t)
    assert got["status"] == "OK"
    assert got["chromosome"] == "11"
    assert got["biotype"] == "protein_coding"
    assert got["ensembl_id"] == "ENSG00000244734"


def test_xref_uniprot_filters_to_uniprot_only(store):
    t = transport_for({XREF_URL: (200, XREF_BODY)})
    got = ensembl.xref_uniprot("HBB", transport=t)
    assert got["status"] == "OK"
    # EntrezGene 3043 is dropped; only UniProt accessions survive, sorted.
    assert got["accessions"] == ["A0A0J9YWK4", "P68871"]


def test_research_gene_writes_genomics(store):
    result = extract.research_gene(store, "HBB", transport=_hbb_transport())
    assert result["status"] == "OK"
    edges = {(e["relation_type"], e["object"])
             for e in store.get_edges(source="gene:HBB")}
    assert ("on_chromosome", "chromosome:11") in edges
    assert ("has_biotype", "biotype:protein_coding") in edges
    assert ("encodes", "protein:P68871") in edges

    for e in store.get_edges(source="gene:HBB"):
        prov = json.loads(e["provenance_json"])
        assert prov["source"] == "ensembl"
        assert prov["url"].startswith("https://rest.ensembl.org/")


def test_gene_wheel_writes_peel_tiles(store):
    result = extract.research_gene(store, "HBB", transport=_hbb_transport())
    rows = store.db.execute(
        "SELECT sentence, topic FROM responses WHERE conversation_id='gene-wheel:HBB'").fetchall()
    assert len(rows) == result["peel_trace"]["tiles_total"]
    assert all(r["topic"] == "genomics:HBB" for r in rows)
    assert any("chromosome 11" in (r["sentence"] or "") for r in rows)


def test_research_gene_is_idempotent(store):
    first = extract.research_gene(store, "HBB", transport=_hbb_transport())
    second = extract.research_gene(store, "HBB", transport=_hbb_transport())
    assert first["status"] == second["status"] == "OK"
    assert second["edges_written"] == []
    assert second["peel_trace"]["tiles_written"] == 0
    assert len(store.get_edges(source="gene:HBB", relation="on_chromosome")) == 1


def test_unknown_gene_is_not_found(store):
    url = ("https://rest.ensembl.org/lookup/symbol/homo_sapiens/NOTAGENE9"
           "?content-type=application/json")
    t = transport_for({url: (400, b'{"error":"not found"}')})
    got = extract.research_gene(store, "NOTAGENE9", transport=t)
    assert got["status"] == "NOT_FOUND"
    assert store.get_edges(source="gene:NOTAGENE9") == []
