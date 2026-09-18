"""Regression pins for the 2026-09-17 adversarial-review infrastructure fixes.

Covers bio_mcp/http.py, bio_mcp/sandbox.py, bio_mcp/citations.py, and
dogfood/harness.py. Per the multi-site discipline: findings that touch both
get() and get_text_capped() get one assertion PER SITE, named for the site.
"""

import asyncio
import re
from pathlib import Path

import httpx
import pytest
import respx

import bio_mcp.http as http_mod
import bio_mcp.sandbox as sandbox_mod
from bio_mcp.citations import source_record
from bio_mcp.http import BioAPIError, BioHTTP, BioOversizeError
from dogfood.harness import _parse_payload


@pytest.fixture
async def http():
    h = BioHTTP()
    yield h
    await h.aclose()


@pytest.fixture
def fast_backoff(monkeypatch):
    monkeypatch.setattr(http_mod, "BACKOFF_BASE", 0.01)


@pytest.fixture
def sleep_log(monkeypatch):
    """Record every asyncio.sleep the HTTP layer requests, without waiting."""
    real_sleep = asyncio.sleep
    sleeps: list[float] = []

    async def fake_sleep(delay):
        sleeps.append(delay)
        await real_sleep(0)

    monkeypatch.setattr(asyncio, "sleep", fake_sleep)
    return sleeps


async def _mock_http(handler) -> BioHTTP:
    """BioHTTP over an httpx.MockTransport — needed when a response STREAM
    must raise mid-body, which respx cannot express."""
    h = BioHTTP()
    await h._client.aclose()
    h._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return h


# ---------- finding 1: mid-body transport errors escaped get_text_capped unretried ----------

class _FlakyStream(httpx.AsyncByteStream):
    """Yields one chunk, then dies — the chromosome-scale reset shape."""

    async def __aiter__(self):
        yield b">chr1\nACGT"
        raise httpx.ReadError("connection reset mid-body")


async def test_get_text_capped_retries_mid_body_transport_error(fast_backoff):
    calls = {"n": 0}

    def handler(request):
        calls["n"] += 1
        if calls["n"] == 1:
            return httpx.Response(200, stream=_FlakyStream())
        return httpx.Response(200, content=b">chr1\nACGTACGT")

    h = await _mock_http(handler)
    try:
        text = await h.get_text_capped("https://example.org/seq", max_bytes=10_000)
    finally:
        await h.aclose()
    assert text == ">chr1\nACGTACGT"
    assert calls["n"] == 2, "mid-body ReadError must burn one retry, not escape raw"


async def test_get_text_capped_mid_body_errors_give_up_as_bioapierror(fast_backoff):
    calls = {"n": 0}

    def handler(request):
        calls["n"] += 1
        return httpx.Response(200, stream=_FlakyStream())

    h = await _mock_http(handler)
    try:
        with pytest.raises(BioAPIError, match="giving up"):
            await h.get_text_capped("https://example.org/seq", max_bytes=10_000)
    finally:
        await h.aclose()
    assert calls["n"] == http_mod.MAX_RETRIES + 1


async def test_get_text_capped_oversize_never_retried(fast_backoff):
    # The new TransportError wrapper around the body read must NOT catch or
    # retry BioOversizeError — oversize stays terminal on attempt 1.
    calls = {"n": 0}

    def handler(request):
        calls["n"] += 1
        return httpx.Response(200, content=b"x" * 5_000)

    h = await _mock_http(handler)
    try:
        with pytest.raises(BioOversizeError):
            await h.get_text_capped("https://example.org/big", max_bytes=100)
    finally:
        await h.aclose()
    assert calls["n"] == 1, "oversize must never be retried"


# ---------- finding 2 (per site): Retry-After trusted unbounded ----------

@respx.mock
async def test_get_retry_after_capped_at_60s(http, sleep_log):
    route = respx.get("https://example.org/a")
    route.side_effect = [
        httpx.Response(429, headers={"Retry-After": "99999999"}),
        httpx.Response(200, json={"ok": 1}),
    ]
    resp = await http.get("https://example.org/a")
    assert resp.status_code == 200
    big = [s for s in sleep_log if s >= 1.0]  # bucket waits stay well under 1s
    assert big == [60.0], f"get(): Retry-After must cap at 60s, slept {big}"


