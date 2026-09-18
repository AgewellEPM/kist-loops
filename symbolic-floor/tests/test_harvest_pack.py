"""Harvest-pack demo lane: pins the walker, the canonical-37 lift, the
fresh-area policy, and honesty of the counts.

A miniature pack with ALL FOUR generations is built in tmp so every
generation gets its own assertion (multi-site discipline: the importer that
handles four shapes gets four per-shape pins, not one lucky one)."""

from __future__ import annotations

import json

import pytest

from symbolic_floor.harvest_pack import (
    MAX_TILES_DEFAULT,
    import_pack,
    pack_files,
    pack_summary,
    tile_sources,
)
from symbolic_floor.peel_tiles import CANONICAL_37


def _mini_pack(tmp_path):
    pack = tmp_path / "MiniPack"
    pack.mkdir()
    (pack / "aac_First_Aid.json").write_text(json.dumps([{
        "conversation_id": "c-1",
        "topic": "First Aid",
        "initial_statement": {
            "emoji": "🩹", "words": "Press the wound",
            "sentence": "Press firmly on the wound with clean cloth.",
            "verb": "press", "intent": "instruct", "confidence_score": 0.9,
        },
        "response_branches": [
            {"aac_response": {"emoji": "🙋", "words": "It hurts",
                              "sentence": "It hurts when I press."}},
        ],
    }]))
    (pack / "tree_Meals.json").write_text(json.dumps([{
        "conversation_id": "c-2",
        "topic": "Meals",
        "question": {"sentence": "What would you like to eat?"},
        "branches": [{"answer": {"sentence": "I want soup please."}}],
    }]))
    (pack / "Pain_golden_tree.json").write_text(json.dumps({
        "conversation_id": "c-3",
        "topic": "Pain",
        "root": {"role": "doctor", "meaning": "pain severity",
                 "sentence": "How bad is the pain?"},
        "branches": [{"patient": {"role": "patient",
                                  "sentence": "It is very bad."}}],
    }))
    (pack / "conversations.jsonl").write_text(json.dumps({
        "question": "Why is the sky blue?",
        "naive_answer": "Because it reflects the ocean.",
        "correction": "Rayleigh scattering favors blue light.",
    }) + "\n")
    return pack


# ---------------------------------------------------------------- discovery

def test_summary_counts_every_generation(tmp_path):
    summary = pack_summary(_mini_pack(tmp_path))
    assert summary == {"pack": "MiniPack", "files": 4, "generations": {
        "aac": 1, "tree": 1, "golden_tree": 1, "conversations": 1}}


def test_pack_files_are_stable_and_unique(tmp_path):
    files = pack_files(_mini_pack(tmp_path))
    assert len(files) == len(set(files)) == 4


# ---------------------------------------------------------------- walker

def test_walker_finds_sentences_with_depths(tmp_path):
    record = {"topic": "t",
              "question": {"sentence": "root?"},
              "branches": [{"answer": {"sentence": "child."},
                            "continuation": [{"sentence": "grandchild."}]}]}
    found = tile_sources(record)
    assert [(d, s["sentence"]) for _, d, s in found] == [
        (0, "root?"), (0, "child."), (0, "grandchild.")]
    # nested sentence-bearing dicts DO deepen:
    nested = {"question": {"sentence": "root?",
                           "follow": {"sentence": "nested."}}}
    assert [(d, s["sentence"]) for _, d, s in tile_sources(nested)] == [
        (0, "root?"), (1, "nested.")]


# ---------------------------------------------------------------- import

def test_import_writes_full_tiles_for_every_generation(store, tmp_path):
    result = import_pack(store, _mini_pack(tmp_path))
    assert result["errors"] == []
    assert result["files_by_generation"] == {
        "aac": 1, "tree": 1, "golden_tree": 1, "conversations": 1}
    # 2 aac + 2 tree + 2 golden + 3 conversation sentences
    assert result["tiles_written"] == 9
    rows = store.db.execute("SELECT * FROM responses").fetchall()
    assert len(rows) == 9
    for row in rows:  # 37/37: no canonical field empty on ANY written tile
        for field in CANONICAL_37:
            value = row[field]
            assert value is not None and str(value).strip() != "", \
                f"tile {row['id']} field {field} empty"
    # one per-generation topic pin each — the four shapes all landed:
    topics = {r["topic"] for r in rows}
    assert {"First Aid", "Meals", "Pain", "conversations"} <= topics


def test_source_fields_pass_through_verbatim(store, tmp_path):
    import_pack(store, _mini_pack(tmp_path))
    row = store.db.execute(
        "SELECT * FROM responses WHERE sentence = ?",
        ("Press firmly on the wound with clean cloth.",)).fetchone()
    assert row["emoji"] == "🩹"
    assert row["words"] == "Press the wound"
    assert row["verb"] == "press"
    assert row["intent"] == "instruct"
    assert row["confidence_score"] == 0.9
    assert row["visual_aids"] == "aac_First_Aid.json"          # the receipt
    assert row["conversation_id"].startswith("demo:MiniPack:")  # the receipt


def test_sibling_tiles_chain_both_ways(store, tmp_path):
    import_pack(store, _mini_pack(tmp_path))
    root = store.db.execute(
        "SELECT * FROM responses WHERE sentence = ?",
        ("How bad is the pain?",)).fetchone()
    child = store.db.execute(
        "SELECT * FROM responses WHERE sentence = ?",
        ("It is very bad.",)).fetchone()
    assert root["next_step"] == child["id"]
    assert child["previous_step"] == root["id"]
    assert root["previous_step"] == "none"
    assert child["next_step"] == "none"


