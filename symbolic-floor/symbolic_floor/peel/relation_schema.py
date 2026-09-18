# ============================================================================
# VENDORED SNAPSHOT — Peel symbolic engine (unmodified).
#
# Source:   /Users/lukekist/jeeves/kids-brain/relation_schema.py
# Snapshot: 2026-09-17  (upstream commit 6cb0056)
# SHA-256:  22a3201cc38fe7188a46dbf358a7f3b924a144d7556d8918abcffea34163af97
#
# This file is the REAL Peel typed-relation engine running in-process (per
# Luke: the symbolic system lives INSIDE this floor, not behind an MCP). Do
# not edit — fix upstream and re-vendor. Bio relations are registered from
# symbolic_floor.peel.floor via the module-level RELATION_TYPES registry, the
# same mechanism the Perslis legacy-ops relations used.
# ============================================================================
#!/usr/bin/env python3
"""
Object-Relation Schema — Typed relational edges for the symbolic brain.

This module transforms the brain from "a pile of tiles" into "a world model"
by extracting and storing typed relationships between concepts.

Relation types:
  is_a          → Cat is_a mammal
  has_part      → Cat has_part tail
  can_do        → Cat can_do climb
  used_for      → Medicine used_for treatment
  located_in    → Hospital located_in city
  causes        → Smoking causes cancer
  prevents      → Vaccine prevents disease
  requires      → Surgery requires anesthesia
  produces      → Photosynthesis produces oxygen
  contains      → Cell contains nucleus
  belongs_to    → Doctor belongs_to hospital
  differs_from  → Cat differs_from dog
  similar_to    → Guitar similar_to ukulele
  affects       → Diabetes affects blood_sugar
  created_by    → Painting created_by artist
  occurred_in   → Revolution occurred_in 1789
  enables       → Oxygen enables combustion
  opposes       → Democracy opposes dictatorship
  precedes      → Egg precedes chicken (or not)
  follows       → Treatment follows diagnosis
  part_of       → Wheel part_of car
  instance_of   → Fido instance_of dog
  transforms    → Caterpillar transforms butterfly

Capabilities:
  1. Extract typed relations from existing tiles (sentence parsing)
  2. Store in typed edge table with confidence + source lineage
  3. Detect contradictions (cat is_a reptile vs cat is_a mammal)
  4. Infer missing links (A→B + B→C = A→?→C)
  5. Transfer knowledge across domains
  6. Query by relation type
  7. Explain reasoning chains
"""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import uuid
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set, Tuple


# =========================================================================
# RELATION TYPES — the vocabulary of the world model
# =========================================================================

RELATION_TYPES = {
    # Taxonomic
    "is_a":         {"inverse": "has_instance",  "transitive": True,  "category": "taxonomic"},
    "instance_of":  {"inverse": "has_instance",  "transitive": False, "category": "taxonomic"},
    "subtype_of":   {"inverse": "has_subtype",   "transitive": True,  "category": "taxonomic"},

    # Structural
    "has_part":     {"inverse": "part_of",       "transitive": False, "category": "structural"},
    "part_of":      {"inverse": "has_part",      "transitive": True,  "category": "structural"},
    "contains":     {"inverse": "contained_in",  "transitive": False, "category": "structural"},
    "belongs_to":   {"inverse": "has_member",    "transitive": False, "category": "structural"},

    # Causal
    "causes":       {"inverse": "caused_by",     "transitive": True,  "category": "causal"},
    "prevents":     {"inverse": "prevented_by",  "transitive": False, "category": "causal"},
    "enables":      {"inverse": "enabled_by",    "transitive": False, "category": "causal"},
    "affects":      {"inverse": "affected_by",   "transitive": False, "category": "causal"},
    "produces":     {"inverse": "produced_by",   "transitive": False, "category": "causal"},
    "requires":     {"inverse": "required_by",   "transitive": False, "category": "causal"},

    # Functional
    "used_for":     {"inverse": "uses",          "transitive": False, "category": "functional"},
    "can_do":       {"inverse": "done_by",       "transitive": False, "category": "functional"},
    "transforms":   {"inverse": "transformed_from", "transitive": False, "category": "functional"},

    # Spatial/Temporal
    "located_in":   {"inverse": "location_of",   "transitive": True,  "category": "spatial"},
    "occurred_in":  {"inverse": "event_of",      "transitive": False, "category": "temporal"},
    "precedes":     {"inverse": "follows",       "transitive": True,  "category": "temporal"},
    "follows":      {"inverse": "precedes",      "transitive": True,  "category": "temporal"},

    # Comparative
    "similar_to":   {"inverse": "similar_to",    "transitive": False, "category": "comparative"},
    "differs_from": {"inverse": "differs_from",  "transitive": False, "category": "comparative"},
    "opposes":      {"inverse": "opposes",       "transitive": False, "category": "comparative"},

    # Attribution
    "created_by":   {"inverse": "created",       "transitive": False, "category": "attribution"},
    "known_for":    {"inverse": "associated_with", "transitive": False, "category": "attribution"},

    # Medical/Functional (added)
    "treats":       {"inverse": "treated_by",    "transitive": False, "category": "functional"},
    "transports_to": {"inverse": "receives_from", "transitive": False, "category": "functional"},
    "works_in":     {"inverse": "employs",       "transitive": False, "category": "functional"},
    "composed_of":  {"inverse": "component_of",  "transitive": False, "category": "structural"},

    # Legacy-systems operational (Perslis). "functional": True means a subject has
    # AT MOST ONE object for this relation (OWL FunctionalProperty), so a differing
    # object is a hard contradiction. This handles OPEN object domains — byte sizes,
    # code meanings — that a fixed mutually-exclusive set cannot enumerate. Existing
    # relations have no "functional" key (-> falsy), so their behavior is unchanged.
    "means":        {"inverse": "meaning_of",   "transitive": False, "category": "definitional",  "functional": True},
    "packs_to":     {"inverse": "packed_from",  "transitive": False, "category": "encoding",       "functional": True},
    "class_of":     {"inverse": "has_member",   "transitive": False, "category": "taxonomic",      "functional": True},
    "caused_by":    {"inverse": "causes",       "transitive": False, "category": "causal"},
    "runs_on":      {"inverse": "hosts",        "transitive": False, "category": "compatibility"},
    "depends_on":   {"inverse": "required_by",  "transitive": False, "category": "compatibility"},
}


