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

    # ---------- scholarly graph ----------
    Scenario("openalex search", "openalex_search", {"query": "CRISPR gene editing", "max_results": 5}, "ok",
             validate=lambda r: check_records(r, "works", id_key="openalex_id"), severity="high"),
    Scenario("openalex work by DOI", "openalex_work", {"work_id": "doi:10.7717/peerj.4375"}, "ok",
             validate=lambda r: _single_ok("openalex_id")(r), severity="medium",
             notes="abstract reconstructed from inverted index; must not be an empty string if present"),
    Scenario("openalex empty query rejected", "openalex_search", {"query": "  "}, "error", error_must_mention="empty"),
    Scenario("semantic scholar empty id rejected", "semantic_scholar_citations", {"paper_id": " "}, "error",
             error_must_mention="empty",
             notes="S2 LIVE happy-path is in smoke tests, not dogfood: unauthenticated 429 is correct upstream behavior, would flake the score"),

    # ---------- predicted structure + domains ----------
    Scenario("alphafold structure P04637", "alphafold_structure", {"uniprot_accession": "P04637"}, "ok",
             validate=lambda r: check_source(r) + ([] if r.get("model", {}).get("downloads") else ["no download URLs on model"]),
             severity="high"),
    Scenario("alphafold bogus accession clean error", "alphafold_structure", {"uniprot_accession": "NOTAUNIPROT9"}, "error",
             severity="medium"),
    Scenario("interpro domains P04637", "interpro_domains", {"uniprot_accession": "P04637"}, "ok",
             validate=lambda r: check_records(r, "entries", id_key="interpro_id"), severity="high"),
    Scenario("interpro entry IPR002117", "interpro_entry", {"interpro_id": "IPR002117"}, "ok",
             validate=lambda r: check_source(r) + ([] if r.get("name") else ["no name on InterPro entry"])),
    Scenario("interpro malformed id rejected", "interpro_entry", {"interpro_id": "NOTANIPR"}, "error",
             error_must_mention="IPR"),

    # ---------- variants / clinical ----------
    Scenario("clinvar search BRCA1", "clinvar_search", {"query": "BRCA1 pathogenic", "max_results": 5}, "ok",
             severity="high",
             validate=lambda r: check_records(r, "variants", id_key="variation_id")
             + ([] if "not medical advice" in (r.get("disclaimer") or "") else ["missing research-use disclaimer"])),
    Scenario("clinvar variant nonnumeric rejected", "clinvar_variant", {"variation_id": "BRCA1"}, "error",
             error_must_mention="numeric"),
    Scenario("dbsnp variant rs328", "dbsnp_variant", {"rsid": "rs328"}, "ok", severity="high",
             validate=lambda r: check_source(r) + ([] if r.get("rsid") == "rs328" else ["rsid not normalized to rs328"])),
    Scenario("dbsnp bad rsid rejected", "dbsnp_variant", {"rsid": "rsABC"}, "error"),
    Scenario("vep consequences rs699", "vep_consequences", {"variant": "rs699"}, "ok", severity="high",
             validate=lambda r: check_source(r) + ([] if r.get("most_severe_consequence") else ["no most_severe_consequence"])),
    Scenario("vep empty variant rejected", "vep_consequences", {"variant": " "}, "error", error_must_mention="empty"),

    # ---------- cheminformatics ----------
    Scenario("pubchem compound aspirin", "pubchem_compound", {"name": "aspirin"}, "ok", severity="high",
             validate=lambda r: check_source(r) + ([] if r.get("cid") and r.get("canonical_smiles") else ["missing CID or SMILES"])),
    Scenario("pubchem bogus name clean error", "pubchem_compound", {"name": "notarealcompoundxyz123"}, "error",
             severity="medium", notes="unresolvable name → PubChem 404 → clean tool error, not a crash"),
    Scenario("pubchem nonpositive cid rejected", "pubchem_compound_by_cid", {"cid": 0}, "error",
             error_must_mention="positive"),
    Scenario("chembl search imatinib", "chembl_search", {"query": "imatinib", "max_results": 5}, "ok",
             validate=lambda r: check_records(r, "molecules", id_key="chembl_id"), severity="high"),
    Scenario("chembl bioactivity bad id rejected", "chembl_bioactivity", {"chembl_id": "941"}, "error",
             error_must_mention="CHEMBL"),

    # ---------- hostile round 3: injection, identity, degraded-upstream ----------
    Scenario("pdb zero-hit search returns empty", "pdb_search", {"query": "zzqqxxjjkkww nonexistent structure zz"}, "ok",
             severity="high",
             validate=lambda r: [] if r.get("returned") == 0 and r.get("structures") == [] else [f"zero-hit search not empty-clean: {r.get('returned')}"],
             notes="RCSB answers zero hits with HTTP 204 empty body; must be returned=0, not an error"),
    Scenario("reactome names carry no markup", "reactome_search", {"query": "apoptosis"}, "ok", severity="medium",
             validate=lambda r: [f"HTML markup leaked into name: {e['name'][:80]}" for e in r.get("entries", []) if "<" in (e.get("name") or "")],
             notes="live Reactome wraps matches in double-quoted highlighting spans"),
    Scenario("kegg path traversal rejected/neutralized", "kegg_search", {"query": "../../get/hsa05224"}, "error",
             severity="high",
             notes="encoded query must NOT reroute /find to /get: KEGG 404s the literal '..%2F..' term → clean tool error. The catastrophic outcome this pins against is 200-with-fabricated-hits (pre-fix behavior)"),
    Scenario("vep traversal variant rejected", "vep_consequences", {"variant": "a:b/../../../../xrefs/id/ENSG00000157764"}, "error",
             severity="critical", error_must_mention="/",
             notes="provenance laundering: crafted HGVS must never reroute to another Ensembl endpoint and come back source-pinned"),
    Scenario("vep hostile species rejected", "vep_consequences", {"variant": "rs699", "species": "human/../../lookup/id"}, "error",
             severity="high", error_must_mention="species"),
    Scenario("ensembl newline symbol rejected", "ensembl_gene", {"symbol": "TP\n53"}, "error", severity="medium",
             notes="non-printable in a path segment must be a clean ValueError, not httpx.InvalidURL"),
    Scenario("dbsnp zero-padded rsid resolves", "dbsnp_variant", {"rsid": "rs00328"}, "ok", severity="medium",
             validate=lambda r: [] if r.get("rsid") == "rs328" else [f"zero-padded rsid not canonicalized: {r.get('rsid')}"]),
    Scenario("chembl truncated id rejected", "chembl_bioactivity", {"chembl_id": "CHEMBL"}, "error", severity="medium",
             notes="bare CHEMBL prefix used to pin a dead source URL"),
    Scenario("pubchem float cid rejected", "pubchem_compound_by_cid", {"cid": 2244.5}, "error", severity="medium",
             notes="int() truncation used to silently query the WRONG compound"),
    Scenario("openalex traversal id neutralized", "openalex_work", {"work_id": "W123/../../authors/A5023888391"}, "error",
             severity="high",
             notes="encoded id must not reroute /works to /authors; upstream 404 surfacing as a clean tool error is the pass condition"),
    Scenario("arxiv negative max_results rejected", "arxiv_search", {"query": "x", "max_results": -1}, "error",
             error_must_mention="max_results"),
    Scenario("biorxiv negative max_results rejected", "biorxiv_recent", {"max_results": -3}, "error",
             error_must_mention="max_results"),
    Scenario("pubmed all-bogus pmids reported missing", "pubmed_abstracts", {"pmids": ["banana"]}, "ok", severity="medium",
             validate=lambda r: [] if r.get("missing") == ["banana"] and r.get("returned") == 0 else [f"malformed pmid not pre-filed into missing: {r.get('missing')}"]),
    Scenario("pubmed book pmid parsed not missing", "pubmed_abstracts", {"pmids": ["20301546"]}, "ok", severity="medium",
             validate=lambda r: [] if r.get("returned") == 1 and not r.get("missing") else [f"book PMID mishandled: returned={r.get('returned')} missing={r.get('missing')}"],
             notes="PubmedBookArticle (GeneReviews) — used to vanish into `missing`"),
    Scenario("pmc bogus id clean error not embargo lie", "pmc_fulltext", {"pmcid": "PMC999999999"}, "error", severity="high",
             notes="nonexistent PMCID used to be reported as 'embargoed' with a pinned source to a nonexistent article"),

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
    Scenario("run_python future imports work", "run_python",
             {"script": "from __future__ import annotations\nprint('future-ok')"}, "ok", severity="medium",
             validate=lambda r: [] if r.get("exit_code") == 0 and "future-ok" in r.get("stdout", "") else [f"__future__ script failed: {r.get('stderr', '')[:150]}"],
             notes="the old RLIMIT prelude was prepended to the script, breaking __future__ and shifting tracebacks"),
    Scenario("run_python traceback line numbers honest", "run_python",
             {"script": "x = 1\ny = 2\nraise RuntimeError('here')"}, "ok", severity="medium",
             validate=lambda r: [] if "line 3" in r.get("stderr", "") else [f"user line numbers shifted: {r.get('stderr', '')[-200:]}"]),
    Scenario("run_python empty script rejected", "run_python", {"script": "  "}, "error", error_must_mention="empty"),
    Scenario("run_python relative cwd rejected", "run_python", {"script": "print(1)", "cwd": "rel/dir"}, "error",
             error_must_mention="absolute"),
    Scenario("run_python zero timeout rejected", "run_python", {"script": "print(1)", "timeout_s": 0}, "error",
             error_must_mention="positive"),
    Scenario("workspace escape blocked", "list_workspace", {"subdir": "../.."}, "error", error_must_mention="escape",
             severity="high"),
    Scenario("workspace listing works", "list_workspace", {}, "ok",
             validate=lambda r: [] if "files" in r else ["no files key"]),

    # ---------- wetware: workspace ops (ordered chain — runner is sequential) ----------
    Scenario("wetware write file", "wetware_write_file",
             {"path": "dogfood_wetware/probe.txt", "content": "dogfood-wetware-r1\n"}, "ok", severity="high",
             validate=lambda r: [] if r.get("path") == "dogfood_wetware/probe.txt" and r.get("bytes", 0) > 0 else [f"write result malformed: {r}"]),
    Scenario("wetware read back verbatim", "wetware_read_file", {"path": "dogfood_wetware/probe.txt"}, "ok",
             severity="high",
             validate=lambda r: [] if r.get("content") == "dogfood-wetware-r1\n" else [f"content mismatch after write: {r.get('content')!r}"]),
    Scenario("wetware append grows file", "wetware_write_file",
             {"path": "dogfood_wetware/probe.txt", "content": "line2\n", "append": True}, "ok",
             validate=lambda r: [] if r.get("appended") and r.get("bytes", 0) > len("dogfood-wetware-r1\n") else [f"append did not grow file: {r}"]),
    Scenario("wetware move within workspace", "wetware_move",
             {"src": "dogfood_wetware/probe.txt", "dst": "dogfood_wetware/moved.txt"}, "ok",
             validate=lambda r: [] if r.get("to") == "dogfood_wetware/moved.txt" else [f"move result malformed: {r}"]),
    Scenario("wetware content intact after move", "wetware_read_file", {"path": "dogfood_wetware/moved.txt"}, "ok",
             severity="high",
             validate=lambda r: [] if (r.get("content") or "").endswith("line2\n") else [f"content lost in move: {r.get('content')!r}"]),
    Scenario("wetware remove cleans up chain", "wetware_remove", {"path": "dogfood_wetware"}, "ok",
             validate=lambda r: [] if r.get("kind") == "directory" and r.get("files_removed") == 1 else [f"remove accounting wrong: {r}"]),

    # ---------- wetware: hostile file ops ----------
    Scenario("wetware write absolute path rejected", "wetware_write_file",
             {"path": "/etc/dogfood-pwned", "content": "x"}, "error", severity="critical", error_must_mention="absolute"),
    Scenario("wetware write escape rejected", "wetware_write_file",
             {"path": "../outside.txt", "content": "x"}, "error", severity="critical", error_must_mention="escape"),
    Scenario("wetware write into job state rejected", "wetware_write_file",
             {"path": ".wetware/jobs/fake/exit.json", "content": "{}"}, "error", severity="high",
             error_must_mention="job-runner",
             notes="file ops must not be able to forge job exit records"),
    Scenario("wetware write empty path rejected", "wetware_write_file", {"path": "  ", "content": "x"}, "error",
             error_must_mention="empty"),
    Scenario("wetware read escape rejected", "wetware_read_file", {"path": "../../etc/hosts"}, "error",
             severity="critical", error_must_mention="escape"),
    Scenario("wetware read missing file clean error", "wetware_read_file", {"path": "nope_xyz/missing.txt"}, "error",
             error_must_mention="no such file"),
    Scenario("wetware move nonexistent rejected", "wetware_move",
             {"src": "nope_xyz/a.txt", "dst": "nope_xyz/b.txt"}, "error", error_must_mention="does not exist"),
    Scenario("wetware remove workspace root refused", "wetware_remove", {"path": "."}, "error", severity="critical",
             error_must_mention="workspace root"),
    Scenario("wetware remove job state refused", "wetware_remove", {"path": ".wetware"}, "error", severity="high",
             error_must_mention="job-runner"),

    # ---------- wetware: hostile job control ----------
    Scenario("wetware job empty script rejected", "wetware_job_start", {"script": "   "}, "error",
             error_must_mention="empty"),
    Scenario("wetware job zero timeout rejected", "wetware_job_start", {"script": "print(1)", "timeout_s": 0}, "error",
             error_must_mention="positive"),
    Scenario("wetware job unknown id clean error", "wetware_job_status", {"job_id": "20990101-000000-deadbeef"}, "error",
             error_must_mention="unknown job"),
    Scenario("wetware job traversal id rejected", "wetware_job_status", {"job_id": "../../../etc"}, "error",
             severity="critical", error_must_mention="invalid job id",
             notes="job_id is used to build a path under .wetware/jobs — traversal must die before touching disk"),
    Scenario("wetware job cancel unknown id clean error", "wetware_job_cancel", {"job_id": "zz-not-a-job"}, "error",
             error_must_mention="unknown job"),
    Scenario("wetware jobs zero max rejected", "wetware_jobs", {"max_results": 0}, "error",
             error_must_mention="positive"),
    Scenario("wetware jobs listing works", "wetware_jobs", {}, "ok",
             validate=lambda r: [] if isinstance(r.get("jobs", None), list) or "note" in r else [f"no jobs list: {r}"]),
]
