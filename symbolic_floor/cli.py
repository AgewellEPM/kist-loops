"""Command-line surface: seed / claim / evaluate / eval-protein.

All output is JSON (sort_keys) so verdicts are byte-reproducible. A fictional
accession yields UNKNOWN, not an error, and writes no edge.
"""

from __future__ import annotations

import argparse
import json
import sys

from .connectors import alphafold, pdb, uniprot
from .connectors.base import ConnectorError
from .db import DEFAULT_DB
from .environments import list_environments, load_environment, register_environment
from .extract import extract_protein
from .handoff import (
    build_contract,
    check_handoff,
    collect_result,
    dispatch_handoff,
    list_handoffs,
)
from .reasoner import evaluate_claim
from .recall import recall_protein
from .schema import ValidationError
from .store import CLAIM_SHAPE_STRUCTURAL, Store


def _print(obj) -> None:
    print(json.dumps(obj, indent=2, sort_keys=True))


def _seed(store: Store, accession: str) -> dict:
    """Run all three connectors; write whatever evidence exists. NOT_FOUND /
    NO_* statuses are honest results, not errors."""
    acc = accession.strip().upper()
    results = {
        "has_sequence": uniprot.fetch_sequence(store, acc),
        "has_structure": pdb.fetch_experimental_structure(store, acc),
        "predicts_structure": alphafold.fetch_prediction(store, acc),
    }
    return {
        "accession": acc,
        "results": results,
        "edges_written": sorted(
            r["edge_id"] for r in results.values()
            if r.get("edge_id") and r.get("created")
        ),
    }


