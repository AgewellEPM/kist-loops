"""PDB connector against fixtures — xref route, confirmation, edge. No live net."""

import json

from symbolic_floor.connectors import pdb

from conftest import load_fixture, transport_for


def test_first_pdb_xref_confirmed_and_stored(store):
    t = transport_for({
        "https://rest.uniprot.org/uniprotkb/P12345.json":
            (200, load_fixture("uniprot_p12345.json")),
        "https://data.rcsb.org/rest/v1/core/entry/1ABC":
            (200, load_fixture("pdb_1abc.json")),
    })
    result = pdb.fetch_experimental_structure(store, "P12345", transport=t)
    assert result["status"] == "OK"
    assert result["pdb_id"] == "1ABC"  # FIRST xref (2XYZ ignored)
    assert result["experimental_method"] == "X-RAY DIFFRACTION"

    edges = store.get_edges(source="protein:P12345", relation="has_structure")
    assert [e["object"] for e in edges] == ["structure:1ABC"]
    prov = json.loads(edges[0]["provenance_json"])
    assert prov["source"] == "pdb"
    assert prov["raw_id"] == "1ABC"
    assert prov["url"] == "https://data.rcsb.org/rest/v1/core/entry/1ABC"


def test_missing_experimental_method_writes_nothing(store):
    t = transport_for({
        "https://rest.uniprot.org/uniprotkb/P12345.json":
            (200, load_fixture("uniprot_p12345.json")),
        "https://data.rcsb.org/rest/v1/core/entry/1ABC":
            (200, b'{"rcsb_id": "1ABC", "rcsb_entry_info": {"experimental_method": null}}'),
    })
    result = pdb.fetch_experimental_structure(store, "P12345", transport=t)
    assert result["status"] == "NO_EXPERIMENTAL_STRUCTURE"
    assert result["reason"] == "experimental_method missing"
    assert store.get_edges() == []


def test_unconfirmed_rcsb_entry_writes_nothing(store):
    t = transport_for({
        "https://rest.uniprot.org/uniprotkb/P12345.json":
            (200, load_fixture("uniprot_p12345.json")),
        "https://data.rcsb.org/rest/v1/core/entry/1ABC": (404, b"gone"),
    })
    result = pdb.fetch_experimental_structure(store, "P12345", transport=t)
    assert result["status"] == "NO_EXPERIMENTAL_STRUCTURE"
    assert result["unconfirmed_pdb_id"] == "1ABC"
    assert store.get_edges() == []
