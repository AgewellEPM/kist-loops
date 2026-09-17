"""Shared fixtures: a temp-file floor store and canned transports.

No live network anywhere in tests — connectors always receive a stub
transport. The store writes to pytest's tmp dir (the CLI's default DB path is
the only runtime write location; see DECISIONS.md #10).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from symbolic_floor.schema import utc_now_iso
from symbolic_floor.store import Store

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture()
def store(tmp_path):
    s = Store(tmp_path / "floor.db")
    yield s
    s.close()


def manual_provenance(citation: str = "test fixture") -> dict:
    return {"source": "manual", "url": None,
            "retrieved_at": utc_now_iso(), "raw_id": citation}


def transport_for(routes: dict[str, tuple[int, bytes]]):
    """Stub transport: exact-URL -> (status, body). Unknown URL is a test bug."""
    calls: list[str] = []

    def _send(url: str, timeout: float) -> tuple[int, bytes]:
        calls.append(url)
        if url not in routes:
            raise AssertionError(f"test transport has no route for {url}")
        return routes[url]

    _send.calls = calls
    return _send


def load_fixture(name: str) -> bytes:
    return (FIXTURES / name).read_bytes()


def load_fixture_json(name: str):
    return json.loads(load_fixture(name))
