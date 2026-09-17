"""Regression pins for the 2026-09-17 adversarial-review findings in the
data-layer clients (pdb / pathways / ensembl / uniprot).

One test per finding. Injection findings assert the OUTGOING request URL
(respx captures it) was percent-encoded, or that ValueError fires before any
request leaves the process. Multi-site findings assert per site, per the
multi-site discipline.
"""

import httpx
import pytest
import respx

from bio_mcp.clients import ensembl, pathways, pdb, uniprot
from bio_mcp.http import BioAPIError, BioHTTP

RCSB_SEARCH = "https://search.rcsb.org/rcsbsearch/v2/query"
RCSB_DATA = "https://data.rcsb.org/rest/v1/core/entry"
KEGG = "https://rest.kegg.jp"
REACTOME_QUERY = "https://reactome.org/ContentService/search/query"
ENSEMBL = "https://rest.ensembl.org"
UNIPROT = "https://rest.uniprot.org/uniprotkb"


@pytest.fixture
async def http():
    h = BioHTTP()
    yield h
    await h.aclose()


# ---------- finding 1: RCSB zero-hit search answers 204 + empty body ----------


@respx.mock
async def test_pdb_search_zero_hit_204_returns_empty(http):
    route = respx.get(RCSB_SEARCH)
    route.return_value = httpx.Response(204)
    out = await pdb.search_pdb(http, "zz_no_such_structure_zz")
    assert out == {"query": "zz_no_such_structure_zz", "total_matches": 0, "returned": 0, "structures": []}

    # Same contract for a 200 with an empty body.
    route.return_value = httpx.Response(200, content=b"")
    out = await pdb.search_pdb(http, "zz_no_such_structure_zz")
    assert out["returned"] == 0 and out["structures"] == []

    # A non-empty non-JSON body is still an upstream error, never swallowed.
    route.return_value = httpx.Response(200, content=b"<html>oops</html>")
    with pytest.raises(BioAPIError, match="non-JSON"):
        await pdb.search_pdb(http, "zz_no_such_structure_zz")


# ---------- finding 2: search hit with score: null hit round(None) ----------


@respx.mock
async def test_pdb_search_null_score(http):
    respx.get(RCSB_SEARCH).mock(
        return_value=httpx.Response(
            200, json={"result_set": [{"identifier": "1ABC", "score": None}], "total_count": 1}
        )
    )
    out = await pdb.search_pdb(http, "spike")
    assert out["structures"][0]["score"] == 0.0
    assert out["structures"][0]["pdb_id"] == "1ABC"


# ---------- finding 3: empty rcsb_primary_citation fell to citation[0] ----------


@respx.mock
async def test_pdb_entry_empty_primary_citation_prefers_id_primary(http):
    # Present-but-empty rcsb_primary_citation must NOT surface the software
    # reference at citation[0]; the id=="primary" entry wins.
    respx.get(f"{RCSB_DATA}/1ABC").mock(
        return_value=httpx.Response(
            200,
            json={
                "rcsb_id": "1ABC",
                "rcsb_primary_citation": {},
                "citation": [
                    {"id": "software", "title": "PHENIX suite"},
                    {"id": "primary", "title": "The real paper", "year": 2001},
                ],
            },
        )
    )
    out = await pdb.fetch_pdb_entry(http, "1abc")
    assert out["primary_citation"]["title"] == "The real paper"

    # No id=="primary" entry → the first-element fallback is preserved.
    respx.get(f"{RCSB_DATA}/2DEF").mock(
        return_value=httpx.Response(
            200,
            json={"rcsb_id": "2DEF", "citation": [{"title": "Only citation", "year": 1999}]},
        )
    )
    out = await pdb.fetch_pdb_entry(http, "2DEF")
    assert out["primary_citation"]["title"] == "Only citation"

    # citation: null → empty primary_citation fields, no crash.
    respx.get(f"{RCSB_DATA}/3GHI").mock(
        return_value=httpx.Response(200, json={"rcsb_id": "3GHI", "citation": None})
    )
    out = await pdb.fetch_pdb_entry(http, "3GHI")
    assert out["primary_citation"]["title"] is None


