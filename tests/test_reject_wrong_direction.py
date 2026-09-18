"""Brief §6.3 — a wrongly-directed edge is a validation error, not a silent fix."""

import pytest

from symbolic_floor.schema import RELATION_DIRECTIONS, ValidationError

from conftest import manual_provenance


def test_reject_wrong_direction(store):
    with pytest.raises(ValidationError, match="wrong direction"):
        store.add_edge(
            "structure:1ABC", "has_structure", "protein:P12345",
            provenance=manual_provenance(),
        )
    assert store.get_edges() == []


def test_direction_enforced_per_relation(store):
    """Multi-site rule: one reversed-edge assertion PER relation."""
    seq = "sequence:" + "b" * 64
    claim = "claim:123e4567-e89b-42d3-a456-426614174000"
    reversed_cases = {
        "encodes":            ("protein:P12345", "gene:BRCA1"),
        "has_sequence":       (seq, "protein:P12345"),
        "has_structure":      ("structure:1ABC", "protein:P12345"),
        "predicts_structure": ("structure:AF-P12345-F1", "protein:P12345"),
        "supports_claim":     (claim, "structure:1ABC"),
        "conflicts_with":     (claim, "structure:1ABC"),
        # slice-1.5 extraction relations — same fixed-direction contract.
        "belongs_to":         ("organism:homo_sapiens", "protein:P12345"),
        "located_in":         ("location:cytoplasm", "protein:P12345"),
        "affects":            ("disease:alpha_thalassemia", "protein:P12345"),
        "has_part":           ("domain:globin", "protein:P12345"),
        # slice-2 chemistry relations (molecule wheel) — reversed = target-first.
        "has_formula":        ("formula:H2O", "molecule:962"),
        "has_iupac_name":     ("compound:oxidane", "molecule:962"),
        "known_as":           ("compound:water", "molecule:962"),
        "has_inchikey":       ("inchikey:XLYOFNOQVPJJNP-UHFFFAOYSA-N", "molecule:962"),
        "has_weight":         ("weight:18.015", "molecule:962"),
    }
    assert set(reversed_cases) == set(RELATION_DIRECTIONS), "cover every relation"
    for relation, (src, dst) in reversed_cases.items():
        with pytest.raises(ValidationError, match="wrong direction"):
            store.add_edge(src, relation, dst, provenance=manual_provenance())
    assert store.get_edges() == []
