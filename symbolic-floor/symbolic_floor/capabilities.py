"""Layer 1 — the affordance model: what hands CAN DO, not what brand they are.

A hand is not a hand; it is a set of capabilities. Each capability here is a
typed operation with a machine-checked parameter schema. Environments (Layer
2) declare WHICH of these they expose; the planner (Layer 3) composes intents
only from what the current environment actually offers. Nothing anywhere
binds to a vendor API.

The registry is deliberately small and typed — extending it is adding a dict
entry with a schema, reviewed, not scraping a robot SDK.
"""

from __future__ import annotations

from .schema import ValidationError

# capability -> {param: (type, constraint)} where constraint is
# ("range", lo, hi) | ("nonempty",) | ("choice", (...)) — validated fail-fast.
CAPABILITIES: dict[str, dict[str, tuple]] = {
    "aspirate": {                      # draw liquid up
        "volume_ul": ("number", ("range", 0.1, 10_000.0)),
        "source":    ("string", ("nonempty",)),
    },
    "dispense": {                      # push liquid out
        "volume_ul": ("number", ("range", 0.1, 10_000.0)),
        "dest":      ("string", ("nonempty",)),
    },
    "mix": {                           # cycles of aspirate/dispense in place
        "target": ("string", ("nonempty",)),
        "cycles": ("integer", ("range", 1, 100)),
    },
    "heat": {
        "target":     ("string", ("nonempty",)),
        "temp_c":     ("number", ("range", 4.0, 121.0)),
        "duration_s": ("integer", ("range", 1, 86_400)),
    },
    "measure_absorbance": {            # returns a reading
        "target":        ("string", ("nonempty",)),
        "wavelength_nm": ("integer", ("range", 200, 1000)),
    },
    "read_sensor": {
        "sensor": ("string", ("nonempty",)),
    },
    "label": {                         # human/robot-agnostic annotation step
        "target": ("string", ("nonempty",)),
        "text":   ("string", ("nonempty",)),
    },
}


def validate_call(capability: str, params: dict) -> dict:
    """Validate one capability invocation against the affordance schema.
    Returns the params (canonical) or raises ValidationError naming the field."""
    schema = CAPABILITIES.get(capability)
    if schema is None:
        raise ValidationError(
            f"unknown capability {capability!r}; known: {sorted(CAPABILITIES)}"
        )
    if not isinstance(params, dict):
        raise ValidationError(f"{capability}: params must be a dict")
    unknown = set(params) - set(schema)
    if unknown:
        raise ValidationError(f"{capability}: unknown params {sorted(unknown)}")
    out = {}
    for field, (ftype, constraint) in schema.items():
        if field not in params:
            raise ValidationError(f"{capability}: missing param {field!r}")
        value = params[field]
        if ftype == "number":
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise ValidationError(f"{capability}.{field}: must be a number, got {value!r}")
            value = float(value)
        elif ftype == "integer":
            if isinstance(value, bool) or not isinstance(value, int):
                raise ValidationError(f"{capability}.{field}: must be an integer, got {value!r}")
        elif ftype == "string":
            if not isinstance(value, str):
                raise ValidationError(f"{capability}.{field}: must be a string, got {value!r}")
        if constraint[0] == "range":
            _, lo, hi = constraint
            if not (lo <= value <= hi):
                raise ValidationError(
                    f"{capability}.{field}: {value} outside [{lo}, {hi}]"
                )
        elif constraint[0] == "nonempty":
            if not str(value).strip():
                raise ValidationError(f"{capability}.{field}: must be non-empty")
        elif constraint[0] == "choice":
            if value not in constraint[1]:
                raise ValidationError(
                    f"{capability}.{field}: {value!r} not in {constraint[1]}"
                )
        out[field] = value
    return out