# =========================================================================
# EXTRACTION PATTERNS — how we detect relations in natural language
# =========================================================================

EXTRACTION_PATTERNS = [
    # is_a: "X is a Y", "X is an Y", "X are Y"
    (r"^(.+?)\s+(?:is|are)\s+(?:a|an)\s+(.+?)[\.,;]?\s*$", "is_a"),
    (r"^(.+?)\s+(?:is|are)\s+(?:a|an)\s+type of\s+(.+?)[\.,;]?\s*$", "subtype_of"),

    # Legacy-ops (Perslis) surface forms: functional definitional/encoding +
    # compatibility. Placed early so "X packs to Y" / "X means Y" beat generic
    # verbs. Compound sentences still need upstream segmentation (a known gap).
    (r"^(.+?)\s+packs?\s+(?:to|into)\s+(.+?)[\.,;]?\s*$", "packs_to"),
    (r"^(.+?)\s+means?\s+(.+?)[\.,;]?\s*$", "means"),
    (r"^(.+?)\s+denotes?\s+(.+?)[\.,;]?\s*$", "means"),
    (r"^(.+?)\s+runs?\s+on\s+(.+?)[\.,;]?\s*$", "runs_on"),
    (r"^(.+?)\s+(?:is\s+)?caused\s+by\s+(.+?)[\.,;]?\s*$", "caused_by"),

    # has_part: "X has Y", "X contains Y", "X consists of Y"
    (r"^(.+?)\s+(?:has|have)\s+(.+?)[\.,;]?\s*$", "has_part"),
    (r"^(.+?)\s+contains?\s+(.+?)[\.,;]?\s*$", "contains"),
    (r"^(.+?)\s+consists?\s+of\s+(.+?)[\.,;]?\s*$", "has_part"),
    (r"^(.+?)\s+includes?\s+(.+?)[\.,;]?\s*$", "contains"),

    # part_of: "X is part of Y", "X belongs to Y"
    (r"^(.+?)\s+is\s+part\s+of\s+(.+?)[\.,;]?\s*$", "part_of"),
    (r"^(.+?)\s+belongs?\s+to\s+(.+?)[\.,;]?\s*$", "belongs_to"),

    # causes: "X causes Y", "X leads to Y", "X results in Y"
    (r"^(.+?)\s+causes?\s+(.+?)[\.,;]?\s*$", "causes"),
    (r"^(.+?)\s+leads?\s+to\s+(.+?)[\.,;]?\s*$", "causes"),
    (r"^(.+?)\s+results?\s+in\s+(.+?)[\.,;]?\s*$", "causes"),

    # prevents: "X prevents Y", "X stops Y"
    (r"^(.+?)\s+prevents?\s+(.+?)[\.,;]?\s*$", "prevents"),
    (r"^(.+?)\s+protects?\s+against\s+(.+?)[\.,;]?\s*$", "prevents"),

    # enables: "X enables Y", "X allows Y"
    (r"^(.+?)\s+enables?\s+(.+?)[\.,;]?\s*$", "enables"),
    (r"^(.+?)\s+allows?\s+(.+?)[\.,;]?\s*$", "enables"),

    # requires: "X requires Y", "X needs Y", "X depends on Y"
    (r"^(.+?)\s+requires?\s+(.+?)[\.,;]?\s*$", "requires"),
    (r"^(.+?)\s+needs?\s+(.+?)[\.,;]?\s*$", "requires"),
    (r"^(.+?)\s+depends?\s+on\s+(.+?)[\.,;]?\s*$", "requires"),

    # produces: "X produces Y", "X generates Y", "X creates Y"
    (r"^(.+?)\s+produces?\s+(.+?)[\.,;]?\s*$", "produces"),
    (r"^(.+?)\s+generates?\s+(.+?)[\.,;]?\s*$", "produces"),
    (r"^(.+?)\s+creates?\s+(.+?)[\.,;]?\s*$", "produces"),

    # used_for: "X is used for Y", "X is used to Y"
    (r"^(.+?)\s+is\s+used\s+(?:for|to)\s+(.+?)[\.,;]?\s*$", "used_for"),

    # can_do: "X can Y"
    (r"^(.+?)\s+can\s+(.+?)[\.,;]?\s*$", "can_do"),

    # located_in: "X is located in Y", "X is found in Y", "X is in Y"
    (r"^(.+?)\s+is\s+(?:located|found|situated)\s+in\s+(.+?)[\.,;]?\s*$", "located_in"),

    # created_by: "X was created by Y", "X was invented by Y", "X was founded by Y"
    (r"^(.+?)\s+was\s+(?:created|invented|founded|discovered|written)\s+by\s+(.+?)[\.,;]?\s*$", "created_by"),

    # occurred_in: "X occurred in Y", "X happened in Y", "X began in Y"
    (r"^(.+?)\s+(?:occurred|happened|began|started|ended)\s+in\s+(\d{3,4})\b", "occurred_in"),

    # known_for: "X is known for Y", "X is famous for Y"
    (r"^(.+?)\s+is\s+(?:known|famous|renowned)\s+for\s+(.+?)[\.,;]?\s*$", "known_for"),

    # transforms: "X transforms into Y", "X becomes Y"
    (r"^(.+?)\s+(?:transforms?|turns?|converts?)\s+into\s+(.+?)[\.,;]?\s*$", "transforms"),
    (r"^(.+?)\s+becomes?\s+(.+?)[\.,;]?\s*$", "transforms"),

    # affects: "X affects Y", "X influences Y", "X impacts Y"
    (r"^(.+?)\s+(?:affects?|influences?|impacts?)\s+(.+?)[\.,;]?\s*$", "affects"),

    # similar_to: "X is similar to Y", "X resembles Y"
    (r"^(.+?)\s+is\s+similar\s+to\s+(.+?)[\.,;]?\s*$", "similar_to"),
    (r"^(.+?)\s+resembles?\s+(.+?)[\.,;]?\s*$", "similar_to"),

    # differs_from: "X differs from Y", "X is different from Y"
    (r"^(.+?)\s+(?:differs?|is\s+different)\s+from\s+(.+?)[\.,;]?\s*$", "differs_from"),

    # opposes: "X opposes Y", "X contradicts Y", "X is the opposite of Y"
    (r"^(.+?)\s+(?:opposes?|contradicts?)\s+(.+?)[\.,;]?\s*$", "opposes"),
    (r"^(.+?)\s+is\s+the\s+opposite\s+of\s+(.+?)[\.,;]?\s*$", "opposes"),

    # treats: "X treats Y", "X is used to treat Y"
    (r"^(.+?)\s+treats?\s+(.+?)[\.,;]?\s*$", "treats"),
    (r"^(.+?)\s+is\s+used\s+to\s+treat\s+(.+?)[\.,;]?\s*$", "treats"),

    # transports_to: "X transports to Y", "X delivers to Y", "X carries to Y"
    (r"^(.+?)\s+(?:transports?|delivers?|carries?)\s+to\s+(.+?)[\.,;]?\s*$", "transports_to"),

    # works_in: "X works in Y", "X is employed in/at Y"
    (r"^(.+?)\s+works?\s+in\s+(.+?)[\.,;]?\s*$", "works_in"),
    (r"^(.+?)\s+is\s+employed\s+(?:in|at)\s+(.+?)[\.,;]?\s*$", "works_in"),

    # composed_of: "X is composed of Y", "X is made of Y", "X is built from Y"
    (r"^(.+?)\s+is\s+(?:composed|made|comprised)\s+of\s+(.+?)[\.,;]?\s*$", "composed_of"),
    (r"^(.+?)\s+is\s+built\s+from\s+(.+?)[\.,;]?\s*$", "composed_of"),
]

