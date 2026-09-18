"""Traversal discovery with an HONEST significance test.

The floor's discovery primitive is "relevance = reachability": nodes reachable
from several seed entities are candidate convergences. But raw convergence is a
trap — every human protein trivially converges on organism:homo_sapiens. A
convergence is only a FINDING if it is enriched beyond what the background would
give by chance.

The null model is an exact HYPERGEOMETRIC test. For a candidate node v reached
from k of the n seeds, let N = the floor's population of the seed type and
m = how many of those N link to v (v's background in-degree). Under H0 (the n
seeds are a random subset of the N), the number reaching v is Hypergeometric(N,
m, n), and the enrichment p-value is P(X >= k). This does the right thing at both
extremes with no heuristics:
  - organism:homo_sapiens: m == N (all are human) -> p == 1 -> NOT a finding.
  - domain:globin among a mixed background: m small, k = n -> p tiny -> a finding.
In a tiny floor (N == n, no background beyond the seeds) every p == 1 and the
system HONESTLY reports "insufficient background" rather than inventing a finding.
More data (the research loop) is what earns significance.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from math import comb

from .store import Store


def _hypergeom_sf(k: int, N: int, m: int, n: int) -> float:
    """P(X >= k) for X ~ Hypergeometric(population=N, successes=m, draws=n).
    Exact (math.comb). Returns 1.0 for degenerate/underpowered inputs."""
    if N <= 0 or n <= 0 or m <= 0 or k <= 0:
        return 1.0
    n = min(n, N)
    denom = comb(N, n)
    if denom == 0:
        return 1.0
    lo = max(k, 0)
    hi = min(m, n)
    total = 0
    for i in range(lo, hi + 1):
        total += comb(m, i) * comb(N - m, n - i)
    return min(1.0, total / denom)


@dataclass
class Convergence:
    node: str
    support: int                       # how many seeds reach it (k)
    supporters: list[str]              # which seeds, sorted
    relations: list[str]               # the typed relation each supporter used
    background_m: int                  # seed-type nodes linking to it (m)
    population_N: int                  # seed-type population in the floor (N)
    degree: int                        # total distinct neighbours (hub signal)
    p_value: float                     # hypergeometric enrichment P(X >= k)
    significant: bool                  # p <= alpha AND support >= min_support
    underpowered: bool                 # N <= support -> no real background
    paths: list[dict] = field(default_factory=list)  # [{seed, relation, node}]


def _type_of(node: str) -> str:
    return node.partition(":")[0]


def population_of_type(store: Store, node_type: str) -> set[str]:
    """Distinct nodes of a given prefix that appear as an edge SUBJECT — the
    background population the null model samples from."""
    rows = store.db.execute(
        "SELECT DISTINCT subject FROM typed_relations WHERE subject LIKE ?",
        (f"{node_type}:%",)).fetchall()
    return {r["subject"] for r in rows}


def _out_neighbours(store: Store, node: str) -> list[tuple[str, str]]:
    """(neighbour, relation) for one 1-hop step out of `node`."""
    return [(e["object"], e["relation_type"]) for e in store.get_edges(source=node)]


def _node_degree(store: Store, node: str) -> int:
    """Distinct neighbours across BOTH directions — the hub signal."""
    nb = {e["object"] for e in store.get_edges(source=node)}
    nb |= {e["subject"] for e in store.get_edges(target=node)}
    return len(nb)


def find_convergences(store: Store, seeds: list[str], *, min_support: int = 3,
                      alpha: float = 0.05) -> list[Convergence]:
    """Directly-reachable nodes shared by >= min_support seeds, each scored by
    the hypergeometric enrichment null model. Seeds must share a type (the
    background population). Returns significant-first, then by support, then by
    p-value. 1-hop by design: the path is a single typed, provenance-pinned edge,
    so 'the path is the proof' stays literally true."""
    seeds = sorted(set(seeds))
    if not seeds:
        return []
    node_type = _type_of(seeds[0])
    population = population_of_type(store, node_type)
    N = max(len(population), len(seeds))

    # who reaches what (support), and the typed relation used
    support: dict[str, set[str]] = {}
    rels: dict[str, set[str]] = {}
    for s in seeds:
        for nb, rel in _out_neighbours(store, s):
            support.setdefault(nb, set()).add(s)
            rels.setdefault(nb, set()).add(rel)

    out: list[Convergence] = []
    for node, who in support.items():
        k = len(who)
        if k < min_support:
            continue
        # background: how many of the N seed-type nodes link to this node at all
        m = len({e["subject"] for e in store.get_edges(target=node)
                 if _type_of(e["subject"]) == node_type})
        m = max(m, k)  # the observed supporters are, by definition, in the background
        p = _hypergeom_sf(k, N, m, len(seeds))
        underpowered = N <= len(seeds)          # no background beyond the seeds
        significant = (not underpowered) and p <= alpha
        out.append(Convergence(
            node=node, support=k, supporters=sorted(who), relations=sorted(rels[node]),
            background_m=m, population_N=N, degree=_node_degree(store, node),
            p_value=p, significant=significant, underpowered=underpowered,
            paths=[{"seed": s, "relation": r, "node": node}
                   for s in sorted(who) for (nb, r) in _out_neighbours(store, s) if nb == node],
        ))
    out.sort(key=lambda c: (not c.significant, -c.support, c.p_value, c.node))
    return out
