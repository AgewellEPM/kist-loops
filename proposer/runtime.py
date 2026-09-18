"""Proposer runtime: local Ollama model -> strict parse -> FLOOR ADMISSION.

The gate that makes any model airtight. A model reply is only ever a
proposal; this module parses it strictly, validates it against the floor's
grammar, and routes it through the floor:

  claim   -> evaluate_claim            (verdict + trace; nothing written)
  extract -> extract_protein           (evidence gathered via allowlisted
                                        connectors, every edge provenanced)
  intent  -> plan-only preview         (planner composes against an env's
                                        capabilities; DISPATCH IS NOT DONE
                                        HERE — physical hand-off stays a
                                        deliberate, separate human action)
  abstain -> recorded as the honest no-op

The model NEVER touches the graph. Ollama runs on localhost only; this module
is outside the reasoning pipeline (the floor's bio-site allowlist is not, and
must not be, widened for it).
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request

from symbolic_floor.environments import load_environment
from symbolic_floor.extract import extract_protein
from symbolic_floor.planner import plan_intent
from symbolic_floor.reasoner import evaluate_claim
from symbolic_floor.schema import ValidationError
from symbolic_floor.store import CLAIM_SHAPE_STRUCTURAL, Store

from .contract import SYSTEM_PROMPT, parse_proposal

OLLAMA_URL = "http://localhost:11434/api/chat"
DEFAULT_MODEL = "floor-proposer"
TIMEOUT_S = 120.0


class ProposerError(RuntimeError):
    """Model unavailable / transport failure (distinct from a bad proposal)."""


def ask_model(prompt: str, *, model: str = DEFAULT_MODEL,
              url: str = OLLAMA_URL, timeout: float = TIMEOUT_S) -> str:
    """One chat turn against local Ollama. Deterministic settings (temp 0)."""
    body = json.dumps({
        "model": model,
        "messages": [{"role": "system", "content": SYSTEM_PROMPT},
                     {"role": "user", "content": prompt}],
        "stream": False,
        "options": {"temperature": 0, "num_predict": 400},
    }).encode()
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/json"},
                                 method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read())
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise ProposerError(f"local model unavailable at {url}: {e}") from e
    content = ((data.get("message") or {}).get("content") or "").strip()
    if not content:
        raise ProposerError(f"model {model!r} returned an empty reply")
    return content


def admit(store: Store, proposal: dict, *, environment: str = "simulation",
          libraries: set[str] | None = None) -> dict:
    """Route a PARSED proposal through the floor. Read-only except `extract`
    (which writes only provenance-pinned connector evidence). Never dispatches
    a physical hand-off — that remains a separate, deliberate action.
    ``libraries`` narrows which wheel libraries an extract collects from
    (None = all); the extraction trace reports what was disabled."""
    kind = proposal["kind"]
    if kind == "abstain":
        return {"admitted": "abstain", "proposal": proposal}

    if kind == "extract":
        result = extract_protein(store, proposal["subject"], enabled=libraries)
        return {"admitted": "extract", "proposal": proposal,
                "extraction": {k: result[k] for k in
                               ("status", "edges_already_present",
                                "pdb_xrefs_total", "libraries_disabled")
                               if k in result} | {"edges_written": len(result.get("edges_written", []))}}

    if kind == "claim":
        claim_id = store.get_or_create_claim(
            f"protein:{proposal['subject']}", CLAIM_SHAPE_STRUCTURAL)
        verdict = evaluate_claim(store, claim_id)
        return {"admitted": "claim", "proposal": proposal, "verdict": verdict}

    # kind == "intent": plan-only preview against the named environment.
    env = load_environment(environment)
    plan = plan_intent(proposal["intent"], proposal["params"], env.capabilities())
    return {"admitted": "intent", "proposal": proposal,
            "environment": env.env_id, "plan": plan}


def propose(store: Store, prompt: str, *, model: str = DEFAULT_MODEL,
            environment: str = "simulation",
            libraries: set[str] | None = None) -> dict:
    """Full lane: model -> strict parse -> floor admission.

    A reply that fails the grammar is REJECTED_UNPARSEABLE — reported
    honestly, admitted nowhere.
    """
    reply = ask_model(prompt, model=model)
    try:
        proposal = parse_proposal(reply)
    except ValidationError as e:
        return {"admitted": "rejected_unparseable", "error": str(e),
                "raw_reply": reply[:500]}
    try:
        return admit(store, proposal, environment=environment,
                     libraries=libraries)
    except ValidationError as e:
        # Parsed but the floor refused it (bad params, unknown claim, ...).
        return {"admitted": "rejected_by_floor", "proposal": proposal,
                "error": str(e)}
