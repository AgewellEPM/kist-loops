"""Layer 3: bioinformatics compute — run Python scripts in the bio-mcp venv.

The venv ships biopython, pandas, scipy, numpy, so scripts can parse FASTA/
FASTQ/CSV, run stats, and align with what fetch_sequence saved to the
workspace.

HONEST SCOPE (do not oversell): this is *process-level* isolation only —
own process, isolated mode (-I), wall-clock timeout, address-space cap,
output caps, workspace cwd. It is NOT a security boundary: scripts run as
the invoking user with network access. Fine for trusted research code; not
for untrusted third-party code.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

WORKSPACE = Path(__file__).resolve().parent.parent / "workspace"
DEFAULT_TIMEOUT_S = 120
MAX_TIMEOUT_S = 600
MAX_OUTPUT_CHARS = 40_000
MAX_LISTED_FILES = 500
ADDRESS_SPACE_MB = 4096

# Bootstrap passed to `python -I -c`: sets the best-effort memory cap, then
# execs the UNMODIFIED user file (argv[1]). Compiling the user source as its
# own unit keeps `from __future__ import ...` legal and line 1 = line 1 in
# tracebacks — prepending a prelude broke both. macOS constrains/ignores
# RLIMIT_AS (hard limit may be below our cap and setrlimit then raises), so
# clamp to the hard limit and fall back to timeout-only bounding rather than
# failing every script.
_BOOTSTRAP = (
    "import resource as _r, sys\n"
    f"_cap = {ADDRESS_SPACE_MB} * 1024 * 1024\n"
    "_soft, _hard = _r.getrlimit(_r.RLIMIT_AS)\n"
    "_target = _cap if _hard == _r.RLIM_INFINITY else min(_cap, _hard)\n"
    "try:\n"
    "    _r.setrlimit(_r.RLIMIT_AS, (_target, _hard))\n"
    "except (ValueError, OSError):\n"
    "    pass  # platform refuses AS cap; wall-clock timeout remains the bound\n"
    "_p = sys.argv[1]\n"
    "sys.argv = sys.argv[1:]  # user script sees argv[0] = its own path, like a normal run\n"
    "exec(compile(open(_p, 'rb').read(), _p, 'exec'), {'__name__': '__main__', '__file__': _p})\n"
)


def run_python_script(
    script: str,
    *,
    timeout_s: int = DEFAULT_TIMEOUT_S,
    cwd: str | None = None,
) -> dict:
    """Run a Python script with the bio-mcp venv interpreter.

    Returns {exit_code, stdout, stderr, truncated, workspace} — never raises
    for script failures (a nonzero exit is a *result*), only for misuse.
    """
    if not script.strip():
        raise ValueError("empty script")
    timeout = min(int(timeout_s), MAX_TIMEOUT_S)
    if timeout <= 0:
        raise ValueError(f"timeout_s must be positive, got {timeout_s}")

    workdir = Path(cwd).expanduser() if cwd else WORKSPACE
    if not workdir.is_absolute():
        raise ValueError(f"cwd must be absolute, got {cwd!r}")
    workdir.mkdir(parents=True, exist_ok=True)

    # RLIMIT_AS via the -c bootstrap keeps this dependency-free and macOS-safe
    # (no preexec_fn threading hazards). The script lives in a PRIVATE temp dir
    # OUTSIDE the workspace: concurrent runs must not read each other's source,
    # and transient tmp*.py must not contaminate scripts that glob the cwd.
    tmpdir = Path(tempfile.mkdtemp(prefix="bio-mcp-run-"))
    script_path = tmpdir / "script.py"
    script_path.write_text(script, encoding="utf-8")
    try:
        proc = subprocess.run(
            [sys.executable, "-I", "-c", _BOOTSTRAP, str(script_path)],
            cwd=workdir,
            capture_output=True,
            text=True,
            errors="replace",  # scripts may emit raw bytes; never crash the tool on decode
            timeout=timeout,
        )
        stdout, stderr, code = proc.stdout, proc.stderr, proc.returncode
        timed_out = False
    except subprocess.TimeoutExpired as e:
        stdout = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        stderr = (e.stderr or b"").decode(errors="replace") if isinstance(e.stderr, bytes) else (e.stderr or "")
        code = -1
        timed_out = True
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    truncated = len(stdout) > MAX_OUTPUT_CHARS or len(stderr) > MAX_OUTPUT_CHARS
    return {
        "exit_code": code,
        "timed_out": timed_out,
        "stdout": stdout[:MAX_OUTPUT_CHARS],
        "stderr": stderr[:MAX_OUTPUT_CHARS],
        "truncated": truncated,
        "workspace": str(workdir),
        "interpreter": sys.executable,
        "isolation": "process-level only (timeout, best-effort memory cap, output cap); NOT a security sandbox",
    }


def list_workspace(subdir: str | None = None) -> dict:
    """List files in the bio-mcp workspace so scripts and fetches can meet."""
    # One resolved root for BOTH the guard and the relative_to below: the old
    # str.startswith prefix check admitted siblings ('../workspace2'), and an
    # unresolved WORKSPACE crashed on every file when the workspace is a symlink.
    ws = WORKSPACE.resolve()
    base = (WORKSPACE / subdir).resolve() if subdir else ws
    try:
        base.relative_to(ws)
    except ValueError:
        # deliberate rejection; never echo the resolved absolute path back
        raise ValueError(f"subdir escapes the workspace: {subdir!r}") from None
    if not base.exists():
        return {"workspace": str(base), "files": [], "note": "directory does not exist yet"}
    files = []
    # Iterate lazily and stop at the cap — never materialize/sort the whole tree.
    for p in base.rglob("*"):
        if p.is_file() and not p.name.startswith("."):
            files.append({"path": str(p.relative_to(ws)), "bytes": p.stat().st_size})
            if len(files) >= MAX_LISTED_FILES:
                break
    files.sort(key=lambda f: f["path"])
    return {"workspace": str(WORKSPACE), "files": files}
