"""Wetware lifecycle probes: multi-call job flows the scenario table can't express.

Five probes, each returning a scenario-shaped result dict:
  1 happy lifecycle   — start → poll finished → output has marker → artifact
                        readable via wetware_read_file → removed
  2 restart survival  — kill/reconnect the SERVER, then job_status of the
                        finished job must still read finished from disk
  3 cancel            — SIGTERM lane records cancelled=True
  4 timeout           — supervisor enforces timeout_s without the server's help
  5 oversize write    — content 1 byte over the 10MB cap must be a clean
                        rejection through the real wire, not a transport death
"""

from __future__ import annotations

import asyncio
import json
import time

POLL_TIMEOUT_S = 25
MAX_WRITE_BYTES = 10 * 1024 * 1024


def _result(name: str, tool: str, severity: str, notes: str = "") -> dict:
    return {"name": name, "tool": tool, "severity": severity, "expect": "ok",
            "status": "PASS", "findings": [], "elapsed_s": None, "notes": notes}


async def _call(handle, tool: str, args: dict):
    from .harness import _is_error, _parse_payload  # late import: harness imports this module

    res = await asyncio.wait_for(handle.session.call_tool(tool, args), timeout=60)
    payload, text = _parse_payload(res)
    return _is_error(res), payload if payload is not None else {}, text


async def _poll_finished(handle, job_id: str) -> dict:
    deadline = time.monotonic() + POLL_TIMEOUT_S
    while time.monotonic() < deadline:
        is_err, st, text = await _call(handle, "wetware_job_status", {"job_id": job_id})
        if is_err:
            raise AssertionError(f"job_status errored mid-poll: {text[:200]}")
        if st.get("state") != "running":
            return st
        await asyncio.sleep(0.3)
    raise AssertionError(f"job {job_id} still running after {POLL_TIMEOUT_S}s")


async def probe_happy_lifecycle(handle) -> tuple[dict, str | None]:
    out = _result("wetware job happy lifecycle", "wetware_job_*", "critical",
                  "start → finished(0) → output marker → artifact written to workspace cwd")
    t0 = time.monotonic()
    job_id = None
    try:
        script = "print('dogfood-job-marker'); open('dogfood_job_artifact.txt','w').write('artifact-ok')"
        is_err, job, text = await _call(handle, "wetware_job_start", {"script": script, "label": "dogfood-happy", "timeout_s": 60})
        if is_err or not job.get("job_id"):
            out["findings"].append(f"job_start failed: {text[:200]}")
            return out, None
        job_id = job["job_id"]
        st = await _poll_finished(handle, job_id)
        if st.get("state") != "finished" or st.get("exit_code") != 0:
            out["findings"].append(f"expected finished/0, got {json.dumps(st)[:250]}")
        _, output, _ = await _call(handle, "wetware_job_output", {"job_id": job_id})
        if "dogfood-job-marker" not in output.get("stdout", ""):
            out["findings"].append(f"stdout lost the marker: {output.get('stdout', '')[:150]!r}")
        is_err, artifact, text = await _call(handle, "wetware_read_file", {"path": "dogfood_job_artifact.txt"})
        if is_err or artifact.get("content") != "artifact-ok":
            out["findings"].append(f"job's workspace artifact unreadable/wrong: {text[:150]}")
        else:
            await _call(handle, "wetware_remove", {"path": "dogfood_job_artifact.txt"})
        # tail_chars validation needs a real job — piggyback here
        is_err, _, text = await _call(handle, "wetware_job_output", {"job_id": job_id, "tail_chars": 0})
        if not is_err or "positive" not in text.lower():
            out["findings"].append(f"tail_chars=0 not cleanly rejected: {text[:150]}")
    except AssertionError as e:
        out["findings"].append(str(e))
    out["elapsed_s"] = round(time.monotonic() - t0, 2)
    if out["findings"]:
        out["status"] = "FINDING"
    return out, job_id


