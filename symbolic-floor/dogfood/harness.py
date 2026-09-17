"""Dogfood harness: drive extract -> store -> recall -> verdict and score it.

Scoring is deliberately inverted (the bio-mcp convention): a confirmed FINDING
is worth points, a PASS is worth nothing. The harness exists to break the
floor, not to flatter it.

Run:  .venv/bin/python -m dogfood.harness           # offline + live
      .venv/bin/python -m dogfood.harness --offline # fixtures only
Out:  dogfood/report.json + dogfood/REPORT.md

Offline scenarios use stub transports over dogfood/fixtures (deterministic);
live scenarios hit the allowlisted bio sites for real. Every run uses a fresh
DB under data/ (the project's only write location).
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from symbolic_floor.connectors.base import AllowlistError, http_get  # noqa: E402
from symbolic_floor.extract import extract_protein  # noqa: E402
from symbolic_floor.reasoner import evaluate_claim  # noqa: E402
from symbolic_floor.recall import recall_protein  # noqa: E402
from symbolic_floor.schema import ValidationError  # noqa: E402
from symbolic_floor.store import Store  # noqa: E402

FIXTURES = Path(__file__).parent / "fixtures"
POINTS = {"critical": 5, "high": 3, "medium": 2, "low": 1}


# ---------------------------------------------------------------- transports

def _fixture_transport():
    """Stub transport for the rich P69905 fixture world."""
    entry = (FIXTURES / "rich_entry.json").read_bytes()
    fasta = (FIXTURES / "rich.fasta").read_bytes()
    rcsb = (FIXTURES / "rcsb_ok.json").read_bytes()
    af = (FIXTURES / "af_ok.json").read_bytes()

    def send(url: str, timeout: float):
        if url.endswith("P69905.json"):
            return 200, entry
        if url.endswith("P69905.fasta"):
            return 200, fasta
        if "data.rcsb.org" in url:
            return 200, rcsb
        if "alphafold" in url:
            return 200, af
        raise AssertionError(f"fixture transport has no route for {url}")

    return send


def _fresh_store(tag: str) -> Store:
    db = ROOT / "data" / f"dogfood_{tag}.db"
    if db.exists():
        db.unlink()
    return Store(db)


# ---------------------------------------------------------------- scenarios
# Each returns a list of finding strings (empty = pass).

def sc_extraction_writes_typed_facts(findings):
    s = _fresh_store("offline")
    try:
        result = extract_protein(s, "P69905", transport=_fixture_transport())
        by_rel: dict[str, int] = {}
        for e in result["edges_written"]:
            by_rel[e["relation"]] = by_rel.get(e["relation"], 0) + 1
        expect = {"encodes": 2, "belongs_to": 1, "located_in": 2, "affects": 2,
                  "has_part": 1, "has_sequence": 1, "has_structure": 5,
                  "predicts_structure": 1}
        for rel, n in expect.items():
            got = by_rel.get(rel, 0)
            if got != n:
                findings.append(f"extraction wrote {got} {rel} edges, expected {n}")
        if result["pdb_xrefs_total"] != 7:
            findings.append(f"xref count dishonest: {result['pdb_xrefs_total']} != 7")
        if result["pdb_confirmed"] != 5 or result["pdb_confirm_cap"] != 5:
            findings.append("PDB confirmation cap not honest in the trace")
    finally:
        s.close()


def sc_every_edge_has_provenance(findings):
    s = _fresh_store("prov")
    try:
        extract_protein(s, "P69905", transport=_fixture_transport())
        for e in s.get_edges():
            if not e["provenance_json"]:
                findings.append(f"edge {e['id']} ({e['relation_type']}) has NO provenance")
            else:
                prov = json.loads(e["provenance_json"])
                for k in ("source", "url", "retrieved_at", "raw_id"):
                    if k not in prov:
                        findings.append(f"edge {e['id']} provenance missing {k}")
    finally:
        s.close()


def sc_reextraction_idempotent(findings):
    s = _fresh_store("idem")
    try:
        first = extract_protein(s, "P69905", transport=_fixture_transport())
        second = extract_protein(s, "P69905", transport=_fixture_transport())
        if second["edges_written"]:
            findings.append(
                f"re-extraction wrote {len(second['edges_written'])} NEW edges (should be 0)"
            )
        if second["edges_already_present"] != len(first["edges_written"]):
            findings.append(
                "idempotency accounting wrong: "
                f"{second['edges_already_present']} existing != {len(first['edges_written'])} originally written"
            )
    finally:
        s.close()


def sc_recall_completeness(findings):
    """'recall it all' — every edge written for the subject must come back."""
    s = _fresh_store("recall")
    try:
        result = extract_protein(s, "P69905", transport=_fixture_transport())
        recall = recall_protein(s, "P69905")
        written_out = {e["edge_id"] for e in result["edges_written"]
                       if e["source"] == "protein:P69905"}
        written_in = {e["edge_id"] for e in result["edges_written"]
                      if e["target"] == "protein:P69905"}
        recalled_out = {f["edge_id"] for facts in recall["facts"].values() for f in facts}
        recalled_in = {f["edge_id"] for facts in recall["incoming"].values() for f in facts}
        if missing := written_out - recalled_out:
            findings.append(f"recall DROPPED outgoing edges: {sorted(missing)[:3]}...")
        if missing_in := written_in - recalled_in:
            findings.append(f"recall DROPPED incoming edges: {sorted(missing_in)[:3]}...")
        for facts in recall["facts"].values():
            for f in facts:
                if not f["provenance"]:
                    findings.append(f"recalled fact {f['edge_id']} lost its provenance")
        if not recall["paths"]:
            findings.append("recall returned no link-trace paths at all")
    finally:
        s.close()


def sc_recall_deterministic(findings):
    s = _fresh_store("det")
    try:
        extract_protein(s, "P69905", transport=_fixture_transport())
        baseline = json.dumps(recall_protein(s, "P69905"), sort_keys=True)
        for _ in range(19):
            if json.dumps(recall_protein(s, "P69905"), sort_keys=True) != baseline:
                findings.append("recall is NOT byte-deterministic on a fixed DB")
                return
    finally:
        s.close()


def sc_extract_then_verdict_supported(findings):
    s = _fresh_store("verdict")
    try:
        extract_protein(s, "P69905", transport=_fixture_transport())
        claim = s.get_or_create_claim("protein:P69905")
        result = evaluate_claim(s, claim)
        if result["verdict"] != "SUPPORTED":
            findings.append(f"extraction world should be SUPPORTED, got {result['verdict']}")
        if len(result["trace"]) < 7:  # 1 seq + 1 pred + 5 experimental
            findings.append(f"verdict trace suspiciously short: {len(result['trace'])} edges")
    finally:
        s.close()


def sc_functional_veto_fires(findings):
    s = _fresh_store("veto")
    try:
        extract_protein(s, "P69905", transport=_fixture_transport())
        from symbolic_floor.schema import utc_now_iso
        s.add_edge("protein:P69905", "predicts_structure", "structure:AF-Q99999-F1",
                   provenance={"source": "manual", "url": None,
                               "retrieved_at": utc_now_iso(),
                               "raw_id": "dogfood: rogue second prediction"})
        result = evaluate_claim(s, s.get_or_create_claim("protein:P69905"))
        if result["verdict"] != "CONFLICTING":
            findings.append(
                f"two different predictions must CONFLICT (functional veto), got {result['verdict']}"
            )
        elif result["conflict"]["type"] != "functional_violation":
            findings.append(f"expected functional_violation, got {result['conflict']['type']}")
    finally:
        s.close()


def sc_engine_contradiction_scan_runs(findings):
    """The EMBEDDED Peel engine's own batch scan must run clean on our floor."""
    s = _fresh_store("scan")
    try:
        extract_protein(s, "P69905", transport=_fixture_transport())
        try:
            contradictions = s.engine.detect_contradictions()
        except Exception as e:
            findings.append(f"engine detect_contradictions CRASHED on the bio floor: {e!r}")
            return
        if contradictions:
            findings.append(
                f"clean fixture world reported {len(contradictions)} engine contradictions"
            )
    finally:
        s.close()


