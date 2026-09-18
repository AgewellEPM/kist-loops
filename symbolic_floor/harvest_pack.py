"""Harvest-pack demo lane: import a Desktop Harvest pack into a floor DB.

A "pack" is one directory of harvested AAC content in any of the known
generations (all four appear in ~/Desktop/Harvest today):

  aac_*.json            [{topic, initial_statement{...}, response_branches:[{aac_response{...}}]}]
  tree_*.json           [{topic, question{...}, branches:[{answer{...}, continuation:[...]}]}]
  *_golden_tree.json    {topic, root{role, meaning, sentence, ...}, branches:[{patient{...}, ...}]}
  conversations.jsonl   one {question, naive_answer, correction, ...} per line

The generations disagree about structure but agree about one thing: a tile
source is a dict carrying a non-empty "sentence". The walker exploits exactly
that — it finds every sentence-bearing dict in document order, remembers its
JSON path and nesting depth, and the normalizer lifts each one to a full
canonical-37 tile (37/37 or nothing; peel_tiles.write_tile enforces it).

Honesty rules:
  - fields present in the source pass through VERBATIM;
  - missing canonical fields get deterministic scaffolding (same precedent as
    peel_tiles._base_tile) — never fabricated content, only neutral defaults;
  - every tile's conversation_id carries pack + file (the receipt), and
    visual_aids falls back to the source filename;
  - tile ids are content-addressed over (pack, file, json-path), so
    re-importing the same pack is idempotent: 0 new tiles.

This module is mechanism only: it walks a directory it is GIVEN and writes
through a Store it is GIVEN. Policy (allowlisted root, fresh-DB-only rule,
caps) lives in the dashboard lane that calls it.
"""

from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path

from .peel_tiles import CANONICAL_37, write_tile
from .schema import ValidationError

# Caps are demo-lane bounds, reported to the caller — never silent truncation.
# The tile cap is sized to swallow a full real pack (Education ≈ 250k tiles);
# it exists to bound a runaway import, not to clip a normal one.
MAX_FILES_DEFAULT = 400
MAX_TILES_DEFAULT = 300_000


def eintr_retry(fn, attempts: int = 6, delay: float = 0.25):
    """This Mac interrupts directory scans under heavy training I/O —
    InterruptedError escapes even post-PEP-475 when scandir dies
    mid-iteration. A blip must not fail a whole import: retry a bounded
    number of times, then raise honestly."""
    for i in range(attempts):
        try:
            return fn()
        except InterruptedError:
            if i == attempts - 1:
                raise
            time.sleep(delay)

_GENERATIONS = (
    ("aac", "aac_*.json"),
    ("tree", "tree_*.json"),
    ("golden_tree", "*_golden_tree.json"),
    ("conversations", "conversations.jsonl"),
)


# ---------------------------------------------------------------- discovery

def pack_summary(pack_dir: Path) -> dict:
    """Filename-level look at one pack: which generations, how many files.
    No content reads — this backs a listing endpoint and must stay cheap."""
    counts = {}
    total = 0
    for label, pattern in _GENERATIONS:
        n = len(eintr_retry(lambda p=pattern: list(pack_dir.glob(p))))
        if n:
            counts[label] = n
            total += n
    return {"pack": pack_dir.name, "files": total, "generations": counts}


def pack_files(pack_dir: Path) -> list[Path]:
    """Every importable file in a stable order (generation, then name)."""
    seen: set[Path] = set()
    ordered: list[Path] = []
    for _, pattern in _GENERATIONS:
        for p in sorted(eintr_retry(lambda pt=pattern: list(pack_dir.glob(pt)))):
            if p not in seen:
                seen.add(p)
                ordered.append(p)
    return ordered


# ---------------------------------------------------------------- walking

