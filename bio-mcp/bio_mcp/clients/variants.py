"""Genetic-variant clients: ClinVar + dbSNP (NCBI E-utilities) and Ensembl VEP.

Endpoints:
- E-utilities: https://eutils.ncbi.nlm.nih.gov/entrez/eutils/{esearch,esummary}.fcgi
- Ensembl VEP:  https://rest.ensembl.org/vep/{species}/{id|hgvs}/...
Rate limiting + NCBI api_key injection live in bio_mcp.http.

CLINICAL-DATA CARE — read before touching anything here:
Clinical significance / classification strings and their review status (star
level) are REPORTED VERBATIM from the source database. We never paraphrase,
re-grade, or interpret a variant's pathogenicity, and we always carry the
classification together with its review_status — a classification without its
review status is misleading. Variant results additionally carry a top-level
`disclaimer` making the research-only, not-medical-advice posture explicit.
"""

from __future__ import annotations

import re

from ..citations import source_record
from ..http import BioAPIError, BioHTTP
from ..pathseg import path_segment

# Ensembl species names/aliases ('human', 'homo_sapiens') are lowercase
# [a-z0-9_]. The species is interpolated raw into the VEP path on BOTH input
# branches, so anything outside this alphabet ('human/../../lookup/id') is a
# route-change vector and must be rejected before a URL exists.
_VEP_SPECIES_RE = re.compile(r"[a-z0-9_]+")

EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
ENSEMBL = "https://rest.ensembl.org"

# Attached to every variant-level result. Verbatim, non-negotiable.
_DISCLAIMER = (
    "Research use only; not medical advice. Clinical significance and review "
    "status are reported verbatim from the source database."
)

# The three ClinVar classification axes as they appear in the modern esummary
# JSON. Each is an object with (at least) description + review_status. We surface
# whichever are populated, always description + review_status TOGETHER.
_CLINVAR_CLASSIFICATION_KEYS = (
    ("germline", "germline_classification"),
    ("clinical_impact", "clinical_impact_classification"),
    ("oncogenicity", "oncogenicity_classification"),
)


def _clinvar_classifications(doc: dict) -> dict[str, dict]:
    """Extract every populated classification axis VERBATIM.

    Returns e.g. {"germline": {"clinical_significance": "Pathogenic",
    "review_status": "criteria provided, single submitter", "last_evaluated": ...,
    "traits": [...]}}. An axis with an empty description is omitted (ClinVar ships
    empty germline/somatic blocks for variants classified on only one axis).
    """
    out: dict[str, dict] = {}
    for axis, key in _CLINVAR_CLASSIFICATION_KEYS:
        block = doc.get(key) or {}
        # `description` IS the clinical-significance string in this schema. Do not
        # rename, normalize, or title-case it — it is carried exactly as received.
        significance = (block.get("description") or "").strip()
        if not significance:
            continue
        # trait_set can be present-but-null and has been seen carrying bare
        # strings; only dict rows have a trait_name to surface.
        traits = [
            t.get("trait_name")
            for t in (block.get("trait_set") or [])
            if isinstance(t, dict) and t.get("trait_name")
        ]
        out[axis] = {
            "clinical_significance": significance,          # VERBATIM
            "review_status": block.get("review_status") or None,  # VERBATIM (star level)
            "last_evaluated": block.get("last_evaluated") or None,
            "traits": traits,
        }
    return out


def _clinvar_genes(doc: dict) -> list[str]:
    """Gene symbols from a ClinVar summary doc's `genes` list.

    `genes` can be present-but-null; rows can be malformed non-dicts.
    """
    return [
        g.get("symbol")
        for g in (doc.get("genes") or [])
        if isinstance(g, dict) and g.get("symbol")
    ]


def _require_summary_doc(result: dict, uid: str, *, db_label: str) -> dict:
    """Pull result[uid] and fail fast if E-utilities reported an error for it.

    A bogus/withdrawn UID comes back not as an HTTP error but as a doc carrying
    an `error` field (e.g. "cannot get document summary"). Swallowing that would
    emit an unpinned/empty record, so we raise instead.
    """
    doc = result.get(uid)
    if not doc:
        raise BioAPIError(f"{db_label} esummary returned no document for uid {uid!r}")
    err = doc.get("error")
    if err:
        raise BioAPIError(f"{db_label} esummary error for uid {uid!r}: {err}")
    return doc


