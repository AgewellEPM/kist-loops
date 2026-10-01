"""Small startup catalog; the long DSL grammar is fetched only when needed."""
from __future__ import annotations


def tool(name, description, properties, required=(), mutation=False):
    return {"name": name, "description": description,
            "inputSchema": {"type": "object", "properties": properties,
                            "required": list(required), "additionalProperties": False},
            "annotations": {"readOnlyHint": not mutation, "destructiveHint": False,
                            "openWorldHint": name in ("runtime_read", "runtime_capture")}}


def p(kind, desc):
    return {"type": kind, "description": desc}


DATA = {"dataset": p("string", "capture:<id> or recovery:<id>; omit when using data_json"),
        "data_json": p("string", 'Inline evidence JSON, e.g. {"sales":[{"amount":"12.50"}]}; omit when using dataset')}
SPEC = {"spec_json": p("string", "Closed DSL JSON; call capabilities(grammar=true) for syntax"),
        "table": p("string", "Base table name from dataset_schema"),
        "question": p("string", "User's exact question, one line, at most 300 characters"), **DATA}
ID = p("string", "New lowercase identifier, 1–64 characters; never overwrites")
TOOLS = [
    tool("capabilities", "Perslis Symbols + Liberate: create symbolic procedures from scratch, inspect runtime state, recover legacy data. Call with grammar=true only when composing a spec. Kist's builtin symbols tool is only a code outline.",
         {"grammar": p("boolean", "Include closed DSL grammar; default false")}),
    tool("runtime_read", "Read registered application runtime state without input or VM control. JSON Pointer selects a field (e.g. /perception, /combat, /orders). Returns bounded pages; endpoint read does not prove sample freshness or total runtime coverage.",
         {"target": p("string", "Registered target, e.g. goldeneye or doom"),
          "path": p("string", "JSON Pointer, default empty = root"),
          "offset": p("integer", "Default 0"), "limit": p("integer", "1–100 fields, default 30")}, ["target"]),
    tool("runtime_capture", "Save runtime snapshots with hashes/times plus floor-ready tables and CSV. Default: all exposed fields from one response. For a short state sequence set samples=2..5 and a narrow JSON Pointer path, e.g. /combat. Original full snapshots are retained. No input or continuous recording.",
         {"target": p("string", "Registered runtime target"), "identifier": ID,
          "path": p("string", "JSON Pointer for tabular fields, default empty = all fields"),
          "samples": p("integer", "1–5, default 1; select a narrow path for multiple samples"),
          "interval_seconds": p("integer", "1–5, default 1; never above 1 Hz")}, ["target", "identifier"], True),
    tool("recover", "Run installed Liberate locally on a selected source or capture:<id>; verify the recovery job and preserve quality flags. No AI, VM launch, guest export, network delivery or source changes.",
         {"source": p("string", "Enrolled source ID or capture:<id>"), "identifier": ID}, ["source", "identifier"], True),
    tool("dataset_schema", "Inspect tables/columns without sending raw rows. Input dataset='capture:<id>'/'recovery:<id>' OR inline data_json. Liberate integrity is verified before reading a recovered dataset.", DATA),
    tool("symbols_check", "Check a new symbolic procedure against evidence with the existing Perslis floor. Return derivation, warnings and failed checks. Does not save or sign. Supply spec_json, table, question and dataset OR data_json.",
         SPEC, ["spec_json", "table", "question"]),
    tool("symbols_build", "Build and save a reusable symbolic draft only after the Perslis gate passes. Input identifier, spec_json, table, question and dataset OR data_json. Saves exact evidence and review packet. Human approval remains absent; no arbitrary code or signatures.",
         {"identifier": ID, **SPEC}, ["identifier", "spec_json", "table", "question"], True),
    tool("symbols_run", "Recheck and run a saved draft with zero embedded model calls. Verify artifact hashes first; changed artifacts are refused. Result is explicitly unapproved, on recorded evidence. No gameplay actions.",
         {"identifier": p("string", "Existing symbolic system identifier")}, ["identifier"]),
]


def effects():
    return {t["name"]: "readOnly" if t["annotations"]["readOnlyHint"] else "projectMutation" for t in TOOLS}
