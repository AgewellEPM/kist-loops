"""The adaptive runtime engine — "mold this around X, I need it to do Y."

A researcher extends the floor's execution vocabulary at runtime by declaring a
new TYPED, bounded capability. The four-step loop:

  1. NATURAL INTENT      the researcher names the capability + its typed params
  2. PEEL INVARIANT CHECK the spec is validated against the floor's hard rules —
                          typed, finitely bounded, and (for recognized physical
                          quantities) within the biological/chemical safety
                          envelope; a molded range may NARROW a built-in, never
                          exceed it
  3. DYNAMIC HARNESS      the validated schema joins the effective capability
                          registry the planner composes from
  4. IDEMPOTENT INTEGRATION  bound by name into the floor state (molded row);
                          re-molding the same name replaces it — safe to repeat

What is molded is a SCHEMA, never code. A capability is a set of typed
parameters with machine-checked constraints; execution composes the floor's
existing vetted primitives through an environment. So the interface adapts to
the lab while the symbolic floor still guarantees no out-of-envelope action and
no silent state corruption — flexibility without arbitrary code execution.
"""

from __future__ import annotations

import json
import re

from .capabilities import CAPABILITIES
from .schema import ValidationError, utc_now_iso

_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{1,40}$")
_TYPES = ("number", "integer", "string")

# THE FLOOR'S HARD ENVELOPES. A recognized physical quantity may only be molded
# with a numeric range that sits INSIDE its envelope — the biological/chemical
# invariants a molded capability can never talk its way past. Narrow freely;
# exceed never. Bounds are deliberately conservative lab-safety limits.
SAFETY_ENVELOPES: dict[str, tuple[float, float]] = {
    "temp_c":        (-80.0, 121.0),     # -80 freezer … 121 autoclave
    "volume_ul":     (0.0, 100_000.0),
    "wavelength_nm": (100.0, 2000.0),
    "duration_s":    (0.0, 604_800.0),   # ≤ 1 week
    "cycles":        (1.0, 1000.0),
    "ph":            (0.0, 14.0),
    "concentration_m": (0.0, 20.0),
    "conc_m":        (0.0, 20.0),
    "pressure_kpa":  (0.0, 1000.0),
    "rpm":           (0.0, 100_000.0),
    "temp":          (-80.0, 121.0),     # common short forms
    "volume":        (0.0, 100_000.0),
}


# ---------------------------------------------------------------- validation

def _canonical_constraint(raw) -> tuple:
    """Validate + canonicalize one constraint into the capabilities.py tuple
    form: ("range", lo, hi) | ("nonempty",) | ("choice", (...))."""
    if not isinstance(raw, (list, tuple)) or not raw:
        raise ValidationError(f"constraint must be a non-empty list, got {raw!r}")
    kind = raw[0]
    if kind == "range":
        if len(raw) != 3:
            raise ValidationError("range constraint is ['range', lo, hi]")
        lo, hi = raw[1], raw[2]
        for b in (lo, hi):
            if isinstance(b, bool) or not isinstance(b, (int, float)):
                raise ValidationError(f"range bounds must be numbers, got {b!r}")
        if not (lo <= hi):
            raise ValidationError(f"range lo {lo} must be <= hi {hi}")
        return ("range", lo, hi)
    if kind == "nonempty":
        return ("nonempty",)
    if kind == "choice":
        choices = tuple(raw[1]) if len(raw) > 1 and isinstance(raw[1], (list, tuple)) else ()
        if not choices:
            raise ValidationError("choice constraint needs a non-empty option list")
        return ("choice", choices)
    raise ValidationError(
        f"unknown constraint kind {kind!r}; use range | nonempty | choice")


def _check_envelope(param: str, ftype: str, constraint: tuple) -> None:
    """Recognized physical quantity → must be numeric with a range inside the
    floor's safety envelope. This is the hard biological/chemical invariant."""
    envelope = SAFETY_ENVELOPES.get(param)
    if envelope is None:
        return
    lo_env, hi_env = envelope
    if ftype not in ("number", "integer"):
        raise ValidationError(
            f"{param!r} is a physical quantity and must be numeric, not {ftype}")
    if constraint[0] != "range":
        raise ValidationError(
            f"{param!r} must declare a range within [{lo_env}, {hi_env}]")
    _, lo, hi = constraint
    if lo < lo_env or hi > hi_env:
        raise ValidationError(
            f"{param!r} range [{lo}, {hi}] exceeds the floor's safety envelope "
            f"[{lo_env}, {hi_env}] — a molded capability may narrow it, never exceed it")


