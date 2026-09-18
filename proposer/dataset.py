"""Training pairs generated FROM the floor — witnessed gold only.

The jeeves-ripper lesson is law here: unwitnessed gold trains hallucination.
Every pair in this dataset is backed by something checkable:
  - claim/extract/intent subjects come from the floor DB or from a tiny
    CURATED name->accession table (verified mappings only),
  - abstain pairs are constructed so that abstention is provably the right
    move (fictional names, non-bio prompts, ambiguous references),
  - assistant outputs are BUILT by code from the same grammar the floor
    validates — the model learns exactly the contract the gate enforces.

Output: chat JSONL (mlx_lm chat format), deterministic order + split.
"""

from __future__ import annotations

import json
import random
from pathlib import Path

from symbolic_floor.store import CLAIM_SHAPE_STRUCTURAL, Store

from .contract import SYSTEM_PROMPT, parse_proposal

# Curated, verified name->accession mappings (human unless noted). Small on
# purpose: every row here is a fact we are willing to teach as recallable.
KNOWN_PROTEINS: dict[str, str] = {
    "hemoglobin alpha": "P69905",
    "hemoglobin subunit alpha": "P69905",
    "p53": "P04637",
    "tumor protein p53": "P04637",
    "human serum albumin": "P02768",
    "insulin": "P01308",
    "lysozyme C": "P61626",
    "myoglobin": "P02144",
    "cytochrome c": "P99999",
    "ubiquitin": "P0CG48",
}

# Accessions with no curated name — used for accession-form prompts.
EXTRA_ACCESSIONS = ["Q5VSL9", "O75592", "P38398", "Q9Y6K9", "P42858"]

FICTIONAL_NAMES = ["glorbulin-7", "xenoprotein alpha", "the memory protein",
                   "flurbozyme", "protein X-99",
                   # v2 abstain-heavy expansion — abstain_recall regressed 0.5->0.4
                   # with only 5 fictional names; widen the class.
                   "zorbinase", "quantumglobin", "krellase", "phantomase B",
                   "vexoglobin", "mystozyme", "darkozyme-12",
                   "protein omega-null", "gluonoprotein", "fablezyme"]

# Real-sounding cousins of curated entries that are NOT in KNOWN_PROTEINS.
# The dangerous failure mode: the model emits the curated cousin's accession
# (hemoglobin gamma != P69905). Abstention is provably right — any accession
# the model could produce from the curated table is wrong for these names.
NEAR_MISS_NAMES = ["hemoglobin subunit beta", "hemoglobin gamma",
                   "p63", "p73",
                   "insulin receptor", "proinsulin",
                   "bovine serum albumin", "lysozyme G",
                   "cytochrome b", "cytochrome c oxidase",
                   "ubiquitin ligase", "myoglobin II"]

OFF_DOMAIN = ["What is the capital of France?",
              "Write me a poem about the sea.",
              "How do I fix a segfault in C?",
              "What's the best pizza topping?",
              "Summarize the French Revolution.",
              "What's the weather like tomorrow?",
              "Should I buy tech stocks right now?",
              "Translate 'good morning' into Japanese.",
              "Give me a recipe for sourdough bread.",
              "Why is my JavaScript promise never resolving?",
              "Plan me a three-day workout split.",
              "Recommend a movie for tonight.",
              "What is the capital of Japan?",
              "Explain SQL injection to a beginner.",
              "What should I get my brother for his birthday?"]

AMBIGUOUS = ["verify the structure of that kinase we discussed",
             "check the protein from yesterday's meeting",
             "run the usual on the new sample protein",
             "validate the enzyme everyone is talking about",
             "verify that protein",
             "check the one from the paper",
             "measure the sample on the bench",
             "run structural validation on the target we chose",
             "verify the enzyme from last week's harvest",
             "check our usual protein"]

