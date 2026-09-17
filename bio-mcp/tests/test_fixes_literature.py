"""Regression pins for the adversarial-review findings (2026-09-17) in the
literature/sequence clients: pubmed, preprints, ncbi_seq.

One test per finding, named after it. Multi-site findings pin every site."""

import httpx
import pytest
import respx

from bio_mcp.clients import ncbi_seq, preprints, pubmed
from bio_mcp.http import BioAPIError, BioHTTP

EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"


@pytest.fixture
async def http():
    h = BioHTTP()
    yield h
    await h.aclose()


# ---------- finding 1: CollectiveName (consortium) authors dropped ----------

ENCODE_XML = """<?xml version="1.0"?>
<PubmedArticleSet><PubmedArticle><MedlineCitation>
  <PMID>22955616</PMID>
  <Article>
    <Journal><ISOAbbreviation>Nature</ISOAbbreviation>
      <JournalIssue><PubDate><Year>2012</Year></PubDate></JournalIssue></Journal>
    <ArticleTitle>An integrated encyclopedia of DNA elements in the human genome</ArticleTitle>
    <Abstract><AbstractText>The human genome encodes.</AbstractText></Abstract>
    <AuthorList>
      <Author><CollectiveName>ENCODE Project Consortium</CollectiveName></Author>
      <Author><LastName>Dunham</LastName><Initials>I</Initials></Author>
    </AuthorList>
  </Article>
</MedlineCitation></PubmedArticle></PubmedArticleSet>"""


@respx.mock
async def test_collective_name_authors_kept(http):
    respx.get(f"{EUTILS}/efetch.fcgi").mock(return_value=httpx.Response(200, text=ENCODE_XML))
    arts = await pubmed.fetch_abstracts(http, ["22955616"])
    assert arts[0]["authors"] == ["ENCODE Project Consortium", "Dunham I"]
    assert "ENCODE Project Consortium" in arts[0]["citation"]


# ---------- finding 2: PMC <error> body (HTTP 200) reported as embargo ----------

@respx.mock
async def test_pmc_error_element_raises(http):
    respx.get(f"{EUTILS}/efetch.fcgi").mock(
        return_value=httpx.Response(
            200,
            text='<pmc-articleset><error id="PMC999999999">The following PMCID is not available</error></pmc-articleset>',
        )
    )
    with pytest.raises(BioAPIError, match="not available"):
        await pubmed.fetch_pmc_fulltext(http, "PMC999999999")


# ---------- finding 3: PubmedBookArticle records dropped, reported missing ----------

BOOK_XML = """<?xml version="1.0"?>
<PubmedArticleSet><PubmedBookArticle><BookDocument>
  <PMID Version="1">20301546</PMID>
  <ArticleIdList><ArticleId IdType="pubmed">20301546</ArticleId></ArticleIdList>
  <Book>
    <BookTitle book="gene">GeneReviews</BookTitle>
    <PubDate><Year>1998</Year></PubDate>
    <AuthorList Type="editors"><Author><LastName>Adam</LastName><Initials>MP</Initials></Author></AuthorList>
  </Book>
  <ArticleTitle book="gene" part="alzheimer">Alzheimer Disease Overview</ArticleTitle>
  <AuthorList Type="authors"><Author><LastName>Bird</LastName><Initials>TD</Initials></Author></AuthorList>
  <Abstract><AbstractText>AD is characterized by dementia.</AbstractText></Abstract>
</BookDocument></PubmedBookArticle></PubmedArticleSet>"""


@respx.mock
async def test_book_article_parsed_not_missing(http):
    respx.get(f"{EUTILS}/efetch.fcgi").mock(return_value=httpx.Response(200, text=BOOK_XML))
    r = await pubmed.fetch_abstracts_report(http, ["20301546"])
    # report shape: the book PMID is a returned article, NOT in missing
    assert r["requested"] == 1 and r["returned"] == 1
    assert r["missing"] == []
    art = r["articles"][0]
    assert art["pmid"] == "20301546"
    assert art["title"] == "Alzheimer Disease Overview"
    assert art["authors"] == ["Bird TD"]  # chapter authors, not the book editors
    assert art["year"] == "1998"
    assert "GeneReviews" in art["citation"] and "PMID: 20301546" in art["citation"]
    assert art["source"]["url"] == "https://pubmed.ncbi.nlm.nih.gov/20301546/"


