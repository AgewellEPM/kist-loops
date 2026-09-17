"""Regression pins for the 2026-09-17 expansion-client bug sweep (findings 1-19).

One test per finding; multi-site findings assert PER SITE with the site named
in the failure message, per the multi-site discipline. Injection findings
assert on the OUTGOING URL respx captured (encoded/validated) or that the call
raised ValueError BEFORE any request left the client (route not called).

Resolver `safe=` choices pinned here (see clients for the live evidence):
- OpenAlex /works/{id} and S2 /paper/{id}: safe=":" — ':' literal for
  doi:/DOI:/https: qualifiers, '/' percent-encoded (both APIs live-verified to
  resolve the encoded form identically), so '../' can never climb out of the
  works/paper family.
- VEP HGVS: safe=":" for HGVS's own separator; '/' rejected outright (no VEP
  notation contains one) — the live traversal repro must raise ValueError.
"""

import httpx
import pytest
import respx

from bio_mcp.clients import chem, scholarly, structure_extra, variants
from bio_mcp.http import BioAPIError, BioHTTP

EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
ENSEMBL = "https://rest.ensembl.org"
OPENALEX = "https://api.openalex.org"
S2 = "https://api.semanticscholar.org/graph/v1"
PUBCHEM = "https://pubchem.ncbi.nlm.nih.gov/rest/pug"
CHEMBL = "https://www.ebi.ac.uk/chembl/api/data"

VEP_OK = [{"most_severe_consequence": "missense_variant", "transcript_consequences": []}]

OA_WORK = {
    "id": "https://openalex.org/W2741809807",
    "title": "The state of OA",
    "publication_year": 2018,
    "doi": "https://doi.org/10.7717/peerj.4375",
    "cited_by_count": 900,
    "authorships": [{"author": {"display_name": "Heather Piwowar"}}],
    "primary_location": {"source": {"display_name": "PeerJ"}},
}


@pytest.fixture
async def http():
    h = BioHTTP()
    yield h
    await h.aclose()


# ================= variants: VEP injection (findings 1-2) =================


@respx.mock
async def test_f1_vep_traversal_variant_rejected_before_request(http):
    """Finding 1 (HIGH): the live repro — a ':'-bearing variant with '/../'
    rerouted /vep/ to /xrefs/ and laundered provenance. Must now ValueError
    with NO request leaving the client."""
    route = respx.get(url__startswith=f"{ENSEMBL}/").mock(
        return_value=httpx.Response(200, json=VEP_OK)
    )
    with pytest.raises(ValueError):
        await variants.vep_consequences(http, "a:b/../../../../xrefs/id/ENSG00000157764")
    assert not route.called, "traversal variant must be rejected before any request leaves"


@respx.mock
async def test_f1_vep_species_validated_on_both_branches(http):
    """Finding 1: species is interpolated on BOTH branches — two sites, two
    assertions. 'human/../../lookup/id' rerouted live pre-fix."""
    route = respx.get(url__startswith=f"{ENSEMBL}/").mock(
        return_value=httpx.Response(200, json=VEP_OK)
    )
    for branch, variant in [("rsid branch", "rs699"), ("hgvs branch", "ENST00000366667.4:c.776T>C")]:
        with pytest.raises(ValueError):
            await variants.vep_consequences(http, variant, species="human/../../lookup/id")
        assert not route.called, f"species traversal must be rejected pre-request on the {branch}"


@respx.mock
async def test_f1_vep_hgvs_colon_literal_specials_encoded(http):
    """Finding 1: the fix must NOT break HGVS — ':' stays literal on the wire
    ('safe=:'), while route-significant chars ('>') ride percent-encoded."""
    route = respx.get(url__startswith=f"{ENSEMBL}/vep/human/hgvs/").mock(
        return_value=httpx.Response(200, json=VEP_OK)
    )
    out = await variants.vep_consequences(http, "ENST00000366667.4:c.776T>C")
    sent = str(route.calls[0].request.url)
    assert "/vep/human/hgvs/ENST00000366667.4:c.776T%3EC" in sent
    assert out["input_mode"] == "hgvs"
    assert out["source"]["database"] == "ensembl"