# Compile patterns once
COMPILED_PATTERNS = [(re.compile(p, re.IGNORECASE), rel) for p, rel in EXTRACTION_PATTERNS]


# =========================================================================
# DATA STRUCTURES
# =========================================================================

@dataclass
class Relation:
    subject: str
    relation_type: str
    object: str
    confidence: float = 0.8
    source_tile_id: str = ""
    source_sentence: str = ""
    topic: str = ""


@dataclass
class Contradiction:
    subject: str
    relation_a: str
    object_a: str
    relation_b: str
    object_b: str
    explanation: str
    tile_a_id: str = ""
    tile_b_id: str = ""


@dataclass
class InferredLink:
    subject: str
    relation_type: str
    object: str
    via: str
    chain: List[Tuple[str, str, str]]  # [(subject, relation, object), ...]
    confidence: float = 0.6
    explanation: str = ""


# =========================================================================
# RELATION SCHEMA ENGINE
# =========================================================================

class RelationSchemaEngine:
    """Typed relational reasoning engine for the symbolic brain."""

    def __init__(self, db_path: str):
        self.db_path = db_path
        self.db = sqlite3.connect(db_path)
        self.db.row_factory = sqlite3.Row
        self._ensure_tables()

    def _ensure_tables(self):
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS typed_relations (
                id TEXT PRIMARY KEY,
                subject TEXT NOT NULL,
                relation_type TEXT NOT NULL,
                object TEXT NOT NULL,
                confidence REAL DEFAULT 0.8,
                source_tile_id TEXT,
                source_sentence TEXT,
                topic TEXT,
                category TEXT,
                is_inferred INTEGER DEFAULT 0,
                inference_chain TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                hash TEXT UNIQUE
            );

            CREATE INDEX IF NOT EXISTS idx_typed_rel_subject ON typed_relations(subject);
            CREATE INDEX IF NOT EXISTS idx_typed_rel_object ON typed_relations(object);
            CREATE INDEX IF NOT EXISTS idx_typed_rel_type ON typed_relations(relation_type);
            CREATE INDEX IF NOT EXISTS idx_typed_rel_topic ON typed_relations(topic);

            CREATE TABLE IF NOT EXISTS contradictions (
                id TEXT PRIMARY KEY,
                subject TEXT NOT NULL,
                relation_a TEXT NOT NULL,
                object_a TEXT NOT NULL,
                tile_a_id TEXT,
                relation_b TEXT NOT NULL,
                object_b TEXT NOT NULL,
                tile_b_id TEXT,
                explanation TEXT,
                resolved INTEGER DEFAULT 0,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );

            CREATE TABLE IF NOT EXISTS inferred_links (
                id TEXT PRIMARY KEY,
                subject TEXT NOT NULL,
                relation_type TEXT NOT NULL,
                object TEXT NOT NULL,
                via TEXT,
                chain TEXT,
                confidence REAL DEFAULT 0.6,
                explanation TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
        """)
        self.db.commit()

    # =========================================================================
    # 1. EXTRACTION — Pull typed relations from existing tiles
    # =========================================================================

    def extract_from_tiles(self, limit: int = 10000) -> int:
        """Extract typed relations from tile sentences using pattern matching."""
        print("🔍 Extracting typed relations from tiles...")

        rows = self.db.execute("""
            SELECT id, sentence, topic, entities, svo_triple,
                   related_to, causes, requires, part_of
            FROM responses
            WHERE sentence IS NOT NULL AND TRIM(sentence) != ''
            AND source_file IN ('facts_generator.py', 'harvest_import', 'self_growth_engine', 'brain_growth')
            LIMIT ?
        """, (limit,)).fetchall()

        extracted = 0
        for row in rows:
            # Method 1: Pattern matching on sentences
            relations = self._extract_from_sentence(
                row['sentence'], row['id'], row['topic']
            )

            # Method 2: Extract from PEEL relationship fields
            relations += self._extract_from_fields(row)

            # Method 3: Extract from SVO triples
            if row['svo_triple']:
                relations += self._extract_from_svo(
                    row['svo_triple'], row['id'], row['topic']
                )

            for rel in relations:
                if self._store_relation(rel):
                    extracted += 1

        self.db.commit()
        print(f"   Extracted {extracted} typed relations")
        return extracted

    def _extract_from_sentence(self, sentence: str, tile_id: str, topic: str) -> List[Relation]:
        """
        HIGH-PRECISION MODE: Only extract when explicit, strong linguistic patterns exist.
        Reject fuzzy/implied relations. Aim for 80%+ accuracy over volume.
        """
        relations = []
        sentence = sentence.strip()
        s_lower = sentence.lower()

        # REJECT: first-person, questions, conversational
        if s_lower.endswith('?'):
            return []
        if any(s_lower.startswith(p) for p in ['i ', "i'm ", 'my ', 'we ', 'you ', 'let']):
            return []
        if any(p in s_lower for p in ["that's ", "wow", "cool", "awesome", "great"]):
            return []

        for pattern, rel_type in COMPILED_PATTERNS:
            match = pattern.match(sentence)
            if match:
                subject = self._clean_concept(match.group(1))
                obj = self._clean_concept(match.group(2))

                if not subject or not obj or len(subject) < 2 or len(obj) < 2:
                    continue
                if len(subject) > 50 or len(obj) > 50:
                    continue

                # HIGH-PRECISION FILTER: reject weak extractions
                # Subject must look like a real concept (not a sentence fragment)
                if len(subject.split()) > 6:
                    continue  # Too long to be a clean concept
                if len(obj.split()) > 8:
                    continue
                # Reject if subject starts with common filler
                if any(subject.lower().startswith(p) for p in ['well', 'so', 'ok', 'yeah', 'actually']):
                    continue
                # Reject if object is too generic
                generic_objects = {'it', 'that', 'this', 'them', 'something', 'things', 'stuff', 'one'}
                if obj.lower().strip() in generic_objects:
                    continue

                relations.append(Relation(
                    subject=subject,
                    relation_type=rel_type,
                    object=obj,
                    confidence=0.85,
                    source_tile_id=tile_id,
                    source_sentence=sentence[:200],
                    topic=topic or "",
                ))

        return relations

    def _extract_from_fields(self, row) -> List[Relation]:
        """Extract relations from PEEL relationship fields.
        Records source_sentence for verifiability. Skips when topic is empty."""
        relations = []
        tile_id = str(row['id'])
        topic = (row['topic'] or '').strip()
        sentence = (row['sentence'] or '').strip()
        entities = self._parse_list(row['entities'])

        # Skip if no topic — prevents "unknown" subject pollution
        if not topic:
            return []

        # related_to field
        for item in self._parse_list(row['related_to']):
            if item and len(item) > 1:
                for entity in entities[:3]:
                    relations.append(Relation(
                        subject=entity, relation_type="similar_to",
                        object=item, confidence=0.7,
                        source_tile_id=tile_id, topic=topic,
                        source_sentence=sentence[:200],
                    ))

        # causes field
        for item in self._parse_list(row['causes']):
            if item and len(item) > 1:
                relations.append(Relation(
                    subject=topic, relation_type="causes",
                    object=item, confidence=0.75,
                    source_tile_id=tile_id, topic=topic,
                    source_sentence=sentence[:200],
                ))

        # requires field
        for item in self._parse_list(row['requires']):
            if item and len(item) > 1:
                relations.append(Relation(
                    subject=topic, relation_type="requires",
                    object=item, confidence=0.75,
                    source_tile_id=tile_id, topic=topic,
                    source_sentence=sentence[:200],
                ))

        # part_of field
        for item in self._parse_list(row['part_of']):
            if item and len(item) > 1:
                for entity in entities[:3]:
                    relations.append(Relation(
                        subject=entity, relation_type="part_of",
                        object=item, confidence=0.75,
                        source_tile_id=tile_id, topic=topic,
                        source_sentence=sentence[:200],
                    ))

        return relations

    def _extract_from_svo(self, svo_raw: str, tile_id: str, topic: str) -> List[Relation]:
        """Extract relations from SVO triples."""
        relations = []
        try:
            svo = json.loads(svo_raw) if isinstance(svo_raw, str) else svo_raw
            if isinstance(svo, dict):
                subject = self._clean_concept(svo.get('subject', ''))
                verb = (svo.get('verb', '') or '').lower().strip()
                obj = self._clean_concept(svo.get('object', ''))

                if subject and obj and verb:
                    # Map SVO verb to relation type
                    rel_type = self._verb_to_relation(verb)
                    if rel_type:
                        relations.append(Relation(
                            subject=subject, relation_type=rel_type,
                            object=obj, confidence=0.8,
                            source_tile_id=tile_id, topic=topic or "",
                        ))
        except:
            pass
        return relations

    def _verb_to_relation(self, verb: str) -> Optional[str]:
        """Map a verb to a relation type."""
        verb_map = {
            'is': 'is_a', 'are': 'is_a',
            'has': 'has_part', 'have': 'has_part',
            'contains': 'contains', 'includes': 'contains',
            'causes': 'causes', 'cause': 'causes',
            'prevents': 'prevents', 'prevent': 'prevents',
            'requires': 'requires', 'require': 'requires', 'needs': 'requires',
            'produces': 'produces', 'produce': 'produces', 'generates': 'produces',
            'enables': 'enables', 'enable': 'enables', 'allows': 'enables',
            'affects': 'affects', 'affect': 'affects', 'influences': 'affects',
            'transforms': 'transforms', 'becomes': 'transforms',
            'creates': 'produces', 'create': 'produces',
            'opposes': 'opposes', 'oppose': 'opposes',
            'resembles': 'similar_to',
            'precedes': 'precedes', 'follows': 'follows',
            'treats': 'treats', 'treat': 'treats',
            'transports': 'transports_to', 'delivers': 'transports_to',
            'works': 'works_in', 'employs': 'works_in',
            # Legacy-ops (Perslis): definitional / encoding / compatibility verbs.
            'means': 'means', 'denotes': 'means', 'signifies': 'means',
            'packs': 'packs_to', 'runs': 'runs_on', 'depends': 'depends_on',
        }
        return verb_map.get(verb)

    # =========================================================================
    # 2. STORAGE
    # =========================================================================

    def _store_relation(self, rel: Relation) -> bool:
        """Store a relation, dedup by hash."""
        rel_hash = hashlib.sha256(
            f"{rel.subject.lower()}||{rel.relation_type}||{rel.object.lower()}".encode()
        ).hexdigest()

        category = RELATION_TYPES.get(rel.relation_type, {}).get('category', 'unknown')

        try:
            self.db.execute("""
                INSERT OR IGNORE INTO typed_relations
                (id, subject, relation_type, object, confidence, source_tile_id,
                 source_sentence, topic, category, hash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                str(uuid.uuid4()), rel.subject, rel.relation_type, rel.object,
                rel.confidence, rel.source_tile_id, rel.source_sentence,
                rel.topic, category, rel_hash,
            ))
            return True
        except sqlite3.IntegrityError:
            return False

    # =========================================================================
    # 3. CONTRADICTION DETECTION
    # =========================================================================

    def detect_contradictions(self) -> List[Contradiction]:
        """Find relations that contradict each other."""
        print("⚠️  Scanning for contradictions...")

        contradictions = []

        # Rule 1: Same subject, same relation type, conflicting objects
        # e.g., "cat is_a mammal" vs "cat is_a reptile"
        conflict_types = ['is_a', 'instance_of', 'subtype_of', 'located_in']

        for rel_type in conflict_types:
            rows = self.db.execute("""
                SELECT a.subject, a.object as obj_a, a.source_tile_id as tile_a,
                       b.object as obj_b, b.source_tile_id as tile_b
                FROM typed_relations a
                JOIN typed_relations b ON a.subject = b.subject
                    AND a.relation_type = b.relation_type
                    AND a.object != b.object
                    AND a.id < b.id
                WHERE a.relation_type = ?
                AND a.confidence > 0.5 AND b.confidence > 0.5
                LIMIT 100
            """, (rel_type,)).fetchall()

            for row in rows:
                # Check if objects are truly conflicting (not just different valid values)
                if self._are_compatible(row['obj_a'], row['obj_b'], rel_type):
                    continue

                c = Contradiction(
                    subject=row['subject'],
                    relation_a=rel_type,
                    object_a=row['obj_a'],
                    relation_b=rel_type,
                    object_b=row['obj_b'],
                    explanation=f"{row['subject']} cannot be both {row['obj_a']} and {row['obj_b']}",
                    tile_a_id=row['tile_a'] or '',
                    tile_b_id=row['tile_b'] or '',
                )
                contradictions.append(c)

                # Store
                self.db.execute("""
                    INSERT OR IGNORE INTO contradictions
                    (id, subject, relation_a, object_a, tile_a_id,
                     relation_b, object_b, tile_b_id, explanation)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    str(uuid.uuid4()), c.subject,
                    c.relation_a, c.object_a, c.tile_a_id,
                    c.relation_b, c.object_b, c.tile_b_id,
                    c.explanation,
                ))

        # Rule 2: Opposites
        rows = self.db.execute("""
            SELECT a.subject, a.relation_type, a.object,
                   b.subject as subj_b, b.relation_type as rel_b, b.object as obj_b,
                   a.source_tile_id as tile_a, b.source_tile_id as tile_b
            FROM typed_relations a
            JOIN typed_relations b ON a.subject = b.subject
                AND a.relation_type = 'causes' AND b.relation_type = 'prevents'
                AND a.object = b.object
            LIMIT 50
        """).fetchall()

        for row in rows:
            c = Contradiction(
                subject=row['subject'],
                relation_a='causes', object_a=row['object'],
                relation_b='prevents', object_b=row['obj_b'],
                explanation=f"{row['subject']} cannot both cause and prevent {row['object']}",
                tile_a_id=row['tile_a'] or '',
                tile_b_id=row['tile_b'] or '',
            )
            contradictions.append(c)

        self.db.commit()
        print(f"   Found {len(contradictions)} contradictions")
        return contradictions

    def _domain_exclusive_sets(self) -> List[set]:
        """Load domain mutual-exclusivity sets from a sidecar JSON next to the DB.

        File: "<db_path>.exclusive.json" — a JSON list of lists of strings, each
        inner list one mutually-exclusive set (lowercased). Missing/invalid file
        -> [] (kids brain has none, so its reasoning is unchanged). Cached per
        engine; read-only; a malformed file is ignored, never fatal.
        """
        cached = getattr(self, "_domain_excl_cache", None)
        if cached is not None:
            return cached
        sets: List[set] = []
        try:
            import json as _json
            from pathlib import Path as _Path
            sidecar = _Path(str(self.db_path) + ".exclusive.json")
            if sidecar.is_file():
                raw = _json.loads(sidecar.read_text())
                if isinstance(raw, list):
                    for group in raw:
                        if isinstance(group, list) and len(group) >= 2:
                            sets.append({str(x).lower().strip() for x in group})
        except Exception:
            sets = []  # never let a bad sidecar break reasoning
        self._domain_excl_cache = sets
        return sets

    def _are_compatible(self, obj_a: str, obj_b: str, rel_type: str) -> bool:
        """
        Smart compatibility check — only flag REAL contradictions.
        Things CAN be multiple is_a categories (Python is_a language AND is_a topic).
        Only flag when objects are in MUTUALLY EXCLUSIVE sets.
        """
        a, b = obj_a.lower().strip(), obj_b.lower().strip()

        # Substring = always compatible
        if a in b or b in a:
            return True

        # FUNCTIONAL relation (OWL FunctionalProperty): at most one object per
        # subject, so two DIFFERENT objects are a real contradiction — no
        # exclusive-set needed. Handles open domains (byte sizes, code meanings)
        # that a fixed set can't enumerate. (a==b and substring already returned.)
        if RELATION_TYPES.get(rel_type, {}).get("functional"):
            return False

        # EXCLUSIVE CATEGORY SETS — only these pairs are true contradictions
        exclusive_sets = [
            {'mammal', 'reptile', 'amphibian', 'insect', 'arachnid', 'fish', 'bird'},
            {'solid', 'liquid', 'gas', 'plasma'},
            {'plant', 'animal', 'fungus', 'bacteria'},
            {'male', 'female'},
            {'alive', 'dead', 'extinct'},
            {'true', 'false'},
            {'positive', 'negative'},
            {'acid', 'base', 'neutral'},
            {'vertebrate', 'invertebrate'},
            {'organic', 'inorganic'},
            {'renewable', 'non-renewable', 'nonrenewable'},
            {'conductor', 'insulator'},
            {'prokaryote', 'eukaryote'},
        ]

        # Domain-specific exclusive sets, loaded from a sidecar file next to the
        # DB (e.g. legacy_floor.db.exclusive.json). Lets non-science domains
        # (COBOL abend classes, etc.) register mutual-exclusivity WITHOUT editing
        # this file per domain. A DB with no sidecar (the kids brain) is
        # unaffected — its behavior is byte-identical to before.
        exclusive_sets = exclusive_sets + self._domain_exclusive_sets()

        for exc_set in exclusive_sets:
            a_in = any(cat in a for cat in exc_set)
            b_in = any(cat in b for cat in exc_set)
            if a_in and b_in:
                # Both match the same exclusive set — check if DIFFERENT categories
                a_cat = next((cat for cat in exc_set if cat in a), None)
                b_cat = next((cat for cat in exc_set if cat in b), None)
                if a_cat and b_cat and a_cat != b_cat:
                    return False  # REAL contradiction

        # For is_a: things can be multiple types — default to compatible
        if rel_type == 'is_a':
            return True

        # Generic: different objects in same relation = compatible by default
        # (a person can work_in multiple places, etc.)
        return True

    # =========================================================================
    # 4. INFERENCE — Find missing links
    # =========================================================================

    def infer_missing_links(self, max_inferences: int = 200) -> List[InferredLink]:
        """
        Find missing links by chaining existing relations.
        A→B + B→C ⇒ infer A→?→C

        SEMANTIC VALIDATION: Only accept inferences where:
        - Both subject and object exist as real concepts in tiles
        - The inferred relation makes domain sense
        - Confidence exceeds minimum threshold
        """
        print("🔮 Inferring missing links (with semantic validation)...")

        inferred = []

        # Build set of known concepts (things that actually exist as tile topics/entities)
        known_concepts = set()
        for row in self.db.execute("SELECT DISTINCT topic FROM responses WHERE topic IS NOT NULL AND topic != ''").fetchall():
            known_concepts.add(row[0].lower().strip())
        for row in self.db.execute("SELECT DISTINCT subject FROM typed_relations WHERE confidence > 0.7").fetchall():
            known_concepts.add(row[0].lower().strip())
        print(f"   Known concepts: {len(known_concepts)}")

        # Get all relations into memory for fast traversal
        all_rels = self.db.execute("""
            SELECT subject, relation_type, object, confidence
            FROM typed_relations
            WHERE confidence > 0.6 AND is_inferred = 0
        """).fetchall()

        # Build adjacency: subject → [(relation, object, confidence)]
        forward = defaultdict(list)
        for row in all_rels:
            forward[row['subject'].lower()].append(
                (row['relation_type'], row['object'], row['confidence'])
            )

        # Transitive inference: if A→B and B→C via transitive relations
        transitive_types = [rt for rt, info in RELATION_TYPES.items() if info.get('transitive')]

        seen_inferences = set()

        for subject, edges in forward.items():
            for rel_type, mid_object, conf_1 in edges:
                if rel_type not in transitive_types:
                    continue

                # Look for mid_object → something via same relation
                mid_key = mid_object.lower()
                if mid_key not in forward:
                    continue

                for rel_type_2, final_object, conf_2 in forward[mid_key]:
                    if rel_type_2 != rel_type:
                        continue
                    if final_object.lower() == subject:
                        continue  # Skip cycles

                    # Check if this inference already exists
                    inf_key = f"{subject}||{rel_type}||{final_object.lower()}"
                    if inf_key in seen_inferences:
                        continue
                    seen_inferences.add(inf_key)

                    # Check if direct relation already exists
                    exists = self.db.execute("""
                        SELECT 1 FROM typed_relations
                        WHERE lower(subject) = ? AND relation_type = ? AND lower(object) = ?
                        LIMIT 1
                    """, (subject, rel_type, final_object.lower())).fetchone()

                    if exists:
                        continue

                    chain_conf = conf_1 * conf_2 * 0.75  # Tightened decay factor
                    if chain_conf < 0.4:  # Minimum confidence threshold
                        continue

                    # SEMANTIC VALIDATION: both endpoints must be real concepts
                    if subject not in known_concepts and mid_key not in known_concepts:
                        continue
                    if final_object.lower() not in known_concepts:
                        continue

                    # Reject if subject or object is generic filler
                    generic = {'important topic', 'general knowledge', 'education', 'response', 'topic'}
                    if any(g in subject for g in generic) or any(g in final_object.lower() for g in generic):
                        continue

                    inf = InferredLink(
                        subject=subject,
                        relation_type=rel_type,
                        object=final_object,
                        via=mid_object,
                        chain=[(subject, rel_type, mid_object), (mid_object, rel_type, final_object)],
                        confidence=chain_conf,
                        explanation=f"{subject} {rel_type} {mid_object} + {mid_object} {rel_type} {final_object} ⇒ {subject} {rel_type} {final_object}",
                    )
                    inferred.append(inf)

                    # Store
                    self.db.execute("""
                        INSERT OR IGNORE INTO inferred_links
                        (id, subject, relation_type, object, via, chain, confidence, explanation)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, (
                        str(uuid.uuid4()), inf.subject, inf.relation_type, inf.object,
                        inf.via, json.dumps(inf.chain), inf.confidence, inf.explanation,
                    ))

                    # Also store as a typed relation (marked as inferred)
                    rel_hash = hashlib.sha256(
                        f"{inf.subject.lower()}||{inf.relation_type}||{inf.object.lower()}||inferred".encode()
                    ).hexdigest()
                    try:
                        self.db.execute("""
                            INSERT OR IGNORE INTO typed_relations
                            (id, subject, relation_type, object, confidence,
                             source_tile_id, source_sentence, topic, category,
                             is_inferred, inference_chain, hash)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                        """, (
                            str(uuid.uuid4()), inf.subject, inf.relation_type, inf.object,
                            inf.confidence, '', inf.explanation, '',
                            RELATION_TYPES.get(inf.relation_type, {}).get('category', 'unknown'),
                            json.dumps(inf.chain), rel_hash,
                        ))
                    except:
                        pass

                    if len(inferred) >= max_inferences:
                        break
                if len(inferred) >= max_inferences:
                    break
            if len(inferred) >= max_inferences:
                break

        # Cross-domain inference: if A causes B and B affects C, then A affects C
        cross_rules = [
            ('causes', 'affects', 'affects'),
            ('produces', 'enables', 'enables'),
            ('requires', 'part_of', 'requires'),
        ]

        for rel_1, rel_2, inferred_rel in cross_rules:
            if len(inferred) >= max_inferences:
                break

            rows = self.db.execute("""
                SELECT a.subject, a.object as mid, b.object as final,
                       a.confidence as c1, b.confidence as c2
                FROM typed_relations a
                JOIN typed_relations b ON lower(a.object) = lower(b.subject)
                WHERE a.relation_type = ? AND b.relation_type = ?
                AND a.is_inferred = 0 AND b.is_inferred = 0
                LIMIT 100
            """, (rel_1, rel_2)).fetchall()

            for row in rows:
                inf_key = f"{row['subject'].lower()}||{inferred_rel}||{row['final'].lower()}"
                if inf_key in seen_inferences:
                    continue
                seen_inferences.add(inf_key)

                chain_conf = row['c1'] * row['c2'] * 0.7  # Tightened cross-domain decay
                if chain_conf < 0.4:  # Minimum confidence threshold
                    continue
                inf = InferredLink(
                    subject=row['subject'],
                    relation_type=inferred_rel,
                    object=row['final'],
                    via=row['mid'],
                    chain=[(row['subject'], rel_1, row['mid']), (row['mid'], rel_2, row['final'])],
                    confidence=chain_conf,
                    explanation=f"{row['subject']} {rel_1} {row['mid']} + {row['mid']} {rel_2} {row['final']} ⇒ {row['subject']} {inferred_rel} {row['final']}",
                )
                inferred.append(inf)

        self.db.commit()
        print(f"   Inferred {len(inferred)} missing links")
        return inferred

    # =========================================================================
    # 5. QUERY — Ask the world model
    # =========================================================================

    def query_subject(self, subject: str) -> Dict[str, List[Dict]]:
        """Get all relations for a subject — the object's full relationship map."""
        rows = self.db.execute("""
            SELECT relation_type, object, confidence, is_inferred, source_sentence
            FROM typed_relations
            WHERE lower(subject) = lower(?)
            ORDER BY confidence DESC
        """, (subject,)).fetchall()

        by_type = defaultdict(list)
        for row in rows:
            by_type[row['relation_type']].append({
                'object': row['object'],
                'confidence': row['confidence'],
                'inferred': bool(row['is_inferred']),
                'source': row['source_sentence'] or '',
            })
        return dict(by_type)

    def query_relation_chain(self, subject: str, target: str, max_hops: int = 4) -> List[List[Tuple[str, str, str]]]:
        """Find all paths from subject to target through the relation graph."""
        # BFS
        queue = [(subject.lower(), [])]
        visited = {subject.lower()}
        paths = []

        for _ in range(max_hops):
            next_queue = []
            for current, path in queue:
                rows = self.db.execute("""
                    SELECT relation_type, object FROM typed_relations
                    WHERE lower(subject) = ? AND confidence > 0.5
                """, (current,)).fetchall()

                for row in rows:
                    obj = row['object'].lower()
                    new_path = path + [(current, row['relation_type'], row['object'])]

                    if obj == target.lower():
                        paths.append(new_path)
                        continue

                    if obj not in visited:
                        visited.add(obj)
                        next_queue.append((obj, new_path))

            queue = next_queue
            if not queue:
                break

        return paths

    def explain(self, subject: str, target: str) -> str:
        """Explain how two concepts are related — human-readable."""
        paths = self.query_relation_chain(subject, target)
        if not paths:
            return f"No known connection between '{subject}' and '{target}'."

        # Use shortest path
        path = min(paths, key=len)
        steps = []
        for s, r, o in path:
            r_display = r.replace('_', ' ')
            steps.append(f"{s} {r_display} {o}")

        chain = " → ".join(steps)
        return f"Connection: {chain}"

    # =========================================================================
    # 5.5. COMMONSENSE BRIDGE SEEDS
    # =========================================================================

    def seed_commonsense(self) -> int:
        """Insert commonsense typed relations as bridge seeds for sparse types."""
        print("🌱 Seeding commonsense bridge relations...")

        seeds = [
            # transports_to
            ("ambulance", "transports_to", "hospital"),
            ("fire_truck", "transports_to", "fire"),
            ("police_car", "transports_to", "crime_scene"),
            # works_in
            ("doctor", "works_in", "hospital"),
            ("nurse", "works_in", "hospital"),
            ("teacher", "works_in", "school"),
            # treats
            ("medicine", "treats", "illness"),
            ("insulin", "treats", "diabetes"),
            ("aspirin", "treats", "pain"),
            # prevents
            ("vaccine", "prevents", "disease"),
            ("exercise", "prevents", "obesity"),
            # causes
            ("smoking", "causes", "cancer"),
            ("pollution", "causes", "asthma"),
            ("deforestation", "causes", "climate_change"),
            ("poverty", "causes", "hunger"),
            # enables
            ("oxygen", "enables", "breathing"),
            ("education", "enables", "employment"),
            # requires
            ("water", "requires", "drinking"),
            ("food", "requires", "eating"),
            ("sleep", "requires", "rest"),
        ]

        inserted = 0
        for subj, rel_type, obj in seeds:
            rel = Relation(
                subject=subj,
                relation_type=rel_type,
                object=obj,
                confidence=0.95,
                source_tile_id="commonsense_seed",
                source_sentence=f"{subj} {rel_type.replace('_', ' ')} {obj}",
                topic="commonsense",
            )
            if self._store_relation(rel):
                inserted += 1

        self.db.commit()
        print(f"   Seeded {inserted} commonsense relations")
        return inserted

    # =========================================================================
    # 6. FULL RUN
    # =========================================================================

    def run(self, extract_limit: int = 10000, infer_limit: int = 200) -> Dict[str, Any]:
        """Run full relation extraction + contradiction detection + inference."""
        print(f"\n{'='*60}")
        print(f"  RELATION SCHEMA ENGINE")
        print(f"{'='*60}")

        self.seed_commonsense()
        extracted = self.extract_from_tiles(limit=extract_limit)
        contradictions = self.detect_contradictions()
        inferred = self.infer_missing_links(max_inferences=infer_limit)

        # Stats
        total_rels = self.db.execute("SELECT COUNT(*) FROM typed_relations").fetchone()[0]
        total_inferred = self.db.execute("SELECT COUNT(*) FROM typed_relations WHERE is_inferred = 1").fetchone()[0]
        total_contradictions = self.db.execute("SELECT COUNT(*) FROM contradictions").fetchone()[0]
        total_inferred_links = self.db.execute("SELECT COUNT(*) FROM inferred_links").fetchone()[0]

        # Relation type breakdown
        type_counts = self.db.execute("""
            SELECT relation_type, COUNT(*) as c FROM typed_relations
            GROUP BY relation_type ORDER BY c DESC
        """).fetchall()

        result = {
            'extracted': extracted,
            'total_relations': total_rels,
            'inferred_relations': total_inferred,
            'contradictions': total_contradictions,
            'inferred_links': total_inferred_links,
            'relation_types': {row[0]: row[1] for row in type_counts},
        }

        print(f"\n{'='*60}")
        print(f"  RELATION SCHEMA COMPLETE")
        print(f"{'='*60}")
        print(f"  Extracted relations:  {extracted:,}")
        print(f"  Total relations:      {total_rels:,}")
        print(f"  Inferred relations:   {total_inferred:,}")
        print(f"  Contradictions found: {total_contradictions}")
        print(f"  Inferred links:       {total_inferred_links:,}")
        print(f"\n  Relation type breakdown:")
        for rtype, count in type_counts[:15]:
            print(f"    {rtype:20s}: {count:,}")

        # Sample some interesting relations
        samples = self.db.execute("""
            SELECT subject, relation_type, object FROM typed_relations
            WHERE relation_type IN ('is_a', 'causes', 'requires', 'produces', 'has_part', 'treats', 'transports_to', 'works_in', 'composed_of')
            AND confidence > 0.7
            ORDER BY RANDOM() LIMIT 10
        """).fetchall()
        if samples:
            print(f"\n  Sample relations:")
            for s in samples:
                print(f"    {s[0]} ──{s[1]}──→ {s[2]}")

        return result

    # =========================================================================
    # HELPERS
    # =========================================================================

    def _clean_concept(self, text: str) -> str:
        """Clean a concept string."""
        text = text.strip()
        text = re.sub(r'\s+', ' ', text)
        # Remove leading articles
        for prefix in ['the ', 'a ', 'an ']:
            if text.lower().startswith(prefix):
                text = text[len(prefix):]
        return text.strip()

    def _parse_list(self, raw) -> List[str]:
        """Parse a field that might be JSON list or comma-separated."""
        if not raw:
            return []
        text = str(raw).strip()
        if not text:
            return []
        try:
            parsed = json.loads(text)
            if isinstance(parsed, list):
                return [str(x).strip() for x in parsed if str(x).strip()]
        except:
            pass
        return [x.strip().strip('[]"\'') for x in text.split(',') if x.strip()]

    def close(self):
        self.db.close()