def tile_sources(record) -> list[tuple[str, int, dict]]:
    """Every sentence-bearing dict in `record`, in document order, as
    (json_path, depth, source_dict). Depth counts sentence-bearing ANCESTORS,
    so a root statement is 0 and its response branches are 1, matching how
    the generations actually nest."""
    found: list[tuple[str, int, dict]] = []

    def walk(node, path: str, depth: int) -> None:
        if isinstance(node, dict):
            here = depth
            if str(node.get("sentence") or "").strip():
                found.append((path, depth, node))
                here = depth + 1
            for key, value in node.items():
                walk(value, f"{path}/{key}", here)
        elif isinstance(node, list):
            for i, value in enumerate(node):
                walk(value, f"{path}/{i}", depth)

    walk(record, "", 0)
    return found


def conversation_records(path: Path) -> list[dict]:
    """Parse one pack file into conversation records. conversations.jsonl
    lines carry bare Q/A text, so they are lifted into sentence-bearing
    dicts here; JSON files are returned as-is (list or single dict)."""
    if path.name.endswith(".jsonl"):
        records = []
        text = eintr_retry(lambda: path.read_text(encoding="utf-8"))
        for line in text.splitlines():
            line = line.strip()
            if line:
                raw = json.loads(line)
                lifted = {"topic": str(raw.get("topic") or path.stem)}
                for role in ("question", "naive_answer", "correction",
                             "alternative_explanation"):
                    value = str(raw.get(role) or "").strip()
                    if value:
                        lifted[role] = {"sentence": value, "verb": "say",
                                        "action": role.replace("_", " "),
                                        "intent": "ask" if role == "question"
                                        else "respond"}
                if [k for k in lifted if k != "topic"]:
                    records.append(lifted)
        return records
    data = json.loads(eintr_retry(lambda: path.read_text(encoding="utf-8")))
    if isinstance(data, dict):
        return [data]
    if isinstance(data, list):
        return [r for r in data if isinstance(r, dict)]
    raise ValidationError(f"{path.name}: expected object or list at top level")


# ---------------------------------------------------------------- normalize

def _demo_tile_id(pack: str, file_name: str, json_path: str) -> str:
    """Content-addressed over the source coordinates — same file+path never
    duplicates, and pack ids (which collide across files) are never trusted."""
    digest = hashlib.sha256(f"{pack}|{file_name}|{json_path}".encode()).hexdigest()
    return f"tile:{digest[:32]}"


def _first_words(sentence: str, n: int = 3) -> str:
    return " ".join(sentence.split()[:n])


def normalize_tile(src: dict, *, pack: str, file_name: str, json_path: str,
                   topic: str, conversation_id: str, depth: int, turn: int,
                   parent_tile_id: str) -> dict:
    """Lift one sentence-bearing source dict to a full canonical-37 tile.
    Source fields pass through verbatim; gaps get neutral deterministic
    scaffolding (peel_tiles._base_tile precedent), never invented content."""
    sentence = str(src["sentence"]).strip()
    role = str(src.get("role") or "").strip()
    scaffold = {
        "id": _demo_tile_id(pack, file_name, json_path),
        "conversation_id": conversation_id,
        "emoji": "🗂️",
        "words": _first_words(sentence),
        "sentence": sentence,
        "verb": "share",
        "action": "sharing harvested content",
        "intent": "share",
        "emotion": "neutral",
        "visual_representation": f"text tile: {_first_words(sentence, 5)}",
        "entities": json.dumps([topic]),
        "svo_triple": json.dumps({"s": role or f"harvest:{pack}",
                                  "v": "states", "o": _first_words(sentence)}),
        "complexity_level": "medium",
        "reading_level": "grade-5",
        "speech_pattern": "declarative",
        "cognitive_load": "low",
        "confidence_score": 1.0,
        "learning_objective": f"communicate about {topic}",
        "prerequisites": json.dumps([]),
        "follow_up_suggestions": json.dumps([]),
        "audio_tts_hints": "plain",
        "visual_aids": file_name,
        "pet_motion": "idle",
        "parent": f"harvest:{pack}",
        "subcategory": topic,
        "related_to": "none",
        "causes": "none",
        "requires": "none",
        "part_of": f"harvest:{pack}",
        "next_step": "none",
        "previous_step": "none",
        "connectors": json.dumps([]),
        "depth_level": depth,
        "parent_tile_id": parent_tile_id,
        "branch_path": json_path or "/root",
        "turn_number": turn,
        "topic": topic,
    }
    tile = dict(scaffold)
    for field in CANONICAL_37:
        if field in ("id", "conversation_id", "depth_level", "parent_tile_id",
                     "branch_path", "turn_number", "topic"):
            continue  # coordinates are OURS — pack ids collide across files
        value = src.get(field)
        if value is None:
            continue
        if isinstance(value, (list, dict)):
            tile[field] = json.dumps(value, ensure_ascii=False)
        elif isinstance(value, (int, float)) or str(value).strip():
            tile[field] = value
    return tile


