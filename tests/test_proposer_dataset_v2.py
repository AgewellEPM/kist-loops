"""Abstain-heavy dataset (v2) pins — the retrain that chases abstain_recall.

v1 shipped 13% abstains over 5 fictional names and abstain_recall REGRESSED
(0.5 -> 0.4, failing the TRAINING.md ship bar). v2 widens the abstain classes
(fictional, near-miss cousins of curated names, off-domain, ambiguous,
malformed accessions). These pins hold the properties that make the retrain
sound; the model numbers still come from proposer/reports.
"""

import json

import pytest

from proposer.contract import parse_proposal
from proposer.dataset import (
    FICTIONAL_NAMES,
    KNOWN_PROTEINS,
    MALFORMED_ACCESSIONS,
    NEAR_MISS_NAMES,
    generate_pairs,
    write_dataset,
)
from symbolic_floor.schema import ValidationError, validate_node_id


def _kind(row: dict) -> str:
    return json.loads(row["messages"][2]["content"])["kind"]


def test_abstain_share_is_heavy_but_not_dominant(store):
    """The whole point of v2 — and the guard against over-correcting into
    a model that abstains on everything (false_abstains gate's job at eval,
    this bound's job at build)."""
    rows = generate_pairs(store, seed=1)
    share = sum(1 for r in rows if _kind(r) == "abstain") / len(rows)
    assert 0.35 <= share <= 0.55, f"abstain share {share:.2f} out of band"


def test_near_miss_names_are_not_curated():
    """Each near-miss name teaches 'don't guess the cousin's accession'.
    If one ever lands in KNOWN_PROTEINS, the pair would teach a FALSE
    abstention — per-name assertion so the failure names the culprit."""
    for name in NEAR_MISS_NAMES:
        assert name not in KNOWN_PROTEINS, f"{name!r} is curated; abstain pair is a lie"


def test_fictional_names_are_not_curated():
    for name in FICTIONAL_NAMES:
        assert name not in KNOWN_PROTEINS, f"{name!r} is curated; abstain pair is a lie"


def test_malformed_accessions_actually_fail_validation():
    """Abstention on these is 'provably right' only if the id really is
    invalid — pin each one against the same validator the gate uses."""
    for acc in MALFORMED_ACCESSIONS:
        with pytest.raises(ValidationError):
            validate_node_id(f"protein:{acc}")


def test_every_abstain_class_is_represented(store):
    """Per-class assertions (multi-site rule): one grep-able failure per
    missing class, not a single 'some abstains exist' check."""
    rows = generate_pairs(store, seed=1)
    abstain_users = [r["messages"][1]["content"]
                     for r in rows if _kind(r) == "abstain"]
    classes = {
        "fictional": FICTIONAL_NAMES[0],
        "near-miss": NEAR_MISS_NAMES[0],
        "malformed": MALFORMED_ACCESSIONS[0],
        "off-domain": "capital of France",
        "ambiguous": "yesterday's meeting",
    }
    for label, needle in classes.items():
        assert any(needle in u for u in abstain_users), f"no {label} abstain pairs"


def test_exclude_eval_removes_prior_eval_prompts_from_every_split(store, tmp_path):
    """Cross-version hygiene: v2 trains while v1's eval stays the yardstick.
    Per-split assertion — a leak into ANY split names the split."""
    first = write_dataset(store, tmp_path / "v1", seed=3)
    assert first["eval"] > 0
    held = {json.loads(line)["messages"][1]["content"]
            for line in (tmp_path / "v1" / "eval.jsonl").read_text().splitlines()}

    write_dataset(store, tmp_path / "v2", seed=3, exclude_eval=tmp_path / "v1" / "eval.jsonl")
    for split in ("train", "valid", "eval"):
        users = {json.loads(line)["messages"][1]["content"]
                 for line in (tmp_path / "v2" / f"{split}.jsonl").read_text().splitlines()}
        assert not (users & held), f"v1 eval prompts leaked into v2 {split}"


def test_v2_pairs_still_all_pass_the_gate(store):
    """Same self-consistency law as v1: the dataset cannot teach what the
    gate rejects — including every new abstain class."""
    for row in generate_pairs(store, seed=2):
        parse_proposal(row["messages"][2]["content"])  # must not raise
