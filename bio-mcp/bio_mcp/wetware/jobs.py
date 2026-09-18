"""Wetware background jobs: simulations that outlive run_python's 600s cap.

Each job gets a directory under workspace/.wetware/jobs/<id>/ holding the
script, logs, and state. A detached SUPERVISOR process (own session) runs the
script with the same -I + memory-cap bootstrap as run_python, enforces the
wall-clock timeout, and writes exit.json atomically when the job ends — so
job state survives MCP-server restarts and is readable from plain files.

States reported by job_status:
  running   — supervisor alive, no exit.json yet
  finished  — exit.json present (exit_code, timed_out, cancelled flags inside)
  died      — supervisor gone with no exit record (machine slept/killed -9)
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path

from ..sandbox import _BOOTSTRAP, WORKSPACE

JOBS_DIR = WORKSPACE / ".wetware" / "jobs"
DEFAULT_JOB_TIMEOUT_S = 3600
MAX_JOB_TIMEOUT_S = 86_400
MAX_TAIL_CHARS = 40_000
MAX_LISTED_JOBS = 50

# Runs detached; argv: job_dir, timeout_s, workdir. Writes exit.json exactly
# once, atomically, on child exit / timeout / SIGTERM (cancel).
_SUPERVISOR = r"""
import json, os, signal, subprocess, sys

job_dir, timeout_s, workdir = sys.argv[1], float(sys.argv[2]), sys.argv[3]
bootstrap = open(os.path.join(job_dir, "bootstrap.txt"), encoding="utf-8").read()
out = open(os.path.join(job_dir, "out.log"), "wb")
err = open(os.path.join(job_dir, "err.log"), "wb")
child = subprocess.Popen(
    [sys.executable, "-I", "-c", bootstrap, os.path.join(job_dir, "script.py")],
    cwd=workdir, stdout=out, stderr=err,
)
result = {"exit_code": None, "timed_out": False, "cancelled": False}

def finish():
    tmp = os.path.join(job_dir, "exit.json.tmp")
    with open(tmp, "w") as f:
        json.dump(result, f)
    os.replace(tmp, os.path.join(job_dir, "exit.json"))

def on_term(sig, frame):
    child.terminate()
    try:
        child.wait(5)
    except Exception:
        child.kill()
        child.wait()
    result["cancelled"] = True
    result["exit_code"] = child.poll()
    finish()
    sys.exit(0)

signal.signal(signal.SIGTERM, on_term)
try:
    result["exit_code"] = child.wait(timeout_s)
except subprocess.TimeoutExpired:
    child.terminate()
    try:
        child.wait(5)
    except Exception:
        child.kill()
        child.wait()
    result["timed_out"] = True
    result["exit_code"] = child.poll()