# ---------- finding 4: deposit_date / rcsb_accession_info null crashed ----------


@respx.mock
async def test_pdb_entry_null_accession_info_and_deposit_date(http):
    respx.get(f"{RCSB_DATA}/4JKL").mock(
        return_value=httpx.Response(200, json={"rcsb_id": "4JKL", "rcsb_accession_info": None})
    )
    out = await pdb.fetch_pdb_entry(http, "4JKL")
    assert out["deposited"] is None

    respx.get(f"{RCSB_DATA}/5MNO").mock(
        return_value=httpx.Response(
            200, json={"rcsb_id": "5MNO", "rcsb_accession_info": {"deposit_date": None}}
        )
    )
    out = await pdb.fetch_pdb_entry(http, "5MNO")
    assert out["deposited"] is None


# ---------- finding 5: len==4 check let "/../" through into the path ----------


@respx.mock
async def test_pdb_entry_rejects_4char_metacharacter_ids(http):
    # No routes registered: if any of these reached the wire, respx would
    # raise its own error instead of the ValueError we require pre-request.
    for bad in ("/../", "1AB?", "1AB#", "1A/B", "..\\a", "1AB "):
        with pytest.raises(ValueError, match="4 characters"):
            await pdb.fetch_pdb_entry(http, bad)
    assert len(respx.calls) == 0, "crafted PDB ids must be rejected before any request"


# ---------- finding 6: Reactome double-quoted highlight spans leaked ----------


@respx.mock
async def test_reactome_strips_double_quoted_highlight_spans(http):
    respx.get(REACTOME_QUERY).mock(
        return_value=httpx.Response(
            200,
            json={
                "results": [
                    {
                        "typeName": "Pathway",
                        "entries": [
                            # live API emits double-quoted attributes
                            {"stId": "R-HSA-109581", "name": 'Intrinsic Pathway for <span class="highlighting" >Apoptosis</span>'},
                            # older single-quoted form must keep working
                            {"stId": "R-HSA-69488", "name": "<span class='highlighting' >G1/S</span> Transition"},
                        ],
                    }
                ]
            },
        )
    )
    out = await pathways.search_reactome(http, "apoptosis")
    names = [e["name"] for e in out["entries"]]
    assert names == ["Intrinsic Pathway for Apoptosis", "G1/S Transition"]
    for n in names:
        assert "<span" not in n and "</span>" not in n


# ---------- finding 7: KEGG query/id interpolated raw into the URL path ----------


@respx.mock
async def test_kegg_query_and_id_path_encoded(http):
    # Colon id must stay byte-identical (exact-URL route proves it) — register first.
    colon_route = respx.get(f"{KEGG}/get/path:map00010").mock(
        return_value=httpx.Response(200, text="ENTRY map00010 Pathway\nNAME Glycolysis\n")
    )
    find_route = respx.get(url__regex=rf"{KEGG}/find/pathway/.+").mock(
        return_value=httpx.Response(200, text="")
    )
    get_route = respx.get(url__regex=rf"{KEGG}/get/.+").mock(
        return_value=httpx.Response(200, text="ENTRY x\n")
    )

    # site 1: search_kegg query — the live-confirmed find→get reroute
    out = await pathways.search_kegg(http, "../../get/hsa05224")
    assert out["returned"] == 0
    sent = str(find_route.calls.last.request.url)
    assert "/find/pathway/..%2F..%2Fget%2Fhsa05224" in sent, f"search query not encoded: {sent}"

    # site 2: fetch_kegg_entry id
    await pathways.fetch_kegg_entry(http, "../../find/pathway/x")
    sent = str(get_route.calls.last.request.url)
    assert "/get/..%2F..%2Ffind%2Fpathway%2Fx" in sent, f"entry id not encoded: {sent}"

    # KEGG ids REQUIRE the literal colon: 'path:map00010' must not be quoted.
    out = await pathways.fetch_kegg_entry(http, "path:map00010")
    assert colon_route.called and out["name"] == "Glycolysis"

    # Non-printable input is rejected BEFORE any request, at both sites.
    n0 = len(respx.calls)
    with pytest.raises(ValueError, match="non-printable"):
        await pathways.search_kegg(http, "gly\ncolysis")
    with pytest.raises(ValueError, match="non-printable"):
        await pathways.fetch_kegg_entry(http, "path:\x00map")
    assert len(respx.calls) == n0, "non-printable KEGG input must never reach the wire"


