"""bio-mcp server: typed bio-science research tools over MCP (stdio).

Layer map (see README.md):
  1 literature   → pubmed_search, pubmed_abstracts, pmc_fulltext,
                   arxiv_search, biorxiv_fetch, biorxiv_recent
  2 bio data     → uniprot_search, uniprot_entry, pdb_search, pdb_entry,
                   ncbi_sequence_search, ncbi_fetch_sequence,
                   ensembl_gene, ensembl_sequence, ensembl_xrefs
  3 compute      → run_python, list_workspace
  5 knowledge    → kegg_search, kegg_entry, reactome_search
                   + resources bio://glossary, bio://citation-style
  4 verification → every result carries source{database,id,url,retrieved};
                   citation strings are Vancouver-style (docs/CITATION_STYLE.md).
"""

from __future__ import annotations

from pathlib import Path

from mcp.server.mcpserver import MCPServer

from .clients import ensembl, ncbi_seq, pathways, pdb, preprints, pubmed, uniprot
from .errors import surface_rejections
from .http import shared_http
from .sandbox import list_workspace as _list_workspace
from .sandbox import run_python_script

DOCS = Path(__file__).resolve().parent.parent / "docs"

mcp = MCPServer(
    "bio-research",
    instructions=(
        "Grounded bio-science research tools. Every result carries a `source` block "
        "(database, accession/PMID, URL) — cite those identifiers, never paraphrase "
        "molecular biology from memory when a tool can pin it. Sequences can be saved "
        "to the workspace and analyzed with run_python (biopython/pandas/scipy)."
    ),
)


# ---------- Layer 1: literature ----------

@mcp.tool()
@surface_rejections
async def pubmed_search(query: str, max_results: int = 20, sort: str = "relevance") -> dict:
    """Search PubMed and return abstracts with PMIDs, DOIs, and citations. sort: relevance|pub_date."""
    return await pubmed.search_pubmed(shared_http(), query, max_results=max_results, sort=sort)


@mcp.tool()
@surface_rejections
async def pubmed_abstracts(pmids: list[str]) -> dict:
    """Fetch abstracts + metadata for specific PMIDs (max 100). Unresolvable PMIDs are listed in `missing`."""
    return await pubmed.fetch_abstracts_report(shared_http(), pmids)


@mcp.tool()
@surface_rejections
async def pmc_fulltext(pmcid: str, max_chars: int = 60000) -> dict:
    """Fetch open-access full text from PubMed Central by PMCID (e.g. PMC7096066)."""
    return await pubmed.fetch_pmc_fulltext(shared_http(), pmcid, max_chars=max_chars)


@mcp.tool()
@surface_rejections
async def arxiv_search(query: str, max_results: int = 20, category: str | None = None) -> dict:
    """Search arXiv preprints. category scopes results, e.g. 'q-bio' or 'q-bio.GN'."""
    return await preprints.search_arxiv(shared_http(), query, max_results=max_results, category=category)


@mcp.tool()
@surface_rejections
async def biorxiv_fetch(doi: str, server: str = "biorxiv") -> dict:
    """Fetch a bioRxiv/medRxiv preprint by DOI (10.1101/...), incl. journal-published version if any."""
    return await preprints.fetch_biorxiv_preprint(shared_http(), doi, server=server)


@mcp.tool()
@surface_rejections
async def biorxiv_recent(server: str = "biorxiv", days: int = 7, category: str | None = None, max_results: int = 30) -> dict:
    """List recent bioRxiv/medRxiv preprints in a date window (their API has no keyword search)."""
    return await preprints.recent_biorxiv(shared_http(), server=server, days=days, category=category, max_results=max_results)


# ---------- Layer 2: structured bio data ----------

@mcp.tool()
@surface_rejections
async def uniprot_search(query: str, max_results: int = 15, reviewed_only: bool = True) -> dict:
    """Search UniProtKB proteins (reviewed_only=True → curated Swiss-Prot entries)."""
    return await uniprot.search_uniprot(shared_http(), query, max_results=max_results, reviewed_only=reviewed_only)


@mcp.tool()
@surface_rejections
async def uniprot_entry(accession: str, include_sequence: bool = True) -> dict:
    """Full UniProt entry: function, localization, disease links, domains, PDB xrefs, sequence."""
    return await uniprot.fetch_uniprot_entry(shared_http(), accession, include_sequence=include_sequence)