def sc_malformed_payload_honest(findings):
    s = _fresh_store("malformed")
    try:
        garbage = json.dumps({
            "primaryAccession": "P69905",
            "genes": [None, {"geneName": None}, {"geneName": {"value": ""}}],
            "organism": None,
            "comments": [None, {"commentType": "SUBCELLULAR LOCATION",
                                "subcellularLocations": [None, {"location": {}}]},
                         {"commentType": "DISEASE", "disease": {}}],
            "features": [None, {"type": "Domain", "description": "@@@@"}],
            "uniProtKBCrossReferences": [None, {"database": "PDB"}],
        }).encode()

        def send(url, timeout):
            if url.endswith(".json"):
                return 200, garbage
            return 404, b""

        result = extract_protein(s, "P69905", transport=send)
        if result["status"] != "OK":
            findings.append(f"malformed-but-200 entry should still extract nothing cleanly, got {result['status']}")
        if result["edges_written"]:
            findings.append(f"garbage payload produced edges: {result['edges_written']}")
    except Exception as e:
        findings.append(f"malformed payload CRASHED extraction: {type(e).__name__}: {e}")
    finally:
        s.close()


def sc_allowlist_still_enforced(findings):
    try:
        http_get("https://api.evil.example/x", transport=lambda u, t: (200, b""))
        findings.append("allowlist FAILED to refuse a foreign host")
    except AllowlistError:
        pass
    except Exception as e:
        findings.append(f"allowlist raised the wrong error type: {type(e).__name__}")