def _clinvar_variant_from_doc(doc: dict, uid: str) -> dict:
    """Shared shaping for one ClinVar esummary doc → pinned variant record.

    `uid` is the ClinVar VariationID and the identifier we pin the source to.
    """
    # variation_set can carry bare strings; only dict members have the fields
    # we read below, so take the first DICT member (or nothing).
    variation_set = [v for v in (doc.get("variation_set") or []) if isinstance(v, dict)]
    first_set = variation_set[0] if variation_set else {}
    return {
        "variation_id": uid,
        "accession": doc.get("accession_version") or doc.get("accession"),
        "title": doc.get("title"),
        "genes": _clinvar_genes(doc),
        # top-level obj_type is the canonical variant type; variation_set echoes it.
        "variant_type": doc.get("obj_type") or first_set.get("variant_type"),
        "molecular_consequences": doc.get("molecular_consequence_list", []),
        "protein_change": doc.get("protein_change") or None,
        "canonical_spdi": first_set.get("canonical_spdi") or None,
        # description + review_status carried together, verbatim, per axis.
        "classifications": _clinvar_classifications(doc),
        "source": source_record("clinvar", uid),
    }


async def clinvar_search(http: BioHTTP, query: str, *, max_results: int = 15) -> dict:
    """esearch db=clinvar → VariationIDs, then esummary → pinned variant records.

    Classification strings and review statuses are carried VERBATIM (see module
    docstring). Returns {query, total_matches, returned, disclaimer, variants}.
    """
    if not query.strip():
        raise ValueError("empty ClinVar query")
    if max_results <= 0:
        raise ValueError(f"max_results must be positive, got {max_results}")

    data = await http.get_json(
        f"{EUTILS}/esearch.fcgi",
        params={
            "db": "clinvar",
            "term": query,
            "retmax": min(max_results, 100),
            "retmode": "json",
        },
    )
    result = data.get("esearchresult", {})
    uids = result.get("idlist", [])
    total = int(result.get("count", 0))

    variants: list[dict] = []
    if uids:
        summaries = await http.get_json(
            f"{EUTILS}/esummary.fcgi",
            params={"db": "clinvar", "id": ",".join(uids), "retmode": "json"},
        )
        res = summaries.get("result", {})
        for uid in uids:
            # A single withdrawn UID inside a batch shouldn't tank the whole search;
            # skip error docs here (they're logged upstream by nothing — but the
            # search contract is best-effort over the id list). Missing/blank docs
            # are simply omitted rather than emitted unpinned.
            doc = res.get(uid)
            if not doc or doc.get("error"):
                continue
            variants.append(_clinvar_variant_from_doc(doc, uid))

    return {
        "query": query,
        "total_matches": total,
        "returned": len(variants),
        "disclaimer": _DISCLAIMER,
        "variants": variants,
    }


async def clinvar_variant(http: BioHTTP, variation_id: str) -> dict:
    """Single ClinVar VariationID → full record with verbatim classification(s),
    review status, and trait/condition names. Pins source_record("clinvar", id).
    """
    vid = str(variation_id).strip()
    if not vid:
        raise ValueError("empty ClinVar variation_id")
    # isdecimal (not isdigit): exactly the digits int() accepts — superscripts
    # and the like pass isdigit but crash int().
    if not vid.isdecimal():
        raise ValueError(f"ClinVar variation_id must be a numeric VariationID, got {variation_id!r}")
    # NCBI canonicalizes esummary uids ('0012345' → uid '12345'); do the same or
    # the result[uid] lookup below misses its own document and reports a false
    # "no document" error.
    vid = str(int(vid))

    summaries = await http.get_json(
        f"{EUTILS}/esummary.fcgi",
        params={"db": "clinvar", "id": vid, "retmode": "json"},
    )
    doc = _require_summary_doc(summaries.get("result", {}), vid, db_label="ClinVar")
    record = _clinvar_variant_from_doc(doc, vid)
    record["disclaimer"] = _DISCLAIMER
    return record


