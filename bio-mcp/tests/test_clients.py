"""Mocked-HTTP tests per client. One test per client asserts the layer-4
contract (source block present) — per-site, per the multi-site discipline."""

import json

import httpx
import pytest
import respx

from bio_mcp.clients import ensembl, ncbi_seq, pathways, pdb, preprints, pubmed, uniprot
from bio_mcp.http import BioAPIError, BioHTTP

EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"


@pytest.fixture
async def http():
    h = BioHTTP()
    yield h
    await h.aclose()


PUBMED_XML = """<?xml version="1.0"?>
<PubmedArticleSet><PubmedArticle><MedlineCitation>
  <PMID>34265844</PMID>
  <Article>
    <Journal><ISOAbbreviation>Nature</ISOAbbreviation>
      <JournalIssue><PubDate><Year>2021</Year></PubDate></JournalIssue></Journal>
    <ArticleTitle>Highly accurate protein structure prediction with AlphaFold</ArticleTitle>
    <Abstract><AbstractText>Proteins are essential.</AbstractText></Abstract>
    <AuthorList><Author><LastName>Jumper</LastName><Initials>J</Initials></Author></AuthorList>
  </Article>
</MedlineCitation><PubmedData><ArticleIdList>
  <ArticleId IdType="doi">10.1038/s41586-021-03819-2</ArticleId>
  <ArticleId IdType="pmc">PMC8371605</ArticleId>
</ArticleIdList></PubmedData></PubmedArticle></PubmedArticleSet>"""


@respx.mock
async def test_pubmed_search_pins_sources(http):
    respx.get(f"{EUTILS}/esearch.fcgi").mock(
        return_value=httpx.Response(200, json={"esearchresult": {"count": "1", "idlist": ["34265844"]}})
    )
    respx.get(f"{EUTILS}/efetch.fcgi").mock(return_value=httpx.Response(200, text=PUBMED_XML))
    out = await pubmed.search_pubmed(http, "alphafold")
    assert out["total_matches"] == 1
    art = out["articles"][0]
    assert art["pmid"] == "34265844"
    assert art["doi"] == "10.1038/s41586-021-03819-2"
    assert art["source"]["url"] == "https://pubmed.ncbi.nlm.nih.gov/34265844/"
    assert "PMID: 34265844" in art["citation"]


async def test_pubmed_rejects_empty_query(http):
    with pytest.raises(ValueError):
        await pubmed.search_pubmed(http, "  ")


async def test_pubmed_abstracts_caps_at_100(http):
    with pytest.raises(ValueError):
        await pubmed.fetch_abstracts(http, [str(i) for i in range(101)])


@respx.mock
async def test_pmc_embargo_reported_honestly(http):
    respx.get(f"{EUTILS}/efetch.fcgi").mock(
        return_value=httpx.Response(200, text="<pmc-articleset><article></article></pmc-articleset>")
    )
    out = await pubmed.fetch_pmc_fulltext(http, "PMC123")
    assert out["full_text_available"] is False
    assert out["source"]["database"] == "pmc"


ARXIV_ATOM = """<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>http://arxiv.org/abs/2103.09992v2</id>
    <title>Deep learning for genomics</title>
    <summary>We survey.</summary>
    <published>2021-03-18T00:00:00Z</published>
    <author><name>A Author</name></author>
  </entry>
</feed>"""


@respx.mock
async def test_arxiv_search_pins_sources(http):
    respx.get("https://export.arxiv.org/api/query").mock(return_value=httpx.Response(200, text=ARXIV_ATOM))
    out = await preprints.search_arxiv(http, "genomics")
    p = out["papers"][0]
    assert p["arxiv_id"] == "2103.09992v2"
    assert p["source"]["url"] == "https://arxiv.org/abs/2103.09992v2"


@respx.mock
async def test_biorxiv_fetch_pins_sources(http):
    respx.get("https://api.biorxiv.org/details/biorxiv/10.1101/2020.02.07.937862").mock(
        return_value=httpx.Response(
            200,
            json={"collection": [{"version": "1", "title": "T", "authors": "Doe, J.", "date": "2020-02-08", "category": "microbiology", "abstract": "A", "published": "NA"}]},
        )
    )
    out = await preprints.fetch_biorxiv_preprint(http, "10.1101/2020.02.07.937862")
    assert out["peer_reviewed_version"] is None
    assert out["source"]["url"].startswith("https://www.biorxiv.org/content/10.1101/")


async def test_biorxiv_rejects_non_biorxiv_doi(http):
    with pytest.raises(ValueError):
        await preprints.fetch_biorxiv_preprint(http, "10.1038/nature")


UNIPROT_ENTRY = {
    "primaryAccession": "P04637",
    "uniProtkbId": "P53_HUMAN",
    "entryType": "UniProtKB reviewed (Swiss-Prot)",
    "proteinDescription": {"recommendedName": {"fullName": {"value": "Cellular tumor antigen p53"}}},
    "genes": [{"geneName": {"value": "TP53"}}],
    "organism": {"scientificName": "Homo sapiens"},
    "comments": [
        {"commentType": "FUNCTION", "texts": [{"value": "Acts as a tumor suppressor."}]},
        {"commentType": "DISEASE", "disease": {"diseaseId": "LFS1", "description": "Li-Fraumeni syndrome"}, "texts": []},
    ],
    "features": [{"type": "Domain", "description": "DNA-binding", "location": {"start": {"value": 102}, "end": {"value": 292}}}],
    "uniProtKBCrossReferences": [{"database": "PDB", "id": "1TUP"}],
    "sequence": {"value": "MEEPQSDPSV", "length": 10},
}


