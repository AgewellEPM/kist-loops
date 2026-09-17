# symbolic_floor — Slice 1: Protein-Structure Validation

A local, deterministic, evidence-attached knowledge store plus a verification
reasoner, built ON the real Peel symbolic engine running in-process. An LLM
proposer can later emit biological claims; this floor stores typed facts and
returns exactly one of three verdicts: `SUPPORTED`, `CONFLICTING`, `UNKNOWN`.

**The engine inside:** `symbolic_floor/peel/relation_schema.py` is a verbatim
vendored snapshot of the Peel typed-relation engine (upstream
`~/jeeves/kids-brain/relation_schema.py`, commit `6cb0056`, SHA-256 pinned in
the file header — the payload below the header is byte-identical to upstream).
It owns the typed fact store (`typed_relations`), dedup, relation categories,
functional-relation semantics, and compatibility checking. This project adds
the bio relation vocabulary, provenance enforcement, three read-only
connectors, and the three-verdict reasoner. No MCP, no external process — the
symbolic system runs inside this package.

## Run

```bash
cd symbolic_floor                      # project root (this directory)
python3.13 -m venv .venv && .venv/bin/pip install pytest   # tests only
.venv/bin/python -m pytest tests/ -q   # 35 tests, no live network

.venv/bin/python -m symbolic_floor seed --uniprot P69905
.venv/bin/python -m symbolic_floor claim --uniprot P69905
.venv/bin/python -m symbolic_floor evaluate --claim <claim_id>
.venv/bin/python -m symbolic_floor eval-protein --uniprot P69905   # end-to-end

.venv/bin/python -m symbolic_floor extract --uniprot P69905  # the bio wheel
.venv/bin/python -m symbolic_floor recall  --uniprot P69905  # recall it all

.venv/bin/python -m dogfood.harness            # dogfood: offline + live
.venv/bin/python -m dogfood.harness --offline  # fixtures only
```

Runtime is stdlib-only (Python 3.11+). The default DB is
`data/bio_floor.db` under this directory — the CLI writes nowhere else.

## The six relations (direction is fixed; anything else is rejected)

| relation             | source → target                  | functional |
|----------------------|----------------------------------|------------|
| `encodes`            | `gene:*` → `protein:*`           | no |
| `has_sequence`       | `protein:*` → `sequence:*`       | **yes** |
| `has_structure`      | `protein:*` → `structure:*` (experimental) | no |
| `predicts_structure` | `protein:*` → `structure:*` (predicted)    | **yes** |
| `supports_claim`     | `structure:*` → `claim:*`        | no |
| `conflicts_with`     | `structure:*` → `claim:*`        | no |

"Functional" is the Peel engine's OWL-FunctionalProperty hard-veto: at most
one object per subject, so two different objects for the same protein are an
ID-provable contradiction detected by the ENGINE (`_are_compatible`), not by
slice-specific code. `has_structure` is deliberately not functional — many
experimental structures per protein is normal.

### Slice-1.5: the bio wheel (extraction + recall)

The analog of the Jeeves wiki wheel: `extract --uniprot ACC` fans one UniProt
entry into typed Peel facts — every one provenance-pinned to the exact URL:

| relation | source → target | derived from |
|---|---|---|
| `encodes` | `gene:*` → `protein:*` | `genes[].geneName` |
| `belongs_to` | `protein:*` → `organism:*` | `organism.scientificName` |
| `located_in` | `protein:*` → `location:*` | SUBCELLULAR LOCATION comments |
| `affects` | `protein:*` → `disease:*` | DISEASE comments (involvement, NOT causation) |
| `has_part` | `protein:*` → `domain:*` | `Domain`-typed features ONLY (no fabrication — p53 legitimately yields zero) |
| `has_structure` | ALL PDB xrefs, first 5 confirmed vs RCSB | cap reported in the trace, never silent |

These map onto relations the vendored engine already knows (`located_in` even
participates in its Rule-1 conflict scan). `recall --uniprot ACC` walks it all
back: facts grouped by relation with edge IDs + provenance, incoming edges,
and bounded 2-hop link-trace paths. Extraction is idempotent; recall is
byte-deterministic on a fixed DB.

### Slice 2: the hand-off terminus (learn the hands, don't own them)

The verified result flows into a hand-off contract and out to a physical
executor — but the moat is *the software that knows how to use unfamiliar
hands*, not the hands. Three layers, none vendor-coupled:

1. **Affordance model** (`capabilities.py`) — a hand is a set of typed
   capabilities (`aspirate`, `dispense`, `mix`, `heat`, `measure_absorbance`,
   …), each with a validated parameter schema. Not a brand.
2. **Environment registry** (`environments.py`) — each back-end registers a
   *dictionary of capabilities* discovered at runtime. Swapping = registering
   a new dictionary. `evidence_grade` is `physical` or `simulated`.
3. **Execution planner** (`planner.py`) — the "knows how to use" part.
   Composes a high-level intent (`serial_dilution`, `measure_sample`,
   `incubate`) from the capabilities the *current* environment exposes. Same
   intent, different hands → different command sequences; reasoning unchanged.
   An intent it can't compose returns `UNPLANNABLE` with the missing
   capabilities — never a guess, never a substitution.

The terminus (`handoff.py`) owns the contract and the **closed loop** —
hands-off is not fire-and-forget:

```
build_contract   verdict + trace + evidence(with provenance) + caller's
                 predicted outcome + intent  ->  content-addressed contract
dispatch_handoff plan the intent from the env's capabilities, then submit
                 (blocked verdict or unplannable intent -> recorded refusal)
handoff-check    poll the executor's status (terminus stays in control)
handoff-collect  pull the observed outcome BACK; a **physical** confirmed/
                 refuted result materializes supports_claim / conflicts_with
                 edges (provenance source "executor"), so the executor's data
                 becomes first-class graph evidence recall + the reasoner use.
```