# ---------- finding 8: Reactome results:null / entries:null crashed ----------


@respx.mock
async def test_reactome_null_results_and_entries(http):
    route = respx.get(REACTOME_QUERY)
    route.return_value = httpx.Response(200, json={"results": None})
    out = await pathways.search_reactome(http, "apoptosis")
    assert out["returned"] == 0 and out["entries"] == []

    route.return_value = httpx.Response(200, json={"results": [{"typeName": "Pathway", "entries": None}]})
    out = await pathways.search_reactome(http, "apoptosis")
    assert out["returned"] == 0 and out["entries"] == []


# ---------- finding 9: Ensembl species/symbol/ids raw in path + non-dict lookup ----------


@respx.mock
async def test_ensembl_injection_encoded_and_list_payload_rejected(http):
    lookup_route = respx.get(url__regex=rf"{ENSEMBL}/lookup/symbol/.+")
    lookup_route.return_value = httpx.Response(200, json={"id": "ENSG00000141510"})
    seq_route = respx.get(url__regex=rf"{ENSEMBL}/sequence/id/.+").mock(
        return_value=httpx.Response(200, text=">x\nACGT")
    )
    xref_route = respx.get(url__regex=rf"{ENSEMBL}/xrefs/id/.+").mock(
        return_value=httpx.Response(200, json=[])
    )

    # sites 1+2: lookup species AND symbol — the live-confirmed reroute shape
    await ensembl.lookup_gene(http, "TP53/x", species="../../xrefs/symbol/homo_sapiens")
    sent = str(lookup_route.calls.last.request.url)
    assert "/lookup/symbol/..%2F..%2Fxrefs%2Fsymbol%2Fhomo_sapiens/TP53%2Fx" in sent, f"lookup not encoded: {sent}"

    # site 3: sequence id
    await ensembl.fetch_ensembl_sequence(http, "ENSG1/../x")
    sent = str(seq_route.calls.last.request.url)
    assert "/sequence/id/ENSG1%2F..%2Fx" in sent, f"sequence id not encoded: {sent}"

    # site 4: xrefs id
    await ensembl.gene_xrefs(http, "ENSG1/../x")
    sent = str(xref_route.calls.last.request.url)
    assert "/xrefs/id/ENSG1%2F..%2Fx" in sent, f"xrefs id not encoded: {sent}"

    # A rerouted/odd endpoint answering the lookup with a LIST must be a clean
    # BioAPIError, not an AttributeError.
    lookup_route.return_value = httpx.Response(200, json=[{"id": "ENSG1"}])
    with pytest.raises(BioAPIError, match="unexpected lookup payload"):
        await ensembl.lookup_gene(http, "TP53")

    # Non-printable input rejected pre-request, per site.
    n0 = len(respx.calls)
    for call in (
        ensembl.lookup_gene(http, "TP\n53"),
        ensembl.fetch_ensembl_sequence(http, "ENSG\t1"),
        ensembl.gene_xrefs(http, "ENSG\n1"),
    ):
        with pytest.raises(ValueError, match="non-printable"):
            await call
    assert len(respx.calls) == n0, "non-printable Ensembl input must never reach the wire"


# ---------- finding 10: UniProt accession raw in path escaped /uniprotkb ----------


