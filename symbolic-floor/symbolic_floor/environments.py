"""Layer 2 — the environment registry: the swap layer.

Each back-end — a cloud lab, a syringe-pump rig, a human tech, a simulation —
registers itself as a DICTIONARY of capabilities behind one protocol. The
planner discovers what an environment exposes (capabilities()) instead of
being hard-coded to a brand; swapping the physical back-end is registering a
new dictionary. Registration is persisted (environments table) so the floor
can enumerate its hands, but the reasoning pipeline never imports a vendor.

evidence_grade is load-bearing honesty: only "physical" environments can
produce outcomes that become graph evidence. "simulated" outcomes validate
PLANS, never the world (see handoff.collect_result).
"""

from __future__ import annotations

import importlib
import json
from typing import Protocol, runtime_checkable

from .schema import ValidationError, utc_now_iso
from .store import Store

EVIDENCE_GRADES = ("physical", "simulated")


@runtime_checkable
class Environment(Protocol):
    """The ONE interface every set of hands implements.

    capabilities() -> set of affordance names this environment exposes
    submit(contract, plan) -> {"status": "submitted", "executor_ref": "..."}
    check(executor_ref)    -> {"status": "pending" | "completed" | "failed"}
    collect(executor_ref)  -> {"observed": "confirmed"|"refuted"|"inconclusive",
                               "notes": ..., "readings": [...]}
    """

    env_id: str
    evidence_grade: str

    def capabilities(self) -> set[str]: ...

    def submit(self, contract: dict, plan: dict) -> dict: ...

    def check(self, executor_ref: str) -> dict: ...

    def collect(self, executor_ref: str) -> dict: ...


def load_environment(spec: str, **kwargs) -> Environment:
    """Resolve an environment by short name or dotted path — the plug-in seam.

    - "simulation" / "human_tech" -> symbolic_floor.adapters.<spec>.Env
    - "pkg.mod:ClassName"         -> any external back-end (Emerald Cloud Lab,
                                     Strateos, a robot bridge...) with zero
                                     changes to the reasoning pipeline.
    """
    if ":" in spec:
        module_name, _, class_name = spec.partition(":")
    else:
        module_name = f"symbolic_floor.adapters.{spec}"
        class_name = "Env"
    try:
        module = importlib.import_module(module_name)
        env = getattr(module, class_name)(**kwargs)
    except (ImportError, AttributeError) as e:
        raise ValidationError(f"cannot load environment {spec!r}: {e}") from e
    if not isinstance(env, Environment):
        raise ValidationError(
            f"environment {spec!r} does not implement the Environment protocol"
        )
    if env.evidence_grade not in EVIDENCE_GRADES:
        raise ValidationError(
            f"environment {spec!r} has invalid evidence_grade {env.evidence_grade!r}"
        )
    return env


def register_environment(store: Store, spec: str, **kwargs) -> dict:
    """Discover an environment's capability dictionary and persist it."""
    env = load_environment(spec, **kwargs)
    caps = sorted(env.capabilities())
    if not caps:
        raise ValidationError(f"environment {env.env_id!r} exposes no capabilities")
    store.db.execute(
        "INSERT OR REPLACE INTO environments "
        "(env_id, spec, evidence_grade, capabilities_json, registered_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (env.env_id, spec, env.evidence_grade, json.dumps(caps), utc_now_iso()),
    )
    store.db.commit()
    return {"env_id": env.env_id, "evidence_grade": env.evidence_grade,
            "capabilities": caps, "spec": spec}


def list_environments(store: Store) -> list[dict]:
    rows = store.db.execute(
        "SELECT env_id, spec, evidence_grade, capabilities_json, registered_at "
        "FROM environments ORDER BY env_id"
    ).fetchall()
    return [{**dict(r), "capabilities": json.loads(r["capabilities_json"])}
            for r in rows]
