"""Dogfood harness: drive the real bio-mcp server over stdio MCP and score it.

Scoring is deliberately inverted: a confirmed FINDING is worth points, a PASS
is worth nothing. The harness exists to break the code, not to flatter it.

Run:  .venv/bin/python -m dogfood.harness
Out:  dogfood/report.json + dogfood/REPORT.md
"""

from __future__ import annotations

import asyncio
import json
import sys
import time
from datetime import date, timedelta
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from .contracts import error_text_quality
from .scenarios import SCENARIOS, Scenario

ROOT = Path(__file__).resolve().parent.parent
CALL_DEADLINE_S = 120
POINTS = {"critical": 5, "high": 3, "medium": 2, "low": 1}


class ServerHandle:
    """Owns one stdio connection; reconnects when a scenario kills the server."""

    def __init__(self) -> None:
        self._stack = None
        self.session: ClientSession | None = None
        self.reconnects = 0

    async def connect(self) -> None:
        from contextlib import AsyncExitStack

        await self.close()
        self._stack = AsyncExitStack()
        params = StdioServerParameters(
            command=str(ROOT / ".venv" / "bin" / "python"), args=["-m", "bio_mcp.server"], cwd=str(ROOT)
        )
        r, w = await self._stack.enter_async_context(stdio_client(params))
        self.session = await self._stack.enter_async_context(ClientSession(r, w))
        await self.session.initialize()

    async def close(self) -> None:
        if self._stack is not None:
            try:
                await self._stack.aclose()
            except Exception:
                pass
            self._stack = None
            self.session = None

    async def alive(self) -> bool:
        try:
            await asyncio.wait_for(self.session.call_tool("list_workspace", {}), timeout=15)
            return True
        except Exception:
            return False


def _is_error(res) -> bool:
    # mcp SDK 2.x models the field as `is_error` (wire alias `isError`);
    # older SDKs exposed `isError` directly. Accept both.
    return bool(getattr(res, "is_error", None) or getattr(res, "isError", False))


def _parse_payload(res) -> tuple[dict | None, str]:
    """Tool result → (parsed dict/list-wrapped, raw text)."""
    text = ""
    for c in res.content or []:
        if getattr(c, "text", None):
            text = c.text
            break
    try:
        obj = json.loads(text)
    except (ValueError, TypeError):
        return None, text
    if isinstance(obj, list):
        return {"_list": obj}, text
    if isinstance(obj, dict):
        return obj, text
    return None, text


def _special_checks(sc: Scenario, payload: dict | None) -> list[str]:
    """Contract checks that need scenario-specific logic beyond validators."""
    findings: list[str] = []
    if payload is None:
        return findings
    if sc.name == "biorxiv recent window freshness":
        # Honest degradation is not pagination blindness: if the tool SELF-FLAGGED
        # freshness=degraded (bioRxiv's slow windowed API forced a window-start
        # fallback) and said so in the note, that's correct behavior under a slow
        # upstream. The failure mode this check exists to catch is SILENT stale.
        if payload.get("freshness") == "degraded":
            if "less recent" not in (payload.get("note") or ""):
                findings.append("freshness=degraded but the note doesn't disclose the staleness to the caller")
            return findings
        dates = sorted(d for d in ((p.get("date") or "") for p in payload.get("preprints", [])) if d)
        if dates:
            newest = date.fromisoformat(dates[-1])
            stale_by = (date.today() - newest).days
            if stale_by > 4:
                findings.append(
                    f"'recent' preprints end at {dates[-1]} ({stale_by}d stale) — cursor-0 page only; "
                    f"window start bias / no pagination (window {payload.get('window')})"
                )
        else:
            findings.append("no preprints returned for a 10-day window")
    elif sc.name == "pubmed nonexistent pmid honest":
        if "999999999" not in (payload.get("missing") or []):
            findings.append(
                "bogus PMID silently dropped: pubmed_abstracts(['999999999']) did not report it "
                "in `missing` (silent-drop contract violation)"
            )
    elif sc.name == "reactome nonsense query honest":
        if payload.get("returned", -1) != 0 or payload.get("entries"):
            # Non-zero could be legit fuzzy matching; only flag fabricated-looking exact zeros
            if not payload.get("entries"):
                findings.append(f"zero-hit query reported returned={payload.get('returned')}")
    return findings


async def run_scenario(handle: ServerHandle, sc: Scenario) -> dict:
    out = {"name": sc.name, "tool": sc.tool, "severity": sc.severity, "expect": sc.expect,
           "status": "PASS", "findings": [], "elapsed_s": None, "notes": sc.notes}
    t0 = time.monotonic()
    try:
        if sc.kind == "resource":
            res = await asyncio.wait_for(handle.session.read_resource(sc.tool), timeout=30)
            body = res.contents[0].text if res.contents else ""
            if len(body or "") < 200:
                out["findings"].append(f"resource body suspiciously small: {len(body or '')} chars")
        else:
            res = await asyncio.wait_for(handle.session.call_tool(sc.tool, sc.args), timeout=CALL_DEADLINE_S)
            payload, text = _parse_payload(res)
            is_err = _is_error(res)
            if sc.expect == "ok":
                if is_err:
                    if sc.name == "uniprot isoform accession behavior":
                        out["findings"].extend(error_text_quality(text))  # clean error accepted
                    else:
                        out["findings"].append(f"expected success, got tool error: {text[:300]}")
                else:
                    if sc.validate:
                        out["findings"].extend(sc.validate(payload if payload is not None else {}))
                    out["findings"].extend(_special_checks(sc, payload))
            else:  # expect error
                if not is_err:
                    out["findings"].append(f"validation gap: call SUCCEEDED, expected rejection. payload head: {text[:200]}")
                else:
                    out["findings"].extend(error_text_quality(text))
                    if sc.error_must_mention and sc.error_must_mention.lower() not in text.lower():
                        out["findings"].append(
                            f"error message unhelpful: expected mention of {sc.error_must_mention!r}, got: {text[:200]}"
                        )
    except asyncio.TimeoutError:
        out["findings"].append(f"DEADLINE: no response within {CALL_DEADLINE_S}s (call hung)")
        out["severity"] = "critical"
        await handle.connect()
        handle.reconnects += 1
    except Exception as e:  # transport/protocol death
        out["findings"].append(f"protocol-level failure: {type(e).__name__}: {str(e)[:300]}")
        out["severity"] = "critical"
        await handle.connect()
        handle.reconnects += 1
    out["elapsed_s"] = round(time.monotonic() - t0, 2)

    if not await handle.alive():
        out["findings"].append("SERVER DEAD after scenario (liveness probe failed) — reconnecting")
        out["severity"] = "critical"
        await handle.connect()
        handle.reconnects += 1
    if out["findings"]:
        out["status"] = "FINDING"
    return out


