"""Ensembl REST client (rest.ensembl.org): gene lookup, sequences, cross-refs."""

from __future__ import annotations

from ..citations import source_record
from ..http import BioAPIError, BioHTTP

ENSEMBL = "https://rest.ensembl.org"


async def lookup_gene(http: BioHTTP, symbol: str, *, species: str = "homo_sapiens") -> dict:
    """Gene symbol → Ensembl gene record (ID, coordinates, biotype, description)."""
    sym = symbol.strip()
    if not sym:
        raise ValueError("empty gene symbol")
    data = await http.get_json(
        f"{ENSEMBL}/lookup/symbol/{species}/{sym}",
        params={"expand": 0},
    )
    gene_id = data.get("id")
    if not gene_id:
        raise BioAPIError(f"Ensembl returned no gene for {sym!r} in {species}")
    return {
        "gene_id": gene_id,
        "symbol": data.get("display_name"),
        "species": data.get("species"),
        "description": data.get("description"),
        "biotype": data.get("biotype"),
        "region": f"{data.get('seq_region_name')}:{data.get('start')}-{data.get('end')}:{data.get('strand')}",
        "assembly": data.get("assembly_name"),
        "canonical_transcript": data.get("canonical_transcript"),
        "source": source_record("ensembl", gene_id),
    }


async def fetch_ensembl_sequence(
    http: BioHTTP,
    ensembl_id: str,
    *,
    seq_type: str = "genomic",
    save_path: str | None = None,
) -> dict:
    """Sequence for an Ensembl ID. seq_type: genomic | cds | cdna | protein."""
    from pathlib import Path

    ident = ensembl_id.strip()
    if not ident:
        raise ValueError("empty Ensembl ID")
    if seq_type not in ("genomic", "cds", "cdna", "protein"):
        raise ValueError(f"seq_type must be genomic|cds|cdna|protein, got {seq_type!r}")
    text = await http.get_text(
        f"{ENSEMBL}/sequence/id/{ident}",
        params={"type": seq_type},
        headers={"Content-Type": "text/x-fasta", "Accept": "text/x-fasta"},
    )
    text = text.strip()
    if not text.startswith(">"):
        raise BioAPIError(f"Ensembl returned non-FASTA for {ident}: {text[:150]}")
    result: dict = {
        "ensembl_id": ident,
        "seq_type": seq_type,
        "chars": len(text),
        "source": source_record("ensembl", ident),
    }
    if save_path:
        p = Path(save_path).expanduser()
        if not p.is_absolute():
            raise ValueError(f"save_path must be absolute, got {save_path!r}")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text + "\n")
        result["saved_to"] = str(p)
        result["preview"] = text[:400]
    elif len(text) > 200_000:
        raise ValueError(
            f"sequence for {ident} is {len(text):,} chars; pass save_path to write to a file"
        )
    else:
        result["fasta"] = text
    return result


async def gene_xrefs(http: BioHTTP, ensembl_gene_id: str) -> dict:
    """Cross-references for an Ensembl gene (UniProt, RefSeq, HGNC, ...)."""
    ident = ensembl_gene_id.strip()
    if not ident:
        raise ValueError("empty Ensembl gene ID")
    data = await http.get_json(f"{ENSEMBL}/xrefs/id/{ident}")
    if not isinstance(data, list):
        raise BioAPIError(f"unexpected xrefs payload for {ident}")
    refs = [
        {"db": x.get("dbname"), "id": x.get("primary_id"), "description": x.get("description")}
        for x in data
        if x.get("dbname") and x.get("primary_id")
    ]
    return {"ensembl_id": ident, "n_xrefs": len(refs), "xrefs": refs, "source": source_record("ensembl", ident)}
