"""Regression pins for the reverse-round-2 dogfood findings (2026-09-17).

Five confirmed findings, one pin each (per-shape where the attack had
multiple shapes): malformed result files, lying environment outcomes,
contract tampering, hostile gene names, executor_ref traversal.
"""

import json

import pytest

from symbolic_floor.adapters.human_tech import Env as HumanTech
from symbolic_floor.environments import load_environment
from symbolic_floor.extract import extract_protein
from symbolic_floor.handoff import (
    build_contract,
    collect_result,
    dispatch_handoff,
    verify_contract,
)
from symbolic_floor.schema import ValidationError

from test_verdict_supported_roundtrip import seed_p12345


def _contract(store):
    seed_p12345(store)
    claim = store.get_or_create_claim("protein:P12345")
    return build_contract(store, claim, predicted_outcome="x",
                          intent="measure_sample",
                          intent_params={"target": "well:D1", "wavelength_nm": 280})


# ---- finding 1: malformed human result files crashed with JSONDecodeError ----

@pytest.mark.parametrize("payload", [b"{{{garbage", b"[1,2,3]", b'"confirmed"'],
                         ids=["not-json", "json-list", "json-string"])
def test_malformed_result_file_clean_refusal(store, tmp_path, payload):
    contract = _contract(store)
    env = load_environment("human_tech", outbox=tmp_path)
    receipt = dispatch_handoff(store, contract, env)
    (tmp_path / f"{receipt['executor_ref']}.result.json").write_bytes(payload)
    with pytest.raises(ValidationError):
        collect_result(store, contract["contract_id"], env)
    assert store.get_edges(relation="supports_claim") == []


# ---- finding 2: non-dict outcome from an environment crashed collect ----

@pytest.mark.parametrize("ret", [None, "confirmed", 7], ids=["none", "str", "int"])
def test_non_dict_outcome_clean_refusal(store, ret):
    contract = _contract(store)

    class Liar:
        env_id = "liar"; evidence_grade = "physical"
        def capabilities(self): return {"measure_absorbance"}
        def submit(self, c, p): return {"status": "submitted", "executor_ref": "L1"}
        def check(self, r): return {"status": "completed"}
        def collect(self, r): return ret

    dispatch_handoff(store, contract, Liar())
    with pytest.raises(ValidationError, match="non-dict outcome"):
        collect_result(store, contract["contract_id"], Liar())


# ---- finding 3: tampered stored contract ingested evidence unchecked ----

def test_contract_tamper_detected(store, tmp_path):
    contract = _contract(store)
    env = load_environment("human_tech", outbox=tmp_path)
    receipt = dispatch_handoff(store, contract, env)
    row = store.db.execute("SELECT rowid, contract_json FROM handoffs").fetchone()
    doc = json.loads(row["contract_json"])
    doc["claim"]["claim_id"] = "claim:00000000-0000-4000-8000-000000000000"
    store.db.execute("UPDATE handoffs SET contract_json=? WHERE rowid=?",
                     (json.dumps(doc, sort_keys=True), row["rowid"]))
    store.db.commit()
    (tmp_path / f"{receipt['executor_ref']}.result.json").write_text(
        '{"observed": "confirmed"}')
    with pytest.raises(ValidationError, match="integrity"):
        collect_result(store, contract["contract_id"], env)
    assert store.get_edges(relation="supports_claim") == []


def test_verify_contract_passes_untampered(store):
    contract = _contract(store)
    verify_contract(contract)  # must not raise
    tampered = {**contract, "execution_class": "verified-nope"}
    with pytest.raises(ValidationError, match="integrity"):
        verify_contract(tampered)


# ---- finding 4: one hostile gene name killed the whole extraction wheel ----

def test_hostile_gene_skipped_not_fatal(store):
    entry = {
        "primaryAccession": "P12345",
        "genes": [{"geneName": {"value": "GOOD1"}},
                  {"geneName": {"value": "BAD GENE; rm -rf /"}}],
        "organism": {"scientificName": "Homo sapiens"},
        "comments": [], "features": [], "uniProtKBCrossReferences": [],
    }

    def send(url, timeout):
        if url.endswith(".json"):
            return 200, json.dumps(entry).encode()
        return 404, b""

    result = extract_protein(store, "P12345", transport=send)
    assert result["status"] == "OK"
    encodes = [e for e in result["edges_written"] if e["relation"] == "encodes"]
    assert [e["source"] for e in encodes] == ["gene:GOOD1"]
    assert result["skipped"] and "BAD GENE" in result["skipped"][0]["source"]


# ---- finding 5: executor_ref traversal reached outside the outbox ----

@pytest.mark.parametrize("ref", ["../../../etc/passwd", "..", "a/../../b", "/abs/path"])
def test_executor_ref_traversal_refused(tmp_path, ref):
    env = HumanTech(outbox=tmp_path)
    with pytest.raises(ValidationError, match="unsafe executor_ref"):
        env.check(ref)
    with pytest.raises(ValidationError, match="unsafe executor_ref"):
        env.collect(ref)
