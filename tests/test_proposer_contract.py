"""Proposer gate pins — the grammar that makes ANY model airtight.

No model needed: these pin the strict parse (what gets through) and the
dataset generator's own compliance (every training pair passes the same
gate it teaches).
"""

import json

import pytest

from proposer.contract import parse_proposal
from proposer.dataset import generate_pairs
from symbolic_floor.schema import ValidationError


def test_valid_shapes_parse():
    claim = parse_proposal(json.dumps({
        "kind": "claim", "subject": "p69905",
        "shape": "structural-consistency-v1", "predicted_outcome": "consistent"}))
    assert claim["subject"] == "P69905"  # normalized upper

    extract = parse_proposal('{"kind": "extract", "subject": "Q5VSL9"}')
    assert extract == {"kind": "extract", "subject": "Q5VSL9"}

    intent = parse_proposal(json.dumps({
        "kind": "intent", "subject": "P69905", "intent": "measure_sample",
        "params": {"target": "well:D1", "wavelength_nm": 280},
        "predicted_outcome": "a reading"}))
    assert intent["intent"] == "measure_sample"

    abstain = parse_proposal('{"kind": "abstain", "reason": "unknown protein"}')
    assert abstain["kind"] == "abstain"


def test_fenced_json_tolerated_but_only_fences():
    got = parse_proposal('```json\n{"kind": "abstain", "reason": "x"}\n```')
    assert got["kind"] == "abstain"
    with pytest.raises(ValidationError):
        parse_proposal('Sure! Here is the JSON: {"kind": "abstain", "reason": "x"}')


@pytest.mark.parametrize("bad,match", [
    ("not json at all", "not valid JSON"),
    ('["a", "list"]', "JSON object"),
    ('{"kind": "prophecy"}', "kind must be one of"),
    ('{"kind": "abstain"}', "requires a reason"),
    ('{"kind": "claim", "subject": "FLURBOZYME", "shape": "structural-consistency-v1", "predicted_outcome": "x"}',
     "malformed protein id"),
    ('{"kind": "claim", "subject": "P69905", "shape": "made-up-shape-v9", "predicted_outcome": "x"}',
     "claim.shape must be"),
    ('{"kind": "claim", "subject": "P69905", "shape": "structural-consistency-v1"}',
     "requires predicted_outcome"),
    ('{"kind": "intent", "subject": "P69905", "intent": "summon", "params": {}, "predicted_outcome": "x"}',
     "intent must be one of"),
    ('{"kind": "intent", "subject": "P69905", "intent": "incubate", "params": "hot", "predicted_outcome": "x"}',
     "params object"),
], ids=["prose", "list", "bad-kind", "no-reason", "fake-accession",
        "invented-shape", "no-prediction", "invented-intent", "params-not-dict"])
def test_hallucination_shapes_rejected(bad, match):
    """Each id is a REAL failure mode observed in the baseline eval —
    the gate must reject every one of them."""
    with pytest.raises(ValidationError, match=match):
        parse_proposal(bad)


def test_every_training_pair_passes_the_gate(store):
    """The dataset can only teach what the gate admits — self-consistency."""
    rows = generate_pairs(store, seed=1)
    assert len(rows) > 100
    for row in rows:
        parse_proposal(row["messages"][2]["content"])  # must not raise


def test_dataset_deterministic(store):
    a = json.dumps(generate_pairs(store, seed=7), sort_keys=True)
    b = json.dumps(generate_pairs(store, seed=7), sort_keys=True)
    assert a == b
