"""Notebook: append-only, grounded refs, honest about corruption; the
dictation helpers derive notes strictly from what actually happened."""

from __future__ import annotations

import pytest

from dogfood.notebook import Notebook
from dogfood.research_loop import _dictate, _dictate_discoveries


@pytest.fixture()
def nb(tmp_path):
    return Notebook(tmp_path / "notebook.jsonl")


def test_note_roundtrip_and_kind_filter(nb):
    nb.note("observation", "saw a thing", session="s1", refs=["protein:P1"])
    nb.note("discovery", "found a thing", session="s1")
    got = nb.entries()
    assert [e["kind"] for e in got] == ["observation", "discovery"]
    assert got[0]["refs"] == ["protein:P1"]
    assert [e["text"] for e in nb.entries(kind="discovery")] == ["found a thing"]


def test_note_rejects_bad_kind_and_empty(nb):
    with pytest.raises(ValueError):
        nb.note("vibes", "x", session="s")
    with pytest.raises(ValueError):
        nb.note("learning", "   ", session="s")


def test_malformed_line_is_counted_not_fatal(nb):
    nb.note("learning", "good line", session="s")
    with nb.path.open("a") as f:
        f.write("{not json\n")
    got = nb.entries()
    assert got[0]["text"] == "good line"
    assert "malformed" in got[-1]["text"]


def test_digest_is_bounded(nb):
    for i in range(20):
        nb.note("observation", f"note {i}", session="s")
    digest = nb.digest(limit=5)
    assert "note 19" in digest and "note 14" not in digest


def test_dictate_probe_extract_is_anomaly(nb):
    result = {"admitted": "extract",
              "proposal": {"kind": "extract", "subject": "P0CG48"},
              "extraction": {"status": "OK", "edges_written": 21,
                             "pdb_xrefs_total": 345}}
    _dictate(nb, "s", "probe", "fictional", result)
    kinds = [e["kind"] for e in nb.entries()]
    assert kinds == ["observation", "anomaly"]
    assert "gate contained it" in nb.entries()[-1]["text"]


def test_dictate_claim_is_learning_with_refs(nb):
    result = {"admitted": "claim",
              "proposal": {"kind": "claim", "subject": "P69905",
                           "predicted_outcome": "agreement"},
              "verdict": {"verdict": "SUPPORTED", "claim_id": "claim:abc",
                          "trace": ["e1", "e2"]}}
    _dictate(nb, "s", "claim", "P69905", result)
    e = nb.entries()[0]
    assert e["kind"] == "learning" and "SUPPORTED" in e["text"]
    assert "protein:P69905" in e["refs"] and "claim:abc" in e["refs"]


def test_dictate_intent_is_reflection_with_plan(nb):
    result = {"admitted": "intent", "environment": "simulation",
              "proposal": {"kind": "intent", "subject": "P69905",
                           "intent": "measure_sample",
                           "params": {"target": "well:D3", "wavelength_nm": 595},
                           "predicted_outcome": "an absorbance reading"},
              "plan": {"status": "PLANNED", "steps": [{"step": 1}]}}
    _dictate(nb, "s", "ponder", "frontier", result)
    e = nb.entries()[0]
    assert e["kind"] == "reflection"
    assert "measure_sample" in e["text"] and "PLANNED" in e["text"]
    assert "human hand-off" in e["text"]
    assert e["refs"] == ["protein:P69905"]


def test_dictate_discoveries_compound_without_repeats(nb):
    disc = [{"node": "domain:globin", "degree": 2,
             "shared_by": ["protein:A0AAA0", "protein:B1BBB1"],
             "paths": [{"edge_id": "e1"}, {"edge_id": "e2"}]}]
    first = _dictate_discoveries(nb, "s1", disc, already=set())
    assert first == {"domain:globin"}
    again = _dictate_discoveries(nb, "s2", disc, already=first)
    assert again == set()
    assert len(nb.entries(kind="discovery")) == 1
