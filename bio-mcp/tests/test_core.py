"""Core contracts: citations (layer 4), HTTP retry/rate-limit, sandbox (layer 3)."""

import asyncio

import httpx
import pytest
import respx

from bio_mcp.citations import (
    SUPPORTED_DATABASES,
    UnpinnedSourceError,
    format_citation,
    source_record,
)
from bio_mcp.http import BioAPIError, BioHTTP
from bio_mcp.sandbox import WORKSPACE, list_workspace, run_python_script


# ---- Layer 4: the verification contract ----

def test_source_record_pins_url():
    rec = source_record("uniprot", "P04637")
    assert rec["url"] == "https://www.uniprot.org/uniprotkb/P04637/entry"
    assert rec["database"] == "uniprot"
    assert rec["id"] == "P04637"
    assert rec["retrieved"]


def test_source_record_rejects_empty_identifier():
    with pytest.raises(UnpinnedSourceError):
        source_record("pubmed", "   ")


def test_source_record_rejects_unknown_database():
    with pytest.raises(UnpinnedSourceError):
        source_record("wikipedia", "p53")


@pytest.mark.parametrize("db", SUPPORTED_DATABASES)
def test_every_supported_database_builds_a_resolvable_url(db):
    # Per-site assertion over ALL databases, not just the one that failed once.
    rec = source_record(db, "TEST123")
    assert rec["url"].startswith("https://"), f"{db} builds a non-https URL"
    assert "TEST123" in rec["url"], f"{db} URL does not embed the identifier"


def test_format_citation_requires_ids():
    with pytest.raises(UnpinnedSourceError):
        format_citation(authors=["Doe J"], title="X", venue="Y", year=2024, ids={})


def test_format_citation_truncates_authors_at_six():
    c = format_citation(
        authors=[f"A{i} B" for i in range(9)],
        title="T",
        venue="V",
        year=2024,
        ids={"pmid": "1"},
    )
    assert "et al" in c and "PMID: 1" in c


# ---- HTTP layer ----

@respx.mock
async def test_http_raises_on_4xx():
    respx.get("https://rest.uniprot.org/uniprotkb/BAD").mock(
        return_value=httpx.Response(400, text="bad accession")
    )
    http = BioHTTP()
    with pytest.raises(BioAPIError) as e:
        await http.get("https://rest.uniprot.org/uniprotkb/BAD")
    assert e.value.status == 400
    await http.aclose()


@respx.mock
async def test_http_retries_5xx_then_succeeds():
    route = respx.get("https://rest.ensembl.org/ping")
    route.side_effect = [httpx.Response(500), httpx.Response(200, json={"ok": 1})]
    http = BioHTTP()
    resp = await http.get_json("https://rest.ensembl.org/ping")
    assert resp == {"ok": 1}
    assert route.call_count == 2
    await http.aclose()


async def test_rate_limiter_spaces_requests():
    http = BioHTTP()
    bucket = http._bucket("export.arxiv.org")  # 1 rps
    t0 = asyncio.get_event_loop().time()
    await bucket.acquire()
    await bucket.acquire()
    elapsed = asyncio.get_event_loop().time() - t0
    assert elapsed >= 0.9, f"second acquire should wait ~1s, waited {elapsed:.2f}s"
    await http.aclose()


# ---- Layer 3: sandbox ----

def test_run_python_happy_path():
    out = run_python_script("import pandas, scipy, Bio; print('libs ok')", timeout_s=60)
    assert out["exit_code"] == 0, out["stderr"]
    assert "libs ok" in out["stdout"]
    assert "NOT a security sandbox" in out["isolation"]


def test_run_python_nonzero_exit_is_result_not_exception():
    out = run_python_script("raise SystemExit(3)")
    assert out["exit_code"] == 3
    assert out["timed_out"] is False


def test_run_python_timeout():
    out = run_python_script("import time; time.sleep(30)", timeout_s=2)
    assert out["timed_out"] is True
    assert out["exit_code"] == -1


def test_run_python_rejects_empty_script():
    with pytest.raises(ValueError):
        run_python_script("   ")


def test_run_python_output_capped():
    out = run_python_script("print('x' * 100_000)")
    assert len(out["stdout"]) <= 40_000
    assert out["truncated"] is True


def test_list_workspace_blocks_escape():
    with pytest.raises(ValueError):
        list_workspace("../..")


def test_workspace_default_cwd(tmp_path):
    out = run_python_script("from pathlib import Path; print(Path.cwd())")
    assert str(WORKSPACE) in out["stdout"]
