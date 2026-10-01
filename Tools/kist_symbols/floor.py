"""Use the existing Perslis admission gate; never sign a human approval."""
from __future__ import annotations

from store import CAP, decode, encoded, need


def tables(value):
    need(isinstance(value, dict) and 0 < len(value) <= 32, "Supply a JSON object containing 1–32 row tables.")
    count = 0
    for table, rows in value.items():
        need(isinstance(table, str) and len(table) <= 200 and isinstance(rows, list), "Invalid evidence table.")
        for row in rows:
            count += 1
            need(isinstance(row, dict) and len(row) <= 256, "Every row must be an object with at most 256 columns.")
            need(all(v is None or type(v) in (str, int, float, bool) for v in row.values()),
                 "Evidence cells must be scalars; use runtime_capture to flatten runtime objects.")
    need(count <= 15000 and len(encoded(value)) <= CAP, "Evidence exceeds 15,000 rows or 2 MiB.")
    # Reparse numbers with the floor's exact decimal loader.
    from floor_runtime.data import strict_json
    return strict_json(encoded(value).decode())


def check(spec, data, table, question):
    from symbolic_floor.authoring import admit
    from symbolic_floor.review import summarize
    need(isinstance(spec, dict), "spec_json must be a JSON object.")
    need(isinstance(question, str) and 0 < len(question) <= 300 and "\n" not in question,
         "Supply the user's question, one line of at most 300 characters.")
    need(table in data, "Base table is absent; inspect the dataset schema first.")
    spec = dict(spec, question=question)
    ctx = tables(data)
    result = admit(spec, ctx, table)
    out = {"status": "DRAFT_VALIDATED" if result.admitted else "REFUSED",
           "approved": False, "model_calls": 0,
           "checks": [{"name": n, "passed": ok, "detail": d} for n, ok, d in result.checks],
           "reasons": result.reasons}
    if result.admitted:
        out["review"] = summarize(spec, ctx, table)
        out["limitation"] = "Mechanical admission does not prove the procedure means the question. No human approval or runtime signature was created."
    return spec, out


def guide():
    from symbolic_floor.floor_ask import build_prompt
    return build_prompt({"example": [{"amount": "12.50", "status": "paid"}]},
                        "example", "Total amount of paid records", sample=False)


def schema(data):
    tables(data)
    return {table: {"rows": len(rows), "columns": sorted({k for row in rows for k in row})}
            for table, rows in data.items()}