@respx.mock
async def test_get_text_capped_retry_after_capped_at_60s(http, sleep_log):
    route = respx.get("https://example.org/b")
    route.side_effect = [
        httpx.Response(429, headers={"Retry-After": "99999999"}, text="slow down"),
        httpx.Response(200, content=b">seq\nACGT"),
    ]
    text = await http.get_text_capped("https://example.org/b", max_bytes=1_000)
    assert text.startswith(">seq")
    big = [s for s in sleep_log if s >= 1.0]
    assert big == [60.0], f"get_text_capped(): Retry-After must cap at 60s, slept {big}"


# ---------- finding 3 (per site): non-ASCII digits crashed the retry loop ----------

def test_retry_delay_rejects_non_ascii_digits():
    # '²'.isdigit() is True but float('²') raises — only ASCII [0-9]+ counts.
    assert http_mod._retry_delay("²", 0) == http_mod.BACKOFF_BASE
    assert http_mod._retry_delay("7", 0) == 7.0


@respx.mock
async def test_get_survives_non_ascii_retry_after(http, fast_backoff):
    route = respx.get("https://example.org/c")
    route.side_effect = [
        # raw latin-1 bytes on the wire; httpx decodes the value back to '²'
        httpx.Response(429, headers={b"Retry-After": "²".encode("latin-1")}),
        httpx.Response(200, json={"ok": 1}),
    ]
    resp = await http.get("https://example.org/c")  # must not raise ValueError
    assert resp.status_code == 200
    assert route.call_count == 2


@respx.mock
async def test_get_text_capped_survives_non_ascii_retry_after(http, fast_backoff):
    route = respx.get("https://example.org/d")
    route.side_effect = [
        httpx.Response(429, headers={b"Retry-After": "²".encode("latin-1")}, text="slow"),
        httpx.Response(200, content=b"ok"),
    ]
    text = await http.get_text_capped("https://example.org/d", max_bytes=1_000)
    assert text == "ok"
    assert route.call_count == 2


# ---------- finding 4 (per site, per branch): wasted terminal backoff sleep ----------

@respx.mock
async def test_get_no_terminal_backoff_on_5xx(http, sleep_log, monkeypatch):
    monkeypatch.setattr(http_mod, "BACKOFF_BASE", 5.0)  # distinctive; fake-slept
    route = respx.get("https://example.org/dead")
    route.side_effect = lambda request: httpx.Response(500, text="down")
    with pytest.raises(BioAPIError, match="giving up"):
        await http.get("https://example.org/dead")
    assert route.call_count == http_mod.MAX_RETRIES + 1
    backoffs = [s for s in sleep_log if s >= 5.0]
    assert backoffs == [5.0, 10.0, 20.0], (
        f"get() 5xx: expected 3 backoffs and NO sleep after the final attempt, got {backoffs}"
    )


@respx.mock
async def test_get_text_capped_no_terminal_backoff_on_5xx(http, sleep_log, monkeypatch):
    monkeypatch.setattr(http_mod, "BACKOFF_BASE", 5.0)
    route = respx.get("https://example.org/dead2")
    route.side_effect = lambda request: httpx.Response(500, text="down")
    with pytest.raises(BioAPIError, match="giving up"):
        await http.get_text_capped("https://example.org/dead2", max_bytes=1_000)
    assert route.call_count == http_mod.MAX_RETRIES + 1
    backoffs = [s for s in sleep_log if s >= 5.0]
    assert backoffs == [5.0, 10.0, 20.0], (
        f"get_text_capped() 5xx: expected 3 backoffs and NO sleep after the final attempt, got {backoffs}"
    )


async def test_get_no_terminal_backoff_on_transport_error(sleep_log, monkeypatch):
    monkeypatch.setattr(http_mod, "BACKOFF_BASE", 5.0)

    def handler(request):
        raise httpx.ConnectError("refused")

    h = await _mock_http(handler)
    try:
        with pytest.raises(BioAPIError, match="giving up"):
            await h.get("https://example.org/x")
    finally:
        await h.aclose()
    backoffs = [s for s in sleep_log if s >= 5.0]
    assert backoffs == [5.0, 10.0, 20.0], (
        f"get() transport: expected 3 backoffs and NO sleep after the final attempt, got {backoffs}"
    )