# ---------- finding 4: all-malformed PMID batch 400s at NCBI ----------

ONE_ARTICLE_XML = """<?xml version="1.0"?>
<PubmedArticleSet><PubmedArticle><MedlineCitation>
  <PMID>34265844</PMID>
  <Article><ArticleTitle>AlphaFold</ArticleTitle>
    <AuthorList><Author><LastName>Jumper</LastName><Initials>J</Initials></Author></AuthorList>
  </Article>
</MedlineCitation></PubmedArticle></PubmedArticleSet>"""


@respx.mock
async def test_malformed_pmids_prefiltered(http):
    route = respx.get(f"{EUTILS}/efetch.fcgi").mock(return_value=httpx.Response(200, text=ONE_ARTICLE_XML))
    # all-malformed batch: reported missing WITHOUT calling NCBI
    r = await pubmed.fetch_abstracts_report(http, ["banana"])
    assert r == {"requested": 1, "returned": 0, "missing": ["banana"], "articles": []}
    assert not route.called, "malformed-only batch must not reach efetch"
    # mixed batch: only the well-formed id goes upstream, malformed lands in missing
    r2 = await pubmed.fetch_abstracts_report(http, ["banana", "34265844"])
    assert r2["returned"] == 1 and r2["missing"] == ["banana"]
    assert route.call_count == 1
    sent = str(route.calls.last.request.url)
    assert "34265844" in sent and "banana" not in sent


# ---------- finding 5: empty bioRxiv tail pages silently served stale page 0 ----------

@respx.mock
async def test_biorxiv_empty_tail_degrades(http):
    first_page = {
        "messages": [{"status": "ok", "total": "350"}],
        "collection": [
            {"doi": "10.1101/2026.old1", "title": "t", "category": "genomics", "date": "2026-09-01"},
            {"doi": "10.1101/2026.old2", "title": "t", "category": "genomics", "date": "2026-09-01"},
        ],
    }
    respx.get(url__regex=r".*/details/biorxiv/.*/0$").mock(
        return_value=httpx.Response(200, json=first_page)
    )
    respx.get(url__regex=r".*/details/biorxiv/.*/(100|200|300)$").mock(
        return_value=httpx.Response(200, json={"messages": [{"status": "ok", "total": "350"}], "collection": []})
    )
    r = await preprints.recent_biorxiv(http, days=10, max_results=30)
    assert r["freshness"] == "degraded", "empty tail pages must not masquerade as a full tail read"
    assert "less recent" in r["note"]
    assert r["returned"] == 2  # page-0 fallback, honestly flagged


# ---------- finding 6: tail walk re-fetched page 0 the probe already held ----------

@respx.mock
async def test_biorxiv_tail_walk_does_not_refetch_page0(http):
    def page(cursor: int, n: int, date: str) -> dict:
        return {
            "messages": [{"status": "ok", "total": "150", "cursor": str(cursor), "count": n}],
            "collection": [
                {"doi": f"10.1101/2026.{cursor}.{i}", "title": "t", "category": "genomics", "date": date}
                for i in range(n)
            ],
        }

    route0 = respx.get(url__regex=r".*/details/biorxiv/.*/0$").mock(
        return_value=httpx.Response(200, json=page(0, 100, "2026-09-07"))
    )
    respx.get(url__regex=r".*/details/biorxiv/.*/100$").mock(
        return_value=httpx.Response(200, json=page(100, 50, "2026-09-16"))
    )
    # max_results > tail-page yield forces the walk down to cursor 0
    r = await preprints.recent_biorxiv(http, days=10, max_results=120)
    assert route0.call_count == 1, "page 0 must be seeded from the probe, not re-requested"
    assert r["freshness"] == "full"
    assert r["returned"] == 120
    assert r["preprints"][0]["date"] == "2026-09-16"
    assert r["preprints"][-1]["date"] == "2026-09-07"  # seeded page-0 entries present