@respx.mock
async def test_f1_vep_species_lowercased_and_accepted(http):
    """Finding 1: 'human' and 'homo_sapiens' (any case) must still pass."""
    route = respx.get(url__startswith=f"{ENSEMBL}/vep/homo_sapiens/id/").mock(
        return_value=httpx.Response(200, json=VEP_OK)
    )
    out = await variants.vep_consequences(http, "rs699", species="Homo_Sapiens")
    assert route.called
    assert out["species"] == "homo_sapiens"


@respx.mock
async def test_f2_vep_nonprintables_valueerror_not_invalidurl(http):
    """Finding 2 (MEDIUM): non-printables previously crashed as opaque
    httpx.InvalidURL. Now a clean ValueError, pre-request, on every input."""
    route = respx.get(url__startswith=f"{ENSEMBL}/").mock(
        return_value=httpx.Response(200, json=VEP_OK)
    )
    for site, kwargs in [
        ("variant/hgvs branch", {"variant": "ENST0001:c.1\x00T>C"}),
        ("variant/rsid branch", {"variant": "rs6\n99"}),
        ("species", {"variant": "rs699", "species": "hu\tman"}),
    ]:
        with pytest.raises(ValueError):
            await variants.vep_consequences(http, **kwargs)
        assert not route.called, f"non-printable {site} must be rejected before any request"


# ================= variants: zero-padded uids (finding 3, two sites) =================


@respx.mock
async def test_f3_dbsnp_zero_padded_rsid_canonicalized(http):
    """Finding 3 site 1/2: dbsnp_variant('rs00328') must query uid 328 (NCBI's
    canonical form) instead of false-erroring on the padded lookup key."""
    route = respx.get(f"{EUTILS}/esummary.fcgi").mock(
        return_value=httpx.Response(200, json={"result": {"328": {"chr": "8"}}})
    )
    out = await variants.dbsnp_variant(http, "rs00328")
    assert route.calls[0].request.url.params["id"] == "328", "dbsnp site must query the canonical uid"
    assert out["rsid"] == "rs328"
    assert out["source"]["url"] == "https://www.ncbi.nlm.nih.gov/snp/rs328"


@respx.mock
async def test_f3_clinvar_zero_padded_variation_id_canonicalized(http):
    """Finding 3 site 2/2: clinvar_variant('0012345') — same mechanics, sibling
    site, own assertion."""
    route = respx.get(f"{EUTILS}/esummary.fcgi").mock(
        return_value=httpx.Response(200, json={"result": {"12345": {"title": "t"}}})
    )
    out = await variants.clinvar_variant(http, "0012345")
    assert route.calls[0].request.url.params["id"] == "12345", "clinvar site must query the canonical uid"
    assert out["variation_id"] == "12345"
    assert out["source"]["url"].endswith("/variation/12345/")


# ================= variants: shaper hardening (finding 4) =================


@respx.mock
async def test_f4_clinvar_shapers_survive_malformed_doc(http):
    """Finding 4: genes:null (:73), trait_set string rows (:57-61), and
    variation_set string rows (:98/:108) — three shaper sites, three asserts."""
    doc = {
        "title": "t",
        "genes": None,
        "variation_set": ["not-a-dict"],
        "germline_classification": {
            "description": "Pathogenic",
            "review_status": "criteria provided",
            "trait_set": ["not-a-dict", {"trait_name": "X"}],
        },
    }
    respx.get(f"{EUTILS}/esummary.fcgi").mock(
        return_value=httpx.Response(200, json={"result": {"111": doc}})
    )
    out = await variants.clinvar_variant(http, "111")
    assert out["genes"] == [], "genes:null site (_clinvar_genes) must not TypeError"
    assert out["canonical_spdi"] is None, "variation_set string-row site must not AttributeError"
    assert out["classifications"]["germline"]["traits"] == ["X"], (
        "trait_set string-row site must skip non-dicts, not AttributeError"
    )
    # VERBATIM contract untouched by the hardening:
    assert out["classifications"]["germline"]["clinical_significance"] == "Pathogenic"