async def test_get_text_capped_no_terminal_backoff_on_transport_error(sleep_log, monkeypatch):
    monkeypatch.setattr(http_mod, "BACKOFF_BASE", 5.0)

    def handler(request):
        raise httpx.ConnectError("refused")

    h = await _mock_http(handler)
    try:
        with pytest.raises(BioAPIError, match="giving up"):
            await h.get_text_capped("https://example.org/x", max_bytes=1_000)
    finally:
        await h.aclose()
    backoffs = [s for s in sleep_log if s >= 5.0]
    assert backoffs == [5.0, 10.0, 20.0], (
        f"get_text_capped() transport: expected 3 backoffs and NO sleep after the final attempt, got {backoffs}"
    )


# ---------- finding 5: error path buffered the ENTIRE 429/5xx body ----------

class _CountingErrorStream(httpx.AsyncByteStream):
    """Serves up to ~10MB in 1KB chunks, counting how much was actually pulled."""

    def __init__(self, counter: dict):
        self._counter = counter

    async def __aiter__(self):
        for _ in range(10_000):
            self._counter["served"] += 1024
            yield b"e" * 1024


async def test_get_text_capped_error_body_read_capped(fast_backoff):
    served = {"served": 0}
    calls = {"n": 0}

    def handler(request):
        calls["n"] += 1
        if calls["n"] == 1:
            return httpx.Response(500, stream=_CountingErrorStream(served))
        return httpx.Response(200, content=b"ok")

    h = await _mock_http(handler)
    try:
        text = await h.get_text_capped("https://example.org/e", max_bytes=1_000)
    finally:
        await h.aclose()
    assert text == "ok" and calls["n"] == 2
    assert 0 < served["served"] <= 2 * http_mod.ERROR_BODY_CAP, (
        f"error path must read ~{http_mod.ERROR_BODY_CAP}B for the message, pulled {served['served']}B"
    )


# ---------- finding 6: sibling-prefix workspace escape ----------

def _make_ws(monkeypatch, tmp_path, name="workspace") -> Path:
    ws = tmp_path / name
    ws.mkdir()
    monkeypatch.setattr(sandbox_mod, "WORKSPACE", ws)
    return ws


@pytest.mark.parametrize("populated", [False, True], ids=["empty-sibling", "populated-sibling"])
def test_list_workspace_rejects_sibling_prefix_escape(monkeypatch, tmp_path, populated):
    # Old guard: str-prefix check passed '../workspace2' (empty sibling listed
    # silently; populated sibling crashed with a path-leaking ValueError).
    _make_ws(monkeypatch, tmp_path)
    sibling = tmp_path / "workspace2"
    sibling.mkdir()
    if populated:
        (sibling / "secret.txt").write_text("leak")
    with pytest.raises(ValueError, match="escapes the workspace") as e:
        sandbox_mod.list_workspace("../workspace2")
    assert str(tmp_path) not in str(e.value), "rejection must not leak absolute paths"


def test_list_workspace_still_blocks_plain_escape(monkeypatch, tmp_path):
    _make_ws(monkeypatch, tmp_path)
    with pytest.raises(ValueError, match="escapes the workspace"):
        sandbox_mod.list_workspace("../..")


# ---------- finding 7: prelude broke __future__ imports and shifted line numbers ----------

def test_run_python_future_imports_work():
    out = sandbox_mod.run_python_script("from __future__ import annotations\nprint('future ok')")
    assert out["exit_code"] == 0, out["stderr"]
    assert "future ok" in out["stdout"]


def test_run_python_preserves_user_line_numbers():
    out = sandbox_mod.run_python_script("x = 1\ny = 2\nraise RuntimeError('boom at three')\n")
    assert out["exit_code"] != 0
    assert "boom at three" in out["stderr"]
    m = re.search(r'File "[^"]*script\.py", line (\d+)', out["stderr"])
    assert m, f"no user-script frame in traceback:\n{out['stderr']}"
    assert m.group(1) == "3", f"user line 3 must report as line 3, got {m.group(1)}:\n{out['stderr']}"


# ---------- finding 8: symlinked workspace crashed every listing ----------