def sc_notfound_writes_nothing(findings):
    s = _fresh_store("nf")
    try:
        def send(url, timeout):
            return (200, b"") if url.endswith((".json", ".fasta")) else (404, b"")
        result = extract_protein(s, "A0AAA0AAA0", transport=send)
        if result["status"] != "NOT_FOUND":
            findings.append(f"fictional accession: expected NOT_FOUND, got {result['status']}")
        if s.get_edges():
            findings.append("fictional accession WROTE edges")
        verdict = evaluate_claim(s, s.get_or_create_claim("protein:A0AAA0AAA0"))
        if verdict["verdict"] != "UNKNOWN":
            findings.append(f"empty world must be UNKNOWN, got {verdict['verdict']}")
    finally:
        s.close()


# ---------------------------------------------------------------- live

def sc_live_extract_recall_roundtrip(findings):
    s = _fresh_store("live")
    try:
        result = extract_protein(s, "P69905")
        if result["status"] != "OK":
            findings.append(f"live P69905 extraction failed: {result['status']}")
            return
        if len(result["edges_written"]) < 8:
            findings.append(f"live P69905 wrote only {len(result['edges_written'])} edges — extraction too thin")
        if result["pdb_xrefs_total"] <= result["pdb_confirm_cap"]:
            findings.append(
                f"P69905 should list many PDB xrefs (got {result['pdb_xrefs_total']}) — cap honesty untestable")
        recall = recall_protein(s, "P69905")
        written = {e["edge_id"] for e in result["edges_written"] if e["source"] == "protein:P69905"}
        recalled = {f["edge_id"] for facts in recall["facts"].values() for f in facts}
        if missing := written - recalled:
            findings.append(f"LIVE recall dropped edges: {sorted(missing)[:3]}")
        verdict = evaluate_claim(s, s.get_or_create_claim("protein:P69905"))
        if verdict["verdict"] != "SUPPORTED":
            findings.append(f"live P69905 verdict: expected SUPPORTED, got {verdict['verdict']}")
        again = extract_protein(s, "P69905")
        if again["edges_written"]:
            findings.append(f"live re-extraction not idempotent: {len(again['edges_written'])} new edges")
    finally:
        s.close()


def sc_live_rich_protein_p04637(findings):
    """p53: heavy xrefs + diseases + domains — the cap-honesty live case."""
    s = _fresh_store("live_p53")
    try:
        result = extract_protein(s, "P04637")
        if result["status"] != "OK":
            findings.append(f"live P04637 extraction failed: {result['status']}")
            return
        if result["pdb_xrefs_total"] < 50:
            findings.append(f"p53 xref total {result['pdb_xrefs_total']} implausibly low")
        if result["pdb_confirmed"] > result["pdb_confirm_cap"]:
            findings.append("confirmation cap exceeded — cap is a lie")
        rels = {e["relation"] for e in result["edges_written"]}
        for wanted in ("encodes", "belongs_to", "affects", "located_in"):
            if wanted not in rels:
                findings.append(f"p53 extraction produced no {wanted} edges")
        # No-fabrication pin: has_part edges must equal the entry's Domain-typed
        # features EXACTLY. p53 has none (UniProt annotates it via DNA binding /
        # Region / Motif) — so the correct count here is genuinely zero; any
        # has_part edge for p53 would be an invented domain.
        from symbolic_floor.connectors.uniprot import fetch_entry_json
        entry = fetch_entry_json("P04637")["entry"]
        domain_features = {f.get("description") for f in entry.get("features") or []
                           if isinstance(f, dict) and f.get("type") == "Domain"
                           and f.get("description")}
        has_part_written = sum(1 for e in result["edges_written"]
                               if e["relation"] == "has_part")
        if has_part_written != len(domain_features):
            findings.append(
                f"has_part fabrication/loss: wrote {has_part_written}, "
                f"entry lists {len(domain_features)} Domain features"
            )
        recall = recall_protein(s, "P04637")
        if recall["counts"]["outgoing_edges"] < 10:
            findings.append(f"p53 recall too thin: {recall['counts']}")
    finally:
        s.close()


