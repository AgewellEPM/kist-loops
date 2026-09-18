"""Symbolic subject resolution — the table binds accessions, not the model.

Three training rounds proved the point empirically: teaching a 3B model the
curated name->accession whitelist by example seesaws between hallucinated
accessions (v1/v2: fictional names answered confidently) and over-abstention
(v3: curated names refused). The binding is a symbolic lookup; make the
symbolic layer do it.

After the strict parse, every non-abstain proposal passes through here:

  grounded accessions = UniProt ids literally present in the user's text
                      + curated-name matches (word-boundary, longest-first,
                        extension-blocked so 'cytochrome c oxidase' never
                        binds 'cytochrome c')

  subject in grounded          -> pass (model agreed with the evidence)
  exactly one grounded, other  -> repair (subject overridden with the binding)
  nothing grounded / ambiguous -> forced abstain

A wrong accession — well-formed, verifiable, about the wrong protein — was
the one proposer failure the floor could not catch. Now it cannot be emitted:
subjects exist only if the user's own words ground them.
"""

from __future__ import annotations

import re

from symbolic_floor.schema import ValidationError, validate_node_id

from .dataset import KNOWN_PROTEINS

# Standard UniProt accession forms (6 or 10 chars). Candidates are still
# re-checked by validate_node_id — one validator, one truth.
_ACCESSION_RE = re.compile(
    r"\b([OPQ][0-9][A-Z0-9]{3}[0-9]|[A-NR-Z][0-9](?:[A-Z][A-Z0-9]{2}[0-9]){1,2})\b",
    re.IGNORECASE,
)

# A curated-name match is void when the very next word extends it into a
# DIFFERENT protein ('ubiquitin ligase', 'insulin receptor', 'myoglobin II').
# Word boundaries already handle fused forms ('proinsulin').
_EXTENSION_WORDS = frozenset({
    "receptor", "receptors", "subunit", "ligase", "oxidase", "kinase",
    "reductase", "synthase", "phosphatase", "protein", "alpha", "beta",
    "gamma", "delta", "epsilon", "zeta", "eta", "theta", "kappa", "sigma",
    "omega", "ii", "iii", "iv", "like", "variant", "precursor", "isoform",
    "homolog", "family", "chain", "complex",
})

_ABSTAIN_UNGROUNDED = ("no accession for this subject is grounded in the "
                       "request or the curated table; refusing to guess")
_ABSTAIN_AMBIGUOUS = ("the request grounds multiple accessions and the "
                      "proposal names none of them; refusing to guess")


def _curated_matches(text: str) -> set[str]:
    """Accessions whose curated names appear in text as maximal mentions."""
    low = text.lower()
    found: set[str] = set()
    for name in sorted(KNOWN_PROTEINS, key=len, reverse=True):
        for m in re.finditer(rf"\b{re.escape(name.lower())}\b", low):
            nxt = re.match(r"[\s\-]+(\w+)", low[m.end():])
            if nxt and nxt.group(1) in _EXTENSION_WORDS:
                continue
            found.add(KNOWN_PROTEINS[name])
            break
    return found


def grounded_accessions(text: str) -> set[str]:
    """Every accession the user's own words justify."""
    grounded = _curated_matches(text)
    for m in _ACCESSION_RE.finditer(text):
        acc = m.group(1).upper()
        try:
            validate_node_id(f"protein:{acc}")
        except ValidationError:
            continue
        grounded.add(acc)
    return grounded


def resolve(user_text: str, proposal: dict) -> tuple[dict, str]:
    """Bind or veto a parsed proposal's subject. Returns (proposal, action),
    action in {'pass', 'repaired', 'abstained'}. Abstain proposals and
    grounded subjects pass through; everything else is repaired to the
    single grounded binding or forced to abstain."""
    if proposal["kind"] == "abstain":
        return proposal, "pass"

    grounded = grounded_accessions(user_text)
    subject = proposal["subject"]

    if subject in grounded:
        return proposal, "pass"
    if len(grounded) == 1:
        repaired = dict(proposal, subject=next(iter(grounded)))
        return repaired, "repaired"
    reason = _ABSTAIN_AMBIGUOUS if grounded else _ABSTAIN_UNGROUNDED
    return {"kind": "abstain", "reason": reason}, "abstained"
