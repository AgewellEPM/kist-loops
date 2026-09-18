"""symbolic_floor — slice 1: protein-structure validation on the Peel engine.

A local, deterministic, evidence-attached knowledge store plus a verification
reasoner. The typed fact store is the REAL vendored Peel engine
(symbolic_floor/peel/relation_schema.py) running in-process; this package adds
provenance enforcement, the six bio relations, three read-only connectors, and
the three-verdict reasoner (SUPPORTED / CONFLICTING / UNKNOWN).
"""

__version__ = "0.1.0"