@respx.mock
async def test_uniprot_accession_path_encoded(http):
    # Exact isoform route FIRST — respx matches in registration order, and the
    # broad regex below would otherwise swallow it.
    iso = respx.get(f"{UNIPROT}/P04637-2").mock(
        return_value=httpx.Response(200, json={"primaryAccession": "P04637-2"})
    )
    route = respx.get(url__regex=rf"{UNIPROT}/.+").mock(
        return_value=httpx.Response(200, json={"primaryAccession": "P04637"})
    )
    await uniprot.fetch_uniprot_entry(http, "P04637/../../uniparc/X")
    sent = str(route.calls.last.request.url)
    # accession is uppercased before encoding
    assert "/uniprotkb/P04637%2F..%2F..%2FUNIPARC%2FX" in sent, f"accession not encoded: {sent}"

    # Isoform accessions keep working byte-identically (exact-URL route).
    out = await uniprot.fetch_uniprot_entry(http, "P04637-2")
    assert iso.called and out["accession"] == "P04637-2"

    n0 = len(respx.calls)
    with pytest.raises(ValueError, match="non-printable"):
        await uniprot.fetch_uniprot_entry(http, "P046\n37")
    assert len(respx.calls) == n0, "non-printable accession must never reach the wire"


# ---------- finding 11: None-vs-missing crashes, one assertion PER SITE ----------

# Each tuple poisons exactly one field with the null shape the review crafted.
# check(out) pins the degraded-but-honest value where one is prescribed.
_NULL_SITES: list[tuple[str, dict, object]] = [
    ("proteinDescription:null", {"proteinDescription": None},
     lambda out: out["protein_name"] is None),
    ("proteinDescription.submissionNames:[null]", {"proteinDescription": {"submissionNames": [None]}},
     lambda out: out["protein_name"] is None),
    ("genes:null", {"genes": None},
     lambda out: out["genes"] == []),
    ("comments:null", {"comments": None},
     lambda out: out["function"] == []),
    ("comments[].texts:null", {"comments": [{"commentType": "FUNCTION", "texts": None}]},
     lambda out: out["function"] == []),
    ("comments[].disease:null", {"comments": [{"commentType": "DISEASE", "texts": [], "disease": None}]},
     lambda out: out["disease"] == []),
    ("features[].location:null", {"features": [{"type": "Domain", "description": "d", "location": None}]},
     lambda out: out["domains"] == [{"description": "d", "start": None, "end": None}]),
    ("features:null", {"features": None},
     lambda out: out["domains"] == []),
    ("uniProtKBCrossReferences:null", {"uniProtKBCrossReferences": None},
     lambda out: out["pdb_structures"] == []),
    ("uniProtKBCrossReferences[].id-missing", {"uniProtKBCrossReferences": [{"database": "PDB"}]},
     lambda out: out["pdb_structures"] == []),
    ("organism:null", {"organism": None},
     lambda out: out["organism"] is None),
    ("sequence:null", {"sequence": None},
     lambda out: out["length"] is None and out["sequence"] is None),
]


@respx.mock
async def test_uniprot_entry_tolerates_null_fields_per_site(http):
    route = respx.get(f"{UNIPROT}/P1")
    for label, poison, check in _NULL_SITES:
        route.return_value = httpx.Response(200, json={"primaryAccession": "P1", **poison})
        try:
            out = await uniprot.fetch_uniprot_entry(http, "P1")
        except Exception as e:  # noqa: BLE001 — converted to a named-site failure
            pytest.fail(f"site {label}: crashed with {type(e).__name__}: {e}")
        assert out["accession"] == "P1", f"site {label}: wrong accession"
        assert check(out), f"site {label}: degraded value wrong: {out}"


@respx.mock
async def test_uniprot_search_tolerates_null_fields(http):
    # Same null shapes on the SEARCH surface (sibling of the entry fix —
    # organism/sequence/genes/proteinDescription flow through the same helpers).
    respx.get(f"{UNIPROT}/search").mock(
        return_value=httpx.Response(
            200,
            json={"results": [{
                "primaryAccession": "P1",
                "proteinDescription": None,
                "genes": None,
                "organism": None,
                "sequence": None,
            }]},
        )
    )
    out = await uniprot.search_uniprot(http, "tp53")
    hit = out["proteins"][0]
    assert hit["accession"] == "P1"
    assert hit["protein_name"] is None and hit["genes"] == []
    assert hit["organism"] is None and hit["length"] is None
