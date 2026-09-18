"""Resolver pins — subjects exist only if the user's words ground them.

The resolver closes the one proposer failure the floor cannot catch: a
well-formed proposal about the WRONG protein. Every pin here is a site where
that failure previously lived (v1-v3 eval evidence in proposer/reports/).
"""

import pytest

from proposer.dataset import KNOWN_PROTEINS, NEAR_MISS_NAMES
from proposer.resolver import grounded_accessions, resolve


def _claim(subject: str) -> dict:
    return {"kind": "claim", "subject": subject,
            "shape": "structural-consistency-v1", "predicted_outcome": "x"}


# --- grounding: curated names bind, per-name (multi-site rule) -------------

@pytest.mark.parametrize("name,acc", sorted(KNOWN_PROTEINS.items()))
def test_each_curated_name_grounds_its_accession(name, acc):
    assert acc in grounded_accessions(f"Verify the structural consistency of {name}.")


@pytest.mark.parametrize("name", NEAR_MISS_NAMES)
def test_each_near_miss_name_grounds_nothing(name):
    """The v1/v2 hallucination class: cousins must NOT bind the curated
    cousin's accession. One assertion per trap name."""
    assert grounded_accessions(f"Has {name} been structurally validated?") == set()


def test_literal_accession_grounds_even_unknown_to_table():
    assert "Q5VSL9" in grounded_accessions("Seed the knowledge base for accession Q5VSL9.")


def test_malformed_identifiers_ground_nothing():
    for bad in ("P1234", "XP_004321", "NM_000518", "PROT-77"):
        assert grounded_accessions(f"Verify accession {bad}.") == set(), bad


def test_fused_prefix_does_not_ground():
    # word boundary: 'proinsulin' must not bind 'insulin'
    assert grounded_accessions("Verify proinsulin's structure.") == set()


# --- resolution: pass / repair / forced abstain -----------------------------

def test_grounded_subject_passes():
    got, action = resolve("Verify hemoglobin alpha.", _claim("P69905"))
    assert action == "pass" and got["subject"] == "P69905"


def test_wrong_subject_repaired_to_single_grounding():
    """v3 parse-failure case: model invented D11308 while the text named
    cytochrome c. Single grounded accession -> subject overridden."""
    got, action = resolve(
        "Measure the absorbance of well:D3 at 280 nm. (sample of cytochrome c)",
        {"kind": "intent", "subject": "D11308", "intent": "measure_sample",
         "params": {"target": "well:D3", "wavelength_nm": 280},
         "predicted_outcome": "a reading"})
    assert action == "repaired" and got["subject"] == "P99999"


def test_ungrounded_confident_claim_forced_to_abstain():
    """v1's missed-abstain class: fictional name, confident claim."""
    got, action = resolve(
        "Does glorbulin-7 have an experimentally validated structure?",
        _claim("P69905"))
    assert action == "abstained" and got["kind"] == "abstain"


def test_off_domain_confident_claim_forced_to_abstain():
    got, action = resolve("How do I fix a segfault in C?", _claim("P04637"))
    assert action == "abstained" and got["kind"] == "abstain"


def test_ambiguous_multiple_groundings_forced_to_abstain():
    got, action = resolve(
        "Compare insulin and myoglobin structures.", _claim("P02768"))
    assert action == "abstained" and got["kind"] == "abstain"


def test_multiple_groundings_pass_when_model_picks_one():
    got, action = resolve(
        "Compare insulin and myoglobin structures.", _claim("P01308"))
    assert action == "pass" and got["subject"] == "P01308"


def test_model_abstain_passes_through_untouched():
    proposal = {"kind": "abstain", "reason": "not my field"}
    got, action = resolve("Verify hemoglobin alpha.", proposal)
    assert action == "pass" and got is proposal


# --- extension blocking: per-extension sites from the near-miss list --------

@pytest.mark.parametrize("phrase", [
    "cytochrome c oxidase",   # would otherwise bind cytochrome c
    "ubiquitin ligase",       # would otherwise bind ubiquitin
    "insulin receptor",       # would otherwise bind insulin
    "myoglobin II",           # would otherwise bind myoglobin
    "lysozyme C variant",     # would otherwise bind lysozyme C
    "myoglobin chain A",      # verify-eng: PDB-style chain label
    "myoglobin alpha oxidase",  # verify-eng: greek-suffix compound
    "insulin complex",        # verify-eng: compound assembly
])
def test_extended_mentions_do_not_bind_the_shorter_curated_name(phrase):
    assert grounded_accessions(f"Verify the structure of {phrase}.") == set()


def test_greek_extension_does_not_break_curated_names_ending_in_greek():
    """'alpha' is an extension word, but curated names CONTAINING alpha
    ('hemoglobin alpha', 'hemoglobin subunit alpha') must still bind —
    blocking applies to the word AFTER the match, not inside it."""
    assert "P69905" in grounded_accessions("Verify hemoglobin alpha.")
    assert "P69905" in grounded_accessions("Verify hemoglobin subunit alpha.")


def test_repair_boundary_incidental_mention_binds_the_mentioned_protein():
    """Documented trade-off (verify-eng finding 1): if the user's text
    grounds exactly ONE curated protein while the model invents a valid-form
    subject for something the text never grounds, repair binds the MENTIONED
    protein. Repair only fires post-parse (valid accession, single
    grounding); the alternative — trusting the model's ungrounded accession
    — is the exact failure this layer exists to kill. If this contract
    changes, change this pin deliberately."""
    got, action = resolve(
        "In studying cytochrome c, we also care about the uncharacterized "
        "membrane protein. Can you extract its structure?",
        {"kind": "extract", "subject": "Q5VSL9"})
    assert action == "repaired" and got["subject"] == "P99999"
