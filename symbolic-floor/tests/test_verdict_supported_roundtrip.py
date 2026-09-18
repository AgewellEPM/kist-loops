"""Brief §6.6 — full seed via fixture transports -> SUPPORTED, trace has all 3 edges."""

from symbolic_floor.connectors import alphafold, pdb, uniprot
from symbolic_floor.reasoner import evaluate_claim

from conftest import load_fixture, transport_for


def _routes():
    return {
        "https://rest.uniprot.org/uniprotkb/P12345.fasta":
            (200, load_fixture("uniprot_p12345.fasta")),
        "https://rest.uniprot.org/uniprotkb/P12345.json":
            (200, load_fixture("uniprot_p12345.json")),
        "https://data.rcsb.org/rest/v1/core/entry/1ABC":
            (200, load_fixture("pdb_1abc.json")),
        "https://alphafold.ebi.ac.uk/api/prediction/P12345":
            (200, load_fixture("alphafold_p12345.json")),
    }


def seed_p12345(store):
    t = transport_for(_routes())
    r_seq = uniprot.fetch_sequence(store, "P12345", transport=t)
    r_pdb = pdb.fetch_experimental_structure(store, "P12345", transport=t)
    r_af = alphafold.fetch_prediction(store, "P12345", transport=t)
    assert r_seq["status"] == r_pdb["status"] == r_af["status"] == "OK"
    return r_seq, r_pdb, r_af


def test_verdict_supported_roundtrip(store):
    r_seq, r_pdb, r_af = seed_p12345(store)
    claim_id = store.get_or_create_claim("protein:P12345")
    result = evaluate_claim(store, claim_id)

    assert result["verdict"] == "SUPPORTED"
    assert result["missing"] == []
    # Trace references all three edges by ID — exactly the ones the seed wrote.
    assert set(result["trace"]) == {r_seq["edge_id"], r_pdb["edge_id"], r_af["edge_id"]}
    assert "structure:1ABC" in result["witnesses"]
    assert "structure:AF-P12345-F1" in result["witnesses"]


def test_supported_edges_carry_provenance(store):
    seed_p12345(store)
    for edge in store.get_edges():
        assert edge["provenance_json"], f"edge {edge['id']} has no provenance"