# ---------------------------------------------------------------- importing

def import_pack(store, pack_dir: Path, *, max_files: int = MAX_FILES_DEFAULT,
                max_tiles: int = MAX_TILES_DEFAULT) -> dict:
    """Walk one pack directory and write every discovered tile through the
    given Store. Returns honest counts: written, skipped (already present),
    per-generation files, caps hit, and per-file errors (bad JSON never
    aborts the whole import — it is reported instead)."""
    files = pack_files(pack_dir)
    capped_files = files[:max_files]
    generation_of = {p: label for label, pattern in _GENERATIONS
                     for p in eintr_retry(lambda pt=pattern:
                                          list(pack_dir.glob(pt)))}
    written = skipped = 0
    tiles_seen = 0
    errors: list[dict] = []
    file_counts: dict[str, int] = {}
    hit_tile_cap = False

    for path in capped_files:
        generation = generation_of.get(path, "aac")
        file_counts[generation] = file_counts.get(generation, 0) + 1
        try:
            records = conversation_records(path)
        except (ValueError, ValidationError) as e:  # bad JSON: report, continue
            errors.append({"file": path.name, "error": str(e)})
            continue
        for r_index, record in enumerate(records):
            topic = str(record.get("topic") or path.stem).strip() or path.stem
            conversation_id = (f"demo:{pack_dir.name}:{path.name}:"
                               f"{record.get('conversation_id') or r_index}")
            sources = tile_sources(record)
            if tiles_seen + len(sources) > max_tiles:
                sources = sources[:max(0, max_tiles - tiles_seen)]
                hit_tile_cap = True
            tiles_seen += len(sources)
            # Normalize the whole record first so next/previous chain BOTH ways
            # (write-as-you-go can never know the next tile's id).
            parent_by_depth = {-1: "root"}
            tiles: list[dict] = []
            for turn, (json_path, depth, src) in enumerate(sources):
                tile = normalize_tile(
                    src, pack=pack_dir.name, file_name=path.name,
                    # record index in the coordinates: two conversations in one
                    # file share json paths, and same-path tiles MUST NOT collide
                    json_path=f"{path.name}#{r_index}{json_path}", topic=topic,
                    conversation_id=conversation_id, depth=depth, turn=turn,
                    parent_tile_id=parent_by_depth.get(depth - 1, "root"))
                parent_by_depth[depth] = tile["id"]
                tiles.append(tile)
            for i, tile in enumerate(tiles):
                if i > 0:
                    tile["previous_step"] = tiles[i - 1]["id"]
                if i + 1 < len(tiles):
                    tile["next_step"] = tiles[i + 1]["id"]
            for tile in tiles:
                try:
                    _, is_new = write_tile(store, tile)
                except ValidationError as e:
                    errors.append({"file": path.name,
                                   "path": tile["branch_path"],
                                   "error": str(e)})
                    continue
                written += 1 if is_new else 0
                skipped += 0 if is_new else 1
            if hit_tile_cap:
                break
        if hit_tile_cap:
            break

    return {
        "pack": pack_dir.name,
        "files_total": len(files),
        "files_processed": len(capped_files) if not hit_tile_cap else
        sum(file_counts.values()),
        "files_by_generation": file_counts,
        "file_cap": max_files,
        "tile_cap": max_tiles,
        "hit_file_cap": len(files) > len(capped_files),
        "hit_tile_cap": hit_tile_cap,
        "tiles_written": written,
        "tiles_already_present": skipped,
        "errors": errors,
    }
