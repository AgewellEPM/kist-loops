# bio-mcp Citation Contract

The rule that separates "sounds right" from "science-ready":

> **No unreferenced molecular-biology assertion.** Every factual bio claim in
> an answer is pinned to an accession, PMID, DOI, or stable pathway ID with a
> resolvable URL — taken from a tool result's `source` block, never recalled
> from model memory.

## Mechanics

1. Every bio-mcp tool result carries `source: {database, id, url, retrieved}`.
   Building an unpinned source raises `UnpinnedSourceError` — it is a bug,
   not a degraded answer.
2. Literature records also carry a preformatted `citation` string.
3. If no tool can ground a claim, the answer must say "unverified" explicitly
   or drop the claim. Model recall is a hypothesis, not a citation.
4. Preprints are labeled as preprints (server + version). If a journal-published
   version exists (`peer_reviewed_version`), prefer citing it.

## Style (Vancouver-derived, one line per reference)

```
Authors (≤6, then et al). Title. Venue. Year. IDS.
```

Example:

```
Jumper J, Evans R, Pritzel A, et al. Highly accurate protein structure
prediction with AlphaFold. Nature. 2021. DOI: 10.1038/s41586-021-03819-2;
PMID: 34265844.
```

Identifier order when several exist: PMID > DOI > accession. Accessions are
cited with database prefix, e.g. `UniProt: P04637`, `PDB: 6VXX`,
`GenBank: NC_045512.2`, `Ensembl: ENSG00000141510`, `Reactome: R-HSA-69488`,
`KEGG: hsa04110`.

## In answers

- Inline: `TP53 encodes p53, a tumor-suppressor transcription factor
  [UniProt: P04637]`.
- End every research answer with a `References` list of the `citation`
  strings / source URLs actually used.
