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
from .extract import extract_protein
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