def test_list_workspace_survives_symlinked_workspace(monkeypatch, tmp_path):
    real = tmp_path / "real_ws"
    (real / "sub").mkdir(parents=True)
    (real / "sub" / "data.fasta").write_text(">x\nACGT\n")
    link = tmp_path / "ws_link"
    link.symlink_to(real, target_is_directory=True)
    monkeypatch.setattr(sandbox_mod, "WORKSPACE", link)
    out = sandbox_mod.list_workspace()
    assert [f["path"] for f in out["files"]] == ["sub/data.fasta"]
    out_sub = sandbox_mod.list_workspace("sub")
    assert [f["path"] for f in out_sub["files"]] == ["sub/data.fasta"]


# ---------- finding 9: temp script written INTO the shared workspace ----------

def test_run_python_script_kept_out_of_cwd_workspace(tmp_path):
    probe = (
        "import pathlib\n"
        "here = pathlib.Path.cwd().resolve()\n"
        "print('SELF_IN_CWD', pathlib.Path(__file__).resolve().parent == here)\n"
        "print('PY_FILES', sorted(p.name for p in here.glob('*.py')))\n"
    )
    out = sandbox_mod.run_python_script(probe, cwd=str(tmp_path))
    assert out["exit_code"] == 0, out["stderr"]
    assert "SELF_IN_CWD False" in out["stdout"], "script source must live OUTSIDE the workspace cwd"
    assert "PY_FILES []" in out["stdout"], "no transient tmp*.py may contaminate workspace globs"


# ---------- finding 10: rglob materialized+sorted the whole tree before capping ----------

def test_list_workspace_caps_at_500_lazily(monkeypatch, tmp_path):
    ws = _make_ws(monkeypatch, tmp_path)
    for i in range(520):
        (ws / f"f{i:04}.txt").write_text("x")
    out = sandbox_mod.list_workspace()
    assert sandbox_mod.MAX_LISTED_FILES == 500
    assert len(out["files"]) == 500
    paths = [f["path"] for f in out["files"]]
    assert paths == sorted(paths), "the capped page must still come back sorted"
    src = Path(sandbox_mod.__file__).read_text()
    assert "sorted(base.rglob" not in src, "must iterate rglob lazily and sort AFTER the cap"


# ---------- finding 11: identifiers not URL-encoded in citation builders ----------

def test_source_record_encodes_unsafe_identifier_chars():
    rec = source_record("doi", "10.1000/a b#x")
    assert rec["id"] == "10.1000/a b#x"  # the id FIELD stays raw
    assert rec["url"] == "https://doi.org/10.1000/a%20b%23x"


@pytest.mark.parametrize(
    "db, ident, url",
    [
        ("pubmed", "34265844", "https://pubmed.ncbi.nlm.nih.gov/34265844/"),
        ("pdb", "6VXX", "https://www.rcsb.org/structure/6VXX"),
        ("kegg", "path:map00010", "https://www.kegg.jp/entry/path:map00010"),
        ("ensembl", "ENSG00000141510", "https://www.ensembl.org/id/ENSG00000141510"),
        ("doi", "10.7717/peerj.4375", "https://doi.org/10.7717/peerj.4375"),
        ("nuccore", "NC_045512.2", "https://www.ncbi.nlm.nih.gov/nuccore/NC_045512.2"),
        ("arxiv", "2103.09992v2", "https://arxiv.org/abs/2103.09992v2"),
        ("reactome", "R-HSA-69488", "https://reactome.org/content/detail/R-HSA-69488"),
    ],
)
def test_source_record_normal_ids_stay_byte_identical(db, ident, url):
    assert source_record(db, ident)["url"] == url


# ---------- finding 12: harness read only the FIRST text content block ----------

class _Block:
    def __init__(self, text):
        self.text = text


class _Result:
    def __init__(self, blocks):
        self.content = blocks


def test_parse_payload_collects_all_text_blocks():
    payload, text = _parse_payload(_Result([_Block('{"a": 1}'), _Block('{"b": 2}')]))
    assert payload == {"_list": [{"a": 1}, {"b": 2}]}
    assert '{"a": 1}' in text and '{"b": 2}' in text


def test_parse_payload_single_and_empty_blocks_unchanged():
    payload, text = _parse_payload(_Result([_Block('{"a": 1}')]))
    assert payload == {"a": 1} and text == '{"a": 1}'
    payload, text = _parse_payload(_Result([]))
    assert payload is None and text == ""
