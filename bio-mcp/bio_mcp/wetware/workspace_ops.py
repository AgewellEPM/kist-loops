"""Wetware workspace operations: write, read, move, remove inside the workspace.

Every path is workspace-relative and containment-checked with the same
resolve()+relative_to() pattern as sandbox.list_workspace — absolute paths
and `..` escapes are deliberate rejections, not errors to soften.
"""

from __future__ import annotations

import shutil
from pathlib import Path

from ..sandbox import WORKSPACE

MAX_WRITE_BYTES = 10 * 1024 * 1024
MAX_READ_CHARS = 200_000
# Job state lives under the workspace; file ops must not corrupt live jobs.
INTERNAL_DIR = ".wetware"


def _resolve(rel_path: str, *, allow_internal: bool = False) -> Path:
    """Map a workspace-relative path to an absolute one, or reject."""
    if not rel_path or not rel_path.strip():
        raise ValueError("empty path")
    p = Path(rel_path)
    if p.is_absolute():
        raise ValueError(f"path must be workspace-relative, got absolute: {rel_path!r}")
    ws = WORKSPACE.resolve()
    target = (ws / p).resolve()
    try:
        relative = target.relative_to(ws)
    except ValueError:
        raise ValueError(f"path escapes the workspace: {rel_path!r}") from None
    if not allow_internal and relative.parts and relative.parts[0] == INTERNAL_DIR:
        raise ValueError(f"{INTERNAL_DIR}/ is job-runner state; use the job tools instead")
    return target


def write_file(rel_path: str, content: str, *, append: bool = False) -> dict:
    """Write (or append) text to a workspace file, creating parent dirs."""
    data = content.encode("utf-8")
    if len(data) > MAX_WRITE_BYTES:
        raise ValueError(f"content is {len(data)} bytes; cap is {MAX_WRITE_BYTES}")
    target = _resolve(rel_path)
    if target == WORKSPACE.resolve():
        raise ValueError("refusing to write the workspace root itself")
    if target.is_dir():
        raise ValueError(f"target is a directory: {rel_path!r}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with open(target, "ab" if append else "wb") as f:
        f.write(data)
    return {
        "path": str(target.relative_to(WORKSPACE.resolve())),
        "bytes": target.stat().st_size,
        "appended": append,
    }


def read_file(rel_path: str, *, max_chars: int = MAX_READ_CHARS) -> dict:
    """Read a workspace file as UTF-8 text (job logs allowed via job tools, not here)."""
    target = _resolve(rel_path)
    if not target.is_file():
        raise ValueError(f"no such file in workspace: {rel_path!r}")
    text = target.read_text(encoding="utf-8", errors="replace")
    cap = min(int(max_chars), MAX_READ_CHARS)
    return {
        "path": str(target.relative_to(WORKSPACE.resolve())),
        "content": text[:cap],
        "truncated": len(text) > cap,
        "bytes": target.stat().st_size,
    }


def move_path(src: str, dst: str) -> dict:
    """Move/rename a file or directory within the workspace."""
    s = _resolve(src)
    d = _resolve(dst)
    if not s.exists():
        raise ValueError(f"source does not exist: {src!r}")
    if s == WORKSPACE.resolve():
        raise ValueError("refusing to move the workspace root")
    if d.exists():
        raise ValueError(f"destination already exists: {dst!r}")
    d.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(s), str(d))
    ws = WORKSPACE.resolve()
    return {"moved": str(s.relative_to(ws)), "to": str(d.relative_to(ws))}


def remove_path(rel_path: str) -> dict:
    """Delete a workspace file or directory tree. Root and job state are refused."""
    target = _resolve(rel_path)
    ws = WORKSPACE.resolve()
    if target == ws:
        raise ValueError("refusing to remove the workspace root")
    if not target.exists():
        raise ValueError(f"path does not exist: {rel_path!r}")
    if target.is_dir():
        n_files = sum(1 for p in target.rglob("*") if p.is_file())
        shutil.rmtree(target)
        return {"removed": str(target.relative_to(ws)), "kind": "directory", "files_removed": n_files}
    target.unlink()
    return {"removed": str(target.relative_to(ws)), "kind": "file", "files_removed": 1}
