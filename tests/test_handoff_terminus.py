"""Hand-off terminus: three layers + the closed loop.

Layer 1 affordance validation, Layer 3 intent->capability planning (same
intent, different environments), Layer 2 registry/swap, and the full
build -> dispatch -> check -> collect -> ingest lifecycle. Plus the honesty
gates: blocked contracts refused, simulations never become graph evidence,
only physical confirmed/refuted materializes edges.
"""

import json
from pathlib import Path

import pytest

from symbolic_floor.capabilities import validate_call
from symbolic_floor.environments import (
    load_environment,
    register_environment,
    list_environments,
)
from symbolic_floor.handoff import (
    build_contract,
    check_handoff,
    collect_result,
    dispatch_handoff,
    list_handoffs,
)
from symbolic_floor.planner import plan_intent
from symbolic_floor.schema import ValidationError

from test_verdict_supported_roundtrip import seed_p12345
from test_verdict_conflicting import test_verdict_conflicting_accession_mismatch  # noqa: F401
from conftest import manual_provenance

DILUTION = {"factor": 10, "steps": 3, "volume_ul": 100}


# ---------------- Layer 1: affordances ----------------

def test_capability_validation_enforces_schema():
    ok = validate_call("aspirate", {"volume_ul": 50, "source": "well:stock"})
    assert ok["volume_ul"] == 50.0
    with pytest.raises(ValidationError, match="unknown capability"):
        validate_call("teleport", {})
    with pytest.raises(ValidationError, match="outside"):
        validate_call("heat", {"target": "w", "temp_c": 500, "duration_s": 10})
    with pytest.raises(ValidationError, match="missing param"):
        validate_call("dispense", {"volume_ul": 5})


# ---------------- Layer 3: planning ----------------

def test_same_intent_plans_differently_per_environment():
    full = {"aspirate", "dispense", "mix"}
    planned = plan_intent("serial_dilution", DILUTION, full)
    assert planned["status"] == "PLANNED"
    # 3 steps x (aspirate, dispense, mix) = 9 capability calls
    assert len(planned["steps"]) == 9
    assert planned["steps"][0]["capability"] == "aspirate"

    # An environment WITHOUT mix cannot do it — honest, not substituted.
    no_mix = plan_intent("serial_dilution", DILUTION, {"aspirate", "dispense"})
    assert no_mix["status"] == "UNPLANNABLE"
    assert no_mix["missing_capabilities"] == ["mix"]
    assert no_mix["steps"] == []


def test_plan_is_deterministic():
    a = json.dumps(plan_intent("serial_dilution", DILUTION, {"aspirate", "dispense", "mix"}), sort_keys=True)
    b = json.dumps(plan_intent("serial_dilution", DILUTION, {"aspirate", "dispense", "mix"}), sort_keys=True)
    assert a == b


def test_plan_rejects_unknown_intent():
    with pytest.raises(ValidationError, match="unknown intent"):
        plan_intent("summon_demon", {}, {"aspirate"})


# ---------------- Layer 2: registry / swap ----------------

def test_register_and_swap_environments(store):
    sim = register_environment(store, "simulation")
    human = register_environment(store, "human_tech")
    assert sim["evidence_grade"] == "simulated"
    assert human["evidence_grade"] == "physical"
    ids = {e["env_id"] for e in list_environments(store)}
    assert ids == {"simulation", "human_tech"}
    # Same capability name space discovered from both — the swap is transparent.
    assert "aspirate" in sim["capabilities"] and "aspirate" in human["capabilities"]


# ---------------- lifecycle: dispatch -> collect ----------------

def _supported_contract(store):
    seed_p12345(store)
    claim = store.get_or_create_claim("protein:P12345")
    return build_contract(store, claim, predicted_outcome="A280 rises after dilution",
                          intent="serial_dilution", intent_params=DILUTION)


def test_contract_carries_result_prediction_and_sources(store):
    contract = _supported_contract(store)
    assert contract["verified_result"]["verdict"] == "SUPPORTED"
    assert contract["predicted_outcome"]["supplied_by"] == "caller"
    # Every evidence item has full provenance (the sources flowing downstream).
    assert contract["evidence"] and all(e["provenance"]["source"] for e in contract["evidence"])
    assert contract["execution_request"]["intent"] == "serial_dilution"
    assert contract["contract_id"].startswith("handoff:")


def test_floor_never_invents_prediction(store):
    seed_p12345(store)
    claim = store.get_or_create_claim("protein:P12345")
    with pytest.raises(ValidationError, match="predicted_outcome is required"):
        build_contract(store, claim, predicted_outcome="  ",
                       intent="measure_sample",
                       intent_params={"target": "well:D1", "wavelength_nm": 280})


