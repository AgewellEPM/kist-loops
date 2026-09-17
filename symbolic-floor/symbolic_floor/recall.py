"""Recall: walk everything the floor knows about a subject, with traces.

The read side of the wheel. Deterministic (ORDER BY id everywhere), pure —
every fact returned carries its edge id AND its provenance, and 2-hop paths
are lists of (source, relation, target, edge_id) steps, so any answer can be
reproduced from stored edges alone. Nothing here consults labels to decide.
"""

from __future__ import annotations

import json

from .schema import validate_node_id
from .store import Store

# Bounded 2-hop link walk (the trace side of the wheel). Deliberate cap: this
# is recall, not unbounded graph search.
MAX_PATHS = 200


def recall_protein(store: Store, accession: str) -> dict:
    """Everything stored about protein:<accession>, grouped + traced."""
    acc = accession.strip().upper()
    protein = validate_node_id(f"protein:{acc}")

    outgoing = store.get_edges(source=protein)          # ORDER BY id
    incoming = store.get_edges(target=protein)

    def _fact(edge: dict, other_end: str) -> dict:
        return {
            "node": edge[other_end],
            "edge_id": edge["id"],
            "provenance": json.loads(edge["provenance_json"]) if edge["provenance_json"] else None,
        }

    facts: dict[str, list[dict]] = {}
    for e in outgoing:
        facts.setdefault(e["relation_type"], []).append(_fact(e, "object"))
    incoming_facts: dict[str, list[dict]] = {}
    for e in incoming:
        incoming_facts.setdefault(e["relation_type"], []).append(_fact(e, "subject"))

    # 2-hop paths: protein -> X -> Y (e.g. structure -> claim) and
    # W -> protein via incoming (e.g. gene encodes protein). Deterministic
    # order: outer ORDER BY id, inner ORDER BY id, bounded by MAX_PATHS.
    paths: list[list[dict]] = []
    for e in outgoing:
        step1 = {"source": e["subject"], "relation": e["relation_type"],
                 "target": e["object"], "edge_id": e["id"]}
        hops = store.get_edges(source=e["object"])
        if not hops:
            paths.append([step1])
        for h in hops:
            paths.append([step1, {"source": h["subject"], "relation": h["relation_type"],
                                  "target": h["object"], "edge_id": h["id"]}])
            if len(paths) >= MAX_PATHS:
                break
        if len(paths) >= MAX_PATHS:
            break

    total = len(outgoing) + len(incoming)
    return {
        "subject": protein,
        "facts": facts,
        "incoming": incoming_facts,
        "paths": paths,
        "paths_truncated": len(paths) >= MAX_PATHS,
        "counts": {
            "outgoing_edges": len(outgoing),
            "incoming_edges": len(incoming),
            "total_edges": total,
            "relations": len(set(facts) | set(incoming_facts)),
        },
        "floor": store.floor_id,
        "authority": store.authority,
    }