def _seed_if_needed(store: Store, accession: str) -> dict:
    """Fetch only the relations that are absent (idempotent re-runs)."""
    acc = accession.strip().upper()
    protein = f"protein:{acc}"
    results: dict = {}
    if not store.get_edges(source=protein, relation="has_sequence"):
        results["has_sequence"] = uniprot.fetch_sequence(store, acc)
    if not store.get_edges(source=protein, relation="has_structure"):
        results["has_structure"] = pdb.fetch_experimental_structure(store, acc)
    if not store.get_edges(source=protein, relation="predicts_structure"):
        results["predicts_structure"] = alphafold.fetch_prediction(store, acc)
    return {"accession": acc, "fetched": results}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="symbolic_floor",
        description="Deterministic protein-structure evidence floor (Peel engine inside).",
    )
    parser.add_argument("--db", default=str(DEFAULT_DB),
                        help=f"floor DB path (default: {DEFAULT_DB})")
    sub = parser.add_subparsers(dest="command", required=True)

    p_seed = sub.add_parser("seed", help="fetch sequence + experimental + predicted; write edges")
    p_seed.add_argument("--uniprot", required=True, metavar="ACCESSION")

    p_claim = sub.add_parser("claim", help="test helper: create/print the structural claim id")
    p_claim.add_argument("--uniprot", required=True, metavar="ACCESSION")

    p_eval = sub.add_parser("evaluate", help="evaluate a claim id; print JSON verdict + trace")
    p_eval.add_argument("--claim", required=True, metavar="CLAIM_ID")

    p_ep = sub.add_parser("eval-protein",
                          help="end-to-end: seed if needed, evaluate structural consistency")
    p_ep.add_argument("--uniprot", required=True, metavar="ACCESSION")

    p_ext = sub.add_parser("extract",
                           help="bio wheel: extract typed facts + links for an accession")
    p_ext.add_argument("--uniprot", required=True, metavar="ACCESSION")

    p_rec = sub.add_parser("recall",
                           help="everything stored about an accession, with traces")
    p_rec.add_argument("--uniprot", required=True, metavar="ACCESSION")

    p_tr = sub.add_parser("trace",
                          help="the canonical-37 PEEL tile trace for an accession")
    p_tr.add_argument("--uniprot", required=True, metavar="ACCESSION")

    p_ho = sub.add_parser("handoff",
                          help="terminus: contract -> capability plan -> dispatch to an environment")
    p_ho.add_argument("--uniprot", metavar="ACCESSION",
                      help="use the structural-consistency claim for this accession")
    p_ho.add_argument("--claim", metavar="CLAIM_ID", help="or an explicit claim id")
    p_ho.add_argument("--predicted-outcome", required=True,
                      help="the proposer's prediction (the floor never invents one)")
    p_ho.add_argument("--intent", required=True,
                      help="high-level intent (serial_dilution | measure_sample | incubate)")
    p_ho.add_argument("--intent-params", default="{}",
                      help='JSON params for the intent, e.g. {"factor":10,"steps":3,"volume_ul":100}')
    p_ho.add_argument("--environment", default="human_tech",
                      help="registered env (simulation | human_tech) or dotted path pkg.mod:Class")
    p_ho.add_argument("--dry-run", action="store_true",
                      help="build + print the contract (and plan) without dispatching")

    p_hc = sub.add_parser("handoff-check", help="poll the executor for a contract's status")
    p_hc.add_argument("--contract", required=True, metavar="CONTRACT_ID")
    p_hc.add_argument("--environment", default="human_tech")

    p_hr = sub.add_parser("handoff-collect",
                          help="pull the observed outcome back and ingest physical evidence")
    p_hr.add_argument("--contract", required=True, metavar="CONTRACT_ID")
    p_hr.add_argument("--environment", default="human_tech")

    sub.add_parser("handoffs", help="audit trail of every dispatch (incl. refusals)")

    p_er = sub.add_parser("env-register",
                          help="discover + persist an environment's capability dictionary")
    p_er.add_argument("--spec", required=True,
                      help="short name (simulation | human_tech) or dotted path")
    sub.add_parser("envs", help="list registered environments and their capabilities")

    args = parser.parse_args(argv)
    store = Store(args.db)
    try:
        if args.command == "seed":
            _print(_seed(store, args.uniprot))
        elif args.command == "claim":
            claim_id = store.get_or_create_claim(
                f"protein:{args.uniprot.strip().upper()}", CLAIM_SHAPE_STRUCTURAL
            )
            _print({"claim_id": claim_id})
        elif args.command == "evaluate":
            _print(evaluate_claim(store, args.claim))
        elif args.command == "eval-protein":
            acc = args.uniprot.strip().upper()
            seeded = _seed_if_needed(store, acc)
            claim_id = store.get_or_create_claim(f"protein:{acc}", CLAIM_SHAPE_STRUCTURAL)
            verdict = evaluate_claim(store, claim_id)
            _print({"seeded": seeded, "evaluation": verdict})
        elif args.command == "extract":
            _print(extract_protein(store, args.uniprot))
        elif args.command == "recall":
            _print(recall_protein(store, args.uniprot))
        elif args.command == "trace":
            from .peel_tiles import tile_trace
            _print(tile_trace(store, args.uniprot))
        elif args.command == "handoff":
            if bool(args.uniprot) == bool(args.claim):
                raise ValidationError("provide exactly one of --uniprot / --claim")
            claim_id = args.claim or store.get_or_create_claim(
                f"protein:{args.uniprot.strip().upper()}", CLAIM_SHAPE_STRUCTURAL
            )
            try:
                intent_params = json.loads(args.intent_params)
            except ValueError as e:
                raise ValidationError(f"--intent-params is not valid JSON: {e}") from e
            contract = build_contract(store, claim_id,
                                      predicted_outcome=args.predicted_outcome,
                                      intent=args.intent, intent_params=intent_params)
            if args.dry_run:
                _print(contract)
            else:
                env = load_environment(args.environment)
                _print(dispatch_handoff(store, contract, env))
        elif args.command == "handoff-check":
            _print(check_handoff(store, args.contract, load_environment(args.environment)))
        elif args.command == "handoff-collect":
            _print(collect_result(store, args.contract, load_environment(args.environment)))
        elif args.command == "handoffs":
            _print(list_handoffs(store))
        elif args.command == "env-register":
            _print(register_environment(store, args.spec))
        elif args.command == "envs":
            _print(list_environments(store))
        return 0
    except ValidationError as e:
        _print({"error": "validation", "message": str(e)})
        return 2
    except ConnectorError as e:
        # A genuine upstream failure is a clean error surface, never a traceback.
        # (Absence of a record is NOT this path — that is an honest NOT_FOUND /
        # NO_* status inside the seed results, and evaluation says UNKNOWN.)
        _print({"error": "connector", "message": str(e)})
        return 3
    finally:
        store.close()


if __name__ == "__main__":
    sys.exit(main())