def sc_terminus_full_loop(findings):
    """extract -> verdict -> contract -> plan -> dispatch -> check -> collect."""
    from symbolic_floor.environments import load_environment, register_environment
    from symbolic_floor.handoff import (build_contract, check_handoff,
                                        collect_result, dispatch_handoff)
    s = _fresh_store("terminus")
    try:
        extract_protein(s, "P69905", transport=_fixture_transport())
        claim = s.get_or_create_claim("protein:P69905")
        register_environment(s, "human_tech")
        contract = build_contract(s, claim, predicted_outcome="A280 changes",
                                  intent="serial_dilution",
                                  intent_params={"factor": 10, "steps": 3, "volume_ul": 100})
        if contract["execution_class"] != "verified":
            findings.append(f"SUPPORTED claim not verified-class: {contract['execution_class']}")
        if not contract["evidence"] or any(not e["provenance"] for e in contract["evidence"]):
            findings.append("contract evidence missing provenance (sources must flow through)")

        outbox = ROOT / "data" / "outbox_dogfood"
        env = load_environment("human_tech", outbox=outbox)
        receipt = dispatch_handoff(s, contract, env)
        if receipt["status"] != "submitted" or receipt["plan_steps"] != 9:
            findings.append(f"dispatch wrong: {receipt}")
        # Human sends data back.
        (outbox / f"{receipt['executor_ref']}.result.json").write_text(
            '{"observed": "confirmed", "notes": "dogfood bench"}')
        if check_handoff(s, contract["contract_id"], env)["status"] != "completed":
            findings.append("check did not see the completed result file")
        collected = collect_result(s, contract["contract_id"], env)
        if not collected["ingested_as_evidence"] or not collected["evidence_edges_written"]:
            findings.append("confirmed physical result did NOT ingest as evidence")
        if not s.get_edges(relation="supports_claim"):
            findings.append("no supports_claim edge after confirmed physical result")
    finally:
        s.close()
        import shutil
        shutil.rmtree(ROOT / "data" / "outbox_dogfood", ignore_errors=True)


def sc_simulation_never_becomes_evidence(findings):
    from symbolic_floor.environments import load_environment
    from symbolic_floor.handoff import (build_contract, collect_result,
                                        dispatch_handoff)
    s = _fresh_store("simhonest")
    try:
        extract_protein(s, "P69905", transport=_fixture_transport())
        claim = s.get_or_create_claim("protein:P69905")
        contract = build_contract(s, claim, predicted_outcome="x",
                                  intent="measure_sample",
                                  intent_params={"target": "well:D1", "wavelength_nm": 280})
        env = load_environment("simulation")
        dispatch_handoff(s, contract, env)
        collected = collect_result(s, contract["contract_id"], env)
        if collected["evidence_grade"] != "simulated":
            findings.append("simulation not graded simulated")
        if collected["ingested_as_evidence"] or s.get_edges(relation="supports_claim"):
            findings.append("SIMULATION LAUNDERED into graph evidence — honesty breach")
        if collected["observed"] != "inconclusive":
            findings.append(f"simulation claimed a world outcome: {collected['observed']}")
    finally:
        s.close()


def sc_blocked_contract_refused(findings):
    from symbolic_floor.environments import load_environment
    from symbolic_floor.handoff import build_contract, dispatch_handoff, list_handoffs
    from symbolic_floor.schema import ValidationError, utc_now_iso
    s = _fresh_store("blocked")
    try:
        def mp(cit):
            return {"source": "manual", "url": None, "retrieved_at": utc_now_iso(), "raw_id": cit}
        s.add_edge("protein:P69905", "has_sequence", "sequence:" + "c" * 64, provenance=mp("s"))
        s.add_edge("protein:P69905", "predicts_structure", "structure:AF-Q99999-F1", provenance=mp("r"))
        s.add_edge("protein:P69905", "has_structure", "structure:1A00", provenance=mp("e"))
        claim = s.get_or_create_claim("protein:P69905")
        contract = build_contract(s, claim, predicted_outcome="x",
                                  intent="measure_sample",
                                  intent_params={"target": "well:D1", "wavelength_nm": 280})
        if contract["execution_class"] != "blocked":
            findings.append(f"CONFLICTING claim not blocked: {contract['execution_class']}")
        try:
            dispatch_handoff(s, contract, load_environment("simulation"))
            findings.append("blocked contract was DISPATCHED — floor shipped a contradiction")
        except ValidationError:
            pass
        if list_handoffs(s)[-1]["status"] != "refused":
            findings.append("blocked refusal not recorded in the audit trail")
    finally:
        s.close()


