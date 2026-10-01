import Foundation

extension KistOptions {
    static let helpText = """
    Mythos / kist — an open-source agent shell that runs on ANY model you bring a key for.

    USAGE:
      kist "<goal>"                 Run the goal to completion, streaming to the terminal.
      kist --headless "<goal>"      Force the governed direct Builder adapter for deterministic dogfood.
      kist --resume <id>            Resume a checkpointed run where it left off.
      kist --resume-last            Resume the most recent unfinished run.
      kist --plan-execute-resume <mission-id> "<same goal>"
                                    Resume exactly one PlanExecute mission; no latest/goal lookup.
      kist --list                   List resumable runs.
      kist --inspect-builder-evidence <sealed-run.json>  Inspect historical training evidence offline.
      kist --list-providers         Show providers and which have a key configured.
      kist --gemini-test            Live smoke-test of the Gemini clients (needs a Gemini key).
      kist --ship "<goal>"          Build hands-free in the autopilot sandbox, then the council of
                                    minds reviews the result → GO/NO-GO (deploy stays your call).
      kist --mission "<goal>"       Autonomous gated mission: research/council → measured simulation
                                    and trials → verified execution → independent review.
      kist --health                 Show provider/model/router health without spending tokens.
      kist --probe-providers        Full live probe of configured providers; may take 1-2 minutes.
      kist --model-vet hf:<repo>    Fetch live model metadata and hard-reject unsafe downloads.
      kist --model-acquire <json>   Verify an acquisition manifest before local-model download.
      kist --model-run <stage> <json>
                                    Run a verified acquisition stage: dry-run, download, inspect,
                                    onboard, or benchmark.
      kist --bench "<task>"         Run the task across configured providers and compare.
      kist --eval "<task>"          Run the task with deterministic agent-behavior assertions.
      kist --loop "<goal>"          Great-loop: self-assess effort per cycle, learn from history, and keep
                                    working (verify each cycle) until done-and-verified or a safety cap.
                                    Caps: --budget <tok> · --loop-hours <h> · --max-cycles <n>. (long-horizon)
      kist --cobolo --cobol-target <path.cbl> --cobol-expect <stdout> [--cobol-max-revisions <1...3>] "<goal>"
                                    Local-only COBOL specialist → sandboxed replay → independent reviews
                                    → lease-bound conditional promotion. Alias: --cobol-loop.
      kist --research "<goal>"      Evidence run → research dossier → council → task board.
      kist --dig "<question>"       Ask EVERY reachable model the same question, synthesize agree/disagree.
      kist --council "<goal>"       Research → council → decision → visible task board.
      kist --council-execute "<g>"  Same, then hand the builder brief to plan→execute.
      kist --protocols              Show MCP/A2A/browser/computer-control status.
      kist --replay [id]            Show a durable run replay from .kist/runs (default latest).
      kist --verify [--verify-cmd "<cmd>"] [--proofs <file>]
                                    Run deterministic checks on the STAGED change and seal a Verification
                                    Receipt (bound to the exact diff) under .kist/receipts/. Commit it.
                                    --proofs folds machine-checkable claims (proof-carrying patch) into the
                                    receipt; a false claim fails the verdict so a lying patch can't merge.
      kist --guard                  Local pre-commit gate: admit the staged change only if a valid receipt
                                    covers it. Bypassable (--no-verify) — defense-in-depth, not the boundary.
      kist --install-guard          Install the pre-commit --guard hook (honors core.hooksPath).
      kist --ci-guard [base] [head] SERVER-AUTHORITATIVE gate: every content-bearing commit in base..head must
                                    carry a valid receipt. Run as a CI REQUIRED CHECK — cannot be --no-verify'd.
                                    Refs inferred from CI env (GITHUB_BASE_REF/GITHUB_SHA) when omitted.
                                    When issuer keys are pinned, each change ALSO needs a valid Ed25519 signature.
      kist --gen-issuer-key <id>    Generate an Ed25519 issuer keypair (private 0600 + public to distribute).
      kist --trust-issuer <id> <pub>  Pin an issuer PUBLIC key — receipts it signs become trusted (cross-org tier).
      kist --unpin-issuer <id>      Stop trusting an issuer (removable; re-pinnable later).
      kist --revoke-issuer <id>     REVOKE a compromised issuer — its signatures are rejected and it can't be
                                    re-pinned until --unrevoke-issuer. Rotate: gen+trust a NEW key, re-sign.
      kist --unrevoke-issuer <id>   Lift a revocation.
      kist --list-issuers           Show pinned + revoked receipt issuer keys.
      kist --trust-root <id> <pub>  Pin a TRUST ROOT — trust bundles it signs distribute issuers (scales trust).
      kist --make-bundle --root-key <priv> [--bundle-out <path>]
                                    Sign the local issuer set into a distributable bundle (.kist/trust-bundle.json).
      kist --verify-bundle <path>   Verify a signed trust bundle against pinned roots.
      kist --list-roots             Show pinned trust roots.
      kist --sign-receipt <digest|latest> --issuer-key <priv>
                                    Ed25519-sign a stored receipt's change → .kist/receipts/<digest>.sig.json.

    OPTIONS:
      -p, --provider <id>           Provider id (default: first configured cloud provider, else local).
      -m, --model <id>              Model id (default: the provider's default).
          --by-cost / --by-power    Pick the DEFAULT model by cost (cheapest) or power (strongest,
                                    default). Persist with config "selectBy" or the /power · /economy
                                    REPL commands. An explicit -p/--provider always overrides.
      -C, --project <path>          Project root the agent is confined to (default: current dir).
          --max-iterations <n>      Max plan→act steps (default: 40).
          --allow-shell             Enable the run_command tool (OFF by default).
          --allow-read <dir>        ALSO allow the file/search tools to READ under <dir> (repeatable),
                                    e.g. --allow-read /Volumes to browse a mounted CD/USB drive.
                                    Read-only: write/edit/move/delete stay confined to the project
                                    root. Never inherited by a nested kist. "/" is refused.
          --sandbox                 Run shell commands inside the macOS Seatbelt OS sandbox.
          --sticky-turns            EXPERIMENTAL opt-in: keep the input box pinned DURING turns
                                    (scroll-region). Off by default — known to corrupt on window
                                    resize in some terminals; --no-sticky-turns restores the default.
          --trust-worktree-tests    Let the fleet verifier trust an IN-REPO test harness (base-trusted
                                    test.sh / swift-test / npm). OFF by default: only a held-out operator
                                    oracle (~/.kist/test-command) verifies. Opt in ONLY for your own honest
                                    agents (a shell harness can transitively run agent code).
          --yolo                    REPL: skip approval prompts for shell/file-write tools.
          --auto, --danger          Hands-off autopilot: implies --yolo + --allow-shell and FORCES
                                    --sandbox (cannot be disabled). Everything runs OS-sandboxed;
                                    on a platform with no sandbox, shell fails closed (won't run raw).
                                    Generated custom_tool helpers also run here without prompts, but
                                    only as project-local sandboxed Python scripts.
                                    Fleet trust gates (captain signoff, merge gate) still apply —
                                    autopilot never pushes/merges to main without a captain's OK.
          --think                   Extended thinking: the model reasons before each action (reasoning
                                    shown inline + saved to the replay). In the REPL, toggle with /think.
          --plan                    Plan mode: read-only; the agent proposes a step-by-step plan
                                    instead of editing. In the REPL, toggle with /plan.
          --headless                Force the typed direct Builder adapter. The run still uses a sealed
                                    preflight contract, scoped mutation tools, finite budgets,
                                    deterministic verification, and independent review.
          --plan-execute            Plan→execute: the planner emits a typed step DAG, you approve
                                    it (unless --yolo), then it runs to completion. (one-shot)
          --plan-candidates <1...4> Compare bounded approaches in one planner call (default 2).
                                    Planner reasons; coder handles bounded steps. Shared budget.
                                    1 uses a single plan. Applies to CLI and REPL planned routes.
          --plan-execute-resume <mission-id>
                                    Resume the exact PlanExecute mission using the supplied same goal.
                                    The ID is 64 lowercase hex; never selects latest or Headless state.
          --cobolo                 High-assurance local COBOL builder. Alias: --cobol-loop.
              --cobol-target <path>    Required project-relative .cbl/.cob target; its parent must exist.
          --cobol-expect <text>    Required stdout substring; sandbox and exit 0 are also mandatory.
          --cobol-max-revisions <n>
                                    Maximum critic-driven candidate revisions (default 3; range 1...3).
          --research                Run an evidence-first research pipeline: web/source discovery,
                                    repo context, durable dossier, council synthesis, task board.
          --council, --consult      Run the AI council as a first-class surface: researcher →
                                    architect → coder → critic → UX → memory → final plan.
                                    Saves the full council artifact and seeds .kist/plan.json
                                    so /goals shows the kanban board immediately.
          --council-execute         Run the council, seed the task board, then hand the council's
                                    builder brief to plan→execute. Alias: --council-build.
          --fleet                   Launch a SUPERVISED parallel fleet: the planner splits the goal
                                    into DISJOINT-scoped subtasks, each runs in an isolated staged
                                    filesystem workspace (heterogeneous — bind roles per vendor), then
                                    one aggregate subject is deterministically verified + independently
                                    reviewed before a journaled global promotion. No Git repo required;
                                    partial child results never publish. (one-shot)
          --evolve                  Run a DGM-style evolution lab: create isolated candidate
                                    worktrees, ask the role-bound team to improve Mythos itself,
                                    benchmark each candidate, and append results to
                                    .mythos/evolution/archive.jsonl. NEVER auto-promotes.
          --agents <n>              Max fleet size for --fleet (default 5; hard-capped).
          --variants <n>            Candidate count for --evolve (default 1; max 10).
          --evolve-test <cmd>       Benchmark command for --evolve. Repeatable. Defaults to
                                    ./test.sh, swift test, or git diff --check depending on repo.
          --evolve-timeout <sec>    Per-benchmark timeout for --evolve (default 600; max 3600).
          --delegation-depth <n>    Nested teammate delegation for spawn_agent (default 1; max 3).
                                    0 = sub-agents cannot spawn helpers; 1 = a sub-agent can ask
                                    one more teammate for help while staying bounded.
          --planner <prov[:model]>  Vendor for the PLANNER role (default: the chosen provider).
          --worker  <prov[:model]>  Vendor for the WORKER/research role used by spawned sub-agents.
          --coder   <prov[:model]>  Vendor for the CODER/BUILDER role — the `generate` tool that produces
                                    content (code/prose) runs on this vendor.
          --builder <prov[:model]>  Alias for --coder.
          --critic  <prov[:model]>  Vendor for the CRITIC / verify-the-goal role. Bind different
                                    vendors per role for a team, e.g.:
                                    --provider openai --builder deepseek --critic gemini
                                    --fleet "big build" --coder mimo --worker deepseek --critic gemini
          --review-grade <grade>    Review evidence for /grow or Builder. Default `independent` requires
                                    a distinct provider. `fresh_context_same_model` is never independent
                                    or deployment authority. Builder permits it only with an explicit exact
                                    --critic on a sandboxed --headless --auto build in a non-Git disposable
                                    temp root, sealed to one file mutation and one deterministic verifier.
          --roles <name>            Load a saved role profile from ~/.config/kist/roles.json.
                                    Explicit role flags override it.
          --budget <tokens>         Hard TOKEN ceiling. Enforced on the agent loops — one-shot, REPL,
                                    resume, plan→execute, --council/--research, --fleet (planner + all
                                    workers share one cap), and --evolve. Halts honestly at the cap;
                                    shared across the delegation tree so no spawned agent overspends.
          --max-cost <usd>          Hard DOLLAR ceiling (e.g. --max-cost 0.50), priced per provider
                                    (a 1M-token Gemini call ≠ Claude). Either cap halts the run.
                                    Combine with --budget. Unpriced providers count toward tokens only.
          --list-learning-sync      Import recent project observations from LIST MCP; no model or execution.
          --list-learning-status    Show dated LIST advisory memory and review-only proposal counts.
          --operator-action         One bounded JSON action on stdin; requires an existing host grant.
          --no-memory               Disable cross-run memory (otherwise plan→execute ingests
                                    AGENTS.md/CLAUDE.md + recent run outcomes as planning context,
                                    and logs each run to .mythos/memory/).
          --tools <mode>            Tool-calling mode: auto (default; native when the model
                                    supports it, else the universal text protocol), native, or text.
          --fetch-host <host>       Restrict fetch_url to this host pattern. Repeatable. Exact
                                    hosts or wildcards like *.swift.org. Also configurable with
                                    {"fetchAllowedHosts":["docs.swift.org"]}.
          --health                  Offline provider health: keys, default model catalog, native/text route.
          --probe-providers         Full live provider health probe; waits for real provider latency and
                                    catches stale models like a 404 Grok id.
          --model-vet <spec>        Hard pre-download gate for local/Hugging Face models. Fetches live
                                    metadata, requires allowlisted license/provenance/size/safe-format weight files,
                                    writes .kist learning artifacts, and exits nonzero on rejection.
          --model-acquire <json>    Verify a model acquisition manifest: policy hash, approval id,
                                    pinned commands, project-local target, and next gate tasks.
          --model-run <stage> <json>
                                    Execute only the stage authorized by a verified acquisition
                                    manifest. Download requires a prior passing dry-run marker;
                                    inspect/onboard/benchmark require the prior stage markers.
          --sml-import-openapi <openapi.json> [--sml-api-id <id>] [--sml-out <dir>]
                                    Import a project-confined OpenAPI 3 JSON document into a
                                    secret-free, pinned HTTP endpoint bundle, create-only wrapper
                                    workflows/source set, and a review-required catalog proposal.
                                    Never modifies the live catalog or creates credentials.
          --sml-runtime-export <json>
                                    Offline-wrap a LangGraph manifest, SML workflow JSON, SML
                                    runtime source package, or runtime source set with optional
                                    per-workflow role/API-base/API-path/model-rounds into a host JSON
                                    payload containing the generated custom REPL mount,
                                    API/OpenAPI routes, native model-router tool, Onyx driver
                                    manifests, planning graph, and launch descriptor.
          --sml-runtime-launch <json>
                                    Launch the wrapped source offline and emit the exact launch
                                    descriptor/receipt for mounted REPL, API, model, Onyx, and
                                    planning adapters.
          --sml-runtime-openapi <json>
                                    Launch the wrapped source offline and emit the generated
                                    OpenAPI document plus its runtime endpoint and launch receipt.
          --sml-runtime-model-router <json>
                                    Launch the wrapped source offline and emit the native
                                    model-router tool descriptor plus launch receipt.
          --sml-runtime-onyx <json> [--sml-workflow <id>]
                                    Launch the wrapped source offline and emit all generated Onyx
                                    driver manifests, or one workflow's driver when filtered.
          --sml-runtime-planning <json>
                                    Launch the wrapped source offline and emit the aggregate
                                    planning manifest: skill index, tool index, graph units,
                                    approval gates, and command bindings.
          --sml-runtime-catalog <json>
                                    Launch the wrapped source offline and emit the mounted
                                    workflow runtime catalog.
          --sml-runtime-mount <json>
                                    Launch the wrapped source offline and emit the host mount
                                    contract for generated REPL/API/model/Onyx/planning surfaces.
          --sml-runtime-agent-guide <json>
                                    Launch the wrapped source offline and emit the canonical
                                    agent/model operating guide.
          --sml-runtime-host-guide <json>
                                    Launch the wrapped source offline and emit the canonical
                                    host integration guide.
          --sml-runtime-host-wiring <json>
                                    Launch the wrapped source offline and emit the compact host
                                    wiring map for REPL/API/model-router/Onyx/planning adapters.
          --sml-runtime-runbook <json> [--sml-workflow <id>]
                                    Launch the wrapped source offline and emit a machine-readable
                                    host runbook with artifact paths, inline scripts, command templates,
                                    API endpoints, model-router IDs, Onyx driver IDs, and planning IDs.
          --sml-runtime-scaffold <json> --sml-out <dir>
                                    Launch the wrapped source offline and write catalog, mount,
                                    OpenAPI, model-router, Onyx, planning, guide, wiring, runbook,
                                    and attachment artifacts into one host-consumable directory.
          --sml-runtime-attachments <json> [--sml-workflow <id>]
                                    Emit the per-workflow attachment manifests for generated REPL,
                                    API, model-router, Onyx driver, and planning adapters; optionally
                                    filter to one mounted workflow.
          --sml-runtime-repl <json> [--sml-line <line>] [--sml-workflow <id>]
                                    Open the generated workflow REPL on stdin/stdout. With --sml-line,
                                    run one command and return command/result JSON instead. Add
                                    --sml-runtime-durable for approval-gated live capability dispatch.
          --sml-runtime-repl-script <json> --sml-script <path> [--sml-workflow <id>]
                                    Launch the same wrapped source offline and run a multi-turn
                                    generated workflow REPL script, returning a transcript whose
                                    later commands can use the session's remembered task ID.
          --sml-runtime-api <json> --sml-path <path> [--sml-method <GET|POST>] [--sml-body <json>]
                                    Launch the same wrapped source offline and handle one generated
                                    runtime API request, returning route, command, result, and body JSON.
          --sml-runtime-api-script <json> --sml-api-script <path>
                                    Launch the same wrapped source offline and handle a JSON array of
                                    generated runtime API requests, returning a transcript of exchanges.
          --sml-runtime-model <json> [--sml-prompt <text>] [--provider <id>] [--model <id>]
                                    Launch the wrapped source and let the selected native-tool model
                                    drive mounted workflows through propose_sml_runtime_command.
          --sml-runtime-model-script <json> --sml-model-script <path> [--provider <id>] [--model <id>]
                                    Launch the wrapped source and run a multi-turn prompt script
                                    through one generated model-router session.
          --sml-runtime-serve <json> [--sml-port <port>]
                                    Long-lived durable harness: approval-gated workflows served
                                    over loopback HTTP with a per-session bearer token
                                    (.kist/sml/serve/session-token). GET /approvals lists pending
                                    human gates; approving through the generated task routes
                                    triggers the single-flight capability pump. Requires the
                                    human-owned .kist/sml/authority.json + catalog.json.
          --sml-store <verify|backup|restore|archive> --project <root>
                                    Offline durable-store maintenance; fails while a host owns
                                    the project. JSON report includes counts and runtime digest.
              --sml-backup <path>       New backup destination, or existing bundle to restore.
              --sml-archive-before <ISO8601>  Preserve older terminal tasks in queryable archives.
              --sml-archive-max <N>     Maximum tasks per archive operation (default 1000).
              --sml-replace-sha256 <digest>  Exact current runtime digest for existing-store restore.
              --sml-runtime-durable     REPL/API verbs use the persistent project store
                                        (.kist/sml/runtime.json), the real clock, and the
                                        human-owned .kist/sml/authority.json + catalog.json
                                        instead of the ephemeral rubber-stamp export host;
                                        takes the exclusive .kist/sml/host.lock while running.
              --sml-role <role>         Override workflow role for the generated mount.
              --sml-api-base <path>     Override API base path for generated endpoints.
              --sml-api-workflow-path <id>=<path>
                                        Override one generated workflow API path; repeat per workflow.
              --sml-out <dir>           Project-confined output directory for scaffold/import.
              --sml-script <path>       Script file for --sml-runtime-repl-script; blank lines and
                                        leading # comments are ignored.
              --sml-api-script <path>   JSON request array for --sml-runtime-api-script.
              --sml-model-script <path> Line-oriented prompt script for --sml-runtime-model-script;
                                        blank lines and leading # comments are ignored.
              --sml-model-rounds <n>    Override model-router round ceiling (1...8).
          --bench                   Provider bake-off for the given task: success, latency, usage/cost,
                                    tool failures, and tests evidence where available.
          --eval                    Agent regression check for the given task: output/trajectory assertions
                                    so behavior changes do not degrade silently.
          --protocols               Print protocol/tool-control status: MCP, A2A, browser, computer control.
          --replay [id]             Render a local replay ledger: model, tool events, outputs,
                                    failures, and proof artifact paths. Defaults to latest.
      -h, --help                    This help.

    KEYS (BYOK): resolved from the macOS Keychain or environment (e.g. OPENAI_API_KEY,
    ANTHROPIC_API_KEY, GEMINI_API_KEY). Local providers (Ollama, MLX) need no key.

    CONFIG: defaults in ~/.config/kist/config.json, e.g. {"provider":"openai","model":"gpt-5.5"}.
    Precedence: flags > config > built-in defaults.
    """
}
