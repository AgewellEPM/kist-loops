"""Thin fail-fast wrapper around the perslis CLI VM operator.

The GhostBridge session owns the VM lifecycle (opened via
legacy_session_open); this wrapper only observes frames and sends keys to
that already-running guest over its QMP socket. Every action is pinned to
the socket path; nothing here can launch or select a different VM.
"""
from __future__ import annotations

import pathlib
import subprocess
import time

PERSLIS = "/Users/lukekist/bin/perslis"
CAPTURE_ROOT = pathlib.Path(
    "/Users/lukekist/.perslis/retroshell-v1-production-dos-qualified/captures")


class GuestError(RuntimeError):
    pass


class PerslisGuest:
    def __init__(self, qmp_socket: str, capture_prefix: str = "symdoom"):
        self.qmp = qmp_socket
        self.prefix = capture_prefix
        self._shot = 0

    def _run(self, *args: str) -> str:
        result = subprocess.run(
            [PERSLIS, *args], capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            raise GuestError(
                f"perslis {' '.join(args[:3])} failed: {result.stderr.strip()[:300]}")
        return result.stdout

    def capture(self) -> pathlib.Path:
        """Grab one framebuffer PNG; returns the host path."""
        self._shot += 1
        name = f"{self.prefix}_{self._shot:05d}.png"
        self._run("vm", "capture", "--qmp", self.qmp, "--out", str(CAPTURE_ROOT / name))
        path = CAPTURE_ROOT / name
        if not path.exists():
            raise GuestError(f"capture claimed success but {path} is missing")
        return path

    def key(self, qcode: str) -> None:
        """Tap one key chord in the guest (e.g. 'left', 'ctrl', 'ret').
        NOTE: the CLI takes the qcode positionally (its --help says --chord,
        but the parser rejects it — verified 2026-09-17)."""
        self._run("vm", "key", "--qmp", self.qmp, qcode)

    def keys(self, qcodes: list[str], gap_s: float = 0.35) -> None:
        for code in qcodes:
            self.key(code)
            time.sleep(gap_s)