def sc_unplannable_intent_honest(findings):
    from symbolic_floor.handoff import build_contract, dispatch_handoff, list_handoffs
    from symbolic_floor.schema import ValidationError
    s = _fresh_store("unplan")
    try:
        extract_protein(s, "P69905", transport=_fixture_transport())
        claim = s.get_or_create_claim("protein:P69905")
        contract = build_contract(s, claim, predicted_outcome="x",
                                  intent="serial_dilution",
                                  intent_params={"factor": 10, "steps": 3, "volume_ul": 100})

        class HeatOnly:
            env_id = "heatonly"; evidence_grade = "physical"
            def capabilities(self): return {"heat"}
            def submit(self, c, p): raise AssertionError("must not submit an unplannable intent")
            def check(self, r): return {}
            def collect(self, r): return {}

        try:
            dispatch_handoff(s, contract, HeatOnly())
            findings.append("unplannable intent was dispatched anyway")
        except ValidationError as e:
            if "missing capabilities" not in str(e):
                findings.append(f"unplannable raised wrong error: {e}")
        if list_handoffs(s)[-1]["status"] != "unplannable":
            findings.append("unplannable not recorded")
    finally:
        s.close()


# ---------------------------------------------------------------- reverse round 2
# Hostile wave against the terminus loop: tampering, lying environments,
# malformed human results, hostile payloads, traversal.

def _supported_world(tag):
    from symbolic_floor.handoff import build_contract
    s = _fresh_store(tag)
    extract_protein(s, "P69905", transport=_fixture_transport())
    claim = s.get_or_create_claim("protein:P69905")
    contract = build_contract(s, claim, predicted_outcome="x",
                              intent="measure_sample",
                              intent_params={"target": "well:D1", "wavelength_nm": 280})
    return s, contract


def sc_tiles_37(findings):
    """Every extraction tile must carry all 37 canonical fields, non-empty,
    chained root->facts — the wiki-wheel trace contract, on the bio wheel."""
    from symbolic_floor.peel_tiles import CANONICAL_37, tile_trace
    s = _fresh_store("tiles37")
    try:
        result = extract_protein(s, "P69905", transport=_fixture_transport())
        tiles = tile_trace(s, "P69905")
        if not tiles:
            findings.append("extraction wrote NO peel tiles")
            return
        for column in CANONICAL_37:
            for t in tiles:
                v = t[column]
                if v is None or (not isinstance(v, (int, float)) and not str(v).strip()):
                    findings.append(f"tile field {column!r} EMPTY on {t['branch_path']}")
                    break
        n_children = sum(1 for t in tiles if t["depth_level"] == 1)
        if result["peel_trace"]["tiles_total"] != 1 + n_children:
            findings.append("tile count does not match root+facts")
        again = extract_protein(s, "P69905", transport=_fixture_transport())
        if again["peel_trace"]["tiles_written"] != 0:
            findings.append(f"re-extraction wrote {again['peel_trace']['tiles_written']} new tiles")
    finally:
        s.close()


def sc_rev_malformed_result_files(findings):
    """The human's result file is hostile: not-JSON, a list, a bad verdict.
    Each must be a CLEAN refusal (ValidationError), never a crash, zero edges."""
    from symbolic_floor.environments import load_environment
    from symbolic_floor.handoff import collect_result, dispatch_handoff
    from symbolic_floor.schema import ValidationError
    import shutil
    for label, payload in (("not-json", b"{{{garbage"),
                           ("json-list", b"[1,2,3]"),
                           ("bad-observed", b'{"observed": "maybe"}')):
        s, contract = _supported_world(f"rev_mrf_{label}")
        outbox = ROOT / "data" / f"outbox_rev_{label}"
        try:
            env = load_environment("human_tech", outbox=outbox)
            receipt = dispatch_handoff(s, contract, env)
            (outbox / f"{receipt['executor_ref']}.result.json").write_bytes(payload)
            try:
                collect_result(s, contract["contract_id"], env)
                findings.append(f"[{label}] hostile result file ACCEPTED")
            except ValidationError:
                pass  # clean refusal — correct
            except Exception as e:
                findings.append(f"[{label}] CRASHED: {type(e).__name__}: {e}")
            if s.get_edges(relation="supports_claim"):
                findings.append(f"[{label}] hostile result STILL wrote evidence edges")
        finally:
            s.close()
            shutil.rmtree(outbox, ignore_errors=True)


