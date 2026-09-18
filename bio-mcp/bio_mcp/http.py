"""Shared HTTP layer for all bio API clients.

Design contract (fail-fast, polite):
- One async client, per-host token-bucket rate limiting so we never hammer
  NCBI/Ensembl/etc. beyond their published limits.
- Retries with exponential backoff on 429/5xx/transport errors only.
- Every failure raises BioAPIError with enough context to debug; no silent
  None returns anywhere in this package.
- NCBI_API_KEY (env) is auto-injected for *.ncbi.nlm.nih.gov and raises the
  NCBI limit from 3 to 10 req/s.
"""

from __future__ import annotations

import asyncio
import os
import re
import time
from dataclasses import dataclass, field

import httpx

USER_AGENT = "bio-mcp/0.1 (research tooling; +https://github.com/AgewellEPM/science-loops)"

DEFAULT_TIMEOUT = 30.0
MAX_RETRIES = 3
BACKOFF_BASE = 1.5  # seconds; grows 1.5, 3.0, 6.0
RETRY_AFTER_CAP = 60.0  # a hostile/buggy Retry-After must not park the loop for days
ERROR_BODY_CAP = 4096  # max bytes pulled from a 429/5xx stream just for the message

# Published/polite requests-per-second budgets. Anything unlisted gets DEFAULT_RPS.
DEFAULT_RPS = 5.0
HOST_RPS: dict[str, float] = {
    "eutils.ncbi.nlm.nih.gov": 3.0,   # 10.0 when NCBI_API_KEY is set (adjusted below)
    "rest.ensembl.org": 10.0,
    "rest.uniprot.org": 5.0,
    "www.ebi.ac.uk": 5.0,
    "search.rcsb.org": 5.0,
    "data.rcsb.org": 5.0,
    "files.rcsb.org": 5.0,
    "export.arxiv.org": 1.0,          # arXiv asks for no more than 1 req / 3 s; be extra polite
    "api.biorxiv.org": 2.0,
    "rest.kegg.jp": 3.0,
    "reactome.org": 5.0,
    "api.openalex.org": 5.0,          # OpenAlex polite pool (with mailto) allows ~10/s; stay conservative
    "api.semanticscholar.org": 1.0,   # unauthenticated S2 is aggressively throttled; 1/s is realistic
    "alphafold.ebi.ac.uk": 5.0,
    "pubchem.ncbi.nlm.nih.gov": 5.0,  # PUG REST asks for <=5 req/s
    # NOTE: www.ebi.ac.uk (InterPro + ChEMBL) already bucketed above at 5.0
}


class BioAPIError(RuntimeError):
    """Raised for any upstream API failure. Message carries host, status, and body head."""

    def __init__(self, message: str, *, status: int | None = None, url: str | None = None):
        super().__init__(message)
        self.status = status
        self.url = url


class BioOversizeError(BioAPIError):
    """Streamed body exceeded the caller's cap. Never retried — the fix is a
    save_path, not another attempt."""


def _retry_delay(retry_after: str | None, attempt: int) -> float:
    """Backoff for a 429/5xx. Honors Retry-After (seconds form) capped at
    RETRY_AFTER_CAP. str.isdigit() admits non-ASCII digits ('²'.isdigit() is
    True) that float() rejects — accept ASCII [0-9]+ only."""
    if retry_after and re.fullmatch(r"[0-9]+", retry_after):
        return min(float(retry_after), RETRY_AFTER_CAP)
    return BACKOFF_BASE * (2**attempt)


async def _read_error_head(resp: httpx.Response) -> bytes:
    """Pull at most ERROR_BODY_CAP bytes of an error body for the message —
    never buffer a whole (possibly huge) 429/5xx body. A transport error
    mid-read is tolerated: the retry/raise decision was already made from the
    status line, and a partial head is fine for a diagnostic."""
    head = b""
    try:
        async for chunk in resp.aiter_bytes():
            head += chunk
            if len(head) >= ERROR_BODY_CAP:
                break
    except httpx.TransportError:
        pass
    return head[:ERROR_BODY_CAP]


@dataclass
class _TokenBucket:
    rps: float
    _next_free: float = field(default=0.0)
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    async def acquire(self) -> None:
        async with self._lock:
            now = time.monotonic()
            wait = self._next_free - now
            self._next_free = max(now, self._next_free) + 1.0 / self.rps
        if wait > 0:
            await asyncio.sleep(wait)


