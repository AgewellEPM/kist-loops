"""Library selection narrows the wheel honestly (trace names what was
disabled; no disabled archive is ever contacted), and the structure
parser reads real PDB-format text without network."""

from __future__ import annotations

import json

import pytest

from conftest import transport_for
from dashboard.structures import parse_ca_atoms, resolve_url
from symbolic_floor.extract import extract_protein
from symbolic_floor.schema import ValidationError

ACC = "P99998"
ENTRY_URL = f"https://rest.uniprot.org/uniprotkb/{ACC}.json"
ENTRY = {
    "primaryAccession": ACC,
    "genes": [{"geneName": {"value": "TST1"}}],
    "organism": {"scientificName": "Homo sapiens"},
    "uniProtKBCrossReferences": [{"database": "PDB", "id": "1TST"}],
}


def test_disabled_libraries_are_not_fetched_and_are_reported(store):
    # Route table contains ONLY the entry URL: any other fetch would hit
    # the stub's unknown-URL assertion and fail the test.
    transport = transport_for({ENTRY_URL: (200, json.dumps(ENTRY).encode())})
    r = extract_protein(store, ACC, transport=transport,
                        enabled={"uniprot"})
    assert r["status"] == "OK"
    assert sorted(r["libraries_disabled"]) == ["alphafold", "pdb", "sequence"]
    assert r["pdb_confirmed"] == 0
    rels = {e["relation"] for e in r["edges_written"]}
    assert "has_sequence" not in rels and "has_structure" not in rels \
        and "predicts_structure" not in rels
    assert "encodes" in rels          # entry facts still flow


def test_uniprot_root_cannot_be_disabled(store):
    with pytest.raises(ValidationError):
        extract_protein(store, ACC, enabled={"pdb"})


def test_unknown_library_rejected(store):
    with pytest.raises(ValidationError):
        extract_protein(store, ACC, enabled={"uniprot", "wikipedia"})


PDB_SNIPPET = """\
ATOM      1  N   MET A   1      11.104   6.134  -6.504  1.00  0.00           N
ATOM      2  CA  MET A   1      11.639   6.071  -5.147  1.00  0.00           C
ATOM      3  CA AVAL A   2       8.760   5.437  -2.800  0.50  0.00           C
ATOM      4  CA BVAL A   2       8.900   5.500  -2.900  0.50  0.00           C
ATOM      5  CA  LEU B   3       5.960   6.869  -0.800  1.00  0.00           C
HETATM    6  CA  HOH A 100       0.000   0.000   0.000  1.00  0.00           C
"""


def test_parse_ca_atoms_chains_and_altloc():
    r = parse_ca_atoms(PDB_SNIPPET)
    # 3 CA kept: MET-A, VAL-A (altloc A only), LEU-B; HETATM ignored.
    assert r["ca_total"] == 3 and len(r["atoms"]) == 3
    assert r["chains"] == ["A", "B"]
    assert r["atoms"][0]["x"] == pytest.approx(11.639)
    assert not r["truncated"]


def test_parse_ca_cap_is_reported():
    text = "\n".join(PDB_SNIPPET.splitlines()[:2] * 5)
    r = parse_ca_atoms(text, cap=2)
    assert len(r["atoms"]) == 2 and r["ca_total"] == 5 and r["truncated"]


def test_resolve_url_shapes():
    assert resolve_url("structure:1A3N").endswith("/1A3N.pdb")
    assert "alphafold" in resolve_url("AF-P69905-F1")
    with pytest.raises(ValueError):
        resolve_url("structure:../../etc/passwd")


def test_af_accession_extraction():
    from dashboard.structures import af_accession
    assert af_accession("AF-P69905-F1") == "P69905"
    assert af_accession("structure:AF-Q9Y6K9-F1") == "Q9Y6K9"
    assert af_accession("1A3N") is None
    assert af_accession("structure:1A3N") is None


def test_af_url_resolves_from_api_and_falls_back(monkeypatch):
    """AlphaFold bumps its model version; the AF URL must come from the API
    (version-current) and fall back to the pinned URL only when the API is down
    — never a stale hardcoded version that 404s."""
    import io
    from dashboard import structures as S

    # API up: return the authoritative (v6+) pdbUrl
    def api_ok(url, timeout=0):
        assert "api/prediction/P69905" in url
        body = json.dumps([{"pdbUrl": "https://alphafold.ebi.ac.uk/files/AF-P69905-F1-model_v9.pdb"}])
        return io.BytesIO(body.encode())
    monkeypatch.setattr(S.urllib.request, "urlopen", api_ok)
    assert S._af_pdb_url("AF-P69905-F1").endswith("model_v9.pdb")

    # API down: fall back to the pinned version on the same allowlisted host
    def api_down(url, timeout=0):
        raise OSError("network down")
    monkeypatch.setattr(S.urllib.request, "urlopen", api_down)
    fb = S._af_pdb_url("AF-P69905-F1")
    assert fb.startswith("https://alphafold.ebi.ac.uk/") and fb.endswith(".pdb")