def sc_rev_lying_environment_shapes(findings):
    """An environment returning garbage from collect(): non-dict shapes must be
    clean refusals, and a 'confirmed' from a SIMULATED grade must not ingest."""
    from symbolic_floor.handoff import collect_result, dispatch_handoff
    from symbolic_floor.schema import ValidationError

    for label, ret in (("none", None), ("string", "confirmed"), ("int", 7)):
        s, contract = _supported_world(f"rev_lie_{label}")
        try:
            class Liar:
                env_id = f"liar_{label}"; evidence_grade = "physical"
                def capabilities(self): return {"measure_absorbance"}
                def submit(self, c, p): return {"status": "submitted", "executor_ref": "L1"}
                def check(self, r): return {"status": "completed"}
                def collect(self, r, _ret=ret): return _ret
            env = Liar()
            dispatch_handoff(s, contract, env)
            try:
                collect_result(s, contract["contract_id"], env)
                findings.append(f"[{label}] non-dict outcome ACCEPTED")
            except ValidationError:
                pass
            except Exception as e:
                findings.append(f"[{label}] CRASHED: {type(e).__name__}: {e}")
        finally:
            s.close()

    # Simulated grade claiming 'confirmed' must be recorded but NEVER ingested.
    s, contract = _supported_world("rev_lie_simconf")
    try:
        class SimLiar:
            env_id = "simliar"; evidence_grade = "simulated"
            def capabilities(self): return {"measure_absorbance"}
            def submit(self, c, p): return {"status": "submitted", "executor_ref": "SL1"}
            def check(self, r): return {"status": "completed"}
            def collect(self, r): return {"observed": "confirmed", "notes": "trust me"}
        from symbolic_floor.handoff import collect_result as _collect
        dispatch_handoff(s, contract, SimLiar())
        out = _collect(s, contract["contract_id"], SimLiar())
        if out["ingested_as_evidence"] or s.get_edges(relation="supports_claim"):
            findings.append("SIMULATED 'confirmed' was ingested as evidence — laundering")
    finally:
        s.close()


def sc_rev_contract_tamper_detected(findings):
    """Tamper the stored contract between dispatch and collect: the
    content-addressed id must be re-verified before ingestion."""
    import json as _json
    from symbolic_floor.environments import load_environment
    from symbolic_floor.handoff import collect_result, dispatch_handoff
    from symbolic_floor.schema import ValidationError
    import shutil
    s, contract = _supported_world("rev_tamper")
    outbox = ROOT / "data" / "outbox_rev_tamper"
    try:
        env = load_environment("human_tech", outbox=outbox)
        receipt = dispatch_handoff(s, contract, env)
        # Attacker swaps the claim inside the recorded contract.
        row = s.db.execute("SELECT rowid, contract_json FROM handoffs WHERE contract_id=?",
                           (contract["contract_id"],)).fetchone()
        doc = _json.loads(row["contract_json"])
        doc["claim"]["claim_id"] = "claim:00000000-0000-4000-8000-000000000000"
        s.db.execute("UPDATE handoffs SET contract_json=? WHERE rowid=?",
                     (_json.dumps(doc, sort_keys=True), row["rowid"]))
        s.db.commit()
        (outbox / f"{receipt['executor_ref']}.result.json").write_text(
            '{"observed": "confirmed", "notes": "tampered"}')
        try:
            collect_result(s, contract["contract_id"], env)
            findings.append("TAMPERED contract accepted at collect — integrity unverified")
        except ValidationError:
            pass  # refused — correct
        if s.get_edges(relation="supports_claim"):
            findings.append("tampered contract STILL produced evidence edges")
    finally:
        s.close()
        shutil.rmtree(outbox, ignore_errors=True)


def sc_rev_hostile_gene_names(findings):
    """One un-typeable gene name must not kill the whole wheel — skip it
    honestly (reported in the trace), keep every valid fact."""
    import json as _json
    s = _fresh_store("rev_gene")
    try:
        entry = _json.loads((FIXTURES / "rich_entry.json").read_text())
        entry["genes"] = [{"geneName": {"value": "HBA1"}},
                          {"geneName": {"value": "BAD GENE; rm -rf /"}},
                          {"geneName": {"value": "x" * 500}}]
        body = _json.dumps(entry).encode()
        fasta = (FIXTURES / "rich.fasta").read_bytes()
        rcsb = (FIXTURES / "rcsb_ok.json").read_bytes()
        af = (FIXTURES / "af_ok.json").read_bytes()

        def send(url, timeout):
            if url.endswith(".json") and "uniprot" in url:
                return 200, body
            if url.endswith(".fasta"):
                return 200, fasta
            if "rcsb" in url:
                return 200, rcsb
            return 200, af

        try:
            result = extract_protein(s, "P69905", transport=send)
        except Exception as e:
            findings.append(f"hostile gene name CRASHED the wheel: {type(e).__name__}: {e}")
            return
        good = [e for e in result["edges_written"]
                if e["relation"] == "encodes" and e["source"] == "gene:HBA1"]
        if not good:
            findings.append("valid gene lost while skipping hostile ones")
        bad = [e for e in result["edges_written"]
               if e["relation"] == "encodes" and e["source"] != "gene:HBA1"]
        if bad:
            findings.append(f"hostile gene names became edges: {bad}")
        if "skipped" in result and not result["skipped"]:
            findings.append("skips not reported in the extraction trace")
    finally:
        s.close()