# Identifier-shaped strings that are NOT valid UniProt accessions (too short,
# RefSeq-style, bare numbers). A claim/extract with these as subject would be
# rejected by validate_node_id — the only admissible reply is abstention.
MALFORMED_ACCESSIONS = ["P1234", "XP_004321", "12345",
                        "NM_000518", "PROT-77", "Q12"]


def _claim(acc: str, expect: str) -> str:
    return json.dumps({"kind": "claim", "subject": acc,
                       "shape": CLAIM_SHAPE_STRUCTURAL,
                       "predicted_outcome": expect}, sort_keys=True)


def _extract(acc: str) -> str:
    return json.dumps({"kind": "extract", "subject": acc}, sort_keys=True)


def _intent(acc: str, intent: str, params: dict, expect: str) -> str:
    return json.dumps({"kind": "intent", "subject": acc, "intent": intent,
                       "params": params, "predicted_outcome": expect},
                      sort_keys=True)


def _abstain(reason: str) -> str:
    return json.dumps({"kind": "abstain", "reason": reason}, sort_keys=True)


_CLAIM_TEMPLATES = [
    "Does {name} have an experimentally validated structure consistent with its predicted one?",
    "Verify the structural consistency of {name}.",
    "Is the AlphaFold prediction for {name} backed by an experimental structure?",
    "Check whether {name}'s predicted and experimental structures agree.",
    "Has {name} been structurally validated?",
]

_EXTRACT_TEMPLATES = [
    "We have no evidence on {acc} yet — gather what's known.",
    "Pull the available evidence for {acc} into the floor.",
    "Seed the knowledge base for accession {acc}.",
    "Collect sequence and structure evidence for {acc}.",
]

_DILUTION_TEMPLATES = [
    "Prepare a 1:{factor} serial dilution of {name} across {steps} wells, {volume} µl each.",
    "Set up a {steps}-step 1:{factor} dilution series for {name} starting from {volume} µl.",
]

_MEASURE_TEMPLATES = [
    "Measure the absorbance of {target} at {nm} nm.",
    "Read A{nm} for {target}.",
]

_INCUBATE_TEMPLATES = [
    "Incubate {target} at {temp} C for {mins} minutes.",
    "Hold {target} at {temp} degrees for {mins} min.",
]


