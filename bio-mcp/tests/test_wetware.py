"""Wetware actuation lane: workspace write ops + background jobs.

Jobs run REAL detached subprocesses (fast scripts) — that's the contract
being pinned: state survives on disk, not in server memory.
"""

import json
import time

import pytest

from bio_mcp.sandbox import WORKSPACE
from bio_mcp.wetware import (
    cancel_job,
    job_output,
    job_status,
    list_jobs,
    move_path,
    read_file,
    remove_path,
    start_job,
    write_file,
)
from bio_mcp.wetware.jobs import JOBS_DIR


def _wait_finished(job_id, timeout=15.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        st = job_status(job_id)
        if st["state"] != "running":
            return st
        time.sleep(0.2)
    raise AssertionError(f"job {job_id} still running after {timeout}s")


# ---- workspace ops ----

def test_write_read_move_remove_roundtrip():
    out = write_file("wetware_test/a.txt", "hello wetware\n")
    assert out["path"] == "wetware_test/a.txt"
    assert read_file("wetware_test/a.txt")["content"] == "hello wetware\n"

    write_file("wetware_test/a.txt", "line2\n", append=True)
    assert read_file("wetware_test/a.txt")["content"].endswith("line2\n")

    moved = move_path("wetware_test/a.txt", "wetware_test/b.txt")
    assert moved["to"] == "wetware_test/b.txt"
    assert not (WORKSPACE / "wetware_test" / "a.txt").exists()

    gone = remove_path("wetware_test")
    assert gone["kind"] == "directory"
    assert gone["files_removed"] == 1
    assert not (WORKSPACE / "wetware_test").exists()


@pytest.mark.parametrize("bad", ["../outside.txt", "/etc/passwd", "a/../../x", "", "  "])
def test_write_rejects_escapes_and_absolutes(bad):
    with pytest.raises(ValueError):
        write_file(bad, "nope")


def test_ops_refuse_wetware_internal_state():
    for fn in (lambda: write_file(".wetware/jobs/x", "clobber"),
               lambda: remove_path(".wetware"),
               lambda: move_path(".wetware", "elsewhere")):
        with pytest.raises(ValueError, match="job-runner state"):
            fn()


def test_remove_refuses_root_and_missing():
    with pytest.raises(ValueError, match="workspace root"):
        remove_path(".")
    with pytest.raises(ValueError, match="does not exist"):
        remove_path("wetware_test/definitely_not_here_xyz")


def test_read_missing_file_is_deliberate_rejection():
    with pytest.raises(ValueError, match="no such file"):
        read_file("wetware_test/nope.txt")


def test_write_size_cap():
    with pytest.raises(ValueError, match="cap is"):
        write_file("wetware_test/big.txt", "x" * (10 * 1024 * 1024 + 1))


# ---- background jobs ----

def test_job_lifecycle_happy_path():
    job = start_job("print('wetware job ran'); open('wetware_job_artifact.txt','w').write('ok')",
                    label="pytest-happy", timeout_s=60)
    assert job["state"] == "running"
    st = _wait_finished(job["job_id"])
    assert st["state"] == "finished"
    assert st["exit_code"] == 0
    assert st["timed_out"] is False and st["cancelled"] is False

    out = job_output(job["job_id"])
    assert "wetware job ran" in out["stdout"]
    # The job wrote into the workspace cwd — actuation, not just observation.
    artifact = WORKSPACE / "wetware_job_artifact.txt"
    assert artifact.read_text() == "ok"
    artifact.unlink()


def test_job_nonzero_exit_is_recorded_not_raised():
    job = start_job("import sys; sys.stderr.write('boom\\n'); sys.exit(3)", timeout_s=60)
    st = _wait_finished(job["job_id"])
    assert st["state"] == "finished"
    assert st["exit_code"] == 3
    assert "boom" in job_output(job["job_id"])["stderr"]


def test_job_timeout_enforced_by_supervisor():
    job = start_job("import time; time.sleep(60)", timeout_s=2)
    st = _wait_finished(job["job_id"], timeout=20)
    assert st["state"] == "finished"
    assert st["timed_out"] is True


def test_job_cancel_records_cancellation():
    job = start_job("import time; time.sleep(60)", timeout_s=120)
    time.sleep(0.5)  # let the supervisor install its handler
    st = cancel_job(job["job_id"])
    assert st["state"] == "finished"
    assert st["cancelled"] is True
    # exit.json is on disk — state survives any server restart.
    assert json.loads((JOBS_DIR / job["job_id"] / "exit.json").read_text())["cancelled"] is True


def test_job_state_is_disk_backed_and_listed():
    job = start_job("print('x')", label="pytest-list", timeout_s=60)
    _wait_finished(job["job_id"])
    listing = list_jobs()
    ids = [j["job_id"] for j in listing["jobs"]]
    assert job["job_id"] in ids
    d = JOBS_DIR / job["job_id"]
    assert (d / "meta.json").is_file() and (d / "script.py").is_file()


def test_job_rejects_bad_input():
    with pytest.raises(ValueError, match="empty script"):
        start_job("   ")
    with pytest.raises(ValueError, match="positive"):
        start_job("print(1)", timeout_s=0)
    with pytest.raises(ValueError, match="unknown job"):
        job_status("20990101-000000-deadbeef")
    with pytest.raises(ValueError, match="invalid job id"):
        job_status("../escape")
