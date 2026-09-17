"""Contract validators for dogfood scenarios.

Each validator returns a list of finding strings (empty = contract held).
Contracts are the *promises the README/docstrings make*, not what the code
happens to do — that asymmetry is what makes dogfooding worth points.
"""

from __future__ import annotations

from datetime import date


def check_source(rec: dict, *, expect_id_in_url: bool = True) -> list[str]:
    """Layer-4 contract: source{database,id,url,retrieved} on every record."""
    findings = []
    src = rec.get("source")
    if not isinstance(src, dict):
        return [f"missing/invalid source block: {src!r}"]
    for key in ("database", "id", "url", "retrieved"):
        if not src.get(key):
            findings.append(f"source.{key} missing/empty: {src!r}")
    url = src.get("url", "")
    if url and not url.startswith("https://"):
        findings.append(f"source.url not https: {url}")
    if expect_id_in_url and src.get("id") and src.get("id") not in url:
        findings.append(f"source.url does not embed id {src.get('id')!r}: {url}")
    if src.get("retrieved") and src["retrieved"] != date.today().isoformat():
        findings.append(f"source.retrieved not today: {src['retrieved']}")
    return findings


def check_records(result: dict, list_key: str, *, min_n: int = 1, id_key: str | None = None) -> list[str]:
    """Result must carry >= min_n records, each with a valid source block."""
    findings = []
    records = result.get(list_key)
    if not isinstance(records, list):
        return [f"result[{list_key!r}] is not a list: {type(records).__name__}"]
    if len(records) < min_n:
        findings.append(f"expected >= {min_n} records in {list_key!r}, got {len(records)}")
    for i, rec in enumerate(records[:10]):
        for f in check_source(rec):
            findings.append(f"{list_key}[{i}]: {f}")
        if id_key and not rec.get(id_key):
            findings.append(f"{list_key}[{i}]: missing {id_key!r}")
    return findings


def check_citation(rec: dict) -> list[str]:
    """Literature records must carry a formatted citation with an identifier."""
    c = rec.get("citation", "")
    if not c:
        return [f"missing citation string on {rec.get('pmid') or rec.get('arxiv_id') or rec.get('doi')}"]
    if not any(tag in c for tag in ("PMID:", "DOI:", "ARXIV:")):
        return [f"citation has no identifier tag: {c[:120]}"]
    return []


def error_text_quality(text: str) -> list[str]:
    """Errors must be actionable messages, not bare tracebacks or empty strings."""
    findings = []
    t = (text or "").strip()
    if not t:
        return ["error surfaced with EMPTY message"]
    if t.startswith("Traceback"):
        findings.append(f"raw traceback leaked to client: {t.splitlines()[-1][:150]}")
    if "Connection closed" in t:
        findings.append("server DIED instead of returning a tool error")
    return findings