@respx.mock
async def test_uniprot_entry_pins_sources(http):
    respx.get("https://rest.uniprot.org/uniprotkb/P04637").mock(return_value=httpx.Response(200, json=UNIPROT_ENTRY))
    out = await uniprot.fetch_uniprot_entry(http, "p04637")
    assert out["protein_name"] == "Cellular tumor antigen p53"
    assert out["genes"] == ["TP53"]
    assert out["pdb_structures"] == ["1TUP"]
    assert "Li-Fraumeni" in out["disease"][0]
    assert out["source"]["url"] == "https://www.uniprot.org/uniprotkb/P04637/entry"


@respx.mock
async def test_pdb_entry_pins_sources(http):
    respx.get("https://data.rcsb.org/rest/v1/core/entry/6VXX").mock(
        return_value=httpx.Response(
            200,
            json={
                "rcsb_id": "6VXX",
                "struct": {"title": "SARS-CoV-2 spike"},
                "rcsb_entry_info": {"experimental_method": "EM", "resolution_combined": [2.8], "polymer_entity_count_total": 1, "molecular_weight": 438.5},
                "rcsb_accession_info": {"deposit_date": "2020-02-25T00:00:00Z"},
                "citation": [{"title": "Structure...", "rcsb_journal_abbrev": "Science", "year": 2020, "pdbx_database_id_doi": "10.1126/science.abb2507", "pdbx_database_id_pub_med": 32075877}],
            },
        )
    )
    out = await pdb.fetch_pdb_entry(http, "6vxx")
    assert out["resolution_angstrom"] == 2.8
    assert out["primary_citation"]["pmid"] == 32075877
    assert out["source"]["url"] == "https://www.rcsb.org/structure/6VXX"
    assert out["download"]["cif"].endswith("6VXX.cif")


async def test_pdb_rejects_bad_id(http):
    with pytest.raises(ValueError):
        await pdb.fetch_pdb_entry(http, "TOOLONG")


@respx.mock
async def test_ncbi_fetch_sequence_pins_sources(http):
    respx.get(f"{EUTILS}/efetch.fcgi").mock(
        return_value=httpx.Response(200, text=">NC_045512.2 SARS-CoV-2\nATTAAAGGTTTAT")
    )
    out = await ncbi_seq.fetch_sequence(http, "NC_045512.2")
    assert out["text"].startswith(">NC_045512.2")
    assert out["source"]["url"] == "https://www.ncbi.nlm.nih.gov/nuccore/NC_045512.2"


@respx.mock
async def test_ncbi_fetch_sequence_saves_to_file(http, tmp_path):
    respx.get(f"{EUTILS}/efetch.fcgi").mock(return_value=httpx.Response(200, text=">X\nACGT"))
    dest = tmp_path / "x.fasta"
    out = await ncbi_seq.fetch_sequence(http, "X1", save_path=str(dest))
    assert dest.read_text().startswith(">X")
    assert out["saved_to"] == str(dest)


async def test_ncbi_rejects_bad_db(http):
    with pytest.raises(ValueError):
        await ncbi_seq.fetch_sequence(http, "X", db="genome")


@respx.mock
async def test_ensembl_gene_pins_sources(http):
    respx.get("https://rest.ensembl.org/lookup/symbol/homo_sapiens/TP53").mock(
        return_value=httpx.Response(
            200,
            json={"id": "ENSG00000141510", "display_name": "TP53", "species": "homo_sapiens", "description": "tumor protein p53", "biotype": "protein_coding", "seq_region_name": "17", "start": 7661779, "end": 7687538, "strand": -1, "assembly_name": "GRCh38", "canonical_transcript": "ENST00000269305.9"},
        )
    )
    out = await ensembl.lookup_gene(http, "TP53")
    assert out["gene_id"] == "ENSG00000141510"
    assert out["assembly"] == "GRCh38"
    assert out["source"]["url"] == "https://www.ensembl.org/id/ENSG00000141510"


@respx.mock
async def test_ensembl_sequence_rejects_non_fasta(http):
    respx.get("https://rest.ensembl.org/sequence/id/ENSG1").mock(return_value=httpx.Response(200, text="{}"))
    with pytest.raises(BioAPIError):
        await ensembl.fetch_ensembl_sequence(http, "ENSG1")


@respx.mock
async def test_kegg_search_pins_sources(http):
    respx.get("https://rest.kegg.jp/find/pathway/glycolysis").mock(
        return_value=httpx.Response(200, text="path:map00010\tGlycolysis / Gluconeogenesis\n")
    )
    out = await pathways.search_kegg(http, "glycolysis")
    assert out["entries"][0]["kegg_id"] == "path:map00010"
    assert out["entries"][0]["source"]["url"] == "https://www.kegg.jp/entry/path:map00010"


@respx.mock
async def test_reactome_search_pins_sources(http):
    respx.get("https://reactome.org/ContentService/search/query").mock(
        return_value=httpx.Response(
            200,
            json={"results": [{"typeName": "Pathway", "entries": [{"stId": "R-HSA-69488", "name": "G1/S Transition", "exactType": "Pathway", "species": "Homo sapiens"}]}]},
        )
    )
    out = await pathways.search_reactome(http, "cell cycle")
    assert out["entries"][0]["stable_id"] == "R-HSA-69488"
    assert out["entries"][0]["source"]["url"] == "https://reactome.org/content/detail/R-HSA-69488"