def sc_rev_executor_ref_traversal(findings):
    """A tampered executor_ref must not walk out of the outbox."""
    from symbolic_floor.environments import load_environment
    from symbolic_floor.schema import ValidationError
    import shutil
    outbox = ROOT / "data" / "outbox_rev_trav"
    try:
        env = load_environment("human_tech", outbox=outbox)
        for ref in ("../../../etc/passwd", "..", "a/../../b"):
            try:
                env.check(ref)
                env.collect(ref)
                findings.append(f"traversal ref {ref!r} was PROCESSED (path escape possible)")
            except (ValidationError, ValueError):
                pass  # refused — correct
            except Exception as e:
                findings.append(f"traversal ref crashed uncleanly: {type(e).__name__}")
    finally:
        shutil.rmtree(outbox, ignore_errors=True)


def sc_rev_double_collect_no_dupes(findings):
    """Collecting twice must not duplicate evidence or corrupt the audit."""
    from symbolic_floor.environments import load_environment
    from symbolic_floor.handoff import collect_result, dispatch_handoff
    import shutil
    s, contract = _supported_world("rev_double")
    outbox = ROOT / "data" / "outbox_rev_double"
    try:
        env = load_environment("human_tech", outbox=outbox)
        receipt = dispatch_handoff(s, contract, env)
        (outbox / f"{receipt['executor_ref']}.result.json").write_text(
            '{"observed": "confirmed", "notes": "run"}')
        first = collect_result(s, contract["contract_id"], env)
        second = collect_result(s, contract["contract_id"], env)
        n = len(s.get_edges(relation="supports_claim"))
        if n != len(first["evidence_edges_written"]):
            findings.append(f"double collect changed evidence count: {n}")
        if second["evidence_edges_written"]:
            findings.append("second collect wrote NEW edges (not idempotent)")
    finally:
        s.close()
        shutil.rmtree(outbox, ignore_errors=True)


def sc_rev_reeval_after_ingest_stable(findings):
    """Executor edges in the graph must not destabilize the reasoner."""
    import json as _json
    from symbolic_floor.environments import load_environment
    from symbolic_floor.handoff import collect_result, dispatch_handoff
    from symbolic_floor.reasoner import evaluate_claim
    import shutil
    s, contract = _supported_world("rev_reeval")
    outbox = ROOT / "data" / "outbox_rev_reeval"
    try:
        env = load_environment("human_tech", outbox=outbox)
        receipt = dispatch_handoff(s, contract, env)
        (outbox / f"{receipt['executor_ref']}.result.json").write_text(
            '{"observed": "confirmed"}')
        collect_result(s, contract["contract_id"], env)
        claim = contract["claim"]["claim_id"]
        v1 = _json.dumps(evaluate_claim(s, claim), sort_keys=True)
        v2 = _json.dumps(evaluate_claim(s, claim), sort_keys=True)
        if v1 != v2:
            findings.append("verdict non-deterministic after executor ingestion")
        if _json.loads(v1)["verdict"] != "SUPPORTED":
            findings.append(f"verdict destabilized after ingestion: {_json.loads(v1)['verdict']}")
    finally:
        s.close()
        shutil.rmtree(outbox, ignore_errors=True)


def sc_rev_extreme_intent_params(findings):
    """Params that compose into out-of-range capability calls must refuse
    cleanly with the range named — no partial plan, no partial writes."""
    from symbolic_floor.planner import plan_intent
    from symbolic_floor.schema import ValidationError
    try:
        plan_intent("serial_dilution", {"factor": 1000, "steps": 3, "volume_ul": 1},
                    {"aspirate", "dispense", "mix"})
        findings.append("sub-0.1ul transfer plan was ACCEPTED (unpipettable)")
    except ValidationError as e:
        if "outside" not in str(e):
            findings.append(f"extreme params refused with unclear error: {e}")
    except Exception as e:
        findings.append(f"extreme params CRASHED planner: {type(e).__name__}")


