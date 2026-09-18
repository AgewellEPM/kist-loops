-- symbolic_floor schema v1 (slice 1: protein-structure validation)
--
-- OWNERSHIP SPLIT: the tables below are owned by this project. The typed
-- fact store itself (typed_relations, contradictions, inferred_links) is
-- owned by the VENDORED Peel engine (symbolic_floor/peel/relation_schema.py,
-- RelationSchemaEngine._ensure_tables) — the engine creates and manages its
-- own DDL in the same SQLite file. Facts live in typed_relations; everything
-- here is the typed node registry, provenance enforcement, sequences, and
-- claim bindings around that engine.

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS nodes (
    node_id    TEXT PRIMARY KEY,   -- e.g. protein:P12345, structure:1ABC
    label      TEXT NOT NULL,      -- cosmetic only; the reasoner never reads it
    created_at TEXT NOT NULL       -- UTC ISO-8601
);

-- Raw amino-acid sequences, content-addressed. DECISIONS.md: table chosen
-- over a sequences/ file directory (single reviewable artifact).
CREATE TABLE IF NOT EXISTS sequences (
    sequence_id TEXT PRIMARY KEY,  -- sequence:<sha256 of exact residue string>
    residues    TEXT NOT NULL,     -- one-letter code, no whitespace
    length      INTEGER NOT NULL,
    created_at  TEXT NOT NULL
);

-- Claim registry. The six relations give no claim->protein linkage and labels
-- are forbidden for reasoning, so the binding is a typed row here
-- (DECISIONS.md #2 — flagged for review).
CREATE TABLE IF NOT EXISTS claims (
    claim_id   TEXT PRIMARY KEY,   -- claim:<uuid4>
    subject    TEXT NOT NULL,      -- protein:<accession>
    shape      TEXT NOT NULL,      -- e.g. structural-consistency-v1
    created_at TEXT NOT NULL,
    UNIQUE (subject, shape)
);

-- Provenance is REQUIRED for every edge; an edge row in typed_relations
-- without a row here is invalid. Enforced at write time in store.py (the only
-- write path), validated before anything is inserted.
CREATE TABLE IF NOT EXISTS edge_provenance (
    edge_id         TEXT PRIMARY KEY,  -- typed_relations.id
    provenance_json TEXT NOT NULL,     -- {"source","url","retrieved_at","raw_id"}
    created_at      TEXT NOT NULL
);

-- Layer 2: registered execution environments (the swap layer). Each row is a
-- capability DICTIONARY discovered from the environment — swapping back-ends
-- is registering a new row, never changing reasoning code.
CREATE TABLE IF NOT EXISTS environments (
    env_id            TEXT PRIMARY KEY,  -- e.g. simulation, human_tech
    spec              TEXT NOT NULL,     -- how it loads (short name / dotted path)
    evidence_grade    TEXT NOT NULL,     -- physical | simulated
    capabilities_json TEXT NOT NULL,     -- sorted list of capability names
    registered_at     TEXT NOT NULL
);

-- Hand-off audit trail: one row per dispatch attempt, INCLUDING refusals and
-- unplannable intents (a refusal is itself auditable evidence). The loop is
-- closed here: plan out, outcome back.
CREATE TABLE IF NOT EXISTS handoffs (
    contract_id     TEXT NOT NULL,     -- handoff:<sha256 of canonical body>
    environment     TEXT NOT NULL,     -- env_id it was dispatched to
    execution_class TEXT NOT NULL,     -- verified | exploratory | blocked
    status          TEXT NOT NULL,     -- submitted | refused | unplannable | completed | failed
    executor_ref    TEXT,              -- the environment's own reference
    contract_json   TEXT NOT NULL,     -- full contract, verbatim
    plan_json       TEXT,              -- the composed capability plan sent out
    outcome_json    TEXT,              -- what came back (readings, observed, notes)
    submitted_at    TEXT NOT NULL,     -- UTC ISO-8601
    completed_at    TEXT               -- set when the outcome is collected
);

-- Canonical-37 PEEL tile trace (same shape as the Jeeves `responses` table,
-- source of truth: kids-brain copy_harvest_to_jeeves_37fields.py). The bio
-- wheel writes one root tile per protein + one tile per extracted fact, so
-- the floor's evidence is traced exactly like the wiki wheel traces pages.
CREATE TABLE IF NOT EXISTS responses (
    id TEXT PRIMARY KEY, conversation_id TEXT, emoji TEXT,
    words TEXT, sentence TEXT, verb TEXT, action TEXT,
    intent TEXT, emotion TEXT, visual_representation TEXT,
    entities TEXT, svo_triple TEXT, complexity_level TEXT,
    reading_level TEXT, speech_pattern TEXT, cognitive_load TEXT,
    confidence_score REAL, learning_objective TEXT, prerequisites TEXT,
    follow_up_suggestions TEXT, audio_tts_hints TEXT, visual_aids TEXT,
    pet_motion TEXT, parent TEXT, subcategory TEXT, related_to TEXT,
    causes TEXT, requires TEXT, part_of TEXT, next_step TEXT,
    previous_step TEXT, connectors TEXT, depth_level INTEGER,
    parent_tile_id TEXT, branch_path TEXT, turn_number INTEGER, topic TEXT
);
CREATE INDEX IF NOT EXISTS idx_responses_conv ON responses(conversation_id);
CREATE INDEX IF NOT EXISTS idx_responses_topic ON responses(topic);

INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '1');
