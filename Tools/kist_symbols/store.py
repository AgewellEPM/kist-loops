"""Private, bounded artifacts for the Symbols/Liberate MCP adapter."""
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import tempfile
from pathlib import Path

CAP = 2 * 1024 * 1024


def need(ok, message):
    if not ok:
        raise ValueError(message)


def name(value):
    need(isinstance(value, str) and re.fullmatch(r"[a-z][a-z0-9_-]{0,63}", value),
         "Use an identifier of 1–64 lowercase letters, digits, hyphens or underscores.")
    return value


def pairs(items):
    out = {}
    for key, value in items:
        need(key not in out, "Duplicate JSON key: " + key)
        out[key] = value
    return out


def decode(raw):
    need(len(raw) <= CAP, "JSON exceeds the 2 MiB evidence limit; select a smaller export.")
    return json.loads(raw, object_pairs_hook=pairs,
                      parse_constant=lambda _: need(False, "Non-finite JSON is refused."))


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, allow_nan=False,
                      separators=(",", ":")).encode()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def checked(path):
    """Do not follow symlinks, including in parents (macOS /var is resolved by config)."""
    path = Path(path).absolute()
    for part in (path, *path.parents):
        need(not part.is_symlink(), "Symlink paths are refused: " + str(part))
    return path


def read(path, cap=CAP):
    path = checked(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        st = os.fstat(stream.fileno())
        need(stat.S_ISREG(st.st_mode) and st.st_nlink == 1, "Evidence must be a regular, unlinked file.")
        need(st.st_size <= cap, "Evidence exceeds the read limit.")
        raw = stream.read(cap + 1)
        need(len(raw) <= cap, "Evidence grew beyond the read limit.")
        return raw


def write(path, raw):
    path = checked(path)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())


def publish(root, kind, identifier, files, metadata):
    """No overwrite; receipt pins every file. Failed builds never become listed systems."""
    parent = checked(Path(root) / kind)
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    dest = checked(parent / name(identifier))
    need(not dest.exists(), "That identifier already exists; use a new identifier.")
    import shutil
    temp = Path(tempfile.mkdtemp(prefix=".pending-", dir=parent))
    try:
        for rel, raw in files.items():
            p = temp / rel
            p.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            write(p, raw)
        receipt = {"schema": "kist-symbols-artifact-v1", **metadata,
                   "files": {k: digest(v) for k, v in files.items()}}
        write(temp / "receipt.json", encoded(receipt))
        # Reserve with mkdir: another server cannot replace a published artifact.
        dest.mkdir(mode=0o700)
        for p in temp.iterdir():
            if p.name != "receipt.json":
                os.rename(p, dest / p.name)
        os.rename(temp / "receipt.json", dest / "receipt.json")
        return dest, receipt
    finally:
        shutil.rmtree(temp)


def verify(path):
    path = checked(path)
    receipt = decode(read(path / "receipt.json"))
    need(receipt.get("schema") == "kist-symbols-artifact-v1", "Unsupported artifact receipt.")
    for rel, sha in receipt["files"].items():
        need(isinstance(rel, str) and not Path(rel).is_absolute() and ".." not in Path(rel).parts,
             "Invalid receipt path.")
        need(digest(read(path / rel)) == sha, "Artifact changed: " + rel)
    return receipt