@respx.mock
async def test_f4_dbsnp_genes_null_sibling_site(http):
    """Finding 4 sibling: dbsnp_variant has the same genes list-comp shape —
    per the multi-site discipline it gets its own guard and its own assert."""
    respx.get(f"{EUTILS}/esummary.fcgi").mock(
        return_value=httpx.Response(200, json={"result": {"699": {"genes": None}}})
    )
    out = await variants.dbsnp_variant(http, "rs699")
    assert out["genes"] == [], "dbsnp genes:null sibling site must not TypeError"


# ================= chem: CID + ChEMBL id validation (findings 5-6) =================


@respx.mock
async def test_f5_pubchem_cid_rejects_float_and_bool(http):
    """Finding 5: int(2244.5) silently queried CID 2244 (wrong compound) and
    True queried CID 1. Only int / digit-string may pass; nothing may leave."""
    route = respx.get(url__startswith=f"{PUBCHEM}/compound/cid/").mock(
        return_value=httpx.Response(200, json={"PropertyTable": {"Properties": [{"CID": 2244}]}})
    )
    for label, bad in [
        ("float truncation", 2244.5),
        ("integer-valued float", 2244.0),
        ("bool True (CID 1!)", True),
        ("bool False", False),
        ("None", None),
    ]:
        with pytest.raises(ValueError):
            await chem.pubchem_compound_by_cid(http, bad)
        assert not route.called, f"{label} must be rejected before any request"
    # The documented contract still holds: int and digit-string both resolve.
    assert (await chem.pubchem_compound_by_cid(http, "2244"))["cid"] == 2244
    assert (await chem.pubchem_compound_by_cid(http, 2244))["cid"] == 2244


@respx.mock
async def test_f6_chembl_id_requires_digits(http):
    """Finding 6: 'CHEMBL'/'CHEMBLxyz' passed the prefix check and live-pinned
    a source to a DEAD URL (200, returned=0). Full CHEMBL+digits or ValueError."""
    route = respx.get(url__startswith=f"{CHEMBL}/activity").mock(
        return_value=httpx.Response(200, json={"activities": []})
    )
    for label, bad in [("bare prefix", "CHEMBL"), ("non-digit tail", "CHEMBLxyz"),
                       ("traversal tail", "CHEMBL1/../x")]:
        with pytest.raises(ValueError):
            await chem.chembl_bioactivities(http, bad)
        assert not route.called, f"{label} must be rejected before any request"


# ================= chem: shaper hardening (finding 7) =================


@respx.mock
async def test_f7_pubchem_propertytable_null_per_site(http):
    """Finding 7: PropertyTable present-but-null crashed with AttributeError.
    Two lookup sites (name :80, cid :99) — two assertions."""
    respx.get(url__startswith=f"{PUBCHEM}/compound/").mock(
        return_value=httpx.Response(200, json={"PropertyTable": None})
    )
    with pytest.raises(BioAPIError):  # name site — clean error, not AttributeError
        await chem.pubchem_compound_by_name(http, "aspirin")
    with pytest.raises(BioAPIError):  # cid site — same contract, own assertion
        await chem.pubchem_compound_by_cid(http, 2244)


@respx.mock
async def test_f7_chembl_molecules_and_properties_hardened(http):
    """Finding 7: molecules:null (:139), molecule_properties-as-list (:113)."""
    route = respx.get(url__startswith=f"{CHEMBL}/molecule/search")
    route.side_effect = [
        httpx.Response(200, json={"molecules": None}),
        httpx.Response(200, json={"molecules": [
            None,  # null row
            {"molecule_chembl_id": "CHEMBL1", "molecule_properties": ["not-a-dict"]},
        ]}),
    ]
    out = await chem.chembl_search_molecule(http, "x")
    assert out["returned"] == 0, "molecules:null site must not TypeError"
    out = await chem.chembl_search_molecule(http, "x")
    assert out["returned"] == 1, "null molecule row must be skipped, not crash"
    assert out["molecules"][0]["full_mwt"] is None, (
        "molecule_properties-as-list site must degrade to None, not AttributeError"
    )


