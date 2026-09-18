"""Brief §6.4 — same sequence string twice yields the same sequence:<sha256> ID."""

import hashlib

from symbolic_floor.store import Store


def test_content_addressing(store):
    seq = "MKAILVVLLYTFATANADT"
    id_a = store.put_sequence(seq)
    id_b = store.put_sequence(seq)
    assert id_a == id_b
    expected = hashlib.sha256(seq.encode("ascii")).hexdigest()
    assert id_a == f"sequence:{expected}"
    # Exactly one row stored.
    rows = store.db.execute("SELECT COUNT(*) c FROM sequences").fetchone()
    assert rows["c"] == 1


def test_content_addressing_is_pure(store):
    # The ID function is deterministic without touching the DB.
    seq = "ACDEFGHIKLMNPQRSTVWY"
    assert Store.sequence_node_id(seq) == Store.sequence_node_id(seq)


def test_different_sequences_different_ids(store):
    assert store.put_sequence("MKAIL") != store.put_sequence("MKAIV")