SCENARIOS = [
    ("extraction writes typed facts", "high", sc_extraction_writes_typed_facts),
    ("every edge has provenance", "critical", sc_every_edge_has_provenance),
    ("re-extraction idempotent", "high", sc_reextraction_idempotent),
    ("recall completeness (recall it all)", "critical", sc_recall_completeness),
    ("recall deterministic", "high", sc_recall_deterministic),
    ("extract -> verdict SUPPORTED", "high", sc_extract_then_verdict_supported),
    ("functional veto fires on rogue prediction", "critical", sc_functional_veto_fires),
    ("embedded engine contradiction scan runs", "medium", sc_engine_contradiction_scan_runs),
    ("malformed payload handled honestly", "high", sc_malformed_payload_honest),
    ("allowlist still enforced", "critical", sc_allowlist_still_enforced),
    ("fictional accession writes nothing", "high", sc_notfound_writes_nothing),
    ("terminus full loop (dispatch->collect->ingest)", "critical", sc_terminus_full_loop),
    ("simulation never becomes evidence", "critical", sc_simulation_never_becomes_evidence),
    ("blocked contract refused (no ship)", "critical", sc_blocked_contract_refused),
    ("unplannable intent honest", "high", sc_unplannable_intent_honest),
    ("canonical-37 tile trace complete", "high", lambda f: sc_tiles_37(f)),
    # reverse round 2 — hostile wave
    ("REV2 malformed result files refused cleanly", "high", sc_rev_malformed_result_files),
    ("REV2 lying environment shapes refused", "high", sc_rev_lying_environment_shapes),
    ("REV2 contract tamper detected at collect", "critical", sc_rev_contract_tamper_detected),
    ("REV2 hostile gene names don't kill the wheel", "high", sc_rev_hostile_gene_names),
    ("REV2 executor_ref traversal contained", "high", sc_rev_executor_ref_traversal),
    ("REV2 double collect idempotent", "medium", sc_rev_double_collect_no_dupes),
    ("REV2 reasoner stable after ingestion", "high", sc_rev_reeval_after_ingest_stable),
    ("REV2 extreme intent params refused", "medium", sc_rev_extreme_intent_params),
]

LIVE_SCENARIOS = [
    ("LIVE extract/recall/verdict roundtrip P69905", "critical", sc_live_extract_recall_roundtrip),
    ("LIVE rich extraction P04637 (cap honesty)", "high", sc_live_rich_protein_p04637),
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--offline", action="store_true", help="skip live-network scenarios")
    args = parser.parse_args()

    scenarios = SCENARIOS + ([] if args.offline else LIVE_SCENARIOS)
    t0 = time.monotonic()
    results = []
    for name, severity, fn in scenarios:
        findings: list[str] = []
        st = time.monotonic()
        try:
            fn(findings)
        except Exception as e:  # a crashing scenario is itself a critical finding
            findings.append(f"scenario CRASHED: {type(e).__name__}: {e}")
            severity = "critical"
        elapsed = round(time.monotonic() - st, 2)
        status = "FINDING" if findings else "PASS"
        print(f"  {'×' if findings else '✓'} {name} ({elapsed}s)"
              + (f" — {findings[0][:100]}" if findings else ""))
        results.append({"name": name, "severity": severity, "status": status,
                        "findings": findings, "elapsed_s": elapsed})

    found = [r for r in results if r["status"] == "FINDING"]
    score = sum(POINTS.get(r["severity"], 1) for r in found)
    wall = time.monotonic() - t0

    (Path(__file__).parent / "report.json").write_text(json.dumps({
        "generated": date.today().isoformat(), "scenarios": len(results),
        "passes": len(results) - len(found), "findings": len(found),
        "finding_points": score, "elapsed_s": round(wall, 1),
        "mode": "offline" if args.offline else "offline+live",
        "results": results,
    }, indent=2))

    lines = ["# symbolic_floor Dogfood Report", "",
             f"Generated {date.today().isoformat()} · {len(results)} scenarios · "
             f"**{len(found)} findings ({score} pts)** · {len(results) - len(found)} passes · "
             f"{wall:.0f}s wall · mode: {'offline' if args.offline else 'offline+live'}", "",
             "Scoring rewards finding failures (critical=5, high=3, medium=2, low=1). "
             "A clean run scores 0.", "", "## Findings", ""]
    if not found:
        lines.append("None. (Suspicious — check the harness before celebrating.)")
    for r in found:
        lines.append(f"### [{r['severity'].upper()}] {r['name']}")
        lines += [f"- {f}" for f in r["findings"]] + [""]
    lines += ["## Passes", ""]
    lines += [f"- {r['name']} ({r['elapsed_s']}s)" for r in results if r["status"] == "PASS"]
    (Path(__file__).parent / "REPORT.md").write_text("\n".join(lines) + "\n")

    print(f"\n{len(found)} findings, {score} points → dogfood/REPORT.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