finish()
"""


def _job_dir(job_id: str) -> Path:
    if not job_id or "/" in job_id or job_id.startswith("."):
        raise ValueError(f"invalid job id: {job_id!r}")
    d = JOBS_DIR / job_id
    if not d.is_dir():
        raise ValueError(f"unknown job: {job_id!r}")
    return d


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _read_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def start_job(script: str, *, label: str | None = None, timeout_s: int = DEFAULT_JOB_TIMEOUT_S) -> dict:
    """Launch a background Python job in the bio-mcp venv; returns its id immediately."""
    if not script.strip():
        raise ValueError("empty script")
    timeout = int(timeout_s)
    if timeout <= 0:
        raise ValueError(f"timeout_s must be positive, got {timeout_s}")
    timeout = min(timeout, MAX_JOB_TIMEOUT_S)

    job_id = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    job_dir = JOBS_DIR / job_id
    job_dir.mkdir(parents=True)
    (job_dir / "script.py").write_text(script, encoding="utf-8")
    (job_dir / "bootstrap.txt").write_text(_BOOTSTRAP, encoding="utf-8")

    with open(job_dir / "supervisor.log", "wb") as sup_log:
        proc = subprocess.Popen(
            [sys.executable, "-I", "-c", _SUPERVISOR, str(job_dir), str(timeout), str(WORKSPACE)],
            stdout=sup_log,
            stderr=sup_log,
            start_new_session=True,  # own session → cancel can signal the whole group
        )
    meta = {
        "id": job_id,
        "label": label,
        "pid": proc.pid,
        "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "started_ts": time.time(),
        "timeout_s": timeout,
        "script_bytes": len(script.encode("utf-8")),
    }
    (job_dir / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
    return {"job_id": job_id, "state": "running", "pid": proc.pid, "timeout_s": timeout, "label": label}


def job_status(job_id: str) -> dict:
    """Current state of one job, from its on-disk record."""
    d = _job_dir(job_id)
    meta = _read_json(d / "meta.json") or {}
    status: dict = {"job_id": job_id, "label": meta.get("label"), "started": meta.get("started"), "timeout_s": meta.get("timeout_s")}
    exit_rec = _read_json(d / "exit.json")
    if exit_rec is not None:
        status["state"] = "finished"
        status.update(exit_rec)
        return status
    pid = meta.get("pid")
    if pid and _pid_alive(int(pid)):
        status["state"] = "running"
        started_ts = meta.get("started_ts")
        if started_ts:
            status["elapsed_s"] = round(time.time() - float(started_ts), 1)
        return status
    status["state"] = "died"
    status["note"] = "supervisor exited without an exit record (host slept or SIGKILL)"
    return status


def job_output(job_id: str, *, tail_chars: int = 10_000) -> dict:
    """Tail of a job's stdout/stderr logs (works while running or after exit)."""
    d = _job_dir(job_id)
    cap = min(int(tail_chars), MAX_TAIL_CHARS)
    if cap <= 0:
        raise ValueError(f"tail_chars must be positive, got {tail_chars}")
    out: dict = {"job_id": job_id, "tail_chars": cap}
    for name, key in (("out.log", "stdout"), ("err.log", "stderr")):
        p = d / name
        if p.is_file():
            text = p.read_text(encoding="utf-8", errors="replace")
            out[key] = text[-cap:]
            out[f"{key}_truncated"] = len(text) > cap
        else:
            out[key] = ""
            out[f"{key}_truncated"] = False
    return out


def cancel_job(job_id: str) -> dict:
    """SIGTERM a running job's whole process group; the supervisor records the cancel."""
    d = _job_dir(job_id)
    if (d / "exit.json").exists():
        return {"job_id": job_id, "state": "finished", "note": "already finished; nothing to cancel"}
    meta = _read_json(d / "meta.json") or {}
    pid = int(meta.get("pid", 0))
    if not pid or not _pid_alive(pid):
        return {"job_id": job_id, "state": "died", "note": "supervisor already gone"}
    try:
        os.killpg(os.getpgid(pid), signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        os.kill(pid, signal.SIGTERM)
    # Give the supervisor's SIGTERM handler a moment to write the exit record.
    deadline = time.time() + 3.0
    while time.time() < deadline:
        if (d / "exit.json").exists():
            return job_status(job_id)
        time.sleep(0.1)
    # Supervisor died before recording (e.g. group-killed mid-write): record it here.
    if not (d / "exit.json").exists():
        tmp = d / "exit.json.tmp"
        tmp.write_text(json.dumps({"exit_code": None, "timed_out": False, "cancelled": True}), encoding="utf-8")
        os.replace(tmp, d / "exit.json")
    return job_status(job_id)


def list_jobs(max_results: int = MAX_LISTED_JOBS) -> dict:
    """Most recent jobs (id sorts chronologically), newest first."""
    cap = min(int(max_results), MAX_LISTED_JOBS)
    if cap <= 0:
        raise ValueError(f"max_results must be positive, got {max_results}")
    if not JOBS_DIR.is_dir():
        return {"jobs": [], "note": "no jobs yet"}
    ids = sorted((p.name for p in JOBS_DIR.iterdir() if p.is_dir()), reverse=True)[:cap]
    return {"jobs": [job_status(i) for i in ids], "n_total": sum(1 for p in JOBS_DIR.iterdir() if p.is_dir())}
