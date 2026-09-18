"""Scored proposer eval — numbers not prose (the ripper discipline).

Runs the held-out eval set against a live local model and scores:
  parse_rate        replies that satisfy the strict grammar
  kind_accuracy     parsed replies whose kind matches gold
  subject_accuracy  claim/extract/intent replies naming the gold accession
  abstain_precision abstained when gold abstains (no false confidence)
  abstain_recall    gold-abstain prompts actually abstained
  floor_admission   parsed proposals the floor admits without error

A model is proposer-fit only when parse + abstention are high — a model that
answers confidently where gold abstains is worse than a model that parses
badly, because the floor can reject garbage but cannot detect a plausible
wrong accession it has never seen.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

from symbolic_floor.schema import ValidationError
from symbolic_floor.store import Store

from .contract import parse_proposal
from .resolver import resolve
from .runtime import admit, ask_model


def evaluate(store: Store, eval_path: str | Path, *, model: str,
             limit: int | None = None, resolver: bool = True) -> dict:
    """resolver=True scores the DEPLOYED lane (symbolic subject binding, as
    propose() applies it) and is the default so casual scoring runs cannot
    quietly exercise the pre-resolver path — which, for extract golds, writes
    real connector edges for whatever subject the raw model invented.
    Pass resolver=False only to measure the raw model, on a throwaway store."""
    rows = [json.loads(line) for line in Path(eval_path).read_text().splitlines()]
    if limit:
        rows = rows[:limit]

    n = len(rows)
    parsed = kind_ok = subject_ok = 0
    gold_abstain = model_abstain_on_gold = model_abstain_total = 0
    admitted = 0
    failures: list[dict] = []
    t0 = time.monotonic()

    for row in rows:
        user = row["messages"][1]["content"]
        gold = json.loads(row["messages"][2]["content"])
        reply = ask_model(user, model=model)
        try:
            got = parse_proposal(reply)
        except ValidationError as e:
            failures.append({"prompt": user[:80], "error": str(e)[:120],
                             "reply": reply[:120]})
            continue
        parsed += 1
        if resolver:
            # Score the deployed lane: symbolic subject binding included
            # (same step propose() applies after the parse).
            got, _ = resolve(user, got)

        if gold["kind"] == "abstain":
            gold_abstain += 1
            if got["kind"] == "abstain":
                model_abstain_on_gold += 1
        if got["kind"] == "abstain":
            model_abstain_total += 1

        if got["kind"] == gold["kind"]:
            kind_ok += 1
            if gold["kind"] != "abstain" and got.get("subject") == gold.get("subject"):
                subject_ok += 1

        try:
            admit(store, got)
            admitted += 1
        except ValidationError:
            pass

    non_abstain_gold = n - gold_abstain
    wrong_confidence = model_abstain_total - model_abstain_on_gold
    report = {
        "model": model,
        "resolver": resolver,
        "n": n,
        "parse_rate": round(parsed / n, 3) if n else 0.0,
        "kind_accuracy": round(kind_ok / n, 3) if n else 0.0,
        "subject_accuracy": round(subject_ok / non_abstain_gold, 3) if non_abstain_gold else None,
        "abstain_recall": round(model_abstain_on_gold / gold_abstain, 3) if gold_abstain else None,
        "false_abstains": wrong_confidence,
        "floor_admission_rate": round(admitted / parsed, 3) if parsed else 0.0,
        "elapsed_s": round(time.monotonic() - t0, 1),
        "parse_failures": failures[:5],
    }
    return report