@respx.mock
async def test_f7_chembl_activities_null_rows(http):
    """Finding 7: activities [null] (:168) crashed with AttributeError."""
    respx.get(url__startswith=f"{CHEMBL}/activity").mock(
        return_value=httpx.Response(200, json={"activities": [None, {"standard_type": "IC50"}]})
    )
    out = await chem.chembl_bioactivities(http, "CHEMBL941")
    assert out["returned"] == 1, "null activity row must be skipped, not crash"
    assert out["activities"][0]["standard_type"] == "IC50"


# ================= scholarly: author shapers (findings 8-9) =================


@respx.mock
async def test_f8_openalex_authorships_null_and_null_rows(http):
    """Finding 8: authorships:null → TypeError; [null] row → AttributeError."""
    work_null = dict(OA_WORK, authorships=None)
    work_rows = dict(OA_WORK, id="https://openalex.org/W2",
                     authorships=[None, {"author": {"display_name": "A"}}])
    respx.get(f"{OPENALEX}/works").mock(
        return_value=httpx.Response(200, json={"results": [work_null, work_rows]})
    )
    out = await scholarly.search_openalex(http, "q")
    assert out["works"][0]["authors"] == [], "authorships:null must not TypeError"
    assert out["works"][1]["authors"] == ["A"], "null authorship row must be skipped, not AttributeError"


@respx.mock
async def test_f9_s2_authors_null_and_null_rows(http):
    """Finding 9: same two crash shapes in _s2_authors."""
    respx.get(url__startswith=f"{S2}/paper/search").mock(
        return_value=httpx.Response(200, json={"data": [
            {"paperId": "p1", "authors": None},
            {"paperId": "p2", "authors": [None, {"name": "A"}]},
        ]})
    )
    out = await scholarly.search_semantic_scholar(http, "q")
    assert out["papers"][0]["authors"] == [], "authors:null must not TypeError"
    assert out["papers"][1]["authors"] == ["A"], "null author row must be skipped, not AttributeError"


# ================= scholarly: top-level null lists (finding 10, 3 sites) =================


@respx.mock
async def test_f10_top_level_null_lists_per_site(http):
    """Finding 10: results:null (:130), search data:null (:201), citations
    data:null + [null] edge (:236) — three sites, named assertions."""
    respx.get(f"{OPENALEX}/works").mock(
        return_value=httpx.Response(200, json={"results": None})
    )
    out = await scholarly.search_openalex(http, "q")
    assert out["returned"] == 0, "openalex search results:null site must not TypeError"

    respx.get(url__startswith=f"{S2}/paper/search").mock(
        return_value=httpx.Response(200, json={"data": None})
    )
    out = await scholarly.search_semantic_scholar(http, "q")
    assert out["returned"] == 0, "s2 search data:null site must not TypeError"

    cit = respx.get(url__startswith=f"{S2}/paper/PID/citations")
    cit.side_effect = [
        httpx.Response(200, json={"data": None}),
        httpx.Response(200, json={"data": [None]}),
    ]
    out = await scholarly.semantic_scholar_citations(http, "PID")
    assert out["returned"] == 0, "s2 citations data:null site must not TypeError"
    out = await scholarly.semantic_scholar_citations(http, "PID")
    assert out["returned"] == 0, "s2 citations null edge must be skipped, not AttributeError"


# ================= scholarly: abstract index hardening (finding 11) =================


@respx.mock
async def test_f11_reconstruct_abstract_skips_malformed_positions(http):
    """Finding 11: positions:null → TypeError; positions-as-string → mixed-type
    sort TypeError. Valid entries must still reconstruct in order."""
    work = dict(OA_WORK, abstract_inverted_index={
        "skip-null": None, "skip-str": "012", "ok": [1, "bad", 0],
    })
    respx.get(url__startswith=f"{OPENALEX}/works/").mock(
        return_value=httpx.Response(200, json=work)
    )
    out = await scholarly.openalex_work(http, "W2741809807")
    assert out["abstract"] == "ok ok"  # only the int positions of the list entry


