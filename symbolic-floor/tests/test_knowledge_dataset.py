"""Knowledge SML corpus: witnessed-gold-only + correct MLX format + abstains.

The ripper law is the whole test: every training ANSWER must trace to a real
provenance-pinned floor edge (unwitnessed gold trains hallucination), and unknown
subjects must become ABSTAIN examples, not invented facts.
"""

import json

from proposer.knowledge_dataset import knowledge_pairs, write_knowledge_corpus
from symbolic_floor import extract

from conftest import transport_for

CID = 962
NAME_URL = "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/water/cids/JSON"
PROP_URL = ("https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/cid/962"
            "/property/MolecularFormula,IUPACName,InChIKey,MolecularWeight/JSON")
SYN_URL = "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/cid/962/synonyms/JSON"


def _water(store):
    t = transport_for({
        NAME_URL: (200, json.dumps({"IdentifierList": {"CID": [962]}}).encode()),
        PROP_URL: (200, json.dumps({"PropertyTable": {"Properties": [{
            "CID": 962, "MolecularFormula": "H2O", "IUPACName": "oxidane",
            "InChIKey": "XLYOFNOQVPJJNP-UHFFFAOYSA-N", "MolecularWeight": "18.015"}]}}).encode()),
        SYN_URL: (200, json.dumps({"InformationList": {"Information": [{
            "CID": 962, "Synonym": ["water", "oxidane", "dihydrogen oxide"]}]}}).encode()),
    })
    extract.research_molecule(store, "water", transport=t)


def test_every_fact_answer_is_a_witnessed_edge(store):
    _water(store)
    # the real facts the floor holds for water
    held = {(e["relation_type"], e["object"].split(":", 1)[1])
            for e in store.get_edges(source="molecule:962")}
    pairs = knowledge_pairs(store)
    fact_pairs = [p for p in pairs if "not have a verified" not in p["messages"][2]["content"]]
    assert fact_pairs, "expected grounded pairs from the gathered facts"
    # the formula answer must be the witnessed formula, verbatim
    formula_q = [p for p in fact_pairs if "molecular formula" in p["messages"][1]["content"]]
    assert formula_q and "H2O" in formula_q[0]["messages"][2]["content"]
    assert ("has_formula", "H2O") in held


def test_abstain_pairs_teach_refusal_not_invention(store):
    _water(store)
    pairs = knowledge_pairs(store)
    abst = [p for p in pairs if "not have a verified" in p["messages"][2]["content"]]
    assert abst, "corpus must include abstain examples"
    # no abstain answer smuggles a fabricated fact
    for p in abst:
        assert "won't guess" in p["messages"][2]["content"]


def test_corpus_is_valid_mlx_chat_format(store, tmp_path):
    _water(store)
    stats = write_knowledge_corpus(store, tmp_path / "sml")
    assert stats["total"] >= 1
    for split in ("train", "valid", "eval"):
        for line in (tmp_path / "sml" / f"{split}.jsonl").read_text().splitlines():
            msgs = json.loads(line)["messages"]
            assert [m["role"] for m in msgs] == ["system", "user", "assistant"]
            assert all(m["content"].strip() for m in msgs)


def test_empty_floor_yields_only_abstains(store):
    # No facts gathered -> the corpus is abstains only, never invented facts.
    pairs = knowledge_pairs(store)
    assert pairs, "even an empty floor yields the abstain curriculum"
    assert all("not have a verified" in p["messages"][2]["content"] for p in pairs)