# ---------- finding 7: negative max_results reached slicing / upstream ----------

@respx.mock
async def test_negative_max_results_rejected_both_sites(http):
    # multi-site: one assertion per function that slices/forwards max_results
    with pytest.raises(ValueError, match="max_results"):
        await preprints.search_arxiv(http, "genomics", max_results=-1)
    with pytest.raises(ValueError, match="max_results"):
        await preprints.recent_biorxiv(http, max_results=-2)


# ---------- finding 8: arXiv error-feed entries parsed as papers ----------

ARXIV_ERROR_FEED = """<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>http://export.arxiv.org/api/errors#incorrect_id_format</id>
    <title>Error</title>
    <summary>malformed id</summary>
  </entry>
  <entry>
    <id>http://arxiv.org/abs/2103.09992v2</id>
    <title>Deep learning for genomics</title>
    <summary>We survey.</summary>
    <published>2021-03-18T00:00:00Z</published>
    <author><name>A Author</name></author>
  </entry>
</feed>"""


@respx.mock
async def test_arxiv_error_feed_entries_skipped(http):
    respx.get("https://export.arxiv.org/api/query").mock(
        return_value=httpx.Response(200, text=ARXIV_ERROR_FEED)
    )
    out = await preprints.search_arxiv(http, "genomics")
    assert out["returned"] == 1
    assert out["papers"][0]["arxiv_id"] == "2103.09992v2"


# ---------- finding 9: save_path pointing at a directory crashed post-download ----------

@respx.mock
async def test_save_path_directory_rejected_before_fetch(http, tmp_path):
    route = respx.get(url__startswith=f"{EUTILS}/efetch.fcgi")
    with pytest.raises(ValueError, match="directory"):
        await ncbi_seq.fetch_sequence(http, "NM_000546.6", save_path=str(tmp_path))
    assert not route.called, "must reject the directory path before downloading anything"


# ---------- finding 10: 200-status XML/HTML failure bodies returned as sequence ----------

@respx.mock
async def test_non_sequence_body_rejected_per_format(http):
    route = respx.get(url__startswith=f"{EUTILS}/efetch.fcgi")
    route.side_effect = [
        httpx.Response(200, text='<?xml version="1.0"?><eFetchResult><ERROR>Otherdb uid</ERROR></eFetchResult>'),
        httpx.Response(200, text="<html><body>NCBI is undergoing maintenance</body></html>"),
        httpx.Response(200, text="LOCUS       NM_000546   1182 bp    mRNA\nORIGIN\n"),
    ]
    with pytest.raises(BioAPIError, match="fasta") as exc:
        await ncbi_seq.fetch_sequence(http, "X1", fmt="fasta")
    assert "eFetchResult" in str(exc.value)  # body head surfaced for debugging
    with pytest.raises(BioAPIError, match="genbank"):
        await ncbi_seq.fetch_sequence(http, "X1", fmt="genbank")
    ok = await ncbi_seq.fetch_sequence(http, "NM_000546", fmt="genbank")
    assert ok["text"].startswith("LOCUS")  # real GenBank head still accepted


# ---------- finding 11: esearch hits but no esummary result → silent returned=0 ----------

@respx.mock
async def test_esummary_missing_result_raises(http):
    respx.get(f"{EUTILS}/esearch.fcgi").mock(
        return_value=httpx.Response(200, json={"esearchresult": {"count": "2", "idlist": ["1", "2"]}})
    )
    respx.get(f"{EUTILS}/esummary.fcgi").mock(
        return_value=httpx.Response(200, json={"error": "esummary backend unavailable"})
    )
    with pytest.raises(BioAPIError, match="esummary"):
        await ncbi_seq.search_ncbi_sequences(http, "tp53")
