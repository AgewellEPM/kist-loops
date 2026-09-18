"""The adaptive runtime — "mold this around X, do Y" — with the PEEL gate.

Pins the invariants that let the interface adapt while the floor still refuses
anything out of envelope: typed + finitely bounded, physical quantities inside
the safety envelope, built-in names only narrowed, idempotent binding, and the
molded capability admitted into the effective registry the planner composes."""

from __future__ import annotations

import pytest

from symbolic_floor.molding import (
    SAFETY_ENVELOPES,
    effective_capabilities,
    invoke_molded,
    list_molded,
    mold_capability,
)
from symbolic_floor.schema import ValidationError

VORTEX = {"target": {"type": "string", "constraint": ["nonempty"]},
          "rpm": {"type": "integer", "constraint": ["range", 100, 3000]}}


# ---------------------------------------------------------------- happy path

def test_mold_new_capability_registers_and_composes(store):
    r = mold_capability(store, "vortex", VORTEX, "spin a tube to mix")
    assert r["molded"] == "vortex" and r["based_on"] is None
    # DYNAMIC HARNESS: the planner's effective registry now offers it
    eff = effective_capabilities(store)
    assert "vortex" in eff and "aspirate" in eff       # molded + built-in
    # execution binding admits an in-envelope call, rejects an out-of-range one
    assert invoke_molded(store, "vortex",
                         {"target": "tube-A", "rpm": 1500})["admitted"]
    with pytest.raises(ValidationError):
        invoke_molded(store, "vortex", {"target": "tube-A", "rpm": 9999})


def test_idempotent_binding(store):
    mold_capability(store, "vortex", VORTEX, "spin")
    again = mold_capability(store, "vortex", VORTEX, "spin")
    assert again["mold_count"] == 2                     # re-mold counted…
    rows = [m for m in list_molded(store) if m["name"] == "vortex"]
    assert len(rows) == 1                               # …but ONE row (idempotent)
    assert rows[0]["spec"] == r_spec()                  # spec stable


def r_spec():
    return {"target": {"type": "string", "constraint": ["nonempty"]},
            "rpm": {"type": "integer", "constraint": ["range", 100, 3000]}}


# ---------------------------------------------------------------- PEEL gate

def test_reject_unbounded_numeric(store):
    with pytest.raises(ValidationError, match="bounded"):
        mold_capability(store, "spin", {"rpm": {"type": "number",
                        "constraint": ["nonempty"]}}, "unbounded rpm")


def test_reject_over_safety_envelope(store):
    # 200°C exceeds the 121°C autoclave envelope — the floor refuses it
    with pytest.raises(ValidationError, match="envelope"):
        mold_capability(store, "superheat",
                        {"temp_c": {"type": "number", "constraint": ["range", 4, 200]}},
                        "heat way too hot")


def test_physical_quantity_must_be_numeric(store):
    with pytest.raises(ValidationError, match="numeric"):
        mold_capability(store, "badtemp",
                        {"temp_c": {"type": "string", "constraint": ["nonempty"]}},
                        "temp as text")


def test_bad_name_and_empty_intent(store):
    with pytest.raises(ValidationError, match="name"):
        mold_capability(store, "Bad Name!", VORTEX, "x")
    with pytest.raises(ValidationError, match="intent"):
        mold_capability(store, "vortex", VORTEX, "   ")


def test_empty_spec_rejected(store):
    with pytest.raises(ValidationError, match="at least one"):
        mold_capability(store, "nothing", {}, "no params")


# ---------------------------------------------------------------- built-in narrowing

def test_narrow_builtin_is_allowed_and_flagged(store):
    # heat built-in is temp_c range [4, 121]; narrow to a gentle band
    r = mold_capability(store, "heat",
                        {"target": {"type": "string", "constraint": ["nonempty"]},
                         "temp_c": {"type": "number", "constraint": ["range", 25, 42]},
                         "duration_s": {"type": "integer", "constraint": ["range", 1, 3600]}},
                        "gentle warm for live cells")
    assert r["based_on"] == "heat"
    # the narrowed heat overrides the built-in in the effective registry
    eff = effective_capabilities(store)
    assert eff["heat"]["temp_c"] == ("number", ("range", 25, 42))


def test_reject_widening_a_builtin(store):
    # duration_s: built-in heat allows up to 86_400s; the safety envelope allows
    # up to 604_800s. Widening past the BUILT-IN (but within the envelope) must
    # still be refused — a narrowing may not loosen the built-in's own contract.
    with pytest.raises(ValidationError, match="inside the built-in"):
        mold_capability(store, "heat",
                        {"target": {"type": "string", "constraint": ["nonempty"]},
                         "temp_c": {"type": "number", "constraint": ["range", 4, 121]},
                         "duration_s": {"type": "integer", "constraint": ["range", 1, 200000]}},
                        "heat too long via a builtin name")


def test_reject_adding_params_to_a_builtin(store):
    with pytest.raises(ValidationError, match="new name"):
        mold_capability(store, "label",
                        {"target": {"type": "string", "constraint": ["nonempty"]},
                         "text": {"type": "string", "constraint": ["nonempty"]},
                         "color": {"type": "string", "constraint": ["nonempty"]}},
                        "label with an extra param")


# ---------------------------------------------------------------- envelope table

def test_every_envelope_is_finite_and_ordered():
    for name, (lo, hi) in SAFETY_ENVELOPES.items():
        assert lo <= hi, f"{name} envelope inverted"
        assert abs(lo) < 1e9 and abs(hi) < 1e9, f"{name} envelope not finite"
