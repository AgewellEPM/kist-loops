"""Extraction + recall pins (offline, dogfood-fixture world).

The dogfood harness drives these paths adversarially; these tests pin the
core contracts in the regular suite: typed facts derive correctly from a rich
entry, every extracted edge carries provenance, recall returns it all with
traces, and _entry_facts is a pure function.
"""

import json
from pathlib import Path

from symbolic_floor.extract import _entry_facts, extract_protein
from symbolic_floor.recall import recall_protein

DOGFOOD_FIXTURES = Path(__file__).parent.parent / "dogfood" / "fixtures"


def _rich_transport():
    entry = (DOGFOOD_FIXTURES / "rich_entry.json").read_bytes()
    fasta = (DOGFOOD_FIXTURES / "rich.fasta").read_bytes()
    rcsb = (DOGFOOD_FIXTURES / "rcsb_ok.json").read_bytes()
    af = (DOGFOOD_FIXTURES / "af_ok.json").read_bytes()

    def send(url: str, timeout: float):
        if url.endswith("P69905.json"):
            return 200, entry
        if url.endswith("P69905.fasta"):
            return 200, fasta
        if "data.rcsb.org" in url:
            return 200, rcsb
        if "alphafold" in url:
            return 200, af
        raise AssertionError(f"no route for {url}")

    return send


def test_entry_facts_pure_and_typed():
    entry = json.loads((DOGFOOD_FIXTURES / "rich_entry.json").read_text())
    facts = _entry_facts(entry, "P69905")
    triples = {(s, r, t) for s, r, t, _ in facts}
    assert ("gene:HBA1", "encodes", "protein:P69905") in triples
    assert ("protein:P69905", "belongs_to", "organism:homo_sapiens") in triples
    assert ("protein:P69905", "located_in", "location:cytoplasm") in triples
    assert ("protein:P69905", "affects", "disease:alpha-thalassemia") in triples
    assert ("protein:P69905", "has_part", "domain:globin") in triples
    # Chain features and FUNCTION comments must NOT become edges.
    assert not any(t.startswith("domain:hemoglobin") for _, _, t, _ in facts)


def test_extract_writes_and_reports(store):
    result = extract_protein(store, "P69905", transport=_rich_transport())
    assert result["status"] == "OK"
    rels = [e["relation"] for e in result["edges_written"]]
    assert rels.count("has_structure") == 5  # capped
    assert result["pdb_xrefs_total"] == 7    # cap is visible, never silent
    assert result["pdb_confirm_cap"] == 5
    # Contract: every written edge exists with provenance.
    for e in result["edges_written"]:
        stored = store.get_edges(source=e["source"], relation=e["relation"],
                                 target=e["target"])
        assert len(stored) == 1 and stored[0]["provenance_json"]


def test_recall_roundtrip_with_traces(store):
    result = extract_protein(store, "P69905", transport=_rich_transport())
    recall = recall_protein(store, "P69905")
    written_out = {e["edge_id"] for e in result["edges_written"]
                   if e["source"] == "protein:P69905"}
    recalled = {f["edge_id"] for facts in recall["facts"].values() for f in facts}
    assert written_out <= recalled, "recall must return every written edge"
    assert recall["incoming"]["encodes"], "gene->protein edges must be recallable"
    assert recall["paths"], "link-trace paths must exist"
    for f in recall["facts"]["located_in"]:
        assert f["provenance"]["source"] == "uniprot"
    assert recall["counts"]["total_edges"] == len(recalled) + len(
        {f["edge_id"] for facts in recall["incoming"].values() for f in facts}
    )
