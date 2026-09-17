"""Dogfood scenario table: happy paths, hostile inputs, upstream edges.

expect:
  "ok"    — call must succeed AND validators must hold
  "error" — call must fail with a CLEAN, informative tool error (validation
            gaps that silently succeed are findings)
Severity is what the finding is worth if this scenario cracks.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

from .contracts import check_citation, check_records, check_source


@dataclass
class Scenario:
    name: str
    tool: str
    args: dict
    expect: str  # "ok" | "error"
    severity: str = "medium"  # low | medium | high | critical
    validate: Callable[[dict], list[str]] | None = None
    error_must_mention: str | None = None
    notes: str = ""
    kind: str = "tool"  # "tool" | "resource"


def _lit_ok(list_key: str, id_key: str):
    def v(result: dict) -> list[str]:
        findings = check_records(result, list_key, id_key=id_key)
        for rec in result.get(list_key, [])[:5]:
            findings.extend(check_citation(rec))
        return findings
    return v


def _single_ok(id_key: str):
    def v(result: dict) -> list[str]:
        findings = check_source(result)
        if not result.get(id_key):
            findings.append(f"missing {id_key!r} on result")
        return findings
    return v


SCENARIOS: list[Scenario] = [
    # ---------- resources ----------
    Scenario("glossary resource readable", "bio://glossary", {}, "ok", kind="resource", severity="high"),
    Scenario("citation-style resource readable", "bio://citation-style", {}, "ok", kind="resource", severity="high"),

    # ---------- literature: happy ----------
    Scenario("pubmed basic search", "pubmed_search", {"query": "CRISPR base editing", "max_results": 5}, "ok",
             validate=_lit_ok("articles", "pmid"), severity="high"),
    Scenario("pubmed unicode query (β-catenin)", "pubmed_search", {"query": "β-catenin Wnt signaling", "max_results": 3}, "ok",
             validate=_lit_ok("articles", "pmid"), severity="high"),
    Scenario("pubmed quoted-phrase query", "pubmed_search", {"query": 'p53 "gain of function" mutation', "max_results": 3}, "ok",
             validate=_lit_ok("articles", "pmid")),
    Scenario("pubmed sort=pub_date", "pubmed_search", {"query": "organoid", "max_results": 3, "sort": "pub_date"}, "ok",
             validate=_lit_ok("articles", "pmid")),
    Scenario("pubmed abstracts by pmid", "pubmed_abstracts", {"pmids": ["34265844"]}, "ok",
             validate=lambda r: check_records(r, "articles", id_key="pmid")
             + ([] if isinstance(r.get("missing"), list) else ["no per-ID `missing` accounting on result"]),
             notes="dict contract: {requested, returned, missing, articles}"),
    Scenario("pmc open-access fulltext", "pmc_fulltext", {"pmcid": "PMC8371605", "max_chars": 5000}, "ok",
             validate=lambda r: check_source(r) + ([] if r.get("full_text_available") else ["known-OA article reported unavailable"]),
             severity="high"),
    Scenario("arxiv q-bio search", "arxiv_search", {"query": "protein structure prediction", "max_results": 4, "category": "q-bio"}, "ok",
             validate=_lit_ok("papers", "arxiv_id")),
    Scenario("biorxiv fetch known preprint", "biorxiv_fetch", {"doi": "10.1101/2020.02.07.937862"}, "ok",
             validate=lambda r: check_source(r) + ([] if r.get("latest", {}).get("title") else ["no title on latest version"])),
    Scenario("biorxiv recent window freshness", "biorxiv_recent", {"days": 10, "max_results": 30}, "ok",
             validate=None, severity="high",
             notes="runner applies special freshness check: are returned dates near the window END or only its start (pagination blindness)?"),

    # ---------- literature: hostile ----------
    Scenario("pubmed empty query rejected", "pubmed_search", {"query": "   "}, "error", error_must_mention="empty"),
    Scenario("pubmed 101 pmids rejected", "pubmed_abstracts", {"pmids": [str(i) for i in range(101)]}, "error",
             error_must_mention="100"),
    Scenario("pubmed nonexistent pmid honest", "pubmed_abstracts", {"pmids": ["999999999"]}, "ok", severity="high",
             validate=None, notes="runner special-check: silently returning [] for a bogus PMID without any note = silent-drop finding"),
    Scenario("pmc rejects non-PMC id", "pmc_fulltext", {"pmcid": "34265844"}, "error", error_must_mention="PMC"),
    Scenario("biorxiv rejects foreign DOI", "biorxiv_fetch", {"doi": "10.1038/s41586-021-03819-2"}, "error",
             error_must_mention="10.1101"),
    Scenario("biorxiv rejects bad server", "biorxiv_fetch", {"doi": "10.1101/2020.02.07.937862", "server": "chemrxiv"}, "error",
             error_must_mention="server"),
    Scenario("arxiv empty query rejected", "arxiv_search", {"query": ""}, "error", error_must_mention="empty"),

    # ---------- bio data: happy ----------
    Scenario("uniprot search kinase", "uniprot_search", {"query": "human tyrosine kinase", "max_results": 5}, "ok",
             validate=lambda r: check_records(r, "proteins", id_key="accession"), severity="high"),
    Scenario("uniprot entry P04637", "uniprot_entry", {"accession": "P04637", "include_sequence": False}, "ok",
             validate=lambda r: _single_ok("accession")(r) + ([] if r.get("function") else ["no function comments on P53_HUMAN"]),
             severity="high"),
    Scenario("pdb search spike", "pdb_search", {"query": "SARS-CoV-2 spike glycoprotein", "max_results": 5}, "ok",
             validate=lambda r: check_records(r, "structures", id_key="pdb_id")),
    Scenario("pdb entry 6VXX", "pdb_entry", {"pdb_id": "6VXX"}, "ok",
             validate=lambda r: _single_ok("pdb_id")(r) + ([] if r.get("primary_citation", {}).get("pmid") else ["no PMID on primary citation"])),
    Scenario("ncbi nuccore search", "ncbi_sequence_search", {"query": "SARS-CoV-2 complete genome refseq", "max_results": 5}, "ok",
             validate=lambda r: check_records(r, "records", id_key="accession")),
    Scenario("ncbi fetch small fasta inline", "ncbi_fetch_sequence", {"accession": "NM_000546.6", "fmt": "fasta"}, "ok",
             validate=lambda r: _single_ok("accession")(r) + ([] if str(r.get("text", "")).startswith(">") else ["inline text is not FASTA"]),
             severity="high"),
    Scenario("ncbi PROTEIN db + genbank fmt", "ncbi_fetch_sequence", {"accession": "NP_000537.3", "db": "protein", "fmt": "genbank"}, "ok",
             severity="high",
             validate=lambda r: _single_ok("accession")(r) + ([] if "LOCUS" in str(r.get("text", ""))[:200] else ["protein GenBank(GenPept) text malformed — rettype mismatch?"]),
             notes="suspect: rettype 'gb' vs required 'gp' for protein db"),
    Scenario("ensembl gene TP53", "ensembl_gene", {"symbol": "TP53"}, "ok",
             validate=lambda r: _single_ok("gene_id")(r) + ([] if r.get("assembly") else ["no assembly name"]), severity="high"),
    Scenario("ensembl protein sequence", "ensembl_sequence", {"ensembl_id": "ENSP00000269305", "seq_type": "protein"}, "ok",
             validate=lambda r: _single_ok("ensembl_id")(r) + ([] if str(r.get("fasta", r.get("preview", ""))).startswith(">") else ["not FASTA"])),
    Scenario("ensembl xrefs bounded?", "ensembl_xrefs", {"ensembl_gene_id": "ENSG00000141510"}, "ok", severity="medium",
             validate=lambda r: _single_ok("ensembl_id")(r) + (["unbounded xrefs payload: n_xrefs=" + str(r.get("n_xrefs")) + " with no cap/pagination param"] if (r.get("n_xrefs") or 0) > 150 else [])),

    # ---------- bio data: hostile ----------
    Scenario("uniprot bogus accession clean error", "uniprot_entry", {"accession": "NOTANACC99"}, "error", severity="high"),
    Scenario("uniprot isoform accession behavior", "uniprot_entry", {"accession": "P04637-2"}, "ok", severity="medium",
             notes="runner accepts EITHER clean success or clean error; crash/ugly error = finding"),
    Scenario("pdb 5-char id rejected", "pdb_entry", {"pdb_id": "TOOLONG"}, "error", error_must_mention="4"),
    Scenario("pdb nonexistent id clean error", "pdb_entry", {"pdb_id": "9ZZ9"}, "error", severity="high"),
    Scenario("ncbi bad db rejected", "ncbi_fetch_sequence", {"accession": "X", "db": "genome"}, "error", error_must_mention="db"),
    Scenario("ncbi relative save_path rejected", "ncbi_fetch_sequence", {"accession": "NM_000546.6", "save_path": "rel/x.fasta"}, "error",
             error_must_mention="absolute"),
    Scenario("ncbi huge genome without save_path", "ncbi_fetch_sequence", {"accession": "NC_000001.11", "fmt": "fasta"}, "error",
             severity="high", error_must_mention="save_path",
             notes="chr1 ~248 Mb: must refuse inline, must NOT try to buffer forever; runner enforces 120s deadline"),
    Scenario("ensembl bogus symbol clean error", "ensembl_gene", {"symbol": "NOTAGENE123"}, "error", severity="high"),
    Scenario("ensembl bad seq_type rejected", "ensembl_sequence", {"ensembl_id": "ENSG00000141510", "seq_type": "rna"}, "error",
             error_must_mention="seq_type"),

    # ---------- pathways ----------
    Scenario("kegg pathway search", "kegg_search", {"query": "glycolysis"}, "ok",
             validate=lambda r: check_records(r, "entries", id_key="kegg_id")),
    Scenario("kegg entry hsa04110", "kegg_entry", {"kegg_id": "hsa04110"}, "ok",
             validate=lambda r: _single_ok("kegg_id")(r) + ([] if r.get("name") else ["NAME not parsed from flat file"])),
    Scenario("kegg bogus id clean error", "kegg_entry", {"kegg_id": "zzz99999"}, "error", severity="high"),
    Scenario("kegg bad database rejected", "kegg_search", {"query": "x", "database": "proteins"}, "error",
             error_must_mention="database"),
    Scenario("reactome apoptosis search", "reactome_search", {"query": "apoptosis"}, "ok",
             validate=lambda r: check_records(r, "entries", id_key="stable_id")),
    Scenario("reactome nonsense query honest", "reactome_search", {"query": "zqxjkwvbnm nonexistent pathway"}, "ok",
             severity="medium", notes="runner special-check: 0 results must be reported as 0, not error/fabrication"),

    # ---------- compute ----------
    Scenario("run_python libs available", "run_python",
             {"script": "import Bio, pandas, scipy, numpy; print('ok', Bio.__version__)"}, "ok",
             validate=lambda r: [] if r.get("exit_code") == 0 and "ok" in r.get("stdout", "") else [f"libs import failed: {r.get('stderr', '')[:200]}"],
             severity="critical"),
    Scenario("run_python timeout honored", "run_python", {"script": "import time; time.sleep(60)", "timeout_s": 3}, "ok",
             validate=lambda r: [] if r.get("timed_out") else ["timeout not honored"], severity="critical"),
    Scenario("run_python non-utf8 stdout survives", "run_python",
             {"script": "import sys; sys.stdout.buffer.write(b'\\xff\\xfe raw bytes\\n'); sys.stdout.buffer.flush()"}, "ok",
             severity="high", validate=lambda r: [] if isinstance(r.get("stdout"), str) else ["stdout not a string"],
             notes="suspect: text=True strict decode raises inside the tool"),
    Scenario("run_python huge output capped", "run_python", {"script": "print('y' * 500_000)"}, "ok",
             validate=lambda r: [] if r.get("truncated") and len(r.get("stdout", "")) <= 40_000 else ["output not capped/flagged"]),
    Scenario("run_python empty script rejected", "run_python", {"script": "  "}, "error", error_must_mention="empty"),
    Scenario("run_python relative cwd rejected", "run_python", {"script": "print(1)", "cwd": "rel/dir"}, "error",
             error_must_mention="absolute"),
    Scenario("run_python zero timeout rejected", "run_python", {"script": "print(1)", "timeout_s": 0}, "error",
             error_must_mention="positive"),
    Scenario("workspace escape blocked", "list_workspace", {"subdir": "../.."}, "error", error_must_mention="escape",
             severity="high"),
    Scenario("workspace listing works", "list_workspace", {}, "ok",
             validate=lambda r: [] if "files" in r else ["no files key"]),
]
