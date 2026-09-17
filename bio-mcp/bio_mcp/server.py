"""bio-mcp server: typed bio-science research tools over MCP (stdio).

Layer map (see README.md):
  1 literature   → pubmed_search, pubmed_abstracts, pmc_fulltext,
                   arxiv_search, biorxiv_fetch, biorxiv_recent
  2 bio data     → uniprot_search, uniprot_entry, pdb_search, pdb_entry,
                   ncbi_sequence_search, ncbi_fetch_sequence,
                   ensembl_gene, ensembl_sequence, ensembl_xrefs
  3 compute      → run_python, list_workspace
  3b wetware     → wetware_write_file, wetware_read_file, wetware_move,
                   wetware_remove, wetware_job_start, wetware_job_status,
                   wetware_job_output, wetware_job_cancel, wetware_jobs
  5 knowledge    → kegg_search, kegg_entry, reactome_search
                   + resources bio://glossary, bio://citation-style
  4 verification → every result carries source{database,id,url,retrieved};
                   citation strings are Vancouver-style (docs/CITATION_STYLE.md).
"""

from __future__ import annotations

from pathlib import Path

from mcp.server.mcpserver import MCPServer

from .clients import (
    chem,
    ensembl,
    ncbi_seq,
    pathways,
    pdb,
    preprints,
    pubmed,
    scholarly,
    structure_extra,
    uniprot,
    variants,
)
from .errors import surface_rejections
from .http import shared_http
from .sandbox import list_workspace as _list_workspace
from .sandbox import run_python_script
from .wetware import jobs as wetware_jobs_mod
from .wetware import workspace_ops

DOCS = Path(__file__).resolve().parent.parent / "docs"

