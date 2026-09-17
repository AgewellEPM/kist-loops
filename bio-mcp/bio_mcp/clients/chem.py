"""Cheminformatics: PubChem PUG REST (small molecules) + ChEMBL (bioactivity).

PubChem: https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/...   (JSON PropertyTable)
ChEMBL:  https://www.ebi.ac.uk/chembl/api/data/{molecule,activity}  (?format=json)

Both are keyless. Compound *properties* come from PubChem's PUG REST property
table; *bioactivity* (assay measurements: IC50/Ki/...) comes from ChEMBL's data
web-services. Names are pinned to a CID (PubChem) and every molecule/activity
row is pinned to a CHEMBL id — a row without a resolvable source is a bug.
"""

from __future__ import annotations

from urllib.parse import quote

from ..citations import source_record
from ..http import BioAPIError, BioHTTP

PUBCHEM = "https://pubchem.ncbi.nlm.nih.gov/rest/pug"
CHEMBL = "https://www.ebi.ac.uk/chembl/api/data"

# The PUG REST property set we request for every compound lookup, mapped into
# snake_case result keys below.
#
# SMILES KEY MIGRATION (verified live 2026-09-17): PubChem PUG REST DEPRECATED
# `CanonicalSMILES` and `IsomericSMILES` — requesting them now silently returns
# them as null. The live table exposes `SMILES` (absolute/isomeric SMILES,
# successor to IsomericSMILES) and `ConnectivitySMILES` (flat connectivity,
# successor to CanonicalSMILES). We request BOTH the new and legacy names so the
# client keeps working if PubChem ever restores the old tags, then resolve
# new-first with a legacy fallback (see _compound_record). Result keys stay
# `canonical_smiles` / `isomeric_smiles` for a stable downstream contract.
_PUBCHEM_PROPS = (
    "MolecularFormula,MolecularWeight,SMILES,ConnectivitySMILES,"
    "CanonicalSMILES,IsomericSMILES,IUPACName,InChIKey,XLogP"
)


def _compound_record(name: str | None, props: dict) -> dict:
    """Shape one PubChem PropertyTable row into our result dict.

    `props` is a single object out of PropertyTable.Properties. It always
    carries CID; the chemistry fields are present only when PubChem has them
    (e.g. XLogP is missing for salts/mixtures) — absent fields surface as None.
    """
    cid = props.get("CID")
    if cid is None:  # PropertyTable without a CID is unusable — cannot pin a source.
        raise BioAPIError(f"PubChem property row missing CID: {props!r}")
    return {
        "name": name,
        "cid": cid,
        "molecular_formula": props.get("MolecularFormula"),
        "molecular_weight": props.get("MolecularWeight"),
        # New PubChem key first, legacy fallback second (see _PUBCHEM_PROPS note):
        # ConnectivitySMILES ≈ old CanonicalSMILES; SMILES ≈ old IsomericSMILES.
        "canonical_smiles": props.get("ConnectivitySMILES") or props.get("CanonicalSMILES"),
        "isomeric_smiles": props.get("SMILES") or props.get("IsomericSMILES"),
        "iupac_name": props.get("IUPACName"),
        "inchikey": props.get("InChIKey"),
        "xlogp": props.get("XLogP"),
        # source id must be the CID as a string (citations builds the compound URL).
        "source": source_record("pubchem", str(cid)),
    }


async def pubchem_compound_by_name(http: BioHTTP, name: str) -> dict:
    """Resolve a compound *name* to its PubChem CID + core physicochemical props.

    A name PubChem cannot resolve returns HTTP 404, which the shared client
    raises as BioAPIError — that is the correct, non-swallowed behavior.
    """
    if not name.strip():
        raise ValueError("empty PubChem compound name")
    # The name is a PATH segment, not a query param, so httpx will NOT encode it.
    # Names legitimately contain spaces, commas, and slashes ("N,N-dimethyl...",
    # "3-hydroxy..."), so percent-encode with safe="" — a bare '/' would fork the
    # REST route and a space would break the request line.
    encoded = quote(name.strip(), safe="")
    data = await http.get_json(f"{PUBCHEM}/compound/name/{encoded}/property/{_PUBCHEM_PROPS}/JSON")
    props = (data.get("PropertyTable", {}).get("Properties") or [None])[0]
    if not props:  # 200 with an empty table — treat as an upstream/parse failure, not "no result".
        raise BioAPIError(f"PubChem returned no property row for name {name!r}")
    return _compound_record(name, props)


