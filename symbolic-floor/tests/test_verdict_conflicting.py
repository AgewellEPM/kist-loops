"""Brief §6.7 — CONFLICTING verdicts, with the exact mismatches documented.

Mismatch A (the brief's step-5 case): protein P12345 has an experimental
structure (1ABC) but its stored AlphaFold prediction is AF-Q99999-F1 — the
predicted structure's EMBEDDED accession (Q99999) provably differs from the
claim's protein (P12345) by ID comparison alone.

Mismatch B (the embedded Peel engine's own hard-veto): has_sequence is a
FUNCTIONAL relation (one object per subject); two different sequence objects
for P12345 contradict — detected via the vendored engine's _are_compatible,
not by any slice-specific rule.
"""

from symbolic_floor.reasoner import evaluate_claim

from conftest import manual_provenance


def test_verdict_conflicting_accession_mismatch(store):
    seq = "sequence:" + "c" * 64
    e_seq, _ = store.add_edge("protein:P12345", "has_sequence", seq,
                              provenance=manual_provenance("fixture: seq"))
    # Prediction stored for a DIFFERENT accession — the provable mismatch.
    e_pred, _ = store.add_edge("protein:P12345", "predicts_structure",
                               "structure:AF-Q99999-F1",
                               provenance=manual_provenance("fixture: rogue prediction"))
    e_exp, _ = store.add_edge("protein:P12345", "has_structure", "structure:1ABC",
                              provenance=manual_provenance("fixture: experimental"))

    result = evaluate_claim(store, store.get_or_create_claim("protein:P12345"))
    assert result["verdict"] == "CONFLICTING"
    assert result["conflict"]["type"] == "accession_mismatch"
    assert result["conflict"]["predicted_edge"] == e_pred
    assert e_exp in result["conflict"]["experimental_edges"]
    # Trace shows the contradicting edges (and the walked sequence edge).
    assert {e_seq, e_pred, e_exp} <= set(result["trace"])


def test_verdict_conflicting_functional_sequence_veto(store):
    """Two different sequences for one protein — the Peel functional flag fires."""
    e_a, _ = store.add_edge("protein:P12345", "has_sequence",
                            "sequence:" + "d" * 64,
                            provenance=manual_provenance("fixture: seq A"))
    e_b, _ = store.add_edge("protein:P12345", "has_sequence",
                            "sequence:" + "e" * 64,
                            provenance=manual_provenance("fixture: seq B"))
    result = evaluate_claim(store, store.get_or_create_claim("protein:P12345"))
    assert result["verdict"] == "CONFLICTING"
    assert result["conflict"]["type"] == "functional_violation"
    assert result["conflict"]["relation"] == "has_sequence"
    assert {e_a, e_b} == set(result["trace"])
