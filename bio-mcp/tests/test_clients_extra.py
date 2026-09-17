"""Mocked-HTTP tests for the expansion clients (scholarly, structure_extra,
chem, variants). One test per function asserts the layer-4 source contract and
the input-validation rejection — per-site, per the multi-site discipline.

Live shapes here are distilled from the agents' live-verification runs
(2026-09-17): OpenAlex full-URL ids, InterPro 204-empty, PubChem SMILES-key
migration, ClinVar germline_classification, dbSNP SPDI position.
"""

import httpx
import pytest
import respx

from bio_mcp.clients import chem, scholarly, structure_extra, variants
from bio_mcp.http import BioAPIError, BioHTTP

EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
ENSEMBL = "https://rest.ensembl.org"


@pytest.fixture
async def http():
    h = BioHTTP()
    yield h
    await h.aclose()


# ================= scholarly: OpenAlex + Semantic Scholar =================

OPENALEX_WORK = {
    "id": "https://openalex.org/W2741809807",
    "title": "The state of OA",
    "publication_year": 2018,
    "doi": "https://doi.org/10.7717/peerj.4375",
    "cited_by_count": 900,
    "authors": [],
    "authorships": [{"author": {"display_name": "Heather Piwowar"}}],
    "primary_location": {"source": {"display_name": "PeerJ"}},
    "referenced_works_count": 71,
    "concepts": [{"display_name": "Open access", "score": 0.9}],
    # inverted index → "Despite growing interest"
    "abstract_inverted_index": {"Despite": [0], "growing": [1], "interest": [2]},
}


@respx.mock
async def test_openalex_search_pins_short_id(http):
    respx.get("https://api.openalex.org/works").mock(
        return_value=httpx.Response(200, json={"results": [OPENALEX_WORK]})
    )
    out = await scholarly.search_openalex(http, "open access")
    w = out["works"][0]
    assert w["openalex_id"] == "W2741809807"  # full-URL prefix stripped
    assert w["doi"] == "10.7717/peerj.4375"  # doi.org prefix stripped
    assert w["venue"] == "PeerJ"  # primary_location.source, not legacy host_venue
    assert w["source"]["url"] == "https://openalex.org/W2741809807"


@respx.mock
async def test_openalex_work_reconstructs_abstract(http):
    respx.get(url__startswith="https://api.openalex.org/works/").mock(
        return_value=httpx.Response(200, json=OPENALEX_WORK)
    )
    out = await scholarly.openalex_work(http, "W2741809807")
    assert out["abstract"] == "Despite growing interest"  # inverted index rebuilt in order
    assert out["referenced_works_count"] == 71
    assert out["related_concepts"][0]["name"] == "Open access"


async def test_openalex_rejects_empty_query(http):
    with pytest.raises(ValueError):
        await scholarly.search_openalex(http, "   ")


@respx.mock
async def test_semantic_scholar_search_pins_sources(http):
    respx.get(url__startswith="https://api.semanticscholar.org/graph/v1/paper/search").mock(
        return_value=httpx.Response(
            200,
            json={"data": [{"paperId": "abc123", "title": "T", "year": 2020,
                            "citationCount": 5, "authors": [{"name": "A Author"}],
                            "venue": "Nature", "externalIds": {"DOI": "10.1/x"}}]},
        )
    )
    out = await scholarly.search_semantic_scholar(http, "crispr")
    p = out["papers"][0]
    assert p["paper_id"] == "abc123"
    assert p["doi"] == "10.1/x"
    assert p["source"]["url"] == "https://www.semanticscholar.org/paper/abc123"


@respx.mock
async def test_semantic_scholar_citations_unwraps_envelope(http):
    respx.get(url__startswith="https://api.semanticscholar.org/graph/v1/paper/").mock(
        return_value=httpx.Response(
            200,
            json={"data": [{"citingPaper": {"paperId": "cite1", "title": "C", "year": 2021,
                                            "authors": [], "externalIds": {}}}]},
        )
    )
    out = await scholarly.semantic_scholar_citations(http, "abc123")
    assert out["citing_papers"][0]["paper_id"] == "cite1"
    assert out["citing_papers"][0]["source"]["database"] == "semanticscholar"


