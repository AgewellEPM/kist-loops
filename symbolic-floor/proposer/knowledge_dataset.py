"""Build a KNOWLEDGE SML corpus from the facts the floor GATHERED.

Distinct from dataset.py (which trains the *proposer* — what action to take).
This distills the floor's accumulated, provenance-pinned facts into a grounded
instruction/response corpus: a small model trained on it can answer "what is the
formula of water?" from its weights, having learned ONLY from witnessed floor
facts.

The ripper law holds, harder: EVERY training answer is a real edge that exists
in the floor with provenance — unwitnessed gold trains hallucination. Unknown
subjects become ABSTAIN examples, so the model learns to say "not on record"
instead of inventing. The corpus is the exact `{"messages":[...]}` MLX-LoRA
format dataset.py emits, so the same training rig consumes it unchanged.
"""

from __future__ import annotations

import json
import random
from pathlib import Path

from symbolic_floor.store import Store

SYSTEM_PROMPT = (
    "You are a grounded science assistant distilled from a symbolic knowledge "
    "floor. Answer ONLY from verified facts you were trained on. If a fact is not "
    "in your knowledge, say you do not have it on record — never guess."
)

# relation -> (question template, answer template). {s}=subject name, {o}=object.
# Every one is a real edge in the floor; the answer is the witnessed object.
_TEMPLATES: dict[str, tuple[str, str]] = {
    "has_formula":        ("What is the molecular formula of {s}?", "{o}."),
    "has_iupac_name":     ("What is the IUPAC name of {s}?", "{o}."),
    "has_inchikey":       ("What is the InChIKey of {s}?", "{o}."),
    "has_weight":         ("What is the molecular weight of {s}?", "{o} g/mol."),
    "known_as":           ("Give another name for {s}.", "{o}."),
    "belongs_to":         ("What organism is {s} from?", "{o}."),
    "located_in":         ("Where in the cell is {s} found?", "{o}."),
    "affects":            ("What disease is {s} involved in?", "{o}."),
    "has_part":           ("What structural domain does {s} contain?", "the {o} domain."),
    "has_structure":      ("Name an experimental structure of {s}.", "PDB entry {o}."),
    "predicts_structure": ("What is the AlphaFold model for {s}?", "{o}."),
    "encodes":            ("What protein does the gene {s} encode?", "UniProt {o}."),
    "on_chromosome":      ("What chromosome is the gene {s} on?", "chromosome {o}."),
    "has_biotype":        ("What is the biotype of the gene {s}?", "{o}."),
}

# Subjects the floor does NOT hold — teach the model to abstain, not invent.
_ABSTAIN_SUBJECTS = [
    ("What is the molecular formula of unobtainium-9?", "molecular formula"),
    ("What is the InChIKey of flubberene?", "InChIKey"),
    ("What chromosome is the gene ZZFAKE1 on?", "chromosome"),
    ("Name an experimental structure of protein Q0FAKE0.", "structure"),
    ("What disease is sparklonin involved in?", "disease"),
]


def _readable(node_id: str, names: dict[str, str]) -> str:
    prefix, _, ident = node_id.partition(":")
    if node_id in names:
        return names[node_id]
    if prefix in ("organism", "location", "disease", "domain", "compound", "biotype"):
        return ident.replace("_", " ")
    return ident


def _subject_names(store: Store) -> dict[str, str]:
    """Human name per subject: molecules -> a real synonym, genes -> symbol,
    proteins -> accession (kept — an accession is a legitimate identifier)."""
    names: dict[str, str] = {}
    # molecule -> shortest alphabetic known_as synonym (a real, readable name)
    for r in store.db.execute(
            "SELECT subject, object FROM typed_relations WHERE relation_type='known_as'"):
        syn = r["object"].split(":", 1)[1].replace("_", " ")
        if syn.replace(" ", "").isalpha():
            cur = names.get(r["subject"])
            if cur is None or len(syn) < len(cur):
                names[r["subject"]] = syn
    return names


def knowledge_pairs(store: Store, *, seed: int = 20260918) -> list[dict]:
    """Grounded (user, assistant) pairs from EVERY provenanced floor edge, plus
    abstain examples. Only witnessed facts — an edge with no provenance row is
    skipped (it cannot be a training answer)."""
    rng = random.Random(seed)
    names = _subject_names(store)
    pairs: list[tuple[str, str]] = []

    rows = store.db.execute(
        """SELECT tr.subject, tr.relation_type, tr.object
             FROM typed_relations tr
             JOIN edge_provenance ep ON ep.edge_id = tr.id
            ORDER BY tr.id""").fetchall()
    for r in rows:
        tpl = _TEMPLATES.get(r["relation_type"])
        if tpl is None:
            continue
        s = _readable(r["subject"], names)
        o = _readable(r["object"], names)
        q, a = tpl
        pairs.append((q.format(s=s), a.format(o=o)))

    for q, _kind in _ABSTAIN_SUBJECTS:
        pairs.append((q, "I do not have a verified record for that, so I won't guess."))

    rng.shuffle(pairs)
    return [{"messages": [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": u},
        {"role": "assistant", "content": a},
    ]} for u, a in pairs]


def write_knowledge_corpus(store: Store, out_dir: str | Path, *,
                           seed: int = 20260918, valid_fraction: float = 0.1) -> dict:
    """train/valid/eval.jsonl in the MLX-LoRA chat format (same as dataset.py)."""
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    rows = knowledge_pairs(store, seed=seed)
    n_eval = max(4, int(len(rows) * 0.15))
    n_valid = max(4, int(len(rows) * valid_fraction))
    eval_rows, valid_rows, train_rows = (rows[:n_eval],
                                         rows[n_eval:n_eval + n_valid],
                                         rows[n_eval + n_valid:])
    for name, subset in (("train", train_rows), ("valid", valid_rows), ("eval", eval_rows)):
        with (out / f"{name}.jsonl").open("w") as f:
            for row in subset:
                f.write(json.dumps(row, sort_keys=True) + "\n")
    return {"train": len(train_rows), "valid": len(valid_rows),
            "eval": len(eval_rows), "total": len(rows), "dir": str(out)}