# ================= scholarly: resolver id hygiene (finding 12) =================


@respx.mock
async def test_f12_resolver_control_chars_rejected_per_site(http):
    """Finding 12: interior control chars crashed as httpx.InvalidURL. Both
    resolver sites must ValueError before any request."""
    route = respx.route(host__in=["api.openalex.org", "api.semanticscholar.org"]).mock(
        return_value=httpx.Response(200, json={})
    )
    with pytest.raises(ValueError):
        await scholarly.openalex_work(http, "W1\x002")
    assert not route.called, "openalex work id with control char must be rejected pre-request"
    with pytest.raises(ValueError):
        await scholarly.semantic_scholar_citations(http, "DOI:10.1038\x0c/nrn3241")
    assert not route.called, "s2 paper id with control char must be rejected pre-request"


@respx.mock
async def test_f12_openalex_doi_id_encoded_but_resolvable_on_wire(http):
    """Finding 12: safe=':' — colon literal (doi:/https: qualifiers), '/'
    percent-encoded (OpenAlex live-verified to resolve the encoded form), so a
    dot-segment can never climb out of /works/."""
    route = respx.get(host="api.openalex.org").mock(
        return_value=httpx.Response(200, json=OA_WORK)
    )
    await scholarly.openalex_work(http, "doi:10.7717/peerj.4375")
    assert "/works/doi:10.7717%2Fpeerj.4375" in str(route.calls[0].request.url)

    await scholarly.openalex_work(http, "W1/../../concepts/C123")
    sent = str(route.calls[-1].request.url)
    assert "/works/W1%2F..%2F..%2Fconcepts%2FC123" in sent, (
        "dot-segments must ride percent-encoded INSIDE /works/, never reroute the path"
    )


@respx.mock
async def test_f12_s2_paper_id_encoded_but_resolvable_on_wire(http):
    """Finding 12: S2 gets the same treatment — 'DOI:10.1038/nrn3241' keeps its
    colon, its slash rides encoded (S2 live-verified to resolve %2F), and
    traversal cannot escape /paper/."""
    route = respx.get(host="api.semanticscholar.org").mock(
        return_value=httpx.Response(200, json={"data": []})
    )
    await scholarly.semantic_scholar_citations(http, "DOI:10.1038/nrn3241")
    assert "/paper/DOI:10.1038%2Fnrn3241/citations" in str(route.calls[0].request.url)

    await scholarly.semantic_scholar_citations(http, "x/../../datasets/v1/x")
    sent = str(route.calls[-1].request.url)
    assert "/paper/x%2F..%2F..%2Fdatasets%2Fv1%2Fx/citations" in sent, (
        "dot-segments must ride percent-encoded INSIDE /paper/, never reroute the path"
    )


# ================= scholarly: search abstract + id canonicality (findings 13-14) =================


@respx.mock
async def test_f13_s2_search_emits_requested_abstract(http):
    """Finding 13: `abstract` is in _S2_SEARCH_FIELDS but was never emitted."""
    respx.get(url__startswith=f"{S2}/paper/search").mock(
        return_value=httpx.Response(200, json={"data": [
            {"paperId": "p1", "title": "T", "abstract": "The abstract text."},
        ]})
    )
    out = await scholarly.search_semantic_scholar(http, "q")
    assert out["papers"][0]["abstract"] == "The abstract text."