class BioHTTP:
    """Rate-limited, retrying async HTTP client shared by every bio client."""

    def __init__(self) -> None:
        self._client = httpx.AsyncClient(
            timeout=DEFAULT_TIMEOUT,
            headers={"User-Agent": USER_AGENT},
            follow_redirects=True,
        )
        self._buckets: dict[str, _TokenBucket] = {}
        self._ncbi_key = os.environ.get("NCBI_API_KEY") or None

    def _bucket(self, host: str) -> _TokenBucket:
        if host not in self._buckets:
            rps = HOST_RPS.get(host, DEFAULT_RPS)
            if host == "eutils.ncbi.nlm.nih.gov" and self._ncbi_key:
                rps = 10.0
            self._buckets[host] = _TokenBucket(rps=rps)
        return self._buckets[host]

    async def get(
        self,
        url: str,
        *,
        params: dict | None = None,
        headers: dict | None = None,
    ) -> httpx.Response:
        req = self._client.build_request("GET", url, params=params, headers=headers)
        host = req.url.host or ""
        if host.endswith("ncbi.nlm.nih.gov") and self._ncbi_key:
            req.url = req.url.copy_merge_params({"api_key": self._ncbi_key})

        last_err: Exception | None = None
        for attempt in range(MAX_RETRIES + 1):
            await self._bucket(host).acquire()
            try:
                resp = await self._client.send(req)
            except httpx.TransportError as e:
                last_err = e
                if attempt < MAX_RETRIES:  # no wasted sleep before "giving up"
                    await asyncio.sleep(BACKOFF_BASE * (2**attempt))
                continue
            if resp.status_code == 429 or resp.status_code >= 500:
                last_err = BioAPIError(
                    f"{host} returned {resp.status_code}: {resp.text[:200]}",
                    status=resp.status_code,
                    url=str(req.url),
                )
                if attempt < MAX_RETRIES:
                    await asyncio.sleep(_retry_delay(resp.headers.get("Retry-After"), attempt))
                continue
            if resp.status_code >= 400:
                raise BioAPIError(
                    f"{host} returned {resp.status_code} for {req.url}: {resp.text[:300]}",
                    status=resp.status_code,
                    url=str(req.url),
                )
            return resp
        raise BioAPIError(
            f"{host}: giving up after {MAX_RETRIES + 1} attempts: {last_err}",
            url=str(req.url),
        )

    async def get_text_capped(
        self,
        url: str,
        *,
        params: dict | None = None,
        headers: dict | None = None,
        max_bytes: int,
    ) -> str:
        """Stream a GET, aborting with BioOversizeError the moment the body
        passes max_bytes — never buffers an unbounded record. Retries 429/5xx
        and transport errors with backoff exactly like get(), including a
        transport error MID-BODY (chromosome-scale streams are where resets
        actually happen). Oversize is terminal and never retried — the fix is
        a save_path, not another attempt."""
        req = self._client.build_request("GET", url, params=params, headers=headers)
        host = req.url.host or ""
        if host.endswith("ncbi.nlm.nih.gov") and self._ncbi_key:
            req.url = req.url.copy_merge_params({"api_key": self._ncbi_key})

        last_err: Exception | None = None
        for attempt in range(MAX_RETRIES + 1):
            await self._bucket(host).acquire()
            try:
                resp = await self._client.send(req, stream=True)
            except httpx.TransportError as e:
                last_err = e
                if attempt < MAX_RETRIES:  # no wasted sleep before "giving up"
                    await asyncio.sleep(BACKOFF_BASE * (2**attempt))
                continue
            delay: float | None = None
            try:
                if resp.status_code == 429 or resp.status_code >= 500:
                    body = (await _read_error_head(resp))[:200].decode(errors="replace")
                    last_err = BioAPIError(
                        f"{host} returned {resp.status_code}: {body}",
                        status=resp.status_code,
                        url=str(req.url),
                    )
                    delay = _retry_delay(resp.headers.get("Retry-After"), attempt)
                elif resp.status_code >= 400:
                    body = (await _read_error_head(resp))[:300].decode(errors="replace")
                    raise BioAPIError(
                        f"{host} returned {resp.status_code} for {req.url}: {body}",
                        status=resp.status_code,
                        url=str(req.url),
                    )
                else:
                    try:
                        chunks: list[bytes] = []
                        size = 0
                        async for chunk in resp.aiter_bytes():
                            size += len(chunk)
                            if size > max_bytes:
                                raise BioOversizeError(
                                    f"response from {host} exceeded the {max_bytes:,}-byte inline cap",
                                    url=str(req.url),
                                )
                            chunks.append(chunk)
                        return b"".join(chunks).decode(resp.encoding or "utf-8", errors="replace")
                    except httpx.TransportError as e:
                        # Mid-body reset: retry exactly like a failed send().
                        # BioOversizeError is NOT a TransportError and stays terminal.
                        last_err = e
                        delay = BACKOFF_BASE * (2**attempt)
            finally:
                await resp.aclose()
            # only reached on a retry branch (delay was set)
            if attempt < MAX_RETRIES:
                await asyncio.sleep(delay)
        raise BioAPIError(
            f"{host}: giving up after {MAX_RETRIES + 1} attempts: {last_err}",
            url=str(req.url),
        )

    async def get_json(self, url: str, *, params: dict | None = None, headers: dict | None = None):
        resp = await self.get(url, params=params, headers={**(headers or {}), "Accept": "application/json"})
        try:
            return resp.json()
        except ValueError as e:
            raise BioAPIError(f"non-JSON response from {url}: {resp.text[:200]}", url=url) from e

    async def get_text(self, url: str, *, params: dict | None = None, headers: dict | None = None) -> str:
        resp = await self.get(url, params=params, headers=headers)
        return resp.text

    async def aclose(self) -> None:
        await self._client.aclose()


_shared: BioHTTP | None = None


def shared_http() -> BioHTTP:
    """Process-wide client so all tools share rate-limit buckets."""
    global _shared
    if _shared is None:
        _shared = BioHTTP()
    return _shared
