"""Traversal discovery + the hypergeometric enrichment null model.

The whole point: a convergence is only a FINDING if it's enriched beyond the
background. organism:homo_sapiens (every human protein) must come out NOT
significant; domain:globin (private to globins in a mixed background) must come
out significant. In a floor with no background beyond the seeds, everything is
'underpowered' — honestly, not a fabricated finding.
"""

from symbolic_floor.discovery import find_convergences, _hypergeom_sf
from symbolic_floor.schema import utc_now_iso

GLOBINS = ["P69905", "P68871", "P02144", "Q9NPG2", "Q8WWM9"]
BACKGROUND = ["P%05d" % (40000 + i) for i in range(15)]  # 15 non-globin human proteins


def _prov():
    return {"source": "manual", "url": None, "retrieved_at": utc_now_iso(), "raw_id": "test"}


def _seed_mixed(store):
    for g in GLOBINS:
        store.add_edge(f"protein:{g}", "belongs_to", "organism:homo_sapiens", _prov())
        store.add_edge(f"protein:{g}", "has_part", "domain:globin", _prov())
    for acc in BACKGROUND:
        store.add_edge(f"protein:{acc}", "belongs_to", "organism:homo_sapiens", _prov())
        store.add_edge(f"protein:{acc}", "has_part", "domain:immunoglobulin", _prov())


def test_specific_convergence_is_significant_hub_is_not(store):
    _seed_mixed(store)
    convs = {c.node: c for c in find_convergences(store, [f"protein:{g}" for g in GLOBINS])}
    assert "domain:globin" in convs and "organism:homo_sapiens" in convs

    globin = convs["domain:globin"]
    organism = convs["organism:homo_sapiens"]
    assert globin.support == 5 and organism.support == 5           # both reached from all 5
    assert globin.significant is True, f"globin p={globin.p_value}"  # private to globins
    assert organism.significant is False, "organism is a trivial hub (every protein is human)"
    assert globin.p_value < organism.p_value                        # globin far more enriched
    # significant convergences sort first
    ordered = find_convergences(store, [f"protein:{g}" for g in GLOBINS])
    assert ordered[0].node == "domain:globin"


def test_tiny_floor_is_honestly_underpowered(store):
    # Only the 5 seeds, no background -> N == n -> every convergence underpowered,
    # NONE marked significant. The system must not fabricate a finding.
    for g in GLOBINS:
        store.add_edge(f"protein:{g}", "belongs_to", "organism:homo_sapiens", _prov())
        store.add_edge(f"protein:{g}", "has_part", "domain:globin", _prov())
    convs = find_convergences(store, [f"protein:{g}" for g in GLOBINS])
    assert convs, "still reports the raw convergences"
    assert all(c.underpowered for c in convs)
    assert not any(c.significant for c in convs), "no background -> no significance claim"


def test_min_support_threshold(store):
    _seed_mixed(store)
    # a node reached from only 2 seeds is below min_support=3 -> excluded
    store.add_edge("protein:P69905", "affects", "disease:x_only_two", _prov())
    store.add_edge("protein:P68871", "affects", "disease:x_only_two", _prov())
    convs = {c.node for c in find_convergences(store, [f"protein:{g}" for g in GLOBINS],
                                               min_support=3)}
    assert "disease:x_only_two" not in convs


def test_paths_are_single_typed_edges(store):
    _seed_mixed(store)
    globin = next(c for c in find_convergences(store, [f"protein:{g}" for g in GLOBINS])
                  if c.node == "domain:globin")
    assert len(globin.paths) == globin.support
    for p in globin.paths:
        assert p["relation"] == "has_part" and p["node"] == "domain:globin"


def test_hypergeom_sf_extremes():
    assert _hypergeom_sf(5, 20, 5, 5) < 0.001      # 5/5 from a rare class -> tiny p
    assert _hypergeom_sf(5, 20, 20, 5) == 1.0      # class == whole population -> p = 1
    assert _hypergeom_sf(0, 20, 5, 5) == 1.0       # degenerate
