"""Molecular structure coordinates for the 3D viewer.

Fetches the real model file for a structure node the floor already holds
(experimental PDB entry or AlphaFold prediction), caches the raw file
under data/structures/, and parses the C-alpha backbone into plain
coordinates the canvas renderer can draw.

Display-only lane: nothing here writes to the floor. Fetch hosts are the
two structure archives already on the floor's provenance allowlist —
nothing else is contacted.
"""

from __future__ import annotations

import re
import urllib.request
from pathlib import Path

CACHE_DIR = Path(__file__).resolve().parent.parent / "data" / "structures"

PDB_ID_RE = re.compile(r"^[0-9][A-Z0-9]{3}$")
AF_ID_RE = re.compile(r"^AF-([OPQ][0-9][A-Z0-9]{3}[0-9]"
                      r"|[A-NR-Z][0-9][A-Z][A-Z0-9]{2}[0-9])-F[0-9]+$")

RCSB_FILE_URL = "https://files.rcsb.org/download/{pdb_id}.pdb"
AF_FILE_URL = "https://alphafold.ebi.ac.uk/files/{af_id}-model_v4.pdb"

MAX_CA_ATOMS = 6000   # backbone cap; reported when hit, never silent
TIMEOUT_S = 20.0


def resolve_url(structure_id: str) -> str:
    """structure node value -> the one archive URL it may be fetched from."""
    sid = structure_id.strip().upper().removeprefix("STRUCTURE:")
    if PDB_ID_RE.fullmatch(sid):
        return RCSB_FILE_URL.format(pdb_id=sid)
    if AF_ID_RE.fullmatch(sid):
        return AF_FILE_URL.format(af_id=sid)
    raise ValueError(f"not a known structure id shape: {structure_id!r}")


def parse_ca_atoms(pdb_text: str, *, cap: int = MAX_CA_ATOMS) -> dict:
    """C-alpha trace from PDB-format text: one point per residue, chain-
    tagged, in file order (which is backbone order per chain). Pure
    function — unit-testable without any network."""
    atoms: list[dict] = []
    total = 0
    for line in pdb_text.splitlines():
        if not line.startswith("ATOM"):
            continue
        if line[12:16].strip() != "CA":
            continue
        # Alternate locations: keep only the first conformer.
        if line[16] not in (" ", "A"):
            continue
        total += 1
        if len(atoms) >= cap:
            continue
        try:
            atoms.append({
                "c": line[21].strip() or "A",
                "x": float(line[30:38]),
                "y": float(line[38:46]),
                "z": float(line[46:54]),
            })
        except ValueError:
            continue
    chains = sorted({a["c"] for a in atoms})
    return {"atoms": atoms, "chains": chains,
            "ca_total": total, "truncated": total > len(atoms)}


def fetch_structure(structure_id: str) -> dict:
    """Cached fetch + parse. The returned payload names its exact source
    URL and whether it came from cache — receipts, as everywhere."""
    url = resolve_url(structure_id)
    sid = structure_id.strip().upper().removeprefix("STRUCTURE:")
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache = CACHE_DIR / f"{sid}.pdb"
    cached = cache.is_file()
    if cached:
        text = cache.read_text()
    else:
        try:
            with urllib.request.urlopen(url, timeout=TIMEOUT_S) as resp:
                if resp.status != 200:
                    raise ValueError(f"{url} returned {resp.status}")
                text = resp.read().decode("utf-8", "replace")
        except OSError as e:
            raise ValueError(f"structure fetch failed: {e}") from e
        cache.write_text(text)
    parsed = parse_ca_atoms(text)
    return {"id": sid, "source_url": url, "cached": cached, **parsed}