def validate_spec(name: str, params_spec: dict) -> tuple[str, dict, str | None]:
    """PEEL INVARIANT CHECK for a molded capability. Returns
    (name, canonical_spec, based_on). Raises ValidationError naming the fault.

    canonical_spec: {param: {"type": t, "constraint": [...]}} — JSON-safe.
    based_on: the built-in capability this narrows, or None.
    """
    if not isinstance(name, str) or not _NAME_RE.match(name):
        raise ValidationError(
            "capability name must be 2-41 chars, lowercase letter then "
            "[a-z0-9_]")
    if not isinstance(params_spec, dict) or not params_spec:
        raise ValidationError("a capability needs at least one typed parameter")

    canonical: dict[str, dict] = {}
    tuples: dict[str, tuple] = {}
    for param, decl in params_spec.items():
        if not isinstance(param, str) or not _NAME_RE.match(param):
            raise ValidationError(f"bad parameter name {param!r}")
        if not isinstance(decl, dict) or "type" not in decl or "constraint" not in decl:
            raise ValidationError(
                f"{param!r} must be {{'type': ..., 'constraint': [...]}}")
        ftype = decl["type"]
        if ftype not in _TYPES:
            raise ValidationError(f"{param}.type must be one of {_TYPES}, got {ftype!r}")
        constraint = _canonical_constraint(decl["constraint"])
        # No unbounded surfaces: numerics need a range; strings need nonempty|choice.
        if ftype in ("number", "integer") and constraint[0] != "range":
            raise ValidationError(
                f"{param!r} is numeric and must be bounded by a range "
                "(no unbounded quantities — they invite silent state corruption)")
        if ftype == "string" and constraint[0] == "range":
            raise ValidationError(f"{param!r} is a string; use nonempty or choice")
        _check_envelope(param, ftype, constraint)
        tuples[param] = constraint
        canonical[param] = {"type": ftype, "constraint": list(constraint)}

    # Name hygiene vs built-ins: a molded capability may only reuse a built-in
    # name as an explicit NARROWING — same params, each range inside the
    # built-in's. Anything else must pick a fresh name (never silently redefine).
    based_on = None
    if name in CAPABILITIES:
        based_on = name
        builtin = CAPABILITIES[name]
        extra = set(tuples) - set(builtin)
        if extra:
            raise ValidationError(
                f"{name!r} is a built-in; a narrowing may not add params "
                f"{sorted(extra)} — choose a new name to define a new capability")
        for param, constraint in tuples.items():
            bt, bc = builtin[param]
            if constraint[0] == "range" and bc[0] == "range":
                if constraint[1] < bc[1] or constraint[2] > bc[2]:
                    raise ValidationError(
                        f"{name}.{param}: narrowing [{constraint[1]}, {constraint[2]}] "
                        f"must sit inside the built-in [{bc[1]}, {bc[2]}]")
    return name, canonical, based_on


# ---------------------------------------------------------------- registry

def _spec_to_tuples(canonical: dict) -> dict[str, tuple]:
    """canonical JSON spec -> capabilities.py (type, constraint-tuple) form."""
    out = {}
    for param, decl in canonical.items():
        c = decl["constraint"]
        constraint = (c[0], c[1], c[2]) if c[0] == "range" else \
                     (c[0], tuple(c[1])) if c[0] == "choice" else (c[0],)
        out[param] = (decl["type"], constraint)
    return out


def list_molded(store) -> list[dict]:
    rows = store.db.execute(
        "SELECT name, spec_json, intent, based_on, molded_at, mold_count "
        "FROM molded_capabilities ORDER BY name").fetchall()
    return [{"name": r["name"], "spec": json.loads(r["spec_json"]),
             "intent": r["intent"], "based_on": r["based_on"],
             "molded_at": r["molded_at"], "mold_count": r["mold_count"]}
            for r in rows]


def effective_capabilities(store) -> dict[str, dict]:
    """The registry the planner composes from: built-ins overlaid with every
    molded capability (a narrowing of a built-in overrides it)."""
    effective = {cap: {p: (t, c) for p, (t, c) in schema.items()}
                 for cap, schema in CAPABILITIES.items()}
    for m in list_molded(store):
        effective[m["name"]] = _spec_to_tuples(m["spec"])
    return effective


def mold_capability(store, name: str, params_spec: dict, intent: str) -> dict:
    """The full loop: validate the request against the floor's invariants, then
    bind it idempotently into the floor state. Raises ValidationError (the PEEL
    gate) if the request would breach a rule — nothing is written on refusal."""
    if not str(intent or "").strip():
        raise ValidationError("mold a capability WITH its intent — one sentence")
    name, canonical, based_on = validate_spec(name, params_spec)

    existing = store.db.execute(
        "SELECT mold_count FROM molded_capabilities WHERE name = ?", (name,)
    ).fetchone()
    mold_count = (existing["mold_count"] + 1) if existing else 1
    store.db.execute(
        "INSERT OR REPLACE INTO molded_capabilities "
        "(name, spec_json, intent, based_on, molded_at, mold_count) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (name, json.dumps(canonical, ensure_ascii=False), str(intent).strip(),
         based_on, utc_now_iso(), mold_count))
    store.db.commit()
    return {"molded": name, "spec": canonical, "based_on": based_on,
            "intent": str(intent).strip(), "mold_count": mold_count,
            "note": ("narrows the built-in " + based_on) if based_on
                    else "new capability admitted through the PEEL gate"}


def invoke_molded(store, name: str, params: dict) -> dict:
    """Validate a call to a molded (or built-in) capability against the
    effective registry — the same fail-fast schema check the planner uses. This
    is the execution BINDING: a call is admitted only if it satisfies the typed,
    bounded schema. (Physical dispatch runs through an Environment; this proves
    the call is well-formed and in-envelope first.)"""
    from .capabilities import validate_call_against
    registry = effective_capabilities(store)
    params = validate_call_against(registry, name, params)
    return {"capability": name, "params": params, "admitted": True}
