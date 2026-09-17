# DECISIONS — ambiguities hit, options weighed, what was chosen

Per brief §9: nothing below was silently picked. Items marked **[REVIEW]**
change the data model or verdict semantics and want a human eye.

## 1. **[REVIEW]** The Peel engine is embedded (Luke's override of brief §0)

- **Ambiguity:** the brief says "do not integrate with Peel or Jeeves; you own
  the store from scratch." Luke then directed: *the entire symbolic system
  needs to be inside this — not as an MCP, actually running inside.*
- **Options:** (a) from-scratch store per the brief; (b) import the engine
  from `~/jeeves/kids-brain` via sys.path at runtime; (c) vendor a verbatim
  snapshot in-repo.
- **Chosen:** (c). `symbolic_floor/peel/relation_schema.py` is byte-identical
  to upstream below its comment header (upstream commit `6cb0056`, SHA-256
  `22a3201c…` pinned in the header and verifiable with
  `tail -n +14 … | shasum -a 256`). Vendoring keeps the floor self-contained
  and reviewable and honors "no external process"; sys.path imports would
  couple this repo to the jeeves working tree.
- `graph_reasoning_engine.py` (Peel's NL/tile traversal) was **not** embedded:
  it imports kids-brain internals (`brain_storage`, `brain_sqlite`), is scoped
  to AAC tile graphs (`responses` table), and slice 1 never traverses NL
  tiles. If a later slice needs multi-hop justification paths, re-vendor it
  then. The bio floor's own DB never touches `kids_brain.db`.

## 2. **[REVIEW]** `claims` table added to the data model

- **Ambiguity:** `evaluate_claim(claim_id)` must find protein P, but the six
  relations give no claim→protein edge, and hard constraint 2 forbids the
  reasoner from reading labels.
- **Options:** (a) encode the accession in the claim node's label (violates
  constraint 2); (b) add a typed `claims(claim_id, subject, shape)` table.
- **Chosen:** (b). The binding is machine-checked typed data, not free text.
  `claim:<uuid4>` node convention preserved; `(subject, shape)` unique so
  `eval-protein` is idempotent.

## 3. Sequences stored in a table, not a `sequences/` directory

Brief offered either. A `sequences` table keeps ONE reviewable artifact (the
SQLite file) and one transaction boundary. SHA-256 is computed over the exact
residue string, no whitespace (`Store.sequence_node_id`).

## 4. Test file names: §6's ten names win over §2's six-file sketch

The brief's layout sketch and §6 disagree; §6 is the graded contract, so the
ten files exist verbatim (`test_reject_unknown_relation.py` … `test_allowlist.py`)
plus `conftest.py` and shared fixtures. 35 tests total (per-site assertions
inflate the count; every §6 case is present under its named file).

## 5. `gene:` node prefix is valid

The nodes list in §3 omits `gene:`, but the `encodes` relation requires
`gene:<id>` sources. Without the prefix the relation would be unusable —
`gene:` validates as `[A-Za-z0-9_.:-]{1,128}`.

## 6. PDB connector semantics

- UniProt entry JSON 404 (or the live 200-empty-body quirk, see #9) →
  `NOT_FOUND` (the *protein* is unknown; distinct from "known protein, no
  structure").
- Xref present but RCSB won't confirm (non-200, or `experimental_method`
  missing/None) → `NO_EXPERIMENTAL_STRUCTURE`, no edge. The xref's promise is
  not evidence; the RCSB confirmation is.
- Edge provenance pins the RCSB confirmation fetch (`source: "pdb"`, the
  data.rcsb.org URL). Discovery-via-UniProt is a route, not the authority.
- "First entry ID" = first PDB xref in UniProt's listed order (deterministic).

## 7. **[REVIEW]** Conflict precedence and non-AF-shaped predicted targets

- A provable conflict beats optimistic support: functional-relation
  violations (two sequences / two predictions) are checked at their step and
  return `CONFLICTING` even though evidence "exists". Rationale: the floor is
  an honesty layer; surfacing contradiction outranks declaring support.
- A `predicts_structure` target that does not parse as `AF-<acc>-F<n>` proves
  nothing about accession identity → it cannot trigger `accession_mismatch`;
  presence semantics (§5 step 4) apply. Only ID-provable mismatches conflict
  (constraint: "a mismatch you can prove by IDs").

## 8. `evaluate_claim` on a nonexistent claim id raises

`UNKNOWN` means "evidence absent for a real claim". A claim id that was never
created is caller error → `ValidationError` (CLI prints a clean JSON error,
exit 2). Conflating the two would make `UNKNOWN` unfalsifiable.

## 9. Live UniProt returns 200 + empty body for nonexistent accessions

Discovered during the definition-of-done check: `GET …/{fictional}.fasta`
answers HTTP 200 with an EMPTY body, not 404. Both UniProt-hitting connectors
treat 200-empty as `NOT_FOUND` (no edge); a non-empty non-FASTA/non-JSON body
is still a loud `ConnectorError`. Pinned per-site in
`test_connector_404_path.py`.

Related honest nuance: AlphaFold DB carries models for some merged/deleted
accessions (live: `Q9ZZZ9` → real prediction, while UniProt has no current
record). The floor stores the evidence that exists and the verdict remains
`UNKNOWN` for the claim (missing `has_sequence`) — evidence-attached
abstention, exactly as designed.

## 10. Where writes go

The CLI's only write location is `<project>/data/bio_floor.db` (+ SQLite
sidecar files). Tests inject `tmp_path` DBs through the same `Store(db_path)`
API — pytest's tmp dir is outside the project by pytest's design; the
DELIVERED runtime never writes outside `symbolic_floor/`.

