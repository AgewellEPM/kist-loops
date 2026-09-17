"""AlphaFold connector: accession -> predicted structure -> predicts_structure."""

from __future__ import annotations

import json
import re

from ..schema import utc_now_iso, validate_node_id
from ..store import Store
from .base import ConnectorError, Transport, http_get

PREDICTION_URL = "https://alphafold.ebi.ac.uk/api/prediction/{accession}"

# .../AF-P12345-F1-model_v4.pdb -> AF-P12345-F1
_PDB_URL_ID = re.compile(r"/(AF-[A-Z0-9]+(?:-\d+)?-F\d+)-model_v\d+\.pdb$")


def fetch_prediction(store: Store, accession: str, *,
                     transport: Transport | None = None) -> dict:
    """Emit predicts_structure for the AlphaFold predicted entry.

    Returns status OK | NO_PREDICTION. 404 (or an empty prediction list)
    writes NO edge.
    """
    acc = accession.strip().upper()
    validate_node_id(f"protein:{acc}")

    url = PREDICTION_URL.format(accession=acc)
    status, body = http_get(url, transport=transport)
    if status == 404:
        return {"status": "NO_PREDICTION", "accession": acc}
    if status != 200:
        raise ConnectorError(f"AlphaFold prediction for {acc}: unexpected HTTP {status}")
    try:
        predictions = json.loads(body)
    except ValueError as e:
        raise ConnectorError(f"AlphaFold prediction for {acc}: unparseable body") from e
    if not isinstance(predictions, list):
        raise ConnectorError(
            f"AlphaFold prediction for {acc}: expected a list, got {type(predictions).__name__}"
        )
    if not predictions:
        return {"status": "NO_PREDICTION", "accession": acc}

    first = predictions[0]
    if not isinstance(first, dict) or not first.get("pdbUrl"):
        raise ConnectorError(f"AlphaFold prediction for {acc}: no pdbUrl on first model")
    m = _PDB_URL_ID.search(str(first["pdbUrl"]))
    if not m:
        raise ConnectorError(
            f"AlphaFold prediction for {acc}: unrecognized pdbUrl shape {first['pdbUrl']!r}"
        )
    af_id = m.group(1)

    edge_id, created = store.add_edge(
        f"protein:{acc}",
        "predicts_structure",
        f"structure:{af_id}",
        provenance={
            "source": "alphafold",
            "url": url,
            "retrieved_at": utc_now_iso(),
            "raw_id": af_id,
        },
        label=f"AlphaFold predicted structure {af_id}",
    )
    return {"status": "OK", "edge_id": edge_id, "structure_id": f"structure:{af_id}",
            "created": created, "accession": acc}