def _normalize_rsid(rsid: str) -> tuple[str, str]:
    """('rs328' | '328' | 'rs00328') → ('328', 'rs328'). Raises on non-numeric.

    Returns (digits, full) so callers hit the API with digits and pin the source
    with the canonical 'rs...' identifier.
    """
    raw = str(rsid).strip()
    if not raw:
        raise ValueError("empty dbSNP rsid")
    digits = raw[2:] if raw.lower().startswith("rs") else raw
    # isdecimal (not isdigit): exactly the digits int() accepts — superscripts
    # and the like pass isdigit but crash int().
    if not digits.isdecimal():
        raise ValueError(f"dbSNP rsid must be 'rs<number>' or '<number>', got {rsid!r}")
    # NCBI canonicalizes esummary uids ('00328' → uid '328'); strip leading
    # zeros the same way or the result[uid] lookup misses its own document and
    # reports a false "no document" error.
    digits = str(int(digits))
    return digits, f"rs{digits}"


def _dbsnp_chrpos(doc: dict) -> str | None:
    """Best-effort 'chr:pos' for a dbSNP summary doc.

    The JSON esummary has no single chrpos field; it carries `chr` plus an SPDI
    string ('NC_000008.11:19962212:C:A,...'). We take the 0-based SPDI position
    of the first allele and render it 1-based alongside the chromosome. If SPDI
    is absent we fall back to just the chromosome. Returns None if neither is set.
    """
    chrom = (doc.get("chr") or "").strip()
    spdi = (doc.get("spdi") or "").strip()
    if spdi:
        # SPDI: <sequence>:<0-based position>:<deleted>:<inserted>
        parts = spdi.split(",")[0].split(":")
        if len(parts) >= 2 and parts[1].isdigit():
            pos_1based = int(parts[1]) + 1  # SPDI position is 0-based
            return f"{chrom}:{pos_1based}" if chrom else f"{parts[0]}:{pos_1based}"
    return chrom or None


async def dbsnp_variant(http: BioHTTP, rsid: str) -> dict:
    """dbSNP rsID → esummary db=snp record. Accepts 'rs328' or '328'.

    Pulls rsid, chromosome+position, gene(s), clinical_significance (if present,
    VERBATIM), alleles/SPDI, and the raw HGVS block. Pins source_record("dbsnp",
    "rs<digits>"). Carries the disclaimer because it can surface a clinical
    significance string.
    """
    digits, full = _normalize_rsid(rsid)

    summaries = await http.get_json(
        f"{EUTILS}/esummary.fcgi",
        params={"db": "snp", "id": digits, "retmode": "json"},
    )
    # db=snp nests data under result[uid]; the uid is the bare digit string.
    doc = _require_summary_doc(summaries.get("result", {}), digits, db_label="dbSNP")

    # Same guard shape as _clinvar_genes: present-but-null list, non-dict rows.
    genes = [g.get("name") for g in (doc.get("genes") or []) if isinstance(g, dict) and g.get("name")]
    # clinical_significance is a top-level string here (e.g. "benign"); carry it
    # VERBATIM, and only when the source actually populated it.
    significance = (doc.get("clinical_significance") or "").strip() or None
    # docsum embeds the HGVS list as 'HGVS=...|SEQ=...'; expose it raw so callers
    # can pick the notation they need without us re-deriving genomics.
    hgvs = None
    docsum = doc.get("docsum") or ""
    if docsum.startswith("HGVS="):
        hgvs = docsum.split("|", 1)[0][len("HGVS="):].split(",")

    return {
        "rsid": full,
        "chromosome": (doc.get("chr") or "").strip() or None,
        "position": _dbsnp_chrpos(doc),
        "assembly_accession": doc.get("acc") or None,
        "genes": genes,
        "clinical_significance": significance,  # VERBATIM (may be None)
        "spdi": (doc.get("spdi") or "").split(",") if doc.get("spdi") else [],
        "function_class": (doc.get("fxn_class") or "").split(",") if doc.get("fxn_class") else [],
        "hgvs": hgvs,
        "disclaimer": _DISCLAIMER,
        "source": source_record("dbsnp", full),
    }