async def pubchem_compound_by_cid(http: BioHTTP, cid: int | str) -> dict:
    """Fetch the same core props for a numeric PubChem CID.

    Accepts an int or a digit-string; anything else (or <= 0) is a ValueError.
    """
    # Validate first so we never build a bad URL; accept "2244" as readily as 2244.
    try:
        cid_int = int(cid)
    except (TypeError, ValueError) as e:
        raise ValueError(f"CID must be a positive integer, got {cid!r}") from e
    if cid_int <= 0:
        raise ValueError(f"CID must be a positive integer, got {cid!r}")
    data = await http.get_json(f"{PUBCHEM}/compound/cid/{cid_int}/property/{_PUBCHEM_PROPS}/JSON")
    props = (data.get("PropertyTable", {}).get("Properties") or [None])[0]
    if not props:
        raise BioAPIError(f"PubChem returned no property row for CID {cid_int}")
    # name is unknown on a CID lookup; leave it None rather than echo the CID.
    return _compound_record(None, props)


def _molecule_record(mol: dict) -> dict | None:
    """Shape one ChEMBL molecule hit. Returns None if it has no CHEMBL id
    (cannot be pinned to a source, so it is dropped rather than emitted)."""
    chembl_id = mol.get("molecule_chembl_id")
    if not chembl_id:
        return None
    # molecule_properties is present for most curated molecules but can be null.
    mprops = mol.get("molecule_properties") or {}
    return {
        "chembl_id": chembl_id,
        "pref_name": mol.get("pref_name"),
        "max_phase": mol.get("max_phase"),  # clinical phase: 4 = approved, 0/None = preclinical
        "molecule_type": mol.get("molecule_type"),
        "full_mwt": mprops.get("full_mwt"),
        "alogp": mprops.get("alogp"),
        "source": source_record("chembl", chembl_id),
    }


async def chembl_search_molecule(http: BioHTTP, query: str, *, max_results: int = 15) -> dict:
    """Full-text ChEMBL molecule search → chembl_id, name, clinical phase, props.

    ChEMBL defaults to XML; we force JSON via ?format=json (the shared client
    also sends Accept: application/json, but the query param is what ChEMBL
    actually honors on this route).
    """
    if not query.strip():
        raise ValueError("empty ChEMBL molecule query")
    data = await http.get_json(
        f"{CHEMBL}/molecule/search",
        params={"q": query, "format": "json", "limit": min(max_results, 100)},
    )
    molecules = []
    for mol in data.get("molecules", []):
        rec = _molecule_record(mol)
        if rec is not None:
            molecules.append(rec)
    return {"query": query, "returned": len(molecules), "molecules": molecules}


async def chembl_bioactivities(http: BioHTTP, chembl_id: str, *, max_results: int = 25) -> dict:
    """Bioactivity measurements (IC50/Ki/EC50/...) recorded for one molecule.

    The whole result is pinned to the *molecule's* CHEMBL id at the top level;
    each activity row also names its target/assay CHEMBL ids inline.
    """
    ident = chembl_id.strip().upper()
    if not ident.startswith("CHEMBL"):
        raise ValueError(f"chembl_id must start with 'CHEMBL', got {chembl_id!r}")
    data = await http.get_json(
        f"{CHEMBL}/activity",
        params={"molecule_chembl_id": ident, "format": "json", "limit": min(max_results, 1000)},
    )
    activities = [
        {
            "target_chembl_id": act.get("target_chembl_id"),
            "standard_type": act.get("standard_type"),   # e.g. IC50, Ki, EC50
            "standard_value": act.get("standard_value"),
            "standard_units": act.get("standard_units"),
            "assay_chembl_id": act.get("assay_chembl_id"),
            "target_organism": act.get("target_organism"),
        }
        for act in data.get("activities", [])
    ]
    return {
        "chembl_id": ident,
        "returned": len(activities),
        "activities": activities,
        # top-level source pins the molecule these measurements belong to.
        "source": source_record("chembl", ident),
    }
