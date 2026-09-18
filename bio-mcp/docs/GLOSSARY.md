# bio-mcp Domain Glossary

Identifier formats, database scopes, and pathway schemas the tools return.
This is the seed knowledge index (layer 5) — extend as domains deepen.

## Identifier formats (recognize on sight)

| Identifier | Shape | Example | Database / tool |
|---|---|---|---|
| PMID | digits | 34265844 | PubMed — `pubmed_search`, `pubmed_abstracts` |
| PMCID | PMC+digits | PMC7096066 | PubMed Central — `pmc_fulltext` |
| DOI | 10.xxxx/... | 10.1038/s41586-021-03819-2 | doi.org |
| bioRxiv DOI | 10.1101/... | 10.1101/2020.02.07.937862 | `biorxiv_fetch` |
| arXiv ID | YYMM.NNNNN | 2103.09992 | `arxiv_search` |
| UniProt accession | [OPQ][0-9]..., or A0A... | P04637 | `uniprot_entry` |
| PDB ID | 4 alphanumerics | 6VXX | `pdb_entry` |
| GenBank/RefSeq | letters+digits.version | NC_045512.2 | `ncbi_fetch_sequence` |
| Ensembl gene | ENSG+11 digits | ENSG00000141510 | `ensembl_gene` |
| Ensembl transcript | ENST+11 digits | ENST00000269305 | `ensembl_sequence` |
| KEGG pathway | org prefix + 5 digits | hsa04110 | `kegg_entry` |
| Reactome stable ID | R-HSA-digits | R-HSA-69488 | `reactome_search` |

## Database scopes

- **PubMed** — biomedical literature abstracts; the citation backbone.
- **PMC** — full text, only for open-access deposits; embargoes are reported
  explicitly by `pmc_fulltext` (`full_text_available: false`).
- **bioRxiv/medRxiv** — preprints: NOT peer-reviewed; cite as preprint and
  check `peer_reviewed_version`.
- **UniProtKB** — protein sequence + function. Swiss-Prot (reviewed) is
  curated; TrEMBL (unreviewed) is computational annotation.
- **RCSB PDB** — experimental 3D structures (X-ray/cryo-EM/NMR); resolution
  in Å, lower is better; primary citation attached.
- **NCBI Nucleotide (nuccore)** — GenBank/RefSeq sequences. RefSeq accessions
  (NC_, NM_, NP_) are curated; raw GenBank submissions are not.
- **Ensembl** — genome annotation: gene models, coordinates (assembly-specific
  — GRCh38 vs GRCh37 matters), cross-refs.
- **KEGG** — pathway maps, orthology (KO), compounds, enzymes. Organism
  prefixes: hsa=human, mmu=mouse, eco=E. coli, sce=yeast; `map` = reference.
- **Reactome** — curated human-centric reaction-level pathways, hierarchical
  (pathway → reaction → participant), evidence-tracked.

## Pathway schema notes

- KEGG pathway entries list GENE, COMPOUND, and linked MODULE/DISEASE blocks
  in the flat file — `kegg_entry` returns it verbatim for parsing.
- Reactome types: Pathway, Reaction, Complex, EntityWithAccessionedSequence
  (protein with UniProt xref). Species-scoped; default filter Homo sapiens.
- Cross-walk: Ensembl gene → `ensembl_xrefs` → UniProt accession →
  `uniprot_entry.pdb_structures` → PDB. That chain grounds gene → protein →
  structure claims end-to-end.

## Analysis conventions (layer 3)

- Fetched sequences land in the bio-mcp `workspace/`; `run_python` scripts
  default their cwd there — use relative paths in scripts.
- Biopython: `from Bio import SeqIO; SeqIO.parse("x.fasta", "fasta")`.
- Report software-derived numbers (GC%, alignment scores, stats) as computed
  by the script, alongside the accession of the input data.