# =========================================================================
# CLI
# =========================================================================

def main():
    import argparse

    parser = argparse.ArgumentParser(description="Object-Relation Schema Engine")
    parser.add_argument("command", nargs="?", default="run",
                        choices=["run", "query", "explain", "stats"])
    parser.add_argument("--db", default="/Users/lukekist/Documents/Disk Drill/Desktop-Dec 3/kids vbrain/kids_brain.db")
    parser.add_argument("--subject", help="Subject to query")
    parser.add_argument("--target", help="Target for explain/chain")
    parser.add_argument("--limit", type=int, default=10000)
    args = parser.parse_args()

    engine = RelationSchemaEngine(args.db)

    if args.command == "run":
        result = engine.run(extract_limit=args.limit)
        print(json.dumps(result, indent=2))

    elif args.command == "query":
        if not args.subject:
            print("Usage: --subject <concept>")
            return
        rels = engine.query_subject(args.subject)
        print(f"\n📊 Relations for '{args.subject}':")
        for rtype, items in rels.items():
            print(f"\n  {rtype}:")
            for item in items[:5]:
                inf = " (inferred)" if item['inferred'] else ""
                print(f"    → {item['object']} [{item['confidence']:.2f}]{inf}")

    elif args.command == "explain":
        if not args.subject or not args.target:
            print("Usage: --subject <A> --target <B>")
            return
        explanation = engine.explain(args.subject, args.target)
        print(f"\n{explanation}")

    elif args.command == "stats":
        total = engine.db.execute("SELECT COUNT(*) FROM typed_relations").fetchone()[0]
        inferred = engine.db.execute("SELECT COUNT(*) FROM typed_relations WHERE is_inferred = 1").fetchone()[0]
        contradictions = engine.db.execute("SELECT COUNT(*) FROM contradictions").fetchone()[0]
        print(json.dumps({
            "total_relations": total,
            "inferred": inferred,
            "contradictions": contradictions,
        }, indent=2))

    engine.close()


if __name__ == "__main__":
    main()