def test_two_records_in_one_file_never_collide(store, tmp_path):
    """Regression: the walker's json paths restart per record, so the record
    index must be part of the tile id — the Education pack (300 conversations
    per file, identical structure) collided 16k of 20k tiles without it."""
    pack = tmp_path / "TwinPack"
    pack.mkdir()
    (pack / "aac_Twins.json").write_text(json.dumps([
        {"topic": "Twins", "initial_statement": {"sentence": "First twin."}},
        {"topic": "Twins", "initial_statement": {"sentence": "Second twin."}},
    ]))
    result = import_pack(store, pack)
    assert result["tiles_written"] == 2
    assert result["tiles_already_present"] == 0
    sentences = {r["sentence"] for r in
                 store.db.execute("SELECT sentence FROM responses")}
    assert sentences == {"First twin.", "Second twin."}


def test_reimport_is_idempotent(store, tmp_path):
    pack = _mini_pack(tmp_path)
    first = import_pack(store, pack)
    second = import_pack(store, pack)
    assert first["tiles_written"] == 9
    assert second["tiles_written"] == 0
    assert second["tiles_already_present"] == 9
    assert store.db.execute(
        "SELECT count(*) FROM responses").fetchone()[0] == 9


def test_bad_json_is_reported_not_fatal(store, tmp_path):
    pack = _mini_pack(tmp_path)
    (pack / "aac_Broken.json").write_text("{not json")
    result = import_pack(store, pack)
    assert result["tiles_written"] == 9  # the good files still landed
    assert [e["file"] for e in result["errors"]] == ["aac_Broken.json"]


def test_caps_are_reported_never_silent(store, tmp_path):
    pack = _mini_pack(tmp_path)
    capped = import_pack(store, pack, max_files=1)
    assert capped["hit_file_cap"] is True
    assert capped["files_total"] == 4
    assert capped["files_processed"] == 1

    tiled = import_pack(store, pack, max_tiles=1)
    assert tiled["hit_tile_cap"] is True
    assert tiled["tile_cap"] == 1


# ---------------------------------------------------------------- demo policy
# (the dashboard lane: allowlist, fresh-area-only, cleanup on failure)

def _lane(tmp_path, monkeypatch):
    from dashboard import server
    monkeypatch.setattr(server, "HARVEST_ROOT", tmp_path)
    monkeypatch.setattr(server, "DATA_DIR", tmp_path / "data")
    (tmp_path / "data").mkdir(exist_ok=True)
    return server


def test_demo_import_creates_fresh_db_and_refuses_existing(tmp_path, monkeypatch):
    server = _lane(tmp_path, monkeypatch)
    _mini_pack(tmp_path)
    result = server.demo_import("MiniPack", "demo_mini")
    assert result["created"] == "demo_mini.db"
    assert result["tiles_written"] == 9
    assert (tmp_path / "data" / "demo_mini.db").is_file()
    with pytest.raises(ValueError, match="completely new"):
        server.demo_import("MiniPack", "demo_mini")


def test_demo_import_refuses_escapes_and_unknown_packs(tmp_path, monkeypatch):
    server = _lane(tmp_path, monkeypatch)
    with pytest.raises(ValueError, match="bad pack name"):
        server.demo_import("../evil", "demo_x")
    with pytest.raises(ValueError, match="no such pack"):
        server.demo_import("Nonexistent", "demo_x")
    with pytest.raises(ValueError, match="mind name"):
        _mini_pack(tmp_path) and None
        server.demo_import("MiniPack", "Bad Name!")
    assert not (tmp_path / "data" / "demo_x.db").exists()


def test_demo_packs_lists_only_real_packs(tmp_path, monkeypatch):
    server = _lane(tmp_path, monkeypatch)
    _mini_pack(tmp_path)
    (tmp_path / "EmptyDir").mkdir()
    (tmp_path / ".hidden").mkdir()
    listing = server.demo_packs()
    assert [p["pack"] for p in listing["packs"]] == ["MiniPack"]
    assert listing["enumerable"] is True


def test_probe_answers_directly_and_feeds_the_registry(tmp_path, monkeypatch):
    server = _lane(tmp_path, monkeypatch)
    _mini_pack(tmp_path)
    assert server._probe_pack("Nope") is None
    with pytest.raises(ValueError, match="bad pack name"):
        server._probe_pack("../evil")
    probed = server._probe_pack("MiniPack")
    assert probed["files"] == 4
    assert server._seen_packs() == ["MiniPack"]


def test_demo_packs_falls_back_to_registry_when_root_wont_enumerate(
        tmp_path, monkeypatch):
    """The Harvest root on this Mac EINTRs persistently while the harvester
    churns it; the lane must then serve every registered pack via direct
    probes and say enumerable=false — never a silent blank."""
    server = _lane(tmp_path, monkeypatch)
    _mini_pack(tmp_path)
    server._probe_pack("MiniPack")  # registry now knows it

    class RootThatWontList(type(tmp_path)):  # concrete Path flavor
        def iterdir(self):
            raise InterruptedError(4, "Interrupted system call")

    monkeypatch.setattr(server, "HARVEST_ROOT", RootThatWontList(tmp_path))
    listing = server.demo_packs()
    assert listing["enumerable"] is False
    assert [p["pack"] for p in listing["packs"]] == ["MiniPack"]
