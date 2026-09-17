"""Brief §6.5 — no has_sequence -> UNKNOWN; trace empty-but-valid, missing named."""

from symbolic_floor.reasoner import evaluate_claim


def test_verdict_unknown_when_no_sequence(store):
    claim_id = store.get_or_create_claim("protein:P12345")
    result = evaluate_claim(store, claim_id)
    assert result["verdict"] == "UNKNOWN"
    assert result["missing"] == ["has_sequence"]
    assert result["trace"] == []          # empty but present — still a valid trace
    assert result["witnesses"] == []
    assert result["floor"] == "bio-structure-floor"  # verdict names its graph
