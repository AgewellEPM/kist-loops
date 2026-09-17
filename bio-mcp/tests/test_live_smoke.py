"""Live smoke tests against real public APIs. Run explicitly: pytest -m live

One assertion per upstream service — proves the wire format assumptions hold
today, not just in mocks. Uses tiny, stable queries to stay polite.
"""

import pytest

from bio_mcp.clients import ensembl, ncbi_seq, pathways, pdb, preprints, pubmed, uniprot
from bio_mcp.http import BioHTTP

pytestmark = pytest.mark.live


@pytest.fixture
async def http():
    h = BioHTTP()
    yield h
    await h.aclose()


async def test_live_pubmed(http):
    out = await pubmed.search_pubmed(http, "AlphaFold protein structure", max_results=2)
    assert out["returned"] >= 1
    assert out["articles"][0]["source"]["url"].startswith("https://pubmed.ncbi.nlm.nih.gov/")


async def test_live_arxiv(http):
    out = await preprints.search_arxiv(http, "protein language model", max_results=2, category="q-bio")
    assert out["returned"] >= 1


async def test_live_biorxiv(http):
    out = await preprints.fetch_biorxiv_preprint(http, "10.1101/2020.02.07.937862")
    assert out["latest"]["title"]


async def test_live_uniprot(http):
    out = await uniprot.fetch_uniprot_entry(http, "P04637", include_sequence=False)
    assert out["genes"] == ["TP53"]
    assert out["reviewed"] is True


async def test_live_pdb(http):
    out = await pdb.fetch_pdb_entry(http, "6VXX")
    assert "spike" in (out["title"] or "").lower()


async def test_live_ncbi_sequence(http):
    out = await ncbi_seq.fetch_sequence(http, "NC_045512.2", fmt="fasta", save_path="/tmp/bio_mcp_smoke_cov2.fasta")
    assert out["chars"] > 29_000  # SARS-CoV-2 genome ~29.9 kb


async def test_live_ensembl(http):
    out = await ensembl.lookup_gene(http, "TP53")
    assert out["gene_id"].startswith("ENSG")


async def test_live_kegg(http):
    out = await pathways.search_kegg(http, "glycolysis", max_results=3)
    assert out["returned"] >= 1


async def test_live_reactome(http):
    out = await pathways.search_reactome(http, "apoptosis", max_results=3)
    assert out["returned"] >= 1