def generate_pairs(store: Store, *, seed: int = 20260917) -> list[dict]:
    """Deterministic pair list. Floor-known accessions get claim pairs;
    unknown-to-floor accessions get extract pairs; intents and abstentions
    are synthesized from validated templates."""
    rng = random.Random(seed)
    pairs: list[tuple[str, str]] = []

    in_floor = {r["subject"].partition(":")[2]
                for r in store.db.execute(
                    "SELECT DISTINCT subject FROM typed_relations "
                    "WHERE subject LIKE 'protein:%'").fetchall()}

    # 1) claim pairs — names AND bare accessions.
    for name, acc in sorted(KNOWN_PROTEINS.items()):
        for tpl in _CLAIM_TEMPLATES:
            expect = "an experimental structure and a prediction exist for the same accession"
            pairs.append((tpl.format(name=name), _claim(acc, expect)))
            pairs.append((tpl.format(name=acc), _claim(acc, expect)))

    # 2) extract pairs — accessions the floor does NOT hold yet (checked live
    #    against this store so the pair is witnessed-correct at build time).
    for acc in EXTRA_ACCESSIONS:
        if acc in in_floor:
            continue
        for tpl in _EXTRACT_TEMPLATES:
            pairs.append((tpl.format(acc=acc), _extract(acc)))

    # 3) intent pairs — params drawn from the planner's own valid ranges.
    for name, acc in sorted(KNOWN_PROTEINS.items())[:6]:
        factor = rng.choice([5, 10, 20])
        steps = rng.choice([3, 4, 6])
        volume = rng.choice([50, 100, 200])
        for tpl in _DILUTION_TEMPLATES:
            pairs.append((
                tpl.format(name=name, factor=factor, steps=steps, volume=volume),
                _intent(acc, "serial_dilution",
                        {"factor": factor, "steps": steps, "volume_ul": volume},
                        f"each well is {factor}x more dilute than the last"),
            ))
        nm = rng.choice([260, 280, 595])
        well = f"well:D{rng.randint(1, 6)}"
        for tpl in _MEASURE_TEMPLATES:
            pairs.append((
                tpl.format(target=well, nm=nm) + f" (sample of {name})",
                _intent(acc, "measure_sample", {"target": well, "wavelength_nm": nm},
                        "a finite absorbance reading proportional to concentration"),
            ))
        temp = rng.choice([25, 37, 42])
        mins = rng.choice([10, 30, 60])
        for tpl in _INCUBATE_TEMPLATES:
            pairs.append((
                tpl.format(target=f"{name} sample", temp=temp, mins=mins),
                _intent(acc, "incubate",
                        {"target": f"sample:{acc}", "temp_c": temp,
                         "duration_s": mins * 60},
                        "sample held at temperature without degradation"),
            ))

    # 4) abstain pairs — fictional, near-miss, off-domain, ambiguous, malformed.
    for name in FICTIONAL_NAMES:
        for tpl in _CLAIM_TEMPLATES[:3]:
            pairs.append((tpl.format(name=name),
                          _abstain(f"no verified UniProt accession is known for '{name}'")))
    for name in NEAR_MISS_NAMES:
        for tpl in _CLAIM_TEMPLATES[:3]:
            pairs.append((tpl.format(name=name),
                          _abstain(f"no verified UniProt accession is known for '{name}'; guessing a related protein's accession would be wrong")))
    for q in OFF_DOMAIN:
        pairs.append((q, _abstain("request is unrelated to protein structure verification")))
    for q in AMBIGUOUS:
        pairs.append((q, _abstain("the protein reference is ambiguous; a specific accession is required")))
    for acc in MALFORMED_ACCESSIONS:
        pairs.append((f"Verify the structural consistency of accession {acc}.",
                      _abstain(f"'{acc}' is not a valid UniProt accession")))

    # Sanity: every assistant output must parse under the SAME grammar the
    # floor enforces — the dataset cannot teach anything the gate would reject.
    for user, assistant in pairs:
        parse_proposal(assistant)

    rng.shuffle(pairs)
    return [{"messages": [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": user},
        {"role": "assistant", "content": assistant},
    ]} for user, assistant in pairs]


def write_dataset(store: Store, out_dir: str | Path, *, seed: int = 20260917,
                  valid_fraction: float = 0.1,
                  exclude_eval: str | Path | None = None) -> dict:
    """train.jsonl / valid.jsonl / eval.jsonl (eval = held out entirely).

    exclude_eval: path to a prior eval.jsonl whose user prompts must not
    appear anywhere in this dataset — keeps a cross-version gating eval
    uncontaminated (v2 trains while v1's eval stays the yardstick)."""
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    rows = generate_pairs(store, seed=seed)
    if exclude_eval:
        held = {json.loads(line)["messages"][1]["content"]
                for line in Path(exclude_eval).read_text().splitlines()}
        rows = [r for r in rows if r["messages"][1]["content"] not in held]
    n_eval = max(8, int(len(rows) * 0.15))
    n_valid = max(8, int(len(rows) * valid_fraction))
    eval_rows, valid_rows, train_rows = (rows[:n_eval],
                                         rows[n_eval:n_eval + n_valid],
                                         rows[n_eval + n_valid:])
    for name, subset in (("train", train_rows), ("valid", valid_rows),
                         ("eval", eval_rows)):
        with (out / f"{name}.jsonl").open("w") as f:
            for row in subset:
                f.write(json.dumps(row, sort_keys=True) + "\n")
    return {"train": len(train_rows), "valid": len(valid_rows),
            "eval": len(eval_rows), "dir": str(out)}
