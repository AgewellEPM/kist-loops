# bio-mcp — Grounded Bio-Science Research MCP Server

**Status: PILOT-READY** — typed clients live-verified against real APIs,
mocked + live test suites, fail-fast error contract. Enterprise-blocked:
no auth story beyond env keys, no observability/alerting, compute tool is
process-isolation only (documented in `sandbox.py`).

Makes any Claude session bio-science-research-ready. Five layers:

| Layer | What | Tools |
|---|---|---|
| 1 Literature | PubMed/PMC via NCBI E-utilities; arXiv; bioRxiv/medRxiv | `pubmed_search`, `pubmed_abstracts`, `pmc_fulltext`, `arxiv_search`, `biorxiv_fetch`, `biorxiv_recent` |
| 2 Bio data | UniProtKB, RCSB PDB, NCBI GenBank/Protein, Ensembl | `uniprot_search`, `uniprot_entry`, `pdb_search`, `pdb_entry`, `ncbi_sequence_search`, `ncbi_fetch_sequence`, `ensembl_gene`, `ensembl_sequence`, `ensembl_xrefs` |
| 3 Compute | Python in the bio-mcp venv: biopython, pandas, scipy, numpy | `run_python`, `list_workspace` |
| 3b Wetware | Actuation lane: workspace writes + detached background jobs (survive server restarts; state on disk under `workspace/.wetware/jobs/`) | `wetware_write_file`, `wetware_read_file`, `wetware_move`, `wetware_remove`, `wetware_job_start`, `wetware_job_status`, `wetware_job_output`, `wetware_job_cancel`, `wetware_jobs` |
| 4 Verification | Every result carries `source{database,id,url,retrieved}`; unpinned source = raised error | (contract, not a tool — see `citations.py`) |
| 5 Knowledge | KEGG + Reactome pathways; glossary + citation-style resources | `kegg_search`, `kegg_entry`, `reactome_search`, `bio://glossary`, `bio://citation-style` |

## Install

```bash
cd bio-mcp
/opt/homebrew/bin/python3.12 -m venv .venv
.venv/bin/pip install -e ".[dev,compute]"
```

## Register with Claude Code (user scope = all projects)

```bash
claude mcp add --scope user bio-research -- \
  /Volumes/PRO-G40/science-loops/bio-mcp/.venv/bin/python -m bio_mcp.server
```

Optional: `NCBI_API_KEY` env raises the NCBI budget 3 → 10 req/s
(free key: https://www.ncbi.nlm.nih.gov/account/settings/).

## Tests

```bash
.venv/bin/pytest              # mocked suite (no network)
.venv/bin/pytest -m live      # live smoke against real public APIs
```

## Politeness / rate limits

Per-host token buckets in `http.py` (NCBI 3/s or 10/s with key, arXiv 1/s,
Ensembl 10/s, ...). Honest User-Agent. Retries only on 429/5xx/transport
errors with backoff + Retry-After.

## The citation rule

No unreferenced molecular-biology assertions — see `docs/CITATION_STYLE.md`.
If a claim can't be pinned to a PMID/accession/DOI from a tool result, the
answer says "unverified" or drops it.
