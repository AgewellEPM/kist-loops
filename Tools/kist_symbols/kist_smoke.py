#!/usr/bin/env python3
"""Installed Kist REPL + real Symbols MCP, with a deterministic local model fixture."""
from __future__ import annotations

import argparse
import http.server
import json
import subprocess
import threading
from pathlib import Path


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mcp", type=Path, required=True)
    ap.add_argument("--kist", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    root = args.output
    root.mkdir(exist_ok=False)
    for part in ("account", "config/kist", "project"):
        (root / part).mkdir(parents=True, exist_ok=True)
    entry = json.loads(args.mcp.read_text())["mcpServers"]["symbols"]
    (root / "account/.mcp.json").write_text(json.dumps({"mcpServers": {"symbols": entry}}))
    (root / "config/kist/config.json").write_text(json.dumps({"provider": "ollama", "model": "fixture",
        "allowedProviders": ["ollama"], "autoRouting": False}))
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"models":[{"name":"fixture"}]}\n')

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append(body)
            messages = body.get("messages", [])
            text = "\n".join(m.get("content", "") for m in messages)
            if "CURRENT REQUEST (untrusted operator text):" in text:
                action = {"intent": "review", "route": "inline", "continuation": False}
            elif '<tool_output tool="symbols__symbols_check" status="ok">' in text:
                action = {"done": True, "summary": "The Symbols floor checked the draft. Paid total is 19.75; human approval is absent."}
            else:
                action = {"tool": "symbols__symbols_check", "parameters": {
                    "spec_json": json.dumps({"question_class": "installed:paid", "pipeline": [
                        {"op": "rows"}, {"op": "filter", "column": "status", "equals": "paid"},
                        {"op": "sum", "column": "amount"}]}), "table": "sales", "question": "Total paid amount",
                    "data_json": json.dumps({"sales": [{"status": "paid", "amount": "12.50"},
                                                       {"status": "paid", "amount": "7.25"}]})}}
            raw = json.dumps({"message": {"role": "assistant", "content": json.dumps(action)},
                              "done": True, "prompt_eval_count": 1, "eval_count": 1}).encode() + b"\n"
            self.send_response(200)
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Content-Type", "application/x-ndjson")
            self.end_headers()
            self.wfile.write(raw)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CFFIXED_USER_HOME": str(root / "account"),
           "XDG_CONFIG_HOME": str(root / "config"), "TERM": "dumb", "NO_COLOR": "1",
           "OLLAMA_HOST": "http://127.0.0.1:" + str(server.server_port), "TMPDIR": "/private/tmp"}
    command = [str(args.kist), "--project", str(root / "project"), "--provider", "ollama", "--model", "fixture",
               "--tools", "text", "--max-iterations", "4", "--budget", "50000", "--no-memory"]
    try:
        result = subprocess.run(command, input="Inspect the paid-total symbolic procedure using the Symbols MCP floor. Report the checked result.\n/exit\n",
                                cwd=root / "project", env=env, capture_output=True, text=True, timeout=90)
        text = result.stdout + result.stderr
        (root / "transcript.txt").write_text(text)
        (root / "requests.json").write_text(json.dumps(requests, indent=2))
        assert "19.75" in text and "symbols__symbols_check" in text, text[-6000:]
        assert any("DRAFT_VALIDATED" in json.dumps(r) for r in requests), "No actual floor result returned to Kist"
        proof = {"passed": True, "model": "deterministic local fixture; not a natural-language model evaluation",
                 "provider_requests": len(requests), "exit": result.returncode,
                 "kist": str(args.kist), "mcp_entry": entry}
        (root / "proof.json").write_text(json.dumps(proof, indent=2))
        print(json.dumps(proof))
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)
        assert not worker.is_alive()


if __name__ == "__main__":
    main()