async def test_semantic_scholar_rejects_empty_id(http):
    with pytest.raises(ValueError):
        await scholarly.semantic_scholar_citations(http, "  ")


# ================= structure_extra: AlphaFold + InterPro =================

@respx.mock
async def test_alphafold_prediction_pins_and_counts(http):
    # A list of 2 (fragmented protein) — model_count must be honest.
    respx.get(url__startswith="https://alphafold.ebi.ac.uk/api/prediction/").mock(
        return_value=httpx.Response(200, json=[
            {"uniprotAccession": "P04637", "uniprotId": "P53_HUMAN",
             "organismScientificName": "Homo sapiens", "latestVersion": 4,
             "cifUrl": "https://a/x.cif", "pdbUrl": "https://a/x.pdb",
             "globalMetricValue": 82.5},
            {"uniprotAccession": "P04637"},
        ])
    )
    out = await structure_extra.alphafold_prediction(http, "p04637")
    assert out["model_count"] == 2
    assert out["model"]["mean_plddt"] == 82.5
    assert out["model"]["downloads"]["cif"] == "https://a/x.cif"
    assert out["source"]["url"] == "https://alphafold.ebi.ac.uk/entry/P04637"


@respx.mock
async def test_alphafold_empty_list_is_error(http):
    respx.get(url__startswith="https://alphafold.ebi.ac.uk/api/prediction/").mock(
        return_value=httpx.Response(200, json=[])
    )
    with pytest.raises(BioAPIError):
        await structure_extra.alphafold_prediction(http, "P00000")


@respx.mock
async def test_interpro_protein_204_is_zero_not_error(http):
    # InterPro answers a valid protein with no matches via HTTP 204 (empty body).
    respx.get(url__startswith="https://www.ebi.ac.uk/interpro/api/entry/interpro/protein/uniprot/").mock(
        return_value=httpx.Response(204)
    )
    out = await structure_extra.interpro_protein_domains(http, "P0DPR3")
    assert out["returned"] == 0 and out["total"] == 0 and out["entries"] == []


@respx.mock
async def test_interpro_protein_pins_entries(http):
    respx.get(url__startswith="https://www.ebi.ac.uk/interpro/api/entry/interpro/protein/uniprot/").mock(
        return_value=httpx.Response(200, json={
            "count": 3,
            "results": [{"metadata": {"accession": "IPR002117", "name": "p53 tumour suppressor",
                                      "type": "family", "source_database": "interpro"}}],
        })
    )
    out = await structure_extra.interpro_protein_domains(http, "P04637")
    e = out["entries"][0]
    assert e["interpro_id"] == "IPR002117"
    assert out["total"] == 3
    assert e["source"]["url"] == "https://www.ebi.ac.uk/interpro/entry/InterPro/IPR002117/"


@respx.mock
async def test_interpro_entry_cleans_description(http):
    respx.get("https://www.ebi.ac.uk/interpro/api/entry/interpro/IPR002117").mock(
        return_value=httpx.Response(200, json={"metadata": {
            "accession": "IPR002117", "name": {"name": "p53", "short": "P53"},
            "type": "family",
            "description": [{"text": "<p>The p53 protein [[cite:PUB00001]] is a suppressor.</p>"}],
            "member_databases": {"pfam": {}, "panther": {}},
            "counters": {"proteins": 1000},
        }})
    )
    out = await structure_extra.interpro_entry(http, "ipr002117")
    assert out["name"] == "p53"
    assert "cite" not in out["description"] and "<p>" not in out["description"]
    assert out["member_databases"] == ["panther", "pfam"]
    assert out["source"]["database"] == "interpro"


async def test_interpro_entry_rejects_malformed_id(http):
    with pytest.raises(ValueError):
        await structure_extra.interpro_entry(http, "NOTANIPR")


