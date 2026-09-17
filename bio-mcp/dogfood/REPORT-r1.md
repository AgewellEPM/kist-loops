# bio-mcp Dogfood Report

Generated 2026-09-17 · 53 scenarios · **25 findings (58 pts)** · 28 passes · 0 forced reconnects · 111s wall

Scoring rewards finding failures (critical=5, high=3, medium=2, low=1). A clean run scores 0.

## Findings

### [HIGH] biorxiv recent window freshness  (`biorxiv_recent`)
- 'recent' preprints end at 2026-09-07 (10d stale) — cursor-0 page only; window start bias / no pagination (window 2026-09-07..2026-09-17)
- _note: runner applies special freshness check: are returned dates near the window END or only its start (pagination blindness)?_

### [HIGH] uniprot bogus accession clean error  (`uniprot_entry`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool uniprot_entry

### [HIGH] pdb nonexistent id clean error  (`pdb_entry`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool pdb_entry

### [HIGH] ncbi huge genome without save_path  (`ncbi_fetch_sequence`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool ncbi_fetch_sequence
- _note: chr1 ~248 Mb: must refuse inline, must NOT try to buffer forever; runner enforces 120s deadline_

### [HIGH] ensembl bogus symbol clean error  (`ensembl_gene`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool ensembl_gene

### [HIGH] kegg bogus id clean error  (`kegg_entry`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool kegg_entry

### [HIGH] run_python non-utf8 stdout survives  (`run_python`)
- stdout not a string
- _note: suspect: text=True strict decode raises inside the tool_

### [HIGH] workspace escape blocked  (`list_workspace`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool list_workspace

### [MEDIUM] pubmed abstracts by pmid  (`pubmed_abstracts`)
- unexpected shape
- _note: runner wraps bare-list results as {'_list': [...]}_

### [MEDIUM] pubmed empty query rejected  (`pubmed_search`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool pubmed_search

### [MEDIUM] pubmed 101 pmids rejected  (`pubmed_abstracts`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool pubmed_abstracts

### [MEDIUM] pmc rejects non-PMC id  (`pmc_fulltext`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool pmc_fulltext

### [MEDIUM] biorxiv rejects foreign DOI  (`biorxiv_fetch`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool biorxiv_fetch

### [MEDIUM] biorxiv rejects bad server  (`biorxiv_fetch`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool biorxiv_fetch

### [MEDIUM] arxiv empty query rejected  (`arxiv_search`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool arxiv_search

### [MEDIUM] pdb entry 6VXX  (`pdb_entry`)
- no PMID on primary citation

### [MEDIUM] ensembl xrefs bounded?  (`ensembl_xrefs`)
- unbounded xrefs payload: n_xrefs=157 with no cap/pagination param

### [MEDIUM] pdb 5-char id rejected  (`pdb_entry`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool pdb_entry

### [MEDIUM] ncbi bad db rejected  (`ncbi_fetch_sequence`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool ncbi_fetch_sequence

### [MEDIUM] ncbi relative save_path rejected  (`ncbi_fetch_sequence`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool ncbi_fetch_sequence

### [MEDIUM] ensembl bad seq_type rejected  (`ensembl_sequence`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool ensembl_sequence

### [MEDIUM] kegg bad database rejected  (`kegg_search`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool kegg_search

### [MEDIUM] run_python empty script rejected  (`run_python`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool run_python

### [MEDIUM] run_python relative cwd rejected  (`run_python`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool run_python

### [MEDIUM] run_python zero timeout rejected  (`run_python`)
- validation gap: call SUCCEEDED, expected rejection. payload head: Error executing tool run_python

## Passes

- glossary resource readable (`bio://glossary`, 0.0s)
- citation-style resource readable (`bio://citation-style`, 0.0s)
- pubmed basic search (`pubmed_search`, 1.08s)
- pubmed unicode query (β-catenin) (`pubmed_search`, 2.61s)
- pubmed quoted-phrase query (`pubmed_search`, 0.59s)
- pubmed sort=pub_date (`pubmed_search`, 0.86s)
- pmc open-access fulltext (`pmc_fulltext`, 0.73s)
- arxiv q-bio search (`arxiv_search`, 0.29s)
- biorxiv fetch known preprint (`biorxiv_fetch`, 0.14s)
- pubmed nonexistent pmid honest (`pubmed_abstracts`, 0.08s)
- uniprot search kinase (`uniprot_search`, 3.85s)
- uniprot entry P04637 (`uniprot_entry`, 0.1s)
- pdb search spike (`pdb_search`, 0.11s)
- ncbi nuccore search (`ncbi_sequence_search`, 0.43s)
- ncbi fetch small fasta inline (`ncbi_fetch_sequence`, 0.61s)
- ncbi PROTEIN db + genbank fmt (`ncbi_fetch_sequence`, 0.14s)
- ensembl gene TP53 (`ensembl_gene`, 1.83s)
- ensembl protein sequence (`ensembl_sequence`, 7.3s)
- uniprot isoform accession behavior (`uniprot_entry`, 0.4s)
- kegg pathway search (`kegg_search`, 0.84s)
- kegg entry hsa04110 (`kegg_entry`, 0.86s)
- reactome apoptosis search (`reactome_search`, 0.18s)
- reactome nonsense query honest (`reactome_search`, 0.11s)
- run_python libs available (`run_python`, 0.41s)
- run_python timeout honored (`run_python`, 3.01s)
- run_python huge output capped (`run_python`, 0.03s)
- workspace listing works (`list_workspace`, 0.0s)
- concurrency: 5 parallel mixed calls (`(multiple)`, 4.05s)
