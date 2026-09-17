"""Regression pins for the dogfood-harness findings (2026-09-17 run).

Per the multi-site discipline: fixes that touch every tool site get one
assertion PER SITE, not one assertion for "the bug".
"""

import re
from pathlib import Path

import httpx
import pytest
import respx

from mcp.server.mcpserver.exceptions import ToolError

from bio_mcp import server as server_mod
from bio_mcp.clients import ensembl, ncbi_seq, preprints, pubmed
from bio_mcp.errors import surface_rejections
from bio_mcp.http import BioHTTP, BioOversizeError
from bio_mcp.sandbox import run_python_script

EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
SERVER_SRC = (Path(server_mod.__file__)).read_text()


@pytest.fixture
async def http():
    h = BioHTTP()
    yield h
    await h.aclose()


# ---------- finding: rejections swallowed to "Error executing tool X" ----------

def test_every_tool_site_surfaces_rejections():
    """Each @mcp.tool() must stack @surface_rejections — per-site, named in the
    failure, so a missed sibling can't hide behind the others."""
    blocks = re.findall(r"@mcp\.tool\(\)\n(@surface_rejections\n)?(?:async )?def (\w+)", SERVER_SRC)
    assert blocks, "no tool sites found — server.py layout changed?"
    unguarded = [name for deco, name in blocks if not deco]
    assert not unguarded, f"tool sites missing @surface_rejections: {unguarded}"


async def test_surface_rejections_converts_and_keeps_message():
    @surface_rejections
    async def tool():
        raise ValueError("save_path must be absolute")

    with pytest.raises(ToolError, match="absolute"):
        await tool()


def test_surface_rejections_sync_path():
    @surface_rejections
    def tool():
        raise ValueError("empty script")

    with pytest.raises(ToolError, match="empty"):
        tool()


def test_surface_rejections_lets_crashes_through():
    @surface_rejections
    def tool():
        raise KeyError("boom")  # a genuine bug must stay a crash, not a clean rejection

    with pytest.raises(KeyError):
        tool()


# ---------- finding: run_python crashed on non-UTF-8 stdout ----------

def test_run_python_non_utf8_stdout_survives():
    r = run_python_script("import sys; sys.stdout.buffer.write(b'\\xff\\xfe raw\\n')")
    assert isinstance(r["stdout"], str)
    assert r["exit_code"] == 0


# ---------- finding: bogus PMIDs silently dropped ----------

@respx.mock
async def test_pubmed_abstracts_reports_missing(http):
    respx.get(url__startswith=f"{EUTILS}/efetch.fcgi").mock(
        return_value=httpx.Response(200, text="<?xml version='1.0'?><PubmedArticleSet></PubmedArticleSet>")
    )
    r = await pubmed.fetch_abstracts_report(http, ["999999999"])
    assert r["missing"] == ["999999999"]
    assert r["returned"] == 0 and r["articles"] == []


# ---------- finding: unbounded ensembl xrefs payload ----------

@respx.mock
async def test_ensembl_xrefs_capped(http):
    fake = [{"dbname": "X", "primary_id": str(i), "description": None} for i in range(157)]
    respx.get(url__startswith="https://rest.ensembl.org/xrefs/id/G").mock(
        return_value=httpx.Response(200, json=fake)
    )
    r = await ensembl.gene_xrefs(http, "G", max_results=100)
    assert r["n_xrefs"] == 100 and r["n_total"] == 157 and r["truncated"] is True


# ---------- finding: huge record buffered for 65s before rejection ----------

@respx.mock
async def test_get_text_capped_aborts_early(http):
    respx.get("https://example.org/big").mock(return_value=httpx.Response(200, content=b"x" * 10_000))
    with pytest.raises(BioOversizeError):
        await http.get_text_capped("https://example.org/big", max_bytes=1_000)


@respx.mock
async def test_ncbi_oversize_names_save_path(http):
    respx.get(url__startswith=f"{EUTILS}/efetch.fcgi").mock(
        return_value=httpx.Response(200, content=b">chr1\n" + b"A" * 300_000)
    )
    with pytest.raises(ValueError, match="save_path"):
        await ncbi_seq.fetch_sequence(http, "NC_000001.11")


@respx.mock
async def test_ncbi_relative_save_path_rejected_before_fetch(http):
    route = respx.get(url__startswith=f"{EUTILS}/efetch.fcgi")
    with pytest.raises(ValueError, match="absolute"):
        await ncbi_seq.fetch_sequence(http, "NM_000546.6", save_path="rel/x.fasta")
    assert not route.called, "must reject the path before downloading anything"


# ---------- finding: pdb primary citation dropped its PMID (key casing) ----------

@respx.mock
async def test_pdb_primary_citation_pmid_casing(http):
    from bio_mcp.clients import pdb

    entry = {
        "rcsb_id": "6VXX",
        "struct": {"title": "t"},
        "rcsb_entry_info": {},
        "rcsb_primary_citation": {
            "title": "c", "rcsb_journal_abbrev": "Cell", "year": 2020,
            "pdbx_database_id_DOI": "10.1016/x", "pdbx_database_id_PubMed": 32155444,
        },
    }
    respx.get("https://data.rcsb.org/rest/v1/core/entry/6VXX").mock(
        return_value=httpx.Response(200, json=entry)
    )
    r = await pdb.fetch_pdb_entry(http, "6VXX")
    assert r["primary_citation"]["pmid"] == "32155444"
    assert r["primary_citation"]["doi"] == "10.1016/x"


# ---------- finding: biorxiv 'recent' returned the stale START of the window ----------

@respx.mock
async def test_biorxiv_recent_reads_window_tail(http):
    def page(cursor: int, dates: list[str]) -> dict:
        return {
            "messages": [{"status": "ok", "total": "250", "cursor": str(cursor), "count": len(dates)}],
            "collection": [
                {"doi": f"10.1101/2026.{cursor + i}", "title": "t", "category": "genomics", "date": d}
                for i, d in enumerate(dates)
            ],
        }

    respx.get(url__regex=r".*/details/biorxiv/.*/0$").mock(
        return_value=httpx.Response(200, json=page(0, ["2026-09-07"] * 100))
    )
    respx.get(url__regex=r".*/details/biorxiv/.*/200$").mock(
        return_value=httpx.Response(200, json=page(200, ["2026-09-16"] * 50))
    )
    respx.get(url__regex=r".*/details/biorxiv/.*/100$").mock(
        return_value=httpx.Response(200, json=page(100, ["2026-09-12"] * 100))
    )
    r = await preprints.recent_biorxiv(http, days=10, max_results=30)
    assert r["returned"] == 30
    assert all(p["date"] == "2026-09-16" for p in r["preprints"][:30]), "newest page must lead"
