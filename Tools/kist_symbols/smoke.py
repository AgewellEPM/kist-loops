#!/usr/bin/env python3
"""Exercise the installed MCP over real stdio; optional read-only live runtime capture."""
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mcp", type=Path, required=True)
    ap.add_argument("--proof", type=Path, required=True)
    ap.add_argument("--live", action="store_true")
    ap.add_argument("--id", default="smoke")
    args = ap.parse_args()
    cfg = json.loads(args.mcp.read_text())["mcpServers"]["symbols"]
    process = subprocess.Popen([cfg["command"], *cfg["args"]], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    responses = []

    def rpc(method, params):
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": len(responses) + 1,
                                        "method": method, "params": params}) + "\n")
        process.stdin.flush()
        raw = process.stdout.readline()
        assert raw, process.stderr.read()
        response = json.loads(raw)
        responses.append({"method": method, "tool": params.get("name"), "response": response})
        assert "error" not in response, response
        return response["result"]

    def tool(name, **kw):
        result = rpc("tools/call", {"name": name, "arguments": kw})
        assert not result.get("isError"), result
        return json.loads(result["content"][0]["text"])

    try:
        rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                           "clientInfo": {"name": "installed-smoke", "version": "1"}})
        assert len(rpc("tools/list", {})["tools"]) == 8
        tool("capabilities")
        spec = json.dumps({"question_class": "smoke:paid", "pipeline": [
            {"op": "rows"}, {"op": "filter", "column": "status", "equals": "paid"},
            {"op": "sum", "column": "amount"}]})
        draft = tool("symbols_build", identifier=args.id, spec_json=spec, table="sales",
                     question="Total paid amount", data_json=json.dumps({"sales": [
                         {"status": "paid", "amount": "12.50"}, {"status": "paid", "amount": "7.25"},
                         {"status": "open", "amount": "999"}]}))
        assert draft["review"]["answer"] == 19.75 and not draft["approved"]
        assert tool("symbols_run", identifier=args.id)["review"]["answer"] == 19.75
        if args.live:
            capture = tool("runtime_capture", target="goldeneye", identifier=args.id)
            dataset = capture["dataset"]
            state = tool("dataset_schema", dataset=dataset)
            assert "health" in state["tables"]["state"]["columns"]
            health = tool("symbols_build", identifier=args.id + "-health", dataset=dataset,
                          table="state", question="Bond health in this saved GoldenEye state",
                          spec_json=json.dumps({"question_class": "goldeneye:health", "pipeline": [
                              {"op": "rows"}, {"op": "max", "column": "health"}]}))
            assert health["status"] == "DRAFT_VALIDATED"
            recovery = tool("recover", source=dataset, identifier=args.id)
            recovered = tool("dataset_schema", dataset=recovery["dataset"])
            assert recovered["tables"], recovered
            table = next(iter(recovered["tables"]))
            count = tool("symbols_check", dataset=recovery["dataset"], table=table,
                         question="Number of fields recovered from the saved GoldenEye state",
                         spec_json=json.dumps({"question_class": "goldeneye:fields", "pipeline": [
                             {"op": "rows"}, {"op": "count"}]}))
            assert count["review"]["answer"] == capture["fields"]
        proof = {"mcp": str(args.mcp), "command": cfg["command"], "args": cfg["args"],
                 "live": args.live, "passed": True, "responses": responses}
        args.proof.write_text(json.dumps(proof, indent=2))
        print(json.dumps({"passed": True, "rpc_calls": len(responses), "proof": str(args.proof)}))
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        assert process.poll() is not None


if __name__ == "__main__":
    main()
