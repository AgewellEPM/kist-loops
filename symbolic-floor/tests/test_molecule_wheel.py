"""Molecule wheel (PubChem, slice 2) against canned transports — name->CID,
identity facts, synonyms, PEEL tiles, idempotency. No live net.

Fixture: WATER (PubChem CID 962). The exact failing case Luke hit — "the floor
doesn't know what water is" — is the assertion here: after research_molecule,
the floor holds H2O / oxidane / InChIKey / 18.015 g/mol as typed, provenanced
edges, and a canonical-37 tile trace.
"""

import json

from symbolic_floor import extract
from symbolic_floor.connectors import pubchem

from conftest import transport_for

CID = 962
NAME_URL = "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/water/cids/JSON"
PROP_URL = ("https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/cid/962"
            "/property/MolecularFormula,IUPACName,InChIKey,MolecularWeight/JSON")
SYN_URL = "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/cid/962/synonyms/JSON"

NAME_BODY = json.dumps({"IdentifierList": {"CID": [962]}}).encode()
PROP_BODY = json.dumps({"PropertyTable": {"Properties": [{
    "CID": 962, "MolecularFormula": "H2O", "IUPACName": "oxidane",
    "InChIKey": "XLYOFNOQVPJJNP-UHFFFAOYSA-N", "MolecularWeight": "18.015",
}]}}).encode()
SYN_BODY = json.dumps({"InformationList": {"Information": [{
    "CID": 962, "Synonym": ["water", "Dihydrogen oxide", "Oxidane",
                            "H2O", "Distilled water"],
}]}}).encode()


def _water_transport():
    return transport_for({NAME_URL: (200, NAME_BODY),
                          PROP_URL: (200, PROP_BODY),
                          SYN_URL: (200, SYN_BODY)})


def test_resolve_name_to_cid(store):
    t = transport_for({NAME_URL: (200, NAME_BODY)})
    got = pubchem.resolve_cid("water", transport=t)
    assert got["status"] == "OK"
    assert got["cid"] == 962


def test_resolve_unknown_name_is_not_found(store):
    url = "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/notamolecule999/cids/JSON"
    t = transport_for({url: (404, b"")})
    got = pubchem.resolve_cid("notamolecule999", transport=t)
    assert got["status"] == "NOT_FOUND"


def test_research_water_writes_real_chemistry(store):
    """The headline: research 'water' -> the floor knows H2O / oxidane / key / weight."""
    result = extract.research_molecule(store, "water", transport=_water_transport())
    assert result["status"] == "OK"
    assert result["resolved_cid"] == 962

    # The four canonical identity edges + the synonyms, all under molecule:962.
    edges = {(e["relation_type"], e["object"])
             for e in store.get_edges(source="molecule:962")}
    assert ("has_formula", "formula:H2O") in edges
    assert ("has_iupac_name", "compound:oxidane") in edges
    assert ("has_inchikey", "inchikey:XLYOFNOQVPJJNP-UHFFFAOYSA-N") in edges
    assert ("has_weight", "weight:18.015") in edges
    assert ("known_as", "compound:water") in edges

    # Every chemistry edge is provenance-pinned to pubchem — no unpinned facts.
    for e in store.get_edges(source="molecule:962"):
        prov = json.loads(e["provenance_json"])
        assert prov["source"] == "pubchem"
        assert prov["url"].startswith("https://pubchem.ncbi.nlm.nih.gov/")
        assert prov["raw_id"] == "962"


def test_formula_case_is_preserved(store):
    """Hill formula is case-sensitive (CO != Co); it must NOT be slugged."""
    extract.research_molecule(store, "water", transport=_water_transport())
    formulas = [e["object"] for e in store.get_edges(source="molecule:962",
                                                     relation="has_formula")]
    assert formulas == ["formula:H2O"]  # exact case, not "formula:h2o"


def test_molecule_wheel_writes_peel_tiles(store):
    result = extract.research_molecule(store, "water", transport=_water_transport())
    trace = result["peel_trace"]
    assert trace["tiles_written"] >= 1
    # Root tile + one per identity/synonym fact, all under chem-wheel:962.
    rows = store.db.execute(
        "SELECT id, emoji, sentence, topic FROM responses WHERE conversation_id = ?",
        ("chem-wheel:962",)).fetchall()
    assert len(rows) == trace["tiles_total"]
    assert any("H2O" in (r["sentence"] or "") for r in rows)
    assert all(r["topic"] == "chemistry:962" for r in rows)


def test_research_molecule_is_idempotent(store):
    t = _water_transport()
    first = extract.research_molecule(store, "water", transport=t)
    second = extract.research_molecule(store, "water", transport=_water_transport())
    assert first["status"] == second["status"] == "OK"
    # Re-running writes NO new edges and NO new tiles.
    assert second["edges_written"] == []
    assert second["peel_trace"]["tiles_written"] == 0
    # Exactly one canonical formula edge, never duplicated.
    assert len(store.get_edges(source="molecule:962", relation="has_formula")) == 1
