"""Canonical-37 PEEL tile trace pins — one assertion per canonical column
(the wiki wheel's 33/37 regression is the lesson; multi-site rule applies).
"""

import json

import pytest

from symbolic_floor.extract import extract_protein
from symbolic_floor.peel_tiles import CANONICAL_37, tile_trace, write_tile
from symbolic_floor.schema import ValidationError

from test_extract_recall import _rich_transport


def _extract(store):
    return extract_protein(store, "P69905", transport=_rich_transport())


def test_every_canonical_field_written_on_every_tile(store):
    _extract(store)
    tiles = tile_trace(store, "P69905")
    assert tiles, "extraction wrote no tiles"
    for column in CANONICAL_37:  # one assertion per canonical column
        for t in tiles:
            value = t[column]
            assert value is not None and (isinstance(value, (int, float))
                                          or str(value).strip()), \
                f"canonical field {column!r} empty on tile {t['id']} ({t['branch_path']})"


def test_trace_shape_root_plus_one_per_fact(store):
    result = _extract(store)
    tiles = tile_trace(store, "P69905")
    root = [t for t in tiles if t["depth_level"] == 0]
    children = [t for t in tiles if t["depth_level"] == 1]
    assert len(root) == 1
    # every stored outgoing fact + incoming encodes edge gets a tile
    assert result["peel_trace"]["tiles_total"] == 1 + len(children)
    # chain integrity: children link to the root and to each other
    assert all(t["parent_tile_id"] == root[0]["id"] for t in children)
    by_id = {t["id"]: t for t in tiles}
    assert root[0]["next_step"] in by_id
    hops = 0
    cursor = root[0]
    while cursor["next_step"] != "none":
        cursor = by_id[cursor["next_step"]]
        hops += 1
    assert hops == len(children), "next_step chain must walk every child tile"


def test_tile_svo_matches_typed_edge(store):
    _extract(store)
    for t in tile_trace(store, "P69905"):
        if t["depth_level"] == 0:
            continue
        svo = json.loads(t["svo_triple"])
        stored = store.get_edges(source=svo["s"], relation=svo["v"], target=svo["o"]) \
            or store.get_edges(source=svo["s"], target=svo["o"])
        assert stored, f"tile {t['id']} svo {svo} has no backing typed edge"
        assert t["requires"] == f"edge:{stored[0]['id']}"


def test_reextraction_writes_zero_new_tiles(store):
    _extract(store)
    n1 = len(tile_trace(store, "P69905"))
    second = _extract(store)
    assert second["peel_trace"]["tiles_written"] == 0
    assert len(tile_trace(store, "P69905")) == n1


def test_incomplete_tile_rejected(store):
    with pytest.raises(ValidationError, match="missing canonical"):
        write_tile(store, {"id": "tile:x"})
    # present-but-empty is equally a bug (the 33/37 failure mode)
    _extract(store)
    tiles = tile_trace(store, "P69905")
    hollow = dict(tiles[0])
    hollow["id"] = "tile:hollow"
    hollow["sentence"] = "   "
    with pytest.raises(ValidationError, match="EMPTY canonical"):
        write_tile(store, hollow)
