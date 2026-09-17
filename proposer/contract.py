"""The proposal grammar and the system prompt that teaches it.

A proposal is ONE JSON object, nothing else. Four kinds:

  {"kind": "claim",   "subject": "P69905",
   "shape": "structural-consistency-v1",
   "predicted_outcome": "<what the proposer expects the floor to find>"}

  {"kind": "extract", "subject": "P69905"}
      -> ask the floor to run the bio wheel on an accession it lacks

  {"kind": "intent",  "subject": "P69905", "intent": "serial_dilution",
   "params": {"factor": 10, "steps": 3, "volume_ul": 100},
   "predicted_outcome": "<expected physical observation>"}

  {"kind": "abstain", "reason": "<why no grounded proposal is possible>"}
      -> the HONEST move when the request is outside the floor's evidence

The proposer never states facts. It proposes; the floor verdicts. Anything
that does not parse into exactly one of these shapes is REJECTED_UNPARSEABLE
and counted against the model — there is no salvage parsing, because salvage
is where hallucinations sneak in.
"""

from __future__ import annotations

import json
import re

from symbolic_floor.planner import INTENTS
from symbolic_floor.schema import ValidationError, validate_node_id
from symbolic_floor.store import CLAIM_SHAPE_STRUCTURAL

PROPOSAL_KINDS = ("claim", "extract", "intent", "abstain")

SYSTEM_PROMPT = """You are the PROPOSER for a symbolic verification floor for protein-structure biology.

You NEVER state facts. You emit exactly ONE JSON object per reply — a proposal — and a deterministic symbolic floor verifies it against stored, provenance-pinned evidence. The floor's verdicts are SUPPORTED, CONFLICTING, or UNKNOWN; your proposals are only admitted through that gate.

Your reply must be ONLY the JSON object. No prose, no markdown, no code fences.

The four proposal shapes (use exactly these fields):
1. Verify a protein's structural consistency:
{"kind": "claim", "subject": "<UniProt accession>", "shape": "structural-consistency-v1", "predicted_outcome": "<one sentence: what you expect the floor to find>"}
2. Ask the floor to gather evidence for an accession it may lack:
{"kind": "extract", "subject": "<UniProt accession>"}
3. Propose a physical experiment (executed only via the floor's hand-off terminus):
{"kind": "intent", "subject": "<UniProt accession>", "intent": "serial_dilution" | "measure_sample" | "incubate", "params": {...}, "predicted_outcome": "<expected observation>"}
   serial_dilution params: {"factor": 2-1000, "steps": 1-24, "volume_ul": 1-10000}
   measure_sample params: {"target": "well:...", "wavelength_nm": 200-1000}
   incubate params: {"target": "...", "temp_c": 4-121, "duration_s": 1-86400}
4. Abstain when no grounded proposal is possible:
{"kind": "abstain", "reason": "<one sentence>"}

Rules:
- subject is ALWAYS a bare UniProt accession (e.g. P69905), never a name.
- If the user gives a protein NAME, use the accession ONLY if it is common knowledge (hemoglobin alpha = P69905, p53 = P04637, human serum albumin = P02768). If unsure of the accession: abstain — a wrong accession is worse than no proposal.
- Never invent evidence, structures, sequences, or verdicts. The floor decides.
- Questions unrelated to proteins/structure: abstain.
- Exactly one JSON object. Nothing else."""


def parse_proposal(text: str) -> dict:
    """Strict parse of a model reply into a proposal. No salvage beyond
    stripping code fences; anything malformed raises ValidationError."""
    raw = (text or "").strip()
    # Tolerate ONLY a fenced block wrapper (models add them reflexively);
    # inside it the grammar is strict.
    fence = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", raw, re.DOTALL)
    if fence:
        raw = fence.group(1).strip()
    try:
        obj = json.loads(raw)
    except ValueError as e:
        raise ValidationError(f"proposal is not valid JSON: {e}") from e
    if not isinstance(obj, dict):
        raise ValidationError(f"proposal must be a JSON object, got {type(obj).__name__}")

    kind = obj.get("kind")
    if kind not in PROPOSAL_KINDS:
        raise ValidationError(f"proposal.kind must be one of {PROPOSAL_KINDS}, got {kind!r}")

    if kind == "abstain":
        if not str(obj.get("reason", "")).strip():
            raise ValidationError("abstain proposal requires a reason")
        return {"kind": "abstain", "reason": str(obj["reason"]).strip()}

    subject = str(obj.get("subject", "")).strip().upper()
    validate_node_id(f"protein:{subject}")  # rejects malformed accessions

    if kind == "extract":
        return {"kind": "extract", "subject": subject}

    predicted = str(obj.get("predicted_outcome", "")).strip()
    if not predicted:
        raise ValidationError(f"{kind} proposal requires predicted_outcome")

    if kind == "claim":
        shape = obj.get("shape")
        if shape != CLAIM_SHAPE_STRUCTURAL:
            raise ValidationError(
                f"claim.shape must be {CLAIM_SHAPE_STRUCTURAL!r}, got {shape!r}"
            )
        return {"kind": "claim", "subject": subject, "shape": shape,
                "predicted_outcome": predicted}

    # kind == "intent"
    intent = obj.get("intent")
    if intent not in INTENTS:
        raise ValidationError(f"intent must be one of {sorted(INTENTS)}, got {intent!r}")
    params = obj.get("params")
    if not isinstance(params, dict):
        raise ValidationError("intent proposal requires a params object")
    return {"kind": "intent", "subject": subject, "intent": intent,
            "params": params, "predicted_outcome": predicted}
