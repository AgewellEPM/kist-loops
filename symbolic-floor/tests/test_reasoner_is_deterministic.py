"""Brief §6.8 — 100 evaluations on the same DB are byte-identical."""

import json

from symbolic_floor.reasoner import evaluate_claim

from test_verdict_supported_roundtrip import seed_p12345


def test_reasoner_is_deterministic(store):
    seed_p12345(store)
    claim_id = store.get_or_create_claim("protein:P12345")

    baseline = json.dumps(evaluate_claim(store, claim_id), sort_keys=True).encode()
    for _ in range(99):
        again = json.dumps(evaluate_claim(store, claim_id), sort_keys=True).encode()
        assert again == baseline  # byte-identical, every time


def test_unknown_verdict_is_deterministic_too(store):
    claim_id = store.get_or_create_claim("protein:P69905")
    baseline = json.dumps(evaluate_claim(store, claim_id), sort_keys=True).encode()
    for _ in range(99):
        assert json.dumps(evaluate_claim(store, claim_id),
                          sort_keys=True).encode() == baseline