@mcp.tool()
@surface_rejections
async def pdb_search(query: str, max_results: int = 15) -> dict:
    """Full-text search over RCSB PDB structures."""
    return await pdb.search_pdb(shared_http(), query, max_results=max_results)


@mcp.tool()
@surface_rejections
async def pdb_entry(pdb_id: str) -> dict:
    """RCSB PDB entry: method, resolution, primary citation, download URLs."""
    return await pdb.fetch_pdb_entry(shared_http(), pdb_id)


@mcp.tool()
@surface_rejections
async def ncbi_sequence_search(query: str, db: str = "nuccore", max_results: int = 20) -> dict:
    """Search NCBI Nucleotide ('nuccore') or Protein ('protein') databases."""
    return await ncbi_seq.search_ncbi_sequences(shared_http(), query, db=db, max_results=max_results)


@mcp.tool()
@surface_rejections
async def ncbi_fetch_sequence(accession: str, db: str = "nuccore", fmt: str = "fasta", save_path: str | None = None) -> dict:
    """Fetch a sequence record as FASTA or GenBank. Long records need save_path (absolute)."""
    return await ncbi_seq.fetch_sequence(shared_http(), accession, db=db, fmt=fmt, save_path=save_path)


@mcp.tool()
@surface_rejections
async def ensembl_gene(symbol: str, species: str = "homo_sapiens") -> dict:
    """Look up a gene symbol in Ensembl → gene ID, coordinates, biotype, canonical transcript."""
    return await ensembl.lookup_gene(shared_http(), symbol, species=species)


@mcp.tool()
@surface_rejections
async def ensembl_sequence(ensembl_id: str, seq_type: str = "genomic", save_path: str | None = None) -> dict:
    """Fetch FASTA for an Ensembl ID. seq_type: genomic|cds|cdna|protein."""
    return await ensembl.fetch_ensembl_sequence(shared_http(), ensembl_id, seq_type=seq_type, save_path=save_path)


@mcp.tool()
@surface_rejections
async def ensembl_xrefs(ensembl_gene_id: str, max_results: int = 100) -> dict:
    """Cross-references for an Ensembl gene (UniProt, RefSeq, HGNC...). Capped at max_results; `n_total` reports the full count."""
    return await ensembl.gene_xrefs(shared_http(), ensembl_gene_id, max_results=max_results)


# ---------- Layer 5: pathway knowledge ----------

@mcp.tool()
@surface_rejections
async def kegg_search(query: str, database: str = "pathway", max_results: int = 20) -> dict:
    """Search KEGG: pathway|ko|genes|compound|enzyme|disease|drug|module."""
    return await pathways.search_kegg(shared_http(), query, database=database, max_results=max_results)


@mcp.tool()
@surface_rejections
async def kegg_entry(kegg_id: str) -> dict:
    """Fetch a KEGG flat-file entry (e.g. 'hsa04110', 'path:map00010', 'C00031')."""
    return await pathways.fetch_kegg_entry(shared_http(), kegg_id)


@mcp.tool()
@surface_rejections
async def reactome_search(query: str, species: str = "Homo sapiens", max_results: int = 15) -> dict:
    """Search Reactome pathways/reactions/proteins with stable IDs."""
    return await pathways.search_reactome(shared_http(), query, species=species, max_results=max_results)


# ---------- Layer 3: compute ----------

@mcp.tool()
@surface_rejections
def run_python(script: str, timeout_s: int = 120, cwd: str | None = None) -> dict:
    """Run a Python script in the bio-mcp venv (biopython, pandas, scipy, numpy).

    cwd defaults to the bio-mcp workspace where ncbi_fetch_sequence/ensembl_sequence
    save files. Process-level isolation only (timeout, best-effort memory cap, output caps) —
    NOT a security sandbox; run trusted research code only.
    """
    return run_python_script(script, timeout_s=timeout_s, cwd=cwd)


@mcp.tool()
@surface_rejections
def list_workspace(subdir: str | None = None) -> dict:
    """List files in the bio-mcp workspace (where fetched sequences are saved)."""
    return _list_workspace(subdir)


# ---------- Layer 5: reference resources ----------

@mcp.resource("bio://glossary")
def glossary() -> str:
    """Bio-mcp domain glossary: databases, identifier formats, pathway schemas."""
    return (DOCS / "GLOSSARY.md").read_text()


@mcp.resource("bio://citation-style")
def citation_style() -> str:
    """The citation contract every bio answer must follow."""
    return (DOCS / "CITATION_STYLE.md").read_text()


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