def _vep_transcript(tc: dict) -> dict:
    """Shape one VEP transcript_consequence, keeping SIFT/PolyPhen only if present."""
    out: dict = {
        "gene_symbol": tc.get("gene_symbol"),
        "gene_id": tc.get("gene_id"),
        "transcript_id": tc.get("transcript_id"),
        "biotype": tc.get("biotype"),
        "consequence_terms": tc.get("consequence_terms", []),
        "impact": tc.get("impact"),
    }
    # SIFT / PolyPhen are only emitted for missense-ish consequences; include the
    # verbatim prediction + score together when the source provides them.
    if "sift_prediction" in tc or "sift_score" in tc:
        out["sift"] = {"prediction": tc.get("sift_prediction"), "score": tc.get("sift_score")}
    if "polyphen_prediction" in tc or "polyphen_score" in tc:
        out["polyphen"] = {
            "prediction": tc.get("polyphen_prediction"),
            "score": tc.get("polyphen_score"),
        }
    return out


async def vep_consequences(http: BioHTTP, variant: str, *, species: str = "human") -> dict:
    """Ensembl VEP: predicted consequences for an rsID or an HGVS notation.

    Input modes:
    - rsID (e.g. 'rs699')        → /vep/{species}/id/{rsid}
    - HGVS  (contains ':', e.g.  → /vep/{species}/hgvs/{hgvs}
      'ENST00000366667.4:c.776T>C')

    Returns most_severe_consequence + a list of transcript_consequences.
    Source pinning: an rsID input pins to dbSNP (the identifier is a dbSNP rs
    accession); an HGVS input has no dbSNP id, so we pin to Ensembl keyed on the
    exact HGVS string the caller supplied (the VEP query IS the provenance).

    Both `variant` and `species` are URL path segments, so both are validated
    BEFORE any URL is built: a '/' in either is rejected (ValueError), and the
    HGVS notation is percent-encoded with only its own ':' left literal.
    """
    var = str(variant).strip()
    if not var:
        raise ValueError("empty VEP variant")
    if "/" in var:
        # No VEP input notation contains '/'. Interpolated raw, a slash lets a
        # crafted variant ('a:b/../../../../xrefs/id/...') climb out of /vep/
        # and return a fully-shaped, source-pinned record from a DIFFERENT
        # endpoint family (provenance laundering, live-repro'd 2026-09-17).
        raise ValueError(f"VEP variant must not contain '/', got {variant!r}")
    sp = str(species).strip().lower()
    if not _VEP_SPECIES_RE.fullmatch(sp):
        raise ValueError(
            f"VEP species must be an Ensembl species name matching [a-z0-9_]+, got {species!r}"
        )

    is_hgvs = ":" in var
    if is_hgvs:
        # path_segment: rejects non-printables, percent-encodes everything
        # route-significant; safe=':' keeps HGVS's own separator literal.
        url = f"{ENSEMBL}/vep/{sp}/hgvs/{path_segment(var, what='VEP HGVS variant', safe=':')}"
        # HGVS has no dbSNP accession — pin provenance to Ensembl on the query.
        source = source_record("ensembl", var)
    else:
        # Treat as an rsID; validate/normalize so 'RS699'/'699' also work and the
        # dbSNP source id is canonical.
        digits, full = _normalize_rsid(var)
        var = full
        url = f"{ENSEMBL}/vep/{sp}/id/{full}"
        source = source_record("dbsnp", full)

    data = await http.get_json(url, params={"content-type": "application/json"})
    # VEP returns a JSON array (one element per input variant); we send one.
    if not isinstance(data, list) or not data:
        raise BioAPIError(f"Ensembl VEP returned no consequences for {var!r}")
    rec = data[0]

    transcripts = [_vep_transcript(tc) for tc in rec.get("transcript_consequences", [])]
    return {
        "variant": var,
        "input_mode": "hgvs" if is_hgvs else "rsid",
        "species": sp,  # the normalized name actually queried
        "assembly": rec.get("assembly_name"),
        "location": (
            f"{rec.get('seq_region_name')}:{rec.get('start')}-{rec.get('end')}"
            if rec.get("seq_region_name")
            else None
        ),
        "allele_string": rec.get("allele_string"),
        "most_severe_consequence": rec.get("most_severe_consequence"),
        "transcript_consequences": transcripts,
        "disclaimer": _DISCLAIMER,
        "source": source,
    }