Honesty gates (pinned in tests + dogfood): a **simulated** outcome validates
the *plan*, never the world — it is recorded but NEVER ingested as evidence; a
**CONFLICTING** verdict is `blocked` and refused (the floor never ships a
contradicted premise); an inconclusive result is recorded, no edges. Shipped
environments: `simulation` (deterministic, full capability set) and
`human_tech` (work order out, result file back). Emerald Cloud Lab / Strateos
/ robots are deliberately unbuilt — each is one new adapter module (or
`pkg.mod:Class`) and the pipeline does not change by one line.

```bash
.venv/bin/python -m symbolic_floor env-register --spec simulation
.venv/bin/python -m symbolic_floor envs
.venv/bin/python -m symbolic_floor handoff --uniprot P69905 \
    --predicted-outcome "A280 drops 10x per well" \
    --intent serial_dilution --intent-params '{"factor":10,"steps":3,"volume_ul":100}' \
    --environment human_tech
.venv/bin/python -m symbolic_floor handoff-collect --contract <id> --environment human_tech
```

### Dogfood harness

`dogfood/harness.py` — inverted scoring (a FINDING earns points; clean run =
0). 17 scenarios over extract → store → recall → verdict → **terminus**:
provenance on every edge, recall completeness ("recall it all" — no silent
drops), idempotency, determinism, functional-veto, the embedded engine's own
contradiction scan, malformed/hostile payloads, allowlist, abstention, the
full dispatch→collect→ingest loop, **simulation-never-becomes-evidence**,
blocked-contract-refused, unplannable-intent-honest, plus LIVE roundtrips
(P69905, P04637). Report: `dogfood/REPORT.md`.

Node ID conventions: `protein:<uniprot_accession>`, `structure:<pdb_id>`
(4-char experimental or `AF-<acc>-F<n>` predicted), `sequence:<sha256>`
(content-addressed over the exact residue string, no whitespace),
`claim:<uuid4>`, `gene:<token>`.

## Provenance schema (required on every edge, validated before write)

```json
{"source": "uniprot" | "pdb" | "alphafold" | "manual",
 "url": "https://<allowlisted-host>/...",     // may be null ONLY for manual
 "retrieved_at": "2026-09-17T12:00:00.000Z",  // timezone-aware UTC ISO-8601
 "raw_id": "P69905"}                          // manual: citation string
```

An edge without complete provenance never reaches the store (`store.add_edge`
is the only write path; fact + provenance commit in one transaction). Network
access is read-only GET to exactly: `rest.uniprot.org`, `data.rcsb.org`,
`alphafold.ebi.ac.uk`, `files.rcsb.org`, `www.ebi.ac.uk`, `search.rcsb.org` —
anything else is refused before I/O (`connectors/base.py`).

## The three verdicts

- `SUPPORTED` — evidence present and consistent (Peel "consistent").
- `CONFLICTING` — an ID-provable contradiction (Peel "contradiction"; the
  floor's hard veto). Two mechanisms, both in the trace:
  1. functional-relation violation (engine-detected): two different sequences
     or two different predicted structures for one protein;
  2. accession mismatch: a `predicts_structure` target `AF-<X>-F*` whose
     embedded accession X differs from the claim's protein while an
     experimental structure exists.
  A provable conflict takes precedence over optimistic support.
- `UNKNOWN` — evidence absent. The reasoner abstains; it never synthesizes,
  interpolates, or reasons by analogy. A missing edge is `UNKNOWN`, period.

Every verdict carries `trace` (the exact edge IDs walked), `missing`,
`witnesses`, and the floor identity (`bio-structure-floor`,
authority `uniprot-pdb-alphafold-evidence`). Verdicts are pure functions of
the stored edges — byte-identical across repeated evaluation (pinned by
`test_reasoner_is_deterministic`).

## Slice-1 semantics of "consistency" (read this)

**"Structurally consistent" in slice 1 means: an experimental structure AND a
predicted structure both exist for the same protein accession, with no
ID-provable contradiction.** It is deliberately a same-protein presence check.
**RMSD / structural alignment is explicitly out of scope for this slice** —
no coordinate comparison happens anywhere. (`AF-P69905-F1` vs `1A00` being
"consistent" asserts identity of the subject protein, not geometric
agreement.)

## Layout

```
symbolic_floor/            project root
  schema.sql               project DDL (nodes/sequences/claims/provenance/meta)
  symbolic_floor/
    peel/relation_schema.py    VENDORED Peel engine (do not edit here)
    peel/floor.py              bio relations registered into the engine
    schema.py                  field-level validation (IDs, direction, provenance)
    db.py  store.py            connection/migrations; the only write path
    reasoner.py                evaluate_claim() — the three verdicts
    connectors/{base,uniprot,pdb,alphafold}.py
    cli.py                     seed / claim / evaluate / eval-protein
  tests/                       35 tests, all offline (stub transports + fixtures)
  DECISIONS.md                 every ambiguity, the options, and what was chosen
```

Verified live 2026-09-17: `eval-protein P69905` → `SUPPORTED` (trace: 3 edges;
witnesses `structure:1A00`, `structure:AF-P69905-F1`); fictional
`A0AAA0AAA0` → `UNKNOWN`, zero edges written. Note P12345 (the brief's
example) genuinely has no PDB cross-reference at UniProt today → honest
`UNKNOWN, missing=["has_structure"]`.