async def probe_restart_survival(handle, job_id: str | None) -> dict:
    out = _result("wetware job state survives server restart", "wetware_job_status", "critical",
                  "the disk-backed claim: reconnect a FRESH server process, finished job must still report finished")
    t0 = time.monotonic()
    if job_id is None:
        out["findings"].append("no finished job available (happy-lifecycle probe failed upstream)")
    else:
        await handle.connect()  # brand-new server process
        handle.reconnects += 1  # deliberate; don't let the counter imply a crash
        try:
            is_err, st, text = await _call(handle, "wetware_job_status", {"job_id": job_id})
            if is_err:
                out["findings"].append(f"status errored after restart: {text[:200]}")
            elif st.get("state") != "finished" or st.get("exit_code") != 0:
                out["findings"].append(f"job state lost across restart: {json.dumps(st)[:250]}")
        except Exception as e:
            out["findings"].append(f"restart probe blew up: {type(e).__name__}: {str(e)[:200]}")
    out["elapsed_s"] = round(time.monotonic() - t0, 2)
    if out["findings"]:
        out["status"] = "FINDING"
    return out


async def probe_cancel(handle) -> dict:
    out = _result("wetware job cancel recorded", "wetware_job_cancel", "high")
    t0 = time.monotonic()
    try:
        _, job, _ = await _call(handle, "wetware_job_start",
                                {"script": "import time; time.sleep(60)", "label": "dogfood-cancel", "timeout_s": 120})
        await asyncio.sleep(0.6)  # supervisor needs a beat to install its SIGTERM handler
        is_err, st, text = await _call(handle, "wetware_job_cancel", {"job_id": job["job_id"]})
        if is_err:
            out["findings"].append(f"cancel errored: {text[:200]}")
        elif st.get("state") != "finished" or st.get("cancelled") is not True:
            out["findings"].append(f"cancel not recorded: {json.dumps(st)[:250]}")
    except AssertionError as e:
        out["findings"].append(str(e))
    out["elapsed_s"] = round(time.monotonic() - t0, 2)
    if out["findings"]:
        out["status"] = "FINDING"
    return out


async def probe_timeout(handle) -> dict:
    out = _result("wetware job timeout enforced by supervisor", "wetware_job_start", "critical",
                  "timeout must hold with zero help from the MCP server process")
    t0 = time.monotonic()
    try:
        _, job, _ = await _call(handle, "wetware_job_start",
                                {"script": "import time; time.sleep(60)", "label": "dogfood-timeout", "timeout_s": 2})
        st = await _poll_finished(handle, job["job_id"])
        if st.get("timed_out") is not True:
            out["findings"].append(f"timed_out not set: {json.dumps(st)[:250]}")
    except AssertionError as e:
        out["findings"].append(str(e))
    out["elapsed_s"] = round(time.monotonic() - t0, 2)
    if out["findings"]:
        out["status"] = "FINDING"
    return out


async def probe_oversize_write(handle) -> dict:
    out = _result("wetware oversize write rejected cleanly", "wetware_write_file", "medium",
                  "10MB+1 through the real stdio wire: clean cap rejection, not a transport death")
    t0 = time.monotonic()
    try:
        is_err, _, text = await _call(
            handle, "wetware_write_file",
            {"path": "dogfood_wetware_oversize.txt", "content": "x" * (MAX_WRITE_BYTES + 1)},
        )
        if not is_err:
            out["findings"].append("write over the documented 10MB cap SUCCEEDED")
            await _call(handle, "wetware_remove", {"path": "dogfood_wetware_oversize.txt"})
        elif "cap" not in text.lower():
            out["findings"].append(f"over-cap error unhelpful: {text[:150]}")
    except Exception as e:
        out["findings"].append(f"oversize payload killed the call/transport: {type(e).__name__}: {str(e)[:200]}")
        await handle.connect()
        handle.reconnects += 1
    out["elapsed_s"] = round(time.monotonic() - t0, 2)
    if out["findings"]:
        out["status"] = "FINDING"
    return out


async def run_wetware_probes(handle) -> list[dict]:
    happy, job_id = await probe_happy_lifecycle(handle)
    results = [happy]
    results.append(await probe_restart_survival(handle, job_id))
    results.append(await probe_cancel(handle))
    results.append(await probe_timeout(handle))
    results.append(await probe_oversize_write(handle))
    return results
