"""Brief §6.10 — non-allowlisted host raises BEFORE any network I/O."""

import pytest

from symbolic_floor.connectors.base import AllowlistError, http_get

from conftest import transport_for


def test_allowlist_rejects_foreign_host_before_io():
    recorder = transport_for({})  # any call would AssertionError; none may happen
    with pytest.raises(AllowlistError, match="not allowlisted"):
        http_get("https://api.evil.example/steal", transport=recorder)
    assert recorder.calls == []  # transport never invoked


def test_allowlist_rejects_http_scheme():
    recorder = transport_for({})
    with pytest.raises(AllowlistError, match="only https"):
        http_get("http://rest.uniprot.org/uniprotkb/P12345.fasta", transport=recorder)
    assert recorder.calls == []


def test_allowlist_accepts_every_briefed_host():
    """Multi-site: one assertion per allowlisted host from the brief."""
    hosts = ("rest.uniprot.org", "data.rcsb.org", "alphafold.ebi.ac.uk",
             "files.rcsb.org", "www.ebi.ac.uk", "search.rcsb.org")
    for host in hosts:
        url = f"https://{host}/ping"
        t = transport_for({url: (200, b"ok")})
        status, body = http_get(url, transport=t)
        assert (status, body) == (200, b"ok"), f"host {host} should be allowed"
