# Build COBOL through the durable SML runtime

The current source build can call the local `cobol-build` MCP server through an exact SML
capability alias. This is the deterministic template/compiler service from `cobol-sml`, not
the separate MLX `cobol_draft` model or Kist's Ollama-backed `cobol_generate` tool.

## Configure the existing server

Kist loads user MCP configuration from `~/.mcp.json`. The command must be an absolute path to
your installed Python interpreter. For Luke's existing installation the entry is:

```json
{
  "mcpServers": {
    "cobol-build": {
      "command": "/opt/homebrew/bin/python3",
      "args": ["/Volumes/PRO-G40/cobol-sml/cobol_build_mcp.py"],
      "env": {"PATH": "/opt/homebrew/bin:/usr/bin:/bin"}
    }
  }
}
```

Merge that entry into existing configuration; do not replace other servers. The server and
`cobc` must already be installed. This guide does not download a runtime or model.

For each SML project, an owner-only `.kist/sml/mcp.json` binds a stable alias:

```json
{
  "schema_version": 1,
  "tools": {
    "cobol.build": {"server": "cobol-build", "tool": "cobol_build"}
  }
}
```

Admit `cobol.build` in `catalog.json`'s `tool_capabilities`, configure an operator in
`authority.json`, and set these host files to mode `0600`. The native workflow instruction is:

```json
{
  "id": "build",
  "op": "CALL_TOOL",
  "capability": "cobol.build",
  "arguments": {"prompt": "the maximum of 7 values", "output_field": "output"},
  "next": "done"
}
```

Declare `output` as a string state field and provide the terminal instruction. The default
approval policy parks the step before execution. Only the bound server is discovered by the
durable capability stack. The external MCP server executes with its own process authority;
SML's shell-denied built-in context is not an OS sandbox for that external implementation.

## Run the executable demonstration

The following command creates a new proof directory with complete project configuration,
workflows, SML records, returned COBOL, executable caller programs, compiler logs, and test data:

```sh
python3 scripts/tests/sml-cobol-build-smoke.py \
  --binary .build/debug/kist \
  --output /absolute/path/to/new-cobol-proof
```

The output directory must not exist. The command explicitly approves ten fixed local numeric
build tasks. Each returned routine is independently linked with a host-owned caller and tested
on eight arrays. It also verifies that no dispatch result appears before approval and that
restarting a completed task creates no new dispatch record. It does not invoke a model, start a
UI/VM, promote a binary, alter the learned capability archive, or enable unattended evolution.

On September 8, 2026, the tested source build produced ten executables and passed all eighty
independent behavioral checks. The installed September 2 binary rejected this interactive
durable REPL invocation; use an explicitly qualified binary and its digest rather than assuming
that identical version strings imply identical capability.

## Evidence limits and next integration step

The MCP output's `verified` field is a server assertion. Its existing functional test was shown
to accept a constant-zero range mutant because its numeric input repeats one value. The separate
COBOL evolution archive also contains a zero-seeded maximum that fails all-negative inputs.
The demonstration therefore uses independent Python oracles and input arrays; it does not treat
the server's claim as Kist acceptance or evolution authority.

The tested domain is ten numeric table operations at length seven, with zero, signed, boundary,
threshold, and varied inputs. Other sizes and shapes need their own cases. The host demonstration
saves the source from the returned JSON; SML's current MCP tool driver stores it as a string.
General multi-step construction needs explicit typed state-to-argument mappings and artifact
references so one step can safely consume another step's output without a separate extraction
harness. Keep compiler identity, project paths, and verifier inputs under host authority.