@respx.mock
async def test_f14_openalex_noncanonical_id_never_double_urls(http):
    """Finding 14: an id without the canonical URL prefix passed the truthy
    guard and produced a double-URL source. Now skipped in search, error in
    single-work fetch."""
    bad = dict(OA_WORK, id="openalex.org/W99")  # no scheme prefix — nothing stripped
    respx.get(f"{OPENALEX}/works").mock(
        return_value=httpx.Response(200, json={"results": [bad, OA_WORK]})
    )
    out = await scholarly.search_openalex(http, "q")
    assert [w["openalex_id"] for w in out["works"]] == ["W2741809807"], (
        "non-canonical id must be skipped, never emitted"
    )
    assert all(w["source"]["url"].count("http") == 1 for w in out["works"])

    respx.get(url__startswith=f"{OPENALEX}/works/").mock(
        return_value=httpx.Response(200, json=dict(OA_WORK, id="garbage"))
    )
    with pytest.raises(BioAPIError):
        await scholarly.openalex_work(http, "W2741809807")


# ================= structure_extra: InterPro + AlphaFold (findings 15-19) =================


@respx.mock
async def test_f15_interpro_metadata_null_skipped(http):
    """Finding 15: metadata present-but-null crashed with AttributeError; the
    row is unpinnable and must be skipped instead."""
    respx.get(url__startswith="https://www.ebi.ac.uk/interpro/api/entry/interpro/protein/uniprot/").mock(
        return_value=httpx.Response(200, json={"count": 3, "results": [
            {"metadata": None},
            None,
            {"metadata": {"accession": "IPR000001", "name": "n", "type": "family",
                          "source_database": "interpro"}},
        ]})
    )
    out = await structure_extra.interpro_protein_domains(http, "P04637")
    assert out["returned"] == 1
    assert out["entries"][0]["interpro_id"] == "IPR000001"


@respx.mock
async def test_f16_uniprot_accession_validated_per_site(http):
    """Finding 16: unvalidated accession = traversal into other API families +
    the tainted string baked into source.url. Two sites — two assertions."""
    route = respx.route(host__in=["alphafold.ebi.ac.uk", "www.ebi.ac.uk"]).mock(
        return_value=httpx.Response(200, json=[])
    )
    for site, call in [
        ("alphafold_prediction", lambda: structure_extra.alphafold_prediction(
            http, "../annotations/P04637?type=MUTAGEN")),
        ("interpro_protein_domains", lambda: structure_extra.interpro_protein_domains(
            http, "P04637/../../../api/entry")),
    ]:
        with pytest.raises(ValueError):
            await call()
        assert not route.called, f"{site}: malformed accession must be rejected before any request"


@respx.mock
async def test_f16_uniprot_accession_formats_still_accepted(http):
    """Finding 16 (accept side): classic 6-char, isoform-suffixed, and 10-char
    accessions all pass the gate."""
    respx.get(url__startswith="https://alphafold.ebi.ac.uk/api/prediction/").mock(
        return_value=httpx.Response(200, json=[{"uniprotAccession": "X"}])
    )
    for acc in ["p04637", "P04637-2", "a0a024r161"]:
        out = await structure_extra.alphafold_prediction(http, acc)
        assert out["uniprot_accession"] == acc.upper(), f"{acc!r} must pass UniProt validation"


@respx.mock
async def test_f17_alphafold_nondict_prediction_is_clean_error(http):
    """Finding 17: predictions[0] non-dict crashed with AttributeError."""
    respx.get(url__startswith="https://alphafold.ebi.ac.uk/api/prediction/").mock(
        return_value=httpx.Response(200, json=["not-a-dict"])
    )
    with pytest.raises(BioAPIError):
        await structure_extra.alphafold_prediction(http, "P04637")


async def test_f18_ipr_rejects_nonascii_digits(http):
    """Finding 18: \\d matched Arabic-Indic digits; [0-9] must not."""
    with pytest.raises(ValueError):
        await structure_extra.interpro_entry(http, "IPR00211٧")  # ٧ = Arabic-Indic 7


@respx.mock
async def test_f19_interpro_results_null(http):
    """Finding 19: top-level results present-but-null crashed with TypeError."""
    respx.get(url__startswith="https://www.ebi.ac.uk/interpro/api/entry/interpro/protein/uniprot/").mock(
        return_value=httpx.Response(200, json={"count": 2, "results": None})
    )
    out = await structure_extra.interpro_protein_domains(http, "P04637")
    assert out["returned"] == 0 and out["entries"] == []