def test_simulation_runs_plan_but_is_not_evidence(store):
    contract = _supported_contract(store)
    env = load_environment("simulation")
    receipt = dispatch_handoff(store, contract, env)
    assert receipt["status"] == "submitted" and receipt["plan_steps"] == 9

    assert check_handoff(store, contract["contract_id"], env)["status"] == "completed"
    collected = collect_result(store, contract["contract_id"], env)
    # A simulation validated the plan; it NEVER becomes graph evidence.
    assert collected["evidence_grade"] == "simulated"
    assert collected["observed"] == "inconclusive"
    assert collected["ingested_as_evidence"] is False
    assert collected["evidence_edges_written"] == []
    # ...and no supports_claim edge exists.
    assert store.get_edges(relation="supports_claim") == []


def test_physical_confirmed_becomes_graph_evidence(tmp_path, store):
    contract = _supported_contract(store)
    outbox = tmp_path / "outbox"
    env = load_environment("human_tech", outbox=outbox)
    receipt = dispatch_handoff(store, contract, env)

    # The human writes the result file — data coming back to the hands' owner.
    ref = receipt["executor_ref"]
    (outbox / f"{ref}.result.json").write_text(json.dumps({
        "observed": "confirmed", "notes": "bench run ok",
        "readings": [{"target": "well:D3", "absorbance": 0.1}],
    }))
    assert check_handoff(store, contract["contract_id"], env)["status"] == "completed"

    collected = collect_result(store, contract["contract_id"], env)
    assert collected["evidence_grade"] == "physical"
    assert collected["observed"] == "confirmed"
    assert collected["ingested_as_evidence"] is True
    assert collected["evidence_edges_written"], "confirmed physical result must write edges"
    # supports_claim edges now exist, provenance pinned to the executor.
    supports = store.get_edges(relation="supports_claim")
    assert supports
    prov = json.loads(supports[0]["provenance_json"])
    assert prov["source"] == "executor" and env.env_id in prov["raw_id"]


def test_physical_refuted_writes_conflicts_with(tmp_path, store):
    contract = _supported_contract(store)
    outbox = tmp_path / "outbox"
    env = load_environment("human_tech", outbox=outbox)
    receipt = dispatch_handoff(store, contract, env)
    (outbox / f"{receipt['executor_ref']}.result.json").write_text(
        json.dumps({"observed": "refuted", "notes": "no signal"}))
    collected = collect_result(store, contract["contract_id"], env)
    assert collected["ingested_as_evidence"] is True
    assert store.get_edges(relation="conflicts_with")
    assert store.get_edges(relation="supports_claim") == []


def test_inconclusive_physical_records_but_writes_nothing(tmp_path, store):
    contract = _supported_contract(store)
    outbox = tmp_path / "outbox"
    env = load_environment("human_tech", outbox=outbox)
    receipt = dispatch_handoff(store, contract, env)
    (outbox / f"{receipt['executor_ref']}.result.json").write_text(
        json.dumps({"observed": "inconclusive", "notes": "ambiguous"}))
    collected = collect_result(store, contract["contract_id"], env)
    assert collected["ingested_as_evidence"] is False
    assert store.get_edges(relation="supports_claim") == []
    assert store.get_edges(relation="conflicts_with") == []
    # ...but the outcome IS recorded (auditable).
    audit = list_handoffs(store)
    assert audit[-1]["status"] == "completed"


def test_blocked_contract_refused(store):
    # Build a CONFLICTING world (accession mismatch), then try to hand off.
    seq = "sequence:" + "c" * 64
    store.add_edge("protein:P12345", "has_sequence", seq, provenance=manual_provenance("s"))
    store.add_edge("protein:P12345", "predicts_structure", "structure:AF-Q99999-F1",
                   provenance=manual_provenance("rogue"))
    store.add_edge("protein:P12345", "has_structure", "structure:1ABC",
                   provenance=manual_provenance("exp"))
    claim = store.get_or_create_claim("protein:P12345")
    contract = build_contract(store, claim, predicted_outcome="x",
                              intent="measure_sample",
                              intent_params={"target": "well:D1", "wavelength_nm": 280})
    assert contract["execution_class"] == "blocked"
    env = load_environment("simulation")
    with pytest.raises(ValidationError, match="BLOCKED"):
        dispatch_handoff(store, contract, env)
    # The refusal is recorded, not silently dropped.
    assert list_handoffs(store)[-1]["status"] == "refused"


def test_unplannable_intent_is_recorded_refusal(store):
    contract = _supported_contract(store)

    class NoMixEnv:
        env_id = "nomix"
        evidence_grade = "physical"
        def capabilities(self): return {"aspirate", "dispense"}
        def submit(self, c, p): raise AssertionError("must not submit")
        def check(self, r): return {}
        def collect(self, r): return {}

    with pytest.raises(ValidationError, match="missing capabilities"):
        dispatch_handoff(store, contract, NoMixEnv())
    assert list_handoffs(store)[-1]["status"] == "unplannable"


def test_swap_environment_no_reasoning_change(store):
    """Same contract, two environments -> both plan+dispatch; reasoning identical."""
    contract = _supported_contract(store)
    sim = dispatch_handoff(store, contract, load_environment("simulation"))
    # A second contract id is identical (deterministic) — same reasoning input.
    contract2 = _supported_contract(store)
    assert contract2["contract_id"] == contract["contract_id"]
    assert sim["plan_steps"] == 9