## 11. Engine `created` flag not trusted

Peel's `_store_relation` uses `INSERT OR IGNORE` and returns True even for
duplicates. `store.add_edge` checks hash-existence itself (first write wins,
original provenance kept, re-seeding idempotent). Caught by
`test_reseed_is_idempotent`.

## 14. **[REVIEW]** Slice 2: hand-off is capability-based, three layers

- **Ambiguity/correction:** the naive terminus was one adapter that took a
  contract and "sent it somewhere". Luke's correction: swapping a robot API in
  doesn't teach the system *how to use the hands* — that capability is the
  product. And even hands-off, the terminus must stay in control and get data
  BACK so the tools are actually usable (Coscientist model: learn unfamiliar
  hands on demand, don't own them).
- **Chosen:** three layers — affordance model (`capabilities.py`), environment
  registry (`environments.py`), execution planner (`planner.py`) — plus a
  closed lifecycle in `handoff.py` (build → dispatch/plan → check → collect →
  ingest). The reasoning pipeline (slices 1/1.5) is untouched; environments are
  loaded by short name or dotted path.
- **Honesty gates (load-bearing, pinned):**
  - `evidence_grade`: only `physical` environments can produce graph evidence.
    A `simulated` outcome validates the PLAN (it executed, volumes balanced),
    never the world — recorded, never ingested. Simulation `collect()` always
    returns `inconclusive` by construction. This is the one rule that keeps the
    floor from laundering a simulation into a fact.
  - Verdict-gated dispatch: SUPPORTED→verified, UNKNOWN→exploratory (the
    experiment is how an unknown resolves), CONFLICTING→blocked (dispatch
    refuses; the refusal is recorded, not dropped).
  - `UNPLANNABLE`: an intent the environment can't compose returns the missing
    capabilities and writes nothing — no substitution, no partial plan.
  - Ingested evidence is a real typed edge (supports_claim/conflicts_with,
    structure→claim) with provenance source `executor` pinned to
    `<env_id>:<executor_ref>`. New provenance source `executor` added
    (url-less, like `manual`; raw_id carries the executor reference).
- **Recall nuance (verified, not a bug):** ingested supports_claim edges are
  `structure→claim`, so `recall --uniprot P` surfaces them as 2-hop paths
  (protein→structure→claim), not in the protein's direct `facts`. All 6 were
  confirmed trace-reachable.
- **Deliberately unbuilt:** Emerald Cloud Lab, Strateos, robot bridges — no
  accounts, no fake integrations. Each is one adapter module conforming to the
  Environment protocol; nothing upstream changes.
- CONTRACT_VERSION bumped 1→2 (added execution_request; the terminus is the
  only consumer, no migration concern for a fresh slice).

## 13. **[REVIEW]** Slice-1.5 extraction relations extend the six (Luke's goal)

- **Ambiguity:** the original brief fixed EXACTLY six relations; Luke then
  directed the Jeeves-wiki-wheel analog for bio sites ("extract … into our
  Peel trace system, recall it all, dogfood test it all") — which needs
  richer vocabulary.
- **Chosen:** `EXTRACTION_RELATIONS` (belongs_to/located_in/affects/has_part)
  added as a SEPARATE registry unioned into validation, all mapping onto
  vocabulary the vendored engine already owns. The verification six are
  unchanged (`CORE_RELATIONS`); the reasoner still evaluates only those.
  Disease uses `affects`, not `causes` — UniProt records involvement, not
  causation. `has_part` derives ONLY from `Domain`-typed features: p53
  legitimately yields zero (its annotation uses DNA binding/Region/Motif) —
  pinned as a no-fabrication check in the dogfood harness.
- PDB confirmation is capped at 5 per protein (politeness; p53 lists ~200+
  xrefs) with `pdb_xrefs_total`/`pdb_confirm_cap` in every trace — capped,
  never silent.

## 12. Reasoner reads edges via direct ordered SQL, semantics via the engine

Edge retrieval uses `ORDER BY id` SQL for byte-stable traces; *semantic*
decisions (functional flags, compatibility) delegate to the vendored engine
(`RELATION_TYPES`, `_are_compatible`). The engine owns meaning; the slice owns
the walk. `supports_claim` / `conflicts_with` are schema-valid but the slice-1
reasoner is read-only and never auto-writes them (they exist for the proposer
and later slices).
