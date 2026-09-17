"""Discovery traversal is pure and deterministic: convergence nodes are
found from stored edges alone, with full edge-ID paths, no model anywhere."""

from __future__ import annotations

from dogfood.research_loop import _studied, find_convergences

from conftest import manual_provenance

SEQ_A = "MVLSPADKTN"
SEQ_B = "MVHLTPEEKS"


def _link(store, src, rel, dst):
    edge_id, _ = store.add_edge(src, rel, dst, manual_provenance(f"{src}-{dst}"))
    return edge_id


def test_convergence_found_with_paths(store):
    # Two globins sharing a domain and a disease; a third node touched once.
    e1 = _link(store, "protein:P69905", "has_part", "domain:globin")
    e2 = _link(store, "protein:P68871", "has_part", "domain:globin")
    e3 = _link(store, "protein:P68871", "affects", "disease:beta-thalassemia")
    _link(store, "protein:P69905", "belongs_to", "organism:homo_sapiens")
    _link(store, "protein:P68871", "belongs_to", "organism:homo_sapiens")

    out = find_convergences(store, ["P69905", "P68871"])
    nodes = {d["node"]: d for d in out}

    assert "domain:globin" in nodes
    globin = nodes["domain:globin"]
    assert globin["degree"] == 2
    assert globin["shared_by"] == ["protein:P68871", "protein:P69905"]
    assert {p["edge_id"] for p in globin["paths"]} == {e1, e2}

    assert "organism:homo_sapiens" in nodes          # shared by both
    assert "disease:beta-thalassemia" not in nodes   # only one protein
    assert e3 not in {p["edge_id"] for d in out for p in d["paths"]}


def test_convergence_ignores_protein_protein_and_unstudied(store):
    _link(store, "protein:P69905", "has_part", "domain:globin")
    _link(store, "protein:P02144", "has_part", "domain:globin")
    # Only P69905 is in the studied set -> no convergence at all.
    assert find_convergences(store, ["P69905"]) == []


def test_convergence_is_deterministic(store):
    for acc in ("P69905", "P68871", "P02144"):
        _link(store, f"protein:{acc}", "has_part", "domain:globin")
        _link(store, f"protein:{acc}", "belongs_to", "organism:homo_sapiens")
    a = find_convergences(store, ["P69905", "P68871", "P02144"])
    b = find_convergences(store, ["P02144", "P69905", "P68871"])
    assert a == b
    # Highest degree first, ties by node id.
    assert [d["node"] for d in a] == ["domain:globin", "organism:homo_sapiens"]


def test_studied_reads_only_ok_admitted_extracts():
    log = [
        {"phase": "extract", "target": "P69905",
         "result": {"admitted": "extract", "extraction": {"status": "OK"}}},
        {"phase": "extract", "target": "Q00000",
         "result": {"admitted": "extract",
                    "extraction": {"status": "NOT_FOUND"}}},
        {"phase": "extract", "target": "P02144",
         "result": {"admitted": "rejected_unparseable"}},
        {"phase": "probe", "target": "fictional",
         "result": {"admitted": "abstain"}},
    ]
    assert _studied(log) == ["P69905"]
