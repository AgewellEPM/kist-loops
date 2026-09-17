"""Simulation environment: full capability set, deterministic execution.

Runs a plan step-by-step against a simulated bench (wells with volumes and
relative concentrations; absorbance readings derived from concentration).
Everything is deterministic — same plan, same readings.

HONESTY: evidence_grade is "simulated". A simulated outcome VALIDATES THE
PLAN (it executed, volumes balanced, readings computed); it says nothing
about the physical world, so collect() always reports observed
"inconclusive" and the floor never turns it into graph evidence.
"""

from __future__ import annotations

import hashlib
import json

from ..capabilities import CAPABILITIES

_RUNS: dict[str, dict] = {}  # executor_ref -> completed run (in-process)


class Env:
    env_id = "simulation"
    evidence_grade = "simulated"

    def capabilities(self) -> set[str]:
        return set(CAPABILITIES)  # the sim can pantomime every affordance

    def submit(self, contract: dict, plan: dict) -> dict:
        wells: dict[str, dict] = {"well:stock": {"volume_ul": 1000.0, "concentration": 1.0}}
        held: dict | None = None  # liquid currently in the "tip"
        readings: list[dict] = []
        log: list[str] = []

        for step in plan["steps"]:
            cap, p = step["capability"], step["params"]
            if cap == "aspirate":
                src = wells.setdefault(p["source"], {"volume_ul": 0.0, "concentration": 0.0})
                take = min(p["volume_ul"], src["volume_ul"])
                held = {"volume_ul": take, "concentration": src["concentration"]}
                src["volume_ul"] -= take
                log.append(f"aspirate {take}ul from {p['source']}")
            elif cap == "dispense":
                dst = wells.setdefault(p["dest"], {"volume_ul": 0.0, "concentration": 0.0})
                vol = held["volume_ul"] if held else 0.0
                conc_in = held["concentration"] if held else 0.0
                total = dst["volume_ul"] + vol
                if total > 0:
                    dst["concentration"] = (
                        dst["concentration"] * dst["volume_ul"] + conc_in * vol
                    ) / total
                dst["volume_ul"] = total
                held = None
                log.append(f"dispense {vol}ul into {p['dest']}")
            elif cap == "mix":
                log.append(f"mix {p['target']} x{p['cycles']}")
            elif cap == "heat":
                log.append(f"heat {p['target']} to {p['temp_c']}C for {p['duration_s']}s")
            elif cap == "measure_absorbance":
                well = wells.setdefault(p["target"], {"volume_ul": 0.0, "concentration": 0.0})
                # Beer-Lambert-shaped toy: absorbance proportional to concentration.
                value = round(well["concentration"] * 1.0, 6)
                readings.append({"capability": cap, "target": p["target"],
                                 "wavelength_nm": p["wavelength_nm"],
                                 "absorbance": value, "simulated": True})
                log.append(f"read A{p['wavelength_nm']} of {p['target']} = {value}")
            elif cap == "read_sensor":
                readings.append({"capability": cap, "sensor": p["sensor"],
                                 "value": 0.0, "simulated": True})
            elif cap == "label":
                log.append(f"label {p['target']}: {p['text']}")

        # Well the dilution planner filled: expose final concentrations as a
        # reading so the caller sees the simulated series.
        series = {w: round(s["concentration"], 9) for w, s in sorted(wells.items())}
        ref = "sim:" + hashlib.sha256(
            json.dumps(plan, sort_keys=True).encode()
        ).hexdigest()[:16]
        _RUNS[ref] = {
            "observed": "inconclusive",  # a simulation NEVER confirms the world
            "notes": "simulation validated plan execution; not physical evidence",
            "readings": readings,
            "final_concentrations": series,
            "log": log,
            "simulated": True,
        }
        return {"status": "submitted", "executor_ref": ref}

    def check(self, executor_ref: str) -> dict:
        return {"status": "completed" if executor_ref in _RUNS else "failed"}

    def collect(self, executor_ref: str) -> dict:
        run = _RUNS.get(executor_ref)
        if run is None:
            return {"observed": "inconclusive",
                    "notes": f"unknown simulation ref {executor_ref}", "readings": []}
        return run
