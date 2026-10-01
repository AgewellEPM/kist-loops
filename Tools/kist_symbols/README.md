# Kist Symbols, runtime evidence and Liberate

This optional local MCP adapter joins existing Perslis Symbols admission with
the installed Liberate CLI and explicitly registered runtime state endpoints.
It does not change the Kist binary or arm autonomy. The builtin Kist `symbols`
tool remains a code-outline tool; this server is namespaced `symbols__…`.

Eight tools cover capabilities/grammar, runtime inspection, bounded capture,
Liberate recovery, dataset schema, symbolic checking, draft creation and replay.
Tool calls do not invoke a model. Kist's surrounding conversation still has its
normal provider cost and permissions. Grammar is fetched on demand and tool
responses are capped at 32 KB; full runtime responses stay in private artifacts.

## Install into the existing Kist MCP client

Use an existing Python 3.11–3.14. No dependencies or browser runtimes are installed.
Select the modern Symbols worktree containing both packages; do not substitute
the older bio-floor runtime just because its directory also says symbolic-floor.

```sh
/opt/homebrew/bin/python3 tools/kist_symbols/install.py \
  --floor /Users/lukekist/science-loops-floor-pilot/symbolic-floor \
  --liberate /Users/lukekist/bin/liberate \
  --prefix /Users/lukekist/.kist/integrations/symbols \
  --mcp /Users/lukekist/.mcp.json
```

The installer snapshots Python modules into a content-addressed release, checks
their hashes, backs up MCP configuration and merges only `mcpServers.symbols`.
Existing Kist sessions need to exit and start again to discover the new server.
`kist --protocols` reports configured servers; discovery alone is not an execution test.

Host-owned `config.json` names the writable artifact root, installed Liberate
executable, enrolled source folders and runtime adapters. Default sources contain
only the integration's `workspace/inbox`. To recover another restored folder,
enroll that exact operator-selected folder under a source ID. Tool arguments
cannot supply arbitrary filesystem roots, executable commands or network URLs.
Default read-only runtime adapters are GoldenEye (`8093`) and DOOM (`8099`).
Each requires an explicit identity pointer/prefix and describes its coverage.
Other runtimes require an appropriate adapter; this is not a universal memory hook.

## Use through Kist's tool loop

Start with `symbols__capabilities`. To inspect N64 state, call
`symbols__runtime_read` with `target="goldeneye"` and `path="/combat"` or
`path="/perception"`. Root reads and nested objects are paged by offset/limit.
These are runtime-data reads, not UI screenshots or control. A fresh endpoint
read does not establish the age of the sample held by the harness.

`symbols__runtime_capture(target="goldeneye", identifier="dam-001")` saves the
entire exposed response, hashes, capture time, scalar state table and field table.
For a short sequence, also use `path="/combat", samples=3, interval_seconds=1`.
Every original response is retained. Tables contain a sample index, and the
state table includes observation times. Maximum: five samples, at most 1 Hz,
15,000 table rows and 2 MiB per artifact. Select a narrow path for a sequence.
No claim is made that a sampling window covers every application stage.

Run `symbols__recover(source="capture:dam-001", identifier="dam-recovered")`
to extract the CSV with installed Liberate and verify its bundle. To extract
selected legacy files, use an enrolled source ID instead. Perslis/GhostBridge
continues to own VM discovery, lifecycle, native controls and file acquisition;
this adapter never launches a guest or substitutes a Windows release.
Liberate's `needs-review` quality status remains visible even when integrity passes.

Call `symbols__dataset_schema(dataset="capture:dam-001")`, then request grammar
with `symbols__capabilities(grammar=true)`. Compose a closed DSL procedure:

```json
{"question_class":"goldeneye:captured_health","pipeline":[{"op":"rows"},{"op":"max","column":"health"}]}
```

`symbols__symbols_check` takes that JSON as `spec_json`, `table="state"`, the
user's `question`, and `dataset="capture:dam-001"`. `symbols__symbols_build`
adds a new `identifier` and saves a draft only after the existing floor gate
passes. Alternatively, supply inline `data_json` instead of `dataset` to build a
new symbolic procedure from scratch. `symbols__symbols_run(identifier="…")`
verifies saved artifacts and reruns the gate without a model.

These are **unapproved drafts**. The floor tests deterministic execution,
evidence grounding, rejection of wrong values and abstention without evidence;
it cannot prove that a procedure means the user's question. No human review key
is accessed, approval fabricated or signature generated. Production deployment
of admitted tools still uses Perslis' existing signed review and floor-kit path.
Data is frozen at build time; new observations require a new revision.

The adapter permits local artifact creation through accurately classified MCP
mutation tools. Kist's own Builder/permission/review gates remain in force.
Its source-code Builder acceptance is distinct from a floor draft's validation.
Artifact hashes detect changed bytes; they are not hostile-account authentication
or Kist host-owned sealed completion evidence.

## Verify and roll back

```sh
PYTHONPATH=/path/to/symbolic-floor:tools/kist_symbols \
  python3 -m unittest discover -s tools/kist_symbols -v
python3 tools/kist_symbols/smoke.py --mcp /path/to/test.mcp.json \
  --proof /path/to/proof.json --id unique-test --live
python3 tools/kist_symbols/kist_smoke.py --mcp /path/to/test.mcp.json \
  --kist /Users/lukekist/bin/kist-current --output /path/to/new-test-directory
```

The last check uses a deterministic local provider fixture with the real installed
Kist and MCP, so it proves discovery/calling/result propagation, not model quality.
All diagnostic processes are stopped. The live smoke observes an already running
GoldenEye harness; it does not start a game or send gameplay input.

`installation.json` records the release and original MCP backup. To roll back,
restore just the prior `mcpServers.symbols` entry from that backup (or remove it
if none existed), preserving subsequent edits to other servers, then restart Kist.
Saved artifacts and older releases remain available for inspection.
