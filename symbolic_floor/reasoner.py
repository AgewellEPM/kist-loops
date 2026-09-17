"""The three-verdict evaluator. Pure code, deterministic, trace-carrying.

Verdict semantics map the Peel floor's own philosophy (check_contradiction's
contradiction / consistent / unknown, hard-veto on functional relations) onto
the slice contract:

  SUPPORTED    — evidence present and consistent (Peel "consistent")
  CONFLICTING  — an ID-provable contradiction (Peel "contradiction", veto)
  UNKNOWN      — evidence absent (Peel "unknown"; abstain, never guess)

Slice-1 "structural consistency" is deliberately a same-protein presence check
(has_structure AND predicts_structure for the same protein) — NOT an RMSD
comparison. RMSD/structure alignment is explicitly out of scope.

CONFLICTING fires on either of two ID-provable mechanisms, checked in order:
  a. functional-relation violation — the vendored engine's own hard-veto:
     has_sequence / predicts_structure are functional, so two edges with
     different objects for one protein contradict (_are_compatible == False);
  b. accession mismatch — a predicts_structure target AF-<X>-F* whose embedded
     accession X differs from the claim's protein while an experimental
     structure exists (the brief's step-5 mismatch).
A provable conflict takes precedence over optimistic support (DECISIONS.md #7).

Every verdict lists the exact edge IDs walked (`trace`); a verdict without a
trace is invalid by construction here.
"""

from __future__ import annotations

import re

from .peel.floor import are_compatible
from .schema import ValidationError
from .store import Store

_AF_ID = re.compile(r"^structure:AF-([A-Z0-9]+(?:-\d+)?)-F\d+$")


def _af_accession(structure_node: str) -> str | None:
    """Embedded UniProt accession of an AlphaFold structure node, else None."""
    m = _AF_ID.match(structure_node)
    return m.group(1) if m else None


def evaluate_claim(store: Store, claim_id: str) -> dict:
    """Evaluate the slice-1 structural-consistency claim. See module docstring."""
    claim = store.get_claim(claim_id)
    if claim is None:
        raise ValidationError(f"unknown claim id {claim_id!r} (create it first)")

    protein = claim["subject"]                      # protein:<accession>
    accession = protein.partition(":")[2]
    base = {
        "claim_id": claim_id,
        "subject": protein,
        "shape": claim["shape"],
        "floor": store.floor_id,
        "authority": store.authority,
    }

    # Step 1 — sequence evidence.
    seq_edges = store.get_edges(source=protein, relation="has_sequence")
    if not seq_edges:
        return {**base, "verdict": "UNKNOWN", "trace": [],
                "missing": ["has_sequence"], "witnesses": []}

    # Peel functional hard-veto: two different sequences for one protein.
    seq_objects = sorted({e["object"] for e in seq_edges})
    if len(seq_objects) > 1 and not are_compatible(
        store.engine, seq_objects[0], seq_objects[1], "has_sequence"
    ):
        return {**base, "verdict": "CONFLICTING",
                "trace": [e["id"] for e in seq_edges],
                "missing": [],
                "witnesses": seq_objects,
                "conflict": {
                    "type": "functional_violation",
                    "relation": "has_sequence",
                    "objects": seq_objects,
                    "explanation": (
                        f"{protein} has_sequence is functional (one object per "
                        f"subject) but the floor holds {len(seq_objects)} distinct sequences"
                    ),
                }}

    trace = [e["id"] for e in seq_edges]

    # Step 2 — predicted structure.
    pred_edges = store.get_edges(source=protein, relation="predicts_structure")
    if not pred_edges:
        return {**base, "verdict": "UNKNOWN", "trace": trace,
                "missing": ["predicts_structure"], "witnesses": []}

    pred_objects = sorted({e["object"] for e in pred_edges})
    if len(pred_objects) > 1 and not are_compatible(
        store.engine, pred_objects[0], pred_objects[1], "predicts_structure"
    ):
        return {**base, "verdict": "CONFLICTING",
                "trace": trace + [e["id"] for e in pred_edges],
                "missing": [],
                "witnesses": pred_objects,
                "conflict": {
                    "type": "functional_violation",
                    "relation": "predicts_structure",
                    "objects": pred_objects,
                    "explanation": (
                        f"{protein} predicts_structure is functional but the floor "
                        f"holds {len(pred_objects)} distinct predicted structures"
                    ),
                }}

    trace += [e["id"] for e in pred_edges]

    # Step 3 — experimental structure.
    exp_edges = store.get_edges(source=protein, relation="has_structure")
    if not exp_edges:
        return {**base, "verdict": "UNKNOWN", "trace": trace,
                "missing": ["has_structure"], "witnesses": []}

    trace += [e["id"] for e in exp_edges]

    # Step 4/5 — accession-mismatch conflict, else same-protein support.
    for pred in pred_edges:
        embedded = _af_accession(pred["object"])
        # A non-AF-shaped predicted target proves nothing either way — presence
        # semantics apply (DECISIONS.md #7). Only a provable mismatch conflicts.
        if embedded is not None and embedded != accession:
            return {**base, "verdict": "CONFLICTING",
                    "trace": trace,
                    "missing": [],
                    "witnesses": sorted({pred["object"]} | {e["object"] for e in exp_edges}),
                    "conflict": {
                        "type": "accession_mismatch",
                        "predicted_edge": pred["id"],
                        "experimental_edges": [e["id"] for e in exp_edges],
                        "explanation": (
                            f"predicted structure {pred['object']} embeds accession "
                            f"{embedded}, which is not {accession}"
                        ),
                    }}

    witnesses = sorted({e["object"] for e in exp_edges} | {e["object"] for e in pred_edges})
    return {**base, "verdict": "SUPPORTED", "trace": trace,
            "missing": [], "witnesses": witnesses}
