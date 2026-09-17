"""AlphaFold connector against fixtures — pdbUrl parse, edge, provenance. No live net."""

import json

from symbolic_floor.connectors import alphafold

from conftest import load_fixture, transport_for


def test_prediction_parsed_and_stored(store):
    t = transport_for({
        "https://alphafold.ebi.ac.uk/api/prediction/P12345":
            (200, load_fixture("alphafold_p12345.json")),
    })
    result = alphafold.fetch_prediction(store, "P12345", transport=t)
    assert result["status"] == "OK"
    assert result["structure_id"] == "structure:AF-P12345-F1"  # parsed from pdbUrl

    edges = store.get_edges(source="protein:P12345", relation="predicts_structure")
    assert [e["object"] for e in edges] == ["structure:AF-P12345-F1"]
    prov = json.loads(edges[0]["provenance_json"])
    assert prov["source"] == "alphafold"
    assert prov["raw_id"] == "AF-P12345-F1"


def test_empty_prediction_list_writes_nothing(store):
    t = transport_for({
        "https://alphafold.ebi.ac.uk/api/prediction/P12345": (200, b"[]"),
    })
    result = alphafold.fetch_prediction(store, "P12345", transport=t)
    assert result["status"] == "NO_PREDICTION"
    assert store.get_edges() == []
