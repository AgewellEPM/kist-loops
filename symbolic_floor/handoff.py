"""The hand-off terminus: verified result -> contract -> planned execution ->
data back into the floor.

Three layers meet here (none of them vendor-coupled):
  1. capabilities.py — the affordance model (what hands can do)
  2. environments.py — the registry (which hands are available, discovered)
  3. planner.py      — composes the caller's INTENT from the capabilities the
                       chosen environment actually exposes

This module owns the contract and the lifecycle:

  build_contract     verified result (verdict + trace) + caller-supplied
                     predicted outcome + full evidence (every trace edge with
                     provenance) + execution request (intent), content-addressed.
  dispatch_handoff   plan the intent against the environment's discovered
                     capabilities; UNPLANNABLE or blocked -> honest refusal
                     (recorded); else submit(contract, plan).
  check_handoff      poll the executor's status; the terminus stays in control.
  collect_result     pull the observed outcome BACK, record it, and — only for
                     evidence_grade "physical" and observed confirmed/refuted —
                     materialize supports_claim / conflicts_with edges
                     (witness structure -> claim, provenance source "executor").
                     Simulated or inconclusive outcomes are recorded but NEVER
                     become graph evidence: the floor does not launder
                     simulations or shrugs into facts.

Verdict-derived dispatch policy (deterministic):
  SUPPORTED -> "verified" | UNKNOWN -> "exploratory" (the experiment IS how an
  unknown gets resolved) | CONFLICTING -> "blocked" (never handed off).
"""

from __future__ import annotations

import hashlib
import json

from .environments import Environment
from .planner import plan_intent
from .reasoner import evaluate_claim
from .schema import ValidationError, utc_now_iso
from .store import Store

CONTRACT_VERSION = "2"

OUTCOME_VALUES = ("confirmed", "refuted", "inconclusive")

_EXECUTION_CLASS = {
    "SUPPORTED": "verified",
    "UNKNOWN": "exploratory",
    "CONFLICTING": "blocked",
}


