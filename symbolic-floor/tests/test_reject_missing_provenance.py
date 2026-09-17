"""Brief §6.2 — an edge without (complete) provenance is rejected at write time."""

import pytest

from symbolic_floor.schema import ValidationError, utc_now_iso

from conftest import manual_provenance


SEQ = "sequence:" + "a" * 64


def test_reject_missing_provenance_entirely(store):
    with pytest.raises(ValidationError):
        store.add_edge("protein:P12345", "has_sequence", SEQ, provenance=None)
    assert store.get_edges() == []


def test_reject_each_missing_required_key(store):
    complete = {"source": "uniprot",
                "url": "https://rest.uniprot.org/uniprotkb/P12345.fasta",
                "retrieved_at": utc_now_iso(), "raw_id": "P12345"}
    # Per-site: every required key, named in the failure.
    for key in ("source", "url", "retrieved_at", "raw_id"):
        broken = {k: v for k, v in complete.items() if k != key}
        with pytest.raises(ValidationError, match="missing required keys"):
            store.add_edge("protein:P12345", "has_sequence", SEQ, provenance=broken)
    assert store.get_edges() == []


def test_reject_non_allowlisted_provenance_url(store):
    with pytest.raises(ValidationError, match="not allowlisted"):
        store.add_edge(
            "protein:P12345", "has_sequence", SEQ,
            provenance={"source": "uniprot", "url": "https://evil.example.com/x",
                        "retrieved_at": utc_now_iso(), "raw_id": "P12345"},
        )


def test_reject_naive_timestamp(store):
    with pytest.raises(ValidationError, match="timezone-aware"):
        store.add_edge(
            "protein:P12345", "has_sequence", SEQ,
            provenance={"source": "uniprot",
                        "url": "https://rest.uniprot.org/uniprotkb/P12345.fasta",
                        "retrieved_at": "2026-09-17T12:00:00", "raw_id": "P12345"},
        )


def test_manual_provenance_requires_citation(store):
    with pytest.raises(ValidationError, match="citation"):
        store.add_edge(
            "protein:P12345", "has_sequence", SEQ,
            provenance={"source": "manual", "url": None,
                        "retrieved_at": utc_now_iso(), "raw_id": "  "},
        )
    # And a proper manual edge (with citation) IS accepted.
    edge_id, created = store.add_edge(
        "protein:P12345", "has_sequence", SEQ, provenance=manual_provenance("doi:10/test"),
    )
    assert created and edge_id
