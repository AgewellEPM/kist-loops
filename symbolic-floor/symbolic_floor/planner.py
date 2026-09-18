"""Layer 3 — the execution planner: the part that KNOWS HOW TO USE the hands.

Takes a high-level intent and composes it from the capabilities the CURRENT
environment exposes. Same intent, different environments -> different command
sequences; the reasoning never changes. Pure code, deterministic, and honest:
an intent that cannot be composed from the available capabilities returns
UNPLANNABLE with the exact missing capabilities — it never guesses.

Every plan carries a trace: the intent rule applied, the capability calls
emitted (each validated against the affordance schema), and what the plan
assumed. A plan without a trace is invalid by construction.
"""

from __future__ import annotations

from .capabilities import validate_call
from .schema import ValidationError

# ---------------------------------------------------------------- intents
# Each intent: required capability set + a pure composer(params) -> steps.


def _compose_serial_dilution(params: dict) -> list[dict]:
    """1:N serial dilution across `steps` wells from a stock well."""
    factor = params["factor"]
    steps = params["steps"]
    volume = params["volume_ul"]
    transfer = volume / factor
    calls: list[dict] = []
    prev = params.get("stock", "well:stock")
    for i in range(1, steps + 1):
        well = f"well:D{i}"
        calls.append({"capability": "aspirate",
                      "params": {"volume_ul": transfer, "source": prev}})
        calls.append({"capability": "dispense",
                      "params": {"volume_ul": transfer, "dest": well}})
        calls.append({"capability": "mix",
                      "params": {"target": well, "cycles": 5}})
        prev = well
    return calls


def _compose_measure_sample(params: dict) -> list[dict]:
    return [{"capability": "measure_absorbance",
             "params": {"target": params["target"],
                        "wavelength_nm": params["wavelength_nm"]}}]


def _compose_incubate(params: dict) -> list[dict]:
    return [{"capability": "heat",
             "params": {"target": params["target"], "temp_c": params["temp_c"],
                        "duration_s": params["duration_s"]}}]


INTENTS: dict[str, dict] = {
    "serial_dilution": {
        "requires": {"aspirate", "dispense", "mix"},
        "params": {"factor": (int, 2, 1000), "steps": (int, 1, 24),
                   "volume_ul": ((int, float), 1, 10_000)},
        "compose": _compose_serial_dilution,
        "description": "1:N serial dilution across N wells from a stock well",
    },
    "measure_sample": {
        "requires": {"measure_absorbance"},
        "params": {"target": (str,), "wavelength_nm": (int, 200, 1000)},
        "compose": _compose_measure_sample,
        "description": "single absorbance reading of a target well",
    },
    "incubate": {
        "requires": {"heat"},
        "params": {"target": (str,), "temp_c": ((int, float), 4, 121),
                   "duration_s": (int, 1, 86_400)},
        "compose": _compose_incubate,
        "description": "hold a target at temperature for a duration",
    },
}


def _validate_intent_params(intent: str, spec: dict, params: dict) -> dict:
    if not isinstance(params, dict):
        raise ValidationError(f"intent {intent}: params must be a dict")
    out = {}
    for field, rule in spec["params"].items():
        if field not in params:
            raise ValidationError(f"intent {intent}: missing param {field!r}")
        value = params[field]
        types = rule[0] if isinstance(rule[0], tuple) else (rule[0],)
        if isinstance(value, bool) or not isinstance(value, types):
            raise ValidationError(f"intent {intent}.{field}: wrong type {value!r}")
        if len(rule) == 3 and not (rule[1] <= value <= rule[2]):
            raise ValidationError(
                f"intent {intent}.{field}: {value} outside [{rule[1]}, {rule[2]}]"
            )
        out[field] = value
    extra = {k: v for k, v in params.items() if k not in spec["params"]}
    return {**out, **extra}  # pass-through extras (e.g. stock well) are kept


def plan_intent(intent: str, params: dict, available_capabilities: set[str]) -> dict:
    """Compose an intent from the capabilities the environment ACTUALLY has.

    Returns {"status": "PLANNED", "steps": [...], "trace": {...}} or
    {"status": "UNPLANNABLE", "missing_capabilities": [...], "trace": {...}}.
    Never partial, never substituted, never guessed.
    """
    spec = INTENTS.get(intent)
    if spec is None:
        raise ValidationError(f"unknown intent {intent!r}; known: {sorted(INTENTS)}")
    clean = _validate_intent_params(intent, spec, params)

    missing = sorted(spec["requires"] - set(available_capabilities))
    trace = {
        "intent": intent,
        "rule": spec["description"],
        "requires": sorted(spec["requires"]),
        "available": sorted(set(available_capabilities)),
        "params": {k: clean[k] for k in sorted(clean)},
    }
    if missing:
        return {"status": "UNPLANNABLE", "intent": intent,
                "missing_capabilities": missing, "steps": [], "trace": trace}

    steps = []
    for i, call in enumerate(spec["compose"](clean), start=1):
        validated = validate_call(call["capability"], call["params"])
        steps.append({"step": i, "capability": call["capability"], "params": validated})
    return {"status": "PLANNED", "intent": intent, "steps": steps, "trace": trace}
