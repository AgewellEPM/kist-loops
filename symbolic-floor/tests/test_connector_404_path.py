"""Brief §6.9 — 404 -> connector returns its no-evidence status and writes NO edge."""

from symbolic_floor.connectors import alphafold, pdb, uniprot

from conftest import transport_for


def test_uniprot_404_writes_nothing(store):
    t = transport_for({
        "https://rest.uniprot.org/uniprotkb/Q9Q9Q9.fasta": (404, b"not found"),
    })
    result = uniprot.fetch_sequence(store, "Q9Q9Q9", transport=t)
    assert result["status"] == "NOT_FOUND"
    assert store.get_edges() == []
    rows = store.db.execute("SELECT COUNT(*) c FROM sequences").fetchone()
    assert rows["c"] == 0


def test_pdb_404_writes_nothing(store):
    t = transport_for({
        "https://rest.uniprot.org/uniprotkb/Q9Q9Q9.json": (404, b"not found"),
    })
    result = pdb.fetch_experimental_structure(store, "Q9Q9Q9", transport=t)
    assert result["status"] == "NOT_FOUND"
    assert store.get_edges() == []


def test_pdb_no_crossref_writes_nothing(store):
    t = transport_for({
        "https://rest.uniprot.org/uniprotkb/P12345.json":
            (200, b'{"primaryAccession": "P12345", "uniProtKBCrossReferences": []}'),
    })
    result = pdb.fetch_experimental_structure(store, "P12345", transport=t)
    assert result["status"] == "NO_EXPERIMENTAL_STRUCTURE"
    assert store.get_edges() == []


def test_uniprot_200_empty_body_is_not_found(store):
    """Live quirk: UniProt answers a nonexistent accession with 200 + EMPTY body,
    not 404. Both UniProt-hitting connectors must treat empty as absent —
    one assertion per site."""
    t = transport_for({
        "https://rest.uniprot.org/uniprotkb/Q9ZZZ9.fasta": (200, b""),
    })
    assert uniprot.fetch_sequence(store, "Q9ZZZ9", transport=t)["status"] == "NOT_FOUND"
    assert store.get_edges() == []

    t2 = transport_for({
        "https://rest.uniprot.org/uniprotkb/Q9ZZZ9.json": (200, b"  "),
    })
    assert pdb.fetch_experimental_structure(store, "Q9ZZZ9", transport=t2)["status"] == "NOT_FOUND"
    assert store.get_edges() == []


def test_alphafold_404_writes_nothing(store):
    t = transport_for({
        "https://alphafold.ebi.ac.uk/api/prediction/Q9Q9Q9": (404, b"not found"),
    })
    result = alphafold.fetch_prediction(store, "Q9Q9Q9", transport=t)
    assert result["status"] == "NO_PREDICTION"
    assert store.get_edges() == []
