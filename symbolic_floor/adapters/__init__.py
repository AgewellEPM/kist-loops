"""Execution environments — the OUTSIDE of the terminus (Layer 2 residents).

Nothing here is part of the reasoning pipeline. Each module implements the
Environment protocol (env_id, evidence_grade, capabilities, submit, check,
collect) and represents one set of hands:

- simulation — full capability set, deterministic in-process execution.
  evidence_grade "simulated": validates PLANS, never the world.
- human_tech — renders plans as human work orders in the outbox; the human
  reports back via a result file. evidence_grade "physical".

Deliberately NOT implemented (no accounts, no fake integrations): Emerald
Cloud Lab, Strateos, robot bridges. Each future back-end is one new module
here — or any external package loaded as "pkg.mod:ClassName" — and the
reasoning pipeline does not change by one line.
"""
