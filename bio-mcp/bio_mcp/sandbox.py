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

import subprocess
import sys
import tempfile
from pathlib import Path

WORKSPACE = Path(__file__).resolve().parent.parent / "workspace"
DEFAULT_TIMEOUT_S = 120
MAX_TIMEOUT_S = 600
MAX_OUTPUT_CHARS = 40_000
ADDRESS_SPACE_MB = 4096

# Best-effort memory cap: macOS constrains/ignores RLIMIT_AS (hard limit may be
# below our cap and setrlimit then raises), so clamp to the hard limit and fall
# back to timeout-only bounding rather than failing every script.
_PREEXEC = (
    "import resource as _r\n"
    f"_cap = {ADDRESS_SPACE_MB} * 1024 * 1024\n"
    "_soft, _hard = _r.getrlimit(_r.RLIMIT_AS)\n"
    "_target = _cap if _hard == _r.RLIM_INFINITY else min(_cap, _hard)\n"
    "try:\n"
    "    _r.setrlimit(_r.RLIMIT_AS, (_target, _hard))\n"
    "except (ValueError, OSError):\n"
    "    pass  # platform refuses AS cap; wall-clock timeout remains the bound\n"
    "del _r, _cap, _soft, _hard, _target\n"
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

    # RLIMIT_AS via an in-script prelude keeps this dependency-free and
    # macOS-safe (no preexec_fn threading hazards).
    full_script = _PREEXEC + script

    with tempfile.NamedTemporaryFile("w", suffix=".py", dir=workdir, delete=False) as f:
        f.write(full_script)
        script_path = Path(f.name)
    try:
        proc = subprocess.run(
            [sys.executable, "-I", str(script_path)],
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
        script_path.unlink(missing_ok=True)

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
    base = WORKSPACE / subdir if subdir else WORKSPACE
    base = base.resolve()
    if not str(base).startswith(str(WORKSPACE.resolve())):
        raise ValueError(f"subdir escapes the workspace: {subdir!r}")
    if not base.exists():
        return {"workspace": str(base), "files": [], "note": "directory does not exist yet"}
    files = []
    for p in sorted(base.rglob("*")):
        if p.is_file() and not p.name.startswith("."):
            files.append({"path": str(p.relative_to(WORKSPACE)), "bytes": p.stat().st_size})
        if len(files) >= 500:
            break
    return {"workspace": str(WORKSPACE), "files": files}