# ================= chem: PubChem + ChEMBL =================

@respx.mock
async def test_pubchem_name_uses_migrated_smiles_keys(http):
    # New keys ConnectivitySMILES/SMILES populated; deprecated keys null.
    respx.get(url__startswith="https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/").mock(
        return_value=httpx.Response(200, json={"PropertyTable": {"Properties": [{
            "CID": 2244, "MolecularFormula": "C9H8O4", "MolecularWeight": "180.16",
            "ConnectivitySMILES": "CC(=O)OC1=CC=CC=C1C(=O)O",
            "SMILES": "CC(=O)OC1=CC=CC=C1C(=O)O",
            "CanonicalSMILES": None, "IsomericSMILES": None,
            "IUPACName": "2-acetyloxybenzoic acid", "InChIKey": "BSYNRYMUTXBXSQ-UHFFFAOYSA-N",
            "XLogP": 1.2,
        }]}})
    )
    out = await chem.pubchem_compound_by_name(http, "aspirin")
    assert out["cid"] == 2244
    assert out["canonical_smiles"] == "CC(=O)OC1=CC=CC=C1C(=O)O"  # from ConnectivitySMILES
    assert out["isomeric_smiles"] == "CC(=O)OC1=CC=CC=C1C(=O)O"  # from SMILES
    assert out["source"]["url"] == "https://pubchem.ncbi.nlm.nih.gov/compound/2244"


async def test_pubchem_cid_rejects_nonpositive(http):
    with pytest.raises(ValueError):
        await chem.pubchem_compound_by_cid(http, 0)
    with pytest.raises(ValueError):
        await chem.pubchem_compound_by_cid(http, "notanumber")


@respx.mock
async def test_chembl_search_pins_sources(http):
    respx.get(url__startswith="https://www.ebi.ac.uk/chembl/api/data/molecule/search").mock(
        return_value=httpx.Response(200, json={"molecules": [{
            "molecule_chembl_id": "CHEMBL941", "pref_name": "IMATINIB", "max_phase": "4",
            "molecule_type": "Small molecule", "molecule_properties": {"full_mwt": "493.6", "alogp": "3.0"},
        }]})
    )
    out = await chem.chembl_search_molecule(http, "imatinib")
    m = out["molecules"][0]
    assert m["chembl_id"] == "CHEMBL941"
    assert m["full_mwt"] == "493.6"
    assert m["source"]["url"] == "https://www.ebi.ac.uk/chembl/explore/compound/CHEMBL941"


@respx.mock
async def test_chembl_bioactivity_pins_molecule(http):
    respx.get(url__startswith="https://www.ebi.ac.uk/chembl/api/data/activity").mock(
        return_value=httpx.Response(200, json={"activities": [{
            "target_chembl_id": "CHEMBL1862", "standard_type": "IC50",
            "standard_value": "40", "standard_units": "nM",
            "assay_chembl_id": "CHEMBL...", "target_organism": "Homo sapiens",
        }]})
    )
    out = await chem.chembl_bioactivities(http, "chembl941")
    assert out["chembl_id"] == "CHEMBL941"  # normalized upper
    assert out["activities"][0]["standard_type"] == "IC50"
    assert out["source"]["database"] == "chembl"


async def test_chembl_bioactivity_rejects_bad_id(http):
    with pytest.raises(ValueError):
        await chem.chembl_bioactivities(http, "941")  # missing CHEMBL prefix


# ================= variants: ClinVar + dbSNP + VEP =================

CLINVAR_DOC = {
    "accession_version": "VCV000012345.1",
    "title": "NM_007294.4(BRCA1):c.68_69del",
    "genes": [{"symbol": "BRCA1"}],
    "obj_type": "Deletion",
    "molecular_consequence_list": ["frameshift"],
    "variation_set": [{"canonical_spdi": "NC_000017.11:..."}],
    "germline_classification": {
        "description": "Pathogenic",
        "review_status": "criteria provided, multiple submitters, no conflicts",
        "trait_set": [{"trait_name": "Hereditary breast ovarian cancer syndrome"}],
    },
}


