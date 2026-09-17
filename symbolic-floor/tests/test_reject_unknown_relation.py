"""Brief §6.1 — an edge with a relation outside the six is rejected."""

import pytest

from symbolic_floor.schema import ValidationError

from conftest import manual_provenance


def test_reject_unknown_relation(store):
    with pytest.raises(ValidationError, match="unknown relation"):
        store.add_edge(
            "protein:P12345", "regulates", "protein:P69905",
            provenance=manual_provenance(),
        )
    assert store.get_edges() == []  # nothing written


def test_reject_unknown_relation_even_from_peel_vocabulary(store):
    # The vendored engine knows is_a etc.; the FLOOR's edge API still allows
    # only the six bio relations. The engine vocabulary is not a bypass.
    with pytest.raises(ValidationError, match="unknown relation"):
        store.add_edge(
            "protein:P12345", "is_a", "protein:P69905",
            provenance=manual_provenance(),
        )
