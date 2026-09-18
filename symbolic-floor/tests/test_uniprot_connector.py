"""UniProt connector against fixtures — parse, hash, edge, provenance. No live net."""

import hashlib
import json

from symbolic_floor.connectors import uniprot

from conftest import load_fixture, transport_for


def test_fasta_parse_and_edge(store):
    body = load_fixture("uniprot_p12345.fasta")
    t = transport_for({"https://rest.uniprot.org/uniprotkb/P12345.fasta": (200, body)})
    result = uniprot.fetch_sequence(store, "P12345", transport=t)

    assert result["status"] == "OK"
    # Sequence = everything after the header, newlines removed.
    expected_seq = "".join(body.decode().splitlines()[1:])
    expected_id = "sequence:" + hashlib.sha256(expected_seq.encode()).hexdigest()
    assert result["sequence_id"] == expected_id

    edges = store.get_edges(source="protein:P12345", relation="has_sequence")
    assert len(edges) == 1
    prov = json.loads(edges[0]["provenance_json"])
    assert prov["source"] == "uniprot"
    assert prov["raw_id"] == "P12345"
    assert prov["url"].startswith("https://rest.uniprot.org/")


def test_lowercase_accession_normalized(store):
    body = load_fixture("uniprot_p12345.fasta")
    t = transport_for({"https://rest.uniprot.org/uniprotkb/P12345.fasta": (200, body)})
    result = uniprot.fetch_sequence(store, "p12345", transport=t)
    assert result["accession"] == "P12345"


def test_reseed_is_idempotent(store):
    body = load_fixture("uniprot_p12345.fasta")
    t = transport_for({"https://rest.uniprot.org/uniprotkb/P12345.fasta": (200, body)})
    first = uniprot.fetch_sequence(store, "P12345", transport=t)
    second = uniprot.fetch_sequence(store, "P12345", transport=t)
    assert first["edge_id"] == second["edge_id"]
    assert first["created"] is True and second["created"] is False
    assert len(store.get_edges(relation="has_sequence")) == 1