@respx.mock
async def test_clinvar_search_carries_verbatim_classification(http):
    respx.get(f"{EUTILS}/esearch.fcgi").mock(
        return_value=httpx.Response(200, json={"esearchresult": {"count": "1", "idlist": ["12345"]}})
    )
    respx.get(f"{EUTILS}/esummary.fcgi").mock(
        return_value=httpx.Response(200, json={"result": {"12345": CLINVAR_DOC}})
    )
    out = await variants.clinvar_search(http, "BRCA1 pathogenic")
    v = out["variants"][0]
    g = v["classifications"]["germline"]
    assert g["clinical_significance"] == "Pathogenic"  # VERBATIM, not re-graded
    assert "multiple submitters" in g["review_status"]  # paired with significance
    assert v["source"]["url"] == "https://www.ncbi.nlm.nih.gov/clinvar/variation/12345/"
    assert "not medical advice" in out["disclaimer"]


async def test_clinvar_variant_rejects_nonnumeric(http):
    with pytest.raises(ValueError):
        await variants.clinvar_variant(http, "BRCA1")


@respx.mock
async def test_dbsnp_variant_normalizes_and_positions(http):
    respx.get(f"{EUTILS}/esummary.fcgi").mock(
        return_value=httpx.Response(200, json={"result": {"328": {
            "chr": "8", "spdi": "NC_000008.11:19962212:C:A",
            "genes": [{"name": "LPL"}], "clinical_significance": "benign",
            "acc": "NC_000008.11", "docsum": "HGVS=NC_000008.11:g.19962213C>A|SEQ=...",
            "fxn_class": "missense_variant",
        }}})
    )
    out = await variants.dbsnp_variant(http, "rs328")
    assert out["rsid"] == "rs328"
    assert out["position"] == "8:19962213"  # SPDI 0-based 19962212 → 1-based +1
    assert out["clinical_significance"] == "benign"  # VERBATIM
    assert out["source"]["url"] == "https://www.ncbi.nlm.nih.gov/snp/rs328"


async def test_dbsnp_rejects_non_numeric(http):
    with pytest.raises(ValueError):
        await variants.dbsnp_variant(http, "rsABC")


@respx.mock
async def test_vep_rsid_pins_to_dbsnp(http):
    respx.get(url__startswith=f"{ENSEMBL}/vep/human/id/").mock(
        return_value=httpx.Response(200, json=[{
            "assembly_name": "GRCh38", "seq_region_name": "1", "start": 100, "end": 100,
            "allele_string": "A/G", "most_severe_consequence": "missense_variant",
            "transcript_consequences": [{"gene_symbol": "AGT", "transcript_id": "ENST1",
                                         "consequence_terms": ["missense_variant"], "impact": "MODERATE",
                                         "sift_prediction": "tolerated", "sift_score": 0.1}],
        }])
    )
    out = await variants.vep_consequences(http, "rs699")
    assert out["input_mode"] == "rsid"
    assert out["source"]["database"] == "dbsnp"  # rsID → dbSNP provenance
    assert out["transcript_consequences"][0]["sift"]["prediction"] == "tolerated"
    assert "not medical advice" in out["disclaimer"]


@respx.mock
async def test_vep_hgvs_pins_to_ensembl(http):
    respx.get(url__startswith=f"{ENSEMBL}/vep/human/hgvs/").mock(
        return_value=httpx.Response(200, json=[{
            "assembly_name": "GRCh38", "most_severe_consequence": "missense_variant",
            "transcript_consequences": [],
        }])
    )
    out = await variants.vep_consequences(http, "ENST00000366667.4:c.776T>C")
    assert out["input_mode"] == "hgvs"
    assert out["source"]["database"] == "ensembl"  # HGVS → Ensembl provenance keyed on query


async def test_vep_rejects_empty(http):
    with pytest.raises(ValueError):
        await variants.vep_consequences(http, "  ")
