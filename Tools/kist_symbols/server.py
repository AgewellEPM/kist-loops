#!/usr/bin/env python3
"""Kist Symbols MCP: stdio JSON-RPC, or a deterministic local --call for diagnostics."""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

# -I deployment loads only the pinned adapter and floor payload, never cwd/PYTHONPATH.
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
if (HERE.parent / "floor").is_dir():
    sys.path.insert(0, str(HERE.parent / "floor"))

from catalog import TOOLS
from service import Service
from store import CAP, decode, encoded, need, read

PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")


def call(service, name, arguments):
    specs = {t["name"]: t for t in TOOLS}
    need(name in specs, "Unknown Symbols tool.")
    need(isinstance(arguments, dict), "Tool arguments must be an object.")
    schema = specs[name]["inputSchema"]
    need(not set(arguments) - set(schema["properties"]), "Unknown tool argument.")
    need(set(schema["required"]).issubset(arguments), "Missing required tool argument.")
    for key, value in arguments.items():
        typ = schema["properties"][key]["type"]
        need(type(value) is {"string": str, "integer": int, "boolean": bool}[typ], "Wrong argument type: " + key)
    result = getattr(service, name)(**arguments)
    # Avoid flooding the model; full evidence has explicit artifact paths.
    need(len(encoded(result)) <= 32000, "Result exceeds 32 KB. Select a smaller runtime path or dataset.")
    return result


def handle(service, request):
    need(isinstance(request, dict), "JSON-RPC request must be an object.")
    if "id" not in request:
        return None
    rid = request["id"]
    method = request.get("method")
    params = request.get("params") or {}
    need(isinstance(params, dict), "JSON-RPC params must be an object.")
    if method == "initialize":
        version = params.get("protocolVersion", PROTOCOLS[0])
        result = {"protocolVersion": version if version in PROTOCOLS else PROTOCOLS[0],
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "kist-symbols", "version": "0.1.0"}}
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        try:
            value = call(service, params.get("name"), params.get("arguments", {}))
            result = {"content": [{"type": "text", "text": encoded(value).decode()}],
                      "isError": value.get("status") == "REFUSED"}
        except (ValueError, TypeError, KeyError, OSError, RuntimeError, RecursionError) as exc:
            result = {"isError": True, "content": [{"type": "text", "text": encoded({
                "status": "REFUSED", "reason": str(exc)[:2000], "model_calls": 0}).decode()}]}
    else:
        return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "Unknown method"}}
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--call", choices=[t["name"] for t in TOOLS])
    parser.add_argument("--arguments", default="{}")
    args = parser.parse_args()
    manifest = HERE.parent / "release.json"
    if manifest.exists():
        release = decode(read(manifest))
        for rel, expected in release["files"].items():
            need(not Path(rel).is_absolute() and ".." not in Path(rel).parts, "Invalid release path.")
            need(hashlib.sha256(read(HERE.parent / rel)).hexdigest() == expected,
                 "Installed adapter/floor payload changed; reinstall the verified source.")
    service = Service(decode(read(args.config)))
    if args.call:
        response = handle(service, {"id": 1, "method": "tools/call", "params": {
            "name": args.call, "arguments": decode(args.arguments)}})["result"]
        print(response["content"][0]["text"])
        return int(response.get("isError", False))
    while True:
        raw = sys.stdin.buffer.readline(CAP + 1)
        if not raw:
            return 0
        if len(raw) > CAP:
            # Stop without interpreting trailing fragments as new requests.
            print(json.dumps({"jsonrpc": "2.0", "id": None, "error": {
                "code": -32600, "message": "Request exceeds 2 MiB"}}), flush=True)
            return 2
        try:
            response = handle(service, decode(raw))
        except (ValueError, TypeError, KeyError, RecursionError) as exc:
            response = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": str(exc)[:300]}}
        if response is not None:
            print(encoded(response).decode(), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
