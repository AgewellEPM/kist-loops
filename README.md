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
