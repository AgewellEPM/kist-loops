#!/usr/bin/env python3
"""Install a content-addressed Symbols adapter and merge just its MCP entry."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from catalog import effects
from store import checked, decode, encoded, need, read, write

MODULES = ("server.py", "catalog.py", "floor.py", "service.py", "runtime.py", "store.py")


def replace(path, raw):
    path = checked(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".symbols-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install(floor_path, liberate, prefix, mcp, python):
    need((3, 11) <= sys.version_info[:2] <= (3, 14), "Install with an existing supported Python 3.11–3.14.")
    prefix = checked(prefix)
    mcp = checked(mcp)
    payload = {"adapter/" + n: read(Path(__file__).parent / n) for n in MODULES}
    for package in ("symbolic_floor", "floor_runtime"):
        source = checked(Path(floor_path) / package)
        need(source.is_dir(), "Missing floor package: " + package)
        for file in sorted(source.rglob("*.py")):
            payload["floor/" + str(file.relative_to(floor_path))] = read(file)
    hashes = {k: hashlib.sha256(v).hexdigest() for k, v in payload.items()}
    release_id = hashlib.sha256(encoded(hashes)).hexdigest()
    release = prefix / "releases" / release_id[:16]
    if not release.exists():
        release.mkdir(mode=0o700, parents=True)
        for rel, raw in payload.items():
            dest = release / rel
            dest.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            write(dest, raw)
        write(release / "release.json", encoded({"schema": "kist-symbols-release-v1", "sha256": release_id,
                                                "files": hashes, "floor_source": str(floor_path)}))
    # Verify every copied byte even when reusing a prior installation.
    for rel, sha in hashes.items():
        need(hashlib.sha256(read(release / rel)).hexdigest() == sha, "Installed payload differs: " + rel)
    cfgpath = prefix / "config.json"
    if not cfgpath.exists():
        root = prefix / "workspace"
        (root / "inbox").mkdir(mode=0o700, parents=True)
        config = {"schema": "kist-symbols-config-v1", "root": str(root), "liberate": str(liberate),
                  "sources": {"inbox": str(root / "inbox")},
                  "targets": {
                      "goldeneye": {"url": "http://127.0.0.1:8093/api/state", "identity_pointer": "/game",
                                    "identity_prefix": "goldeneye-", "coverage": "N64 GoldenEye harness snapshot: RAM-derived gameplay, pilot, perception, navigation, rules and evidence as exposed by /api/state"},
                      "doom": {"url": "http://127.0.0.1:8099/api/state", "identity_pointer": "/game",
                               "identity_prefix": "doom-", "coverage": "DOOM harness snapshot as exposed by /api/state"}}}
        write(cfgpath, encoded(config))
    before = read(mcp) if mcp.exists() else b'{"mcpServers":{}}'
    document = decode(before)
    entry = {"command": str(python), "args": ["-I", "-B", str(release / "adapter/server.py"),
                                                 "--config", str(cfgpath)],
             "computerUse": False, "toolEffects": effects()}
    previous = document.setdefault("mcpServers", {}).get("symbols")
    if previous and previous != entry:
        prevargs = previous.get("args", [])
        need(len(prevargs) == 5 and prevargs[3:] == ["--config", str(cfgpath)]
             and Path(prevargs[2]).parent.parent.parent == prefix / "releases",
             "A different Symbols server is already registered; inspect it before replacing it.")
    backup = prefix / ("mcp-before-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f") + ".json")
    write(backup, before)
    document["mcpServers"]["symbols"] = entry
    replace(mcp, json.dumps(document, indent=2).encode() + b"\n")
    receipt = {"release": str(release), "sha256": release_id, "config": str(cfgpath),
               "mcp": str(mcp), "backup": str(backup), "tool_count": len(effects())}
    replace(prefix / "installation.json", encoded(receipt))
    return receipt


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--floor", type=Path, required=True)
    p.add_argument("--liberate", type=Path, required=True)
    p.add_argument("--prefix", type=Path, required=True)
    p.add_argument("--mcp", type=Path, required=True)
    a = p.parse_args()
    print(json.dumps(install(a.floor.resolve(), a.liberate.absolute(), a.prefix.absolute(),
                             a.mcp.absolute(), Path(sys.executable).resolve()), indent=2))