def build_contract(store: Store, claim_id: str, *, predicted_outcome: str,
                   intent: str, intent_params: dict,
                   safety_constraints: list[str] | None = None) -> dict:
    """Package verdict + trace + evidence + prediction + execution request.

    Deterministic: contract_id is the sha256 of the canonical body (volatile
    fields excluded) — same floor state + same request = same identity.
    The floor NEVER invents the prediction; the caller supplies it.
    """
    outcome = (predicted_outcome or "").strip()
    if not outcome:
        raise ValidationError("predicted_outcome is required (the proposer supplies it; "
                              "the floor never invents predictions)")

    result = evaluate_claim(store, claim_id)  # raises on unknown claim

    evidence = []
    for edge_id in result["trace"]:
        row = store.db.execute(
            """SELECT t.id, t.subject, t.relation_type, t.object, p.provenance_json
               FROM typed_relations t
               LEFT JOIN edge_provenance p ON p.edge_id = t.id
               WHERE t.id = ?""",
            (edge_id,),
        ).fetchone()
        if row is None or not row["provenance_json"]:
            raise ValidationError(f"trace edge {edge_id} has no resolvable provenance")
        evidence.append({
            "edge_id": row["id"],
            "source": row["subject"],
            "relation": row["relation_type"],
            "target": row["object"],
            "provenance": json.loads(row["provenance_json"]),
        })

    body = {
        "contract_version": CONTRACT_VERSION,
        "claim": {"claim_id": result["claim_id"], "subject": result["subject"],
                  "shape": result["shape"]},
        "verified_result": {
            "verdict": result["verdict"],
            "trace": result["trace"],
            "witnesses": result["witnesses"],
            "missing": result["missing"],
            **({"conflict": result["conflict"]} if "conflict" in result else {}),
        },
        "evidence": evidence,
        "predicted_outcome": {"statement": outcome, "supplied_by": "caller"},
        "execution_request": {
            "intent": intent,
            "params": intent_params,
            "safety_constraints": sorted(safety_constraints or []),
        },
        "floor": {"floor_id": result["floor"], "authority": result["authority"]},
        "execution_class": _EXECUTION_CLASS[result["verdict"]],
    }
    digest = hashlib.sha256(
        json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return {**body, "contract_id": f"handoff:{digest}", "created_at": utc_now_iso()}


def verify_contract(contract: dict) -> None:
    """Re-derive the content hash and compare to contract_id. A contract that
    was modified after build — anywhere, by anyone — fails here. Runs at
    dispatch AND at collect, so tampering with the stored copy between the
    two is caught before any evidence is ingested."""
    body = {k: v for k, v in contract.items() if k not in ("contract_id", "created_at")}
    digest = hashlib.sha256(
        json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    if contract.get("contract_id") != f"handoff:{digest}":
        raise ValidationError(
            f"contract integrity check FAILED for {contract.get('contract_id')!r} "
            "— body does not match its content address; refusing"
        )


def _record(store: Store, contract: dict, env_id: str, status: str, *,
            executor_ref: str | None = None, plan: dict | None = None,
            outcome: dict | None = None, completed_at: str | None = None) -> None:
    store.db.execute(
        "INSERT INTO handoffs (contract_id, environment, execution_class, status, "
        "executor_ref, contract_json, plan_json, outcome_json, submitted_at, completed_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (contract["contract_id"], env_id, contract["execution_class"], status,
         executor_ref, json.dumps(contract, sort_keys=True),
         json.dumps(plan, sort_keys=True) if plan else None,
         json.dumps(outcome, sort_keys=True) if outcome else None,
         utc_now_iso(), completed_at),
    )
    store.db.commit()


def dispatch_handoff(store: Store, contract: dict, env: Environment) -> dict:
    """Plan the contract's intent from the environment's DISCOVERED
    capabilities, then submit. Refusals (blocked / unplannable) are recorded
    and raised — never silently dropped, never guessed around."""
    verify_contract(contract)
    if contract["execution_class"] == "blocked":
        _record(store, contract, env.env_id, "refused")
        raise ValidationError(
            f"contract {contract['contract_id']} is BLOCKED "
            f"(verdict {contract['verified_result']['verdict']}) — refusing to hand off"
        )

    request = contract["execution_request"]
    plan = plan_intent(request["intent"], request["params"], env.capabilities())
    if plan["status"] == "UNPLANNABLE":
        _record(store, contract, env.env_id, "unplannable", plan=plan)
        raise ValidationError(
            f"environment {env.env_id!r} cannot execute intent "
            f"{request['intent']!r}: missing capabilities {plan['missing_capabilities']}"
        )

    receipt = env.submit(contract, plan)
    if not isinstance(receipt, dict) or receipt.get("status") != "submitted" \
            or not receipt.get("executor_ref"):
        raise ValidationError(
            f"environment {env.env_id!r} returned an invalid receipt: {receipt!r}"
        )
    _record(store, contract, env.env_id, "submitted",
            executor_ref=receipt["executor_ref"], plan=plan)
    return {"contract_id": contract["contract_id"], "environment": env.env_id,
            "execution_class": contract["execution_class"],
            "executor_ref": receipt["executor_ref"],
            "plan_steps": len(plan["steps"]), "status": "submitted"}


def _latest_handoff(store: Store, contract_id: str) -> dict:
    row = store.db.execute(
        "SELECT rowid, * FROM handoffs WHERE contract_id = ? "
        "ORDER BY submitted_at DESC, rowid DESC LIMIT 1",
        (contract_id,),
    ).fetchone()
    if row is None:
        raise ValidationError(f"no hand-off recorded for {contract_id!r}")
    return dict(row)


def check_handoff(store: Store, contract_id: str, env: Environment) -> dict:
    """Poll the executor. Hands-off is not fire-and-forget — the terminus
    stays in control of the lifecycle."""
    record = _latest_handoff(store, contract_id)
    if not record["executor_ref"]:
        return {"contract_id": contract_id, "status": record["status"],
                "note": "never submitted (refused/unplannable)"}
    status = env.check(record["executor_ref"])
    return {"contract_id": contract_id, "executor_ref": record["executor_ref"],
            "environment": env.env_id, **status}


def collect_result(store: Store, contract_id: str, env: Environment) -> dict:
    """Pull the observed outcome back and CLOSE THE LOOP.

    Recording is unconditional (auditable). Graph ingestion is gated twice:
    evidence_grade must be "physical" AND observed must be confirmed/refuted.
    Ingestion materializes structure->claim edges (supports_claim /
    conflicts_with) with provenance source "executor" pinned to the
    environment + executor_ref — after which recall and the reasoner can use
    the executor's data like any other typed fact.
    """
    record = _latest_handoff(store, contract_id)
    if not record["executor_ref"]:
        raise ValidationError(
            f"{contract_id} was never submitted (status {record['status']})"
        )
    contract = json.loads(record["contract_json"])
    verify_contract(contract)  # tamper between dispatch and collect -> refuse

    outcome = env.collect(record["executor_ref"])
    if not isinstance(outcome, dict):
        raise ValidationError(
            f"environment {env.env_id!r} returned a non-dict outcome: "
            f"{type(outcome).__name__}"
        )
    observed = outcome.get("observed")
    if observed not in OUTCOME_VALUES:
        raise ValidationError(
            f"environment {env.env_id!r} returned invalid observed={observed!r}; "
            f"allowed: {OUTCOME_VALUES}"
        )

    now = utc_now_iso()
    store.db.execute(
        "UPDATE handoffs SET status = ?, outcome_json = ?, completed_at = ? "
        "WHERE rowid = ?",
        ("completed", json.dumps(outcome, sort_keys=True), now, record["rowid"]),
    )
    store.db.commit()

    edges_written: list[str] = []
    ingested = False
    if env.evidence_grade == "physical" and observed in ("confirmed", "refuted"):
        relation = "supports_claim" if observed == "confirmed" else "conflicts_with"
        claim_id = contract["claim"]["claim_id"]
        for witness in contract["verified_result"]["witnesses"]:
            if not witness.startswith("structure:"):
                continue
            edge_id, created = store.add_edge(
                witness, relation, claim_id,
                provenance={"source": "executor", "url": None,
                            "retrieved_at": now,
                            "raw_id": f"{env.env_id}:{record['executor_ref']}"},
                label=f"executor {env.env_id} observed {observed}",
            )
            if created:
                edges_written.append(edge_id)
        ingested = True

    return {
        "contract_id": contract_id,
        "environment": env.env_id,
        "evidence_grade": env.evidence_grade,
        "observed": observed,
        "notes": outcome.get("notes", ""),
        "readings": outcome.get("readings", []),
        "ingested_as_evidence": ingested,
        "evidence_edges_written": edges_written,
        "completed_at": now,
    }


def list_handoffs(store: Store) -> list[dict]:
    """Audit trail: every dispatch attempt (incl. refusals), stable order."""
    rows = store.db.execute(
        "SELECT contract_id, environment, execution_class, status, executor_ref, "
        "submitted_at, completed_at FROM handoffs ORDER BY submitted_at, contract_id"
    ).fetchall()
    return [dict(r) for r in rows]