mcp = MCPServer(
    "bio-research",
    instructions=(
        "Grounded bio-science research tools spanning literature (PubMed/PMC/arXiv/"
        "bioRxiv), scholarly graph (OpenAlex/Semantic Scholar), proteins & structure "
        "(UniProt/PDB/AlphaFold/InterPro), genomics (Ensembl/NCBI), variants (ClinVar/"
        "dbSNP/VEP), cheminformatics (PubChem/ChEMBL), and pathways (KEGG/Reactome). "
        "Every result carries a `source` block (database, accession/PMID, URL) — cite "
        "those identifiers, never paraphrase molecular biology from memory when a tool "
        "can pin it. Variant/clinical tools report significance VERBATIM and are for "
        "research use only, not medical advice. Sequences and molecules can be analyzed "
        "with run_python (biopython/pandas/scipy/rdkit)."
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


# ---------- Layer 1b: scholarly citation graph ----------

@mcp.tool()
@surface_rejections
async def openalex_search(query: str, max_results: int = 15) -> dict:
    """Search OpenAlex scholarly works (open metadata: any discipline, citation counts, no key)."""
    return await scholarly.search_openalex(shared_http(), query, max_results=max_results)


@mcp.tool()
@surface_rejections
async def openalex_work(work_id: str) -> dict:
    """One OpenAlex work by ID or DOI (W-id, 'doi:10...', or DOI URL): abstract, references, concepts."""
    return await scholarly.openalex_work(shared_http(), work_id)


@mcp.tool()
@surface_rejections
async def semantic_scholar_search(query: str, max_results: int = 15) -> dict:
    """Search Semantic Scholar papers (abstracts, citation counts). Unauthenticated tier is rate-limited."""
    return await scholarly.search_semantic_scholar(shared_http(), query, max_results=max_results)


@mcp.tool()
@surface_rejections
async def semantic_scholar_citations(paper_id: str, max_results: int = 25) -> dict:
    """Papers that CITE a given Semantic Scholar paper (S2 id or 'DOI:10...'). Forward citation graph."""
    return await scholarly.semantic_scholar_citations(shared_http(), paper_id, max_results=max_results)


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


# ---------- Layer 2b: predicted structure + protein domains ----------

@mcp.tool()
@surface_rejections
async def alphafold_structure(uniprot_accession: str) -> dict:
    """AlphaFold DB predicted structure for a UniProt accession → model + cif/pdb/PAE download URLs."""
    return await structure_extra.alphafold_prediction(shared_http(), uniprot_accession)


@mcp.tool()
@surface_rejections
async def interpro_domains(uniprot_accession: str) -> dict:
    """InterPro families/domains/sites matching a UniProt protein (returned=0 is honest, not an error)."""
    return await structure_extra.interpro_protein_domains(shared_http(), uniprot_accession)


@mcp.tool()
@surface_rejections
async def interpro_entry(interpro_id: str) -> dict:
    """Metadata for one InterPro entry (IPR######): name, type, description, member databases."""
    return await structure_extra.interpro_entry(shared_http(), interpro_id)


# ---------- Layer 2c: variants & clinical (research use only) ----------

@mcp.tool()
@surface_rejections
async def clinvar_search(query: str, max_results: int = 15) -> dict:
    """Search ClinVar variants. Clinical significance + review status reported VERBATIM. Research use only."""
    return await variants.clinvar_search(shared_http(), query, max_results=max_results)


@mcp.tool()
@surface_rejections
async def clinvar_variant(variation_id: str) -> dict:
    """One ClinVar VariationID: verbatim classifications (significance + review status) + conditions. Research use only."""
    return await variants.clinvar_variant(shared_http(), variation_id)


@mcp.tool()
@surface_rejections
async def dbsnp_variant(rsid: str) -> dict:
    """dbSNP record for an rsID ('rs328' or '328'): location, genes, alleles, clinical significance if any."""
    return await variants.dbsnp_variant(shared_http(), rsid)


@mcp.tool()
@surface_rejections
async def vep_consequences(variant: str, species: str = "human") -> dict:
    """Ensembl VEP: predicted consequences for an rsID or HGVS notation. Research use only."""
    return await variants.vep_consequences(shared_http(), variant, species=species)


# ---------- Layer 2d: cheminformatics ----------

@mcp.tool()
@surface_rejections
async def pubchem_compound(name: str) -> dict:
    """Resolve a compound NAME via PubChem → CID, formula, weight, SMILES, InChIKey, XLogP."""
    return await chem.pubchem_compound_by_name(shared_http(), name)


@mcp.tool()
@surface_rejections
async def pubchem_compound_by_cid(cid: int) -> dict:
    """PubChem compound properties by numeric CID."""
    return await chem.pubchem_compound_by_cid(shared_http(), cid)


@mcp.tool()
@surface_rejections
async def chembl_search(query: str, max_results: int = 15) -> dict:
    """Search ChEMBL molecules → CHEMBL IDs, clinical phase, molecular properties."""
    return await chem.chembl_search_molecule(shared_http(), query, max_results=max_results)


@mcp.tool()
@surface_rejections
async def chembl_bioactivity(chembl_id: str, max_results: int = 25) -> dict:
    """Measured bioactivities (IC50/Ki/...) for a ChEMBL molecule ID against biological targets."""
    return await chem.chembl_bioactivities(shared_http(), chembl_id, max_results=max_results)


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


# ---------- Layer 3b: wetware actuation lane ----------

@mcp.tool()
@surface_rejections
def wetware_write_file(path: str, content: str, append: bool = False) -> dict:
    """Write (or append) a text file inside the bio-mcp workspace. Path is workspace-relative."""
    return workspace_ops.write_file(path, content, append=append)


@mcp.tool()
@surface_rejections
def wetware_read_file(path: str, max_chars: int = 200000) -> dict:
    """Read a workspace file as text (results, FASTA, CSVs written by jobs or fetches)."""
    return workspace_ops.read_file(path, max_chars=max_chars)


@mcp.tool()
@surface_rejections
def wetware_move(src: str, dst: str) -> dict:
    """Move/rename a file or directory within the workspace."""
    return workspace_ops.move_path(src, dst)


@mcp.tool()
@surface_rejections
def wetware_remove(path: str) -> dict:
    """Delete a workspace file or directory tree (workspace root and job state refused)."""
    return workspace_ops.remove_path(path)


@mcp.tool()
@surface_rejections
def wetware_job_start(script: str, label: str | None = None, timeout_s: int = 3600) -> dict:
    """Start a long-running Python job (simulation/analysis) in the background.

    Runs in the bio-mcp venv with the same process isolation as run_python but
    detached — survives this server restarting. Returns a job_id immediately;
    poll wetware_job_status / wetware_job_output. Max timeout 24h.
    """
    return wetware_jobs_mod.start_job(script, label=label, timeout_s=timeout_s)


@mcp.tool()
@surface_rejections
def wetware_job_status(job_id: str) -> dict:
    """State of a background job: running | finished (exit_code/timed_out/cancelled) | died."""
    return wetware_jobs_mod.job_status(job_id)


@mcp.tool()
@surface_rejections
def wetware_job_output(job_id: str, tail_chars: int = 10000) -> dict:
    """Tail of a job's stdout/stderr — readable while it runs and after it exits."""
    return wetware_jobs_mod.job_output(job_id, tail_chars=tail_chars)


@mcp.tool()
@surface_rejections
def wetware_job_cancel(job_id: str) -> dict:
    """Cancel a running job (SIGTERM to its process group); the cancel is recorded."""
    return wetware_jobs_mod.cancel_job(job_id)


@mcp.tool()
@surface_rejections
def wetware_jobs(max_results: int = 50) -> dict:
    """List recent background jobs with their states, newest first."""
    return wetware_jobs_mod.list_jobs(max_results)


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