async def concurrency_probe(handle: ServerHandle) -> dict:
    """5 mixed live calls at once: all must complete, server must survive."""
    out = {"name": "concurrency: 5 parallel mixed calls", "tool": "(multiple)", "severity": "high",
           "expect": "ok", "status": "PASS", "findings": [], "notes": ""}
    calls = [
        ("uniprot_entry", {"accession": "P69905", "include_sequence": False}),
        ("ensembl_gene", {"symbol": "BRCA1"}),
        ("kegg_search", {"query": "citrate cycle"}),
        ("pubmed_search", {"query": "single cell RNA-seq atlas", "max_results": 2}),
        ("run_python", {"script": "print(sum(range(10**6)))"}),
    ]
    t0 = time.monotonic()
    try:
        results = await asyncio.wait_for(
            asyncio.gather(*(handle.session.call_tool(t, a) for t, a in calls), return_exceptions=True),
            timeout=180,
        )
        for (tool, _), res in zip(calls, results):
            if isinstance(res, Exception):
                out["findings"].append(f"{tool} raised under concurrency: {type(res).__name__}: {str(res)[:150]}")
            elif _is_error(res):
                _, text = _parse_payload(res)
                out["findings"].append(f"{tool} tool-errored under concurrency: {text[:150]}")
    except asyncio.TimeoutError:
        out["findings"].append("concurrent batch hung past 180s")
        out["severity"] = "critical"
    out["elapsed_s"] = round(time.monotonic() - t0, 2)
    if not await handle.alive():
        out["findings"].append("SERVER DEAD after concurrency probe")
        out["severity"] = "critical"
    if out["findings"]:
        out["status"] = "FINDING"
    return out


def write_report(results: list[dict], reconnects: int, elapsed: float) -> tuple[int, int]:
    findings = [r for r in results if r["status"] == "FINDING"]
    passes = [r for r in results if r["status"] == "PASS"]
    score = sum(POINTS.get(r["severity"], 1) for r in findings)
    (ROOT / "dogfood" / "report.json").write_text(json.dumps({
        "generated": date.today().isoformat(),
        "scenarios": len(results),
        "passes": len(passes),
        "findings": len(findings),
        "finding_points": score,
        "server_reconnects": reconnects,
        "elapsed_s": round(elapsed, 1),
        "results": results,
    }, indent=2))

    lines = [
        "# bio-mcp Dogfood Report",
        "",
        f"Generated {date.today().isoformat()} · {len(results)} scenarios · "
        f"**{len(findings)} findings ({score} pts)** · {len(passes)} passes · "
        f"{reconnects} forced reconnects · {elapsed:.0f}s wall",
        "",
        "Scoring rewards finding failures (critical=5, high=3, medium=2, low=1). A clean run scores 0.",
        "",
        "## Findings",
        "",
    ]
    if not findings:
        lines.append("None. (Suspicious — check the harness before celebrating.)")
    for r in sorted(findings, key=lambda x: -POINTS.get(x["severity"], 1)):
        lines.append(f"### [{r['severity'].upper()}] {r['name']}  (`{r['tool']}`)")
        for f in r["findings"]:
            lines.append(f"- {f}")
        if r.get("notes"):
            lines.append(f"- _note: {r['notes']}_")
        lines.append("")
    lines += ["## Passes", ""]
    for r in passes:
        lines.append(f"- {r['name']} (`{r['tool']}`, {r.get('elapsed_s', '?')}s)")
    (ROOT / "dogfood" / "REPORT.md").write_text("\n".join(lines) + "\n")
    return len(findings), score


async def main() -> None:
    handle = ServerHandle()
    await handle.connect()
    t0 = time.monotonic()
    results = []
    for sc in SCENARIOS:
        r = await run_scenario(handle, sc)
        marker = "×" if r["status"] == "FINDING" else "✓"
        print(f"  {marker} {sc.name} ({r['elapsed_s']}s)" + (f" — {r['findings'][0][:110]}" if r["findings"] else ""))
        results.append(r)
    results.append(await concurrency_probe(handle))
    print(f"  {'×' if results[-1]['status'] == 'FINDING' else '✓'} {results[-1]['name']}")
    await handle.close()
    n, score = write_report(results, handle.reconnects, time.monotonic() - t0)
    print(f"\n{n} findings, {score} points → dogfood/REPORT.md")


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
