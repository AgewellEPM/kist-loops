import Foundation

/// The human changelog behind `/version` — so typing `/version` in the terminal shows the version,
/// WHAT we worked on in it, and WHEN it shipped (build stamp from the deployment manifest). Curated
/// by hand and compiled into the binary (the single-binary deploy has no sidecar resources), newest
/// release first. Keep the top entry in sync with `KistBuildInfo.productVersion` on every bump.
enum KistChangelog {
    struct Release: Equatable, Sendable {
        let version: String
        let date: String        // ISO date the release shipped
        let headline: String
        let changes: [String]
    }

    static let releases: [Release] = [
        Release(version: "0.17.40", date: "2026-08-06",
                headline: "Choose your default by COST or by POWER (Luke request)",
                changes: [
                    "New selection policy for how the DEFAULT model is picked when nothing is pinned: `--by-power` (strongest — the default, claude-cli/codex-cli/gemini lead) or `--by-cost` (cheapest per-token). Persist it with config `\"selectBy\":\"cost\"` or the REPL commands `/power` · `/economy` (`/select cost|power`); an explicit `-p/--provider` or `/model` always overrides",
                    "Cost ranking uses the existing price book: local models and flat-rate subscription CLIs (claude-cli/codex-cli) are $0 marginal; among paid APIs the cheapest wins (mimo < deepseek < gemini < openai). Ties break toward the stronger model, so 'cheapest' is never gratuitously the weakest; an unpriced vendor sorts as expensive so cost-mode never silently prefers something it can't price",
                    "Only the AUTO-DEFAULT changes — teams (/council, /ultra, /role) and explicit pins are untouched. Pinned by ProviderSelectionPolicyTests + ProviderPickByPolicyTests (parse, cost-ordering, power-vs-cost pick, config merge-write preserves other fields)",
                ]),
        Release(version: "0.17.39", date: "2026-08-06",
                headline: "Strongest model leads the default — claude-cli/codex-cli, not gemini (dogfood \"why only gemini\")",
                changes: [
                    "Dogfood find (Luke: \"why was it stuck only on gemini\"): one-shot + /build run on ONE provider, and that default was gemini because subscription CLIs (claude-cli/codex-cli) were EXCLUDED from the default pool (requiresAPIKey == false), so the two strongest providers could never lead and gemini — the top KEYED cloud — always won",
                    "Fix (Luke's call: strongest leads, team stays opt-in): the single-model default now also considers subscription CLIs that pass the bounded, non-billable isLocallyAvailable() probe (binary on a trusted PATH + auth/login status OK — never sends a prompt), ranked together with keyed cloud. claude-cli (100) / codex-cli (95) outrank gemini (85), so an authed Max/Codex subscription now leads. Local models (ollama/mlx) stay last-resort",
                    "Teams remain explicit: /council + --council-execute auto-distribute a real team (planner/coder/critic on different models), /ultra runs the review roster, /role · /code pin roles. Pinned by KistRunnerSafetyTests (source + ranking)",
                ]),
        Release(version: "0.17.38", date: "2026-08-06",
                headline: "/council-execute stops false-blocking on its own transcript (dogfood team-mode fix)",
                changes: [
                    "Dogfood find: `--council-execute` assembled a real team (planner=gemini, worker/coder=deepseek, critic=grok) then the captain REFUSED at the simulation gate — 'Security lab sandbox · critical risk · 77% < 82%' — for a benign COBOL report tweak. Cause: the builder brief embeds the ENTIRE council markdown transcript into the objective, and the risk classifier keyword-scanned that blob, so an incidental 'auth/safety/exploit' word (plus an org-store domain mislabel) flipped the whole build to CRITICAL, which is above the user-request advisory downgrade",
                    "Fix: the domain + simulation safety gates now classify risk on the USER'S original goal, not the council transcript (new riskObjective threaded through runPlanExecute; council-execute passes the user goal). Critical work the USER actually describes still blocks; the gate's evidence/simulation is unchanged",
                    "Pinned in CouncilExecuteRiskObjectiveTests: benign goal is sub-critical, the transcript-embedding string still trips critical (proving the bug), and a source pin that the hand-off threads riskObjective",
                ]),
        Release(version: "0.17.37", date: "2026-08-06",
                headline: "VM run-and-prove goals are EXTERNAL-ACTION turns + failure-gate doctrine reconciled (dogfood round 3 fix #3)",
                changes: [
                    "Dogfood find (round 3, attempt 7): full proof flow succeeded — app ran in the VM, OCR'd TWICE — but the goal had classified as a BUILD turn ('create…' wins the intent), so none of the external-evidence rules applied and one benign no-op edit failure mid-run sank the turn as 'the last mutation failed'",
                    "Root fix: 'create and run X in the Win98 VM / DOS environment and capture proof' now classifies as a DESKTOP/EXTERNAL-ACTION contract (needs BOTH a guest-runtime noun AND a run-there verb — 'fix the win98 driver code' and host builds like the COBOL round stay build). Pinned in PromptCompilerTests with all four shapes",
                    "Failure gates reconciled with the anti-laundering pin: a failed final attempt is excused ONLY on external-action turns where the work was already delivered by an earlier successful mutation AND external proof followed the failure. A later PASSING BUILD/TEST deliberately cannot excuse — the gate suite's planted-always-green-test attack (resume-boundary pin) caught my first draft allowing exactly that, and the pin won",
                    "Net effect for VM rounds: the trajectory that actually happened (write ✓ → guest run ✓ → OCR proof ✓ → surplus no-op edit ✗) now verifies; every build-turn protection is unchanged",
                ]),
        Release(version: "0.17.36", date: "2026-08-06",
                headline: "perslis vm dos-exec --expect counts as verification (dogfood round 3 fix #2)",
                changes: [
                    "Dogfood find (round 3, attempt 6): the model FOUND the deterministic dos-exec path and planned the exact right command — but `perslis vm dos-exec … --expect` classified as a non-verifying command, so verify-before-done could never be satisfied by the very tool built to satisfy it",
                    "Fix: `perslis vm dos-exec` WITH `--expect` classifies as a verification (it exits 0 only when OCR proves the expected text on the guest screen — fail-closed, grounded). Without --expect it stays non-verifying; other perslis verbs unchanged. This also makes it replayable by the symbolic re-verify",
                    "Pinned in CompletionVerifierTests (with/without --expect + foreign-verb shapes)",
                ]),
        Release(version: "0.17.35", date: "2026-08-06",
                headline: "External proof outranks a failed speculative step — DOS round stops sinking on gate 1 (dogfood round 3 fix)",
                changes: [
                    "Dogfood find (round 3, attempt 4): the DOS app RAN — two MS-DOS Prompt windows with 'HELLO FROM KIST' on screen, OCR proof captured TWICE — and the turn still failed 'the last mutation failed' because one mid-run host command (a maybe-mutating run_command) had errored and nothing after it classified as a mutation",
                    "Fix: on an EXTERNAL-ACTION turn, successful external-state evidence recorded AFTER the failed step outranks it — at BOTH failure gates (last-mutation-failed and last-source-mutation-failed; the per-site pin caught the second one). Non-external turns keep both strict gates; a failure with no later external proof still sinks",
                    "Pinned in CompletionVerifierTests: accept-with-later-proof, fail-when-failure-is-last, and the strict non-external shape",
                    "(Perslis side, shipped separately: new deterministic `perslis vm dos-exec --qmp --line --capture --expect` — opens the DOS prompt, types, enters, captures, OCR-verifies in ONE fail-closed call; win98_run_command refusals now point at it. Release 5459e9bc, doctor passed)",
                ]),
        Release(version: "0.17.34", date: "2026-08-06",
                headline: "Self-evolution: a failed run now classifies WHY and routes the fix instead of giving up",
                changes: [
                    "A failed turn no longer assumes every failure is a code bug. It CLASSIFIES the real tool errors (visible since 0.17.29) into taskBug / knowledgeGap / toolLimit / blocked, and steers the self-heal toward the right recovery — knowledgeGap → discover the tool's real capabilities and RETRY (this is exactly what the perslis 'unknown Windows 98 run command → search: win98_run_commands' run needed); toolLimit → extend the capability; blocked → surface the authority; taskBug → repair. Prints the verdict live (`self-evolution · knowledgeGap → discoverAndRetry · <tool>`)",
                    "Never-blend-repos is mechanical: only a NATIVE kist tool is an auto-evolve target; a foreign MCP tool (perslis__…) only ever gets a capability SPEC handed to its owner. A ledger loop-guard refuses to repeat a resolved evolution or churn the binary (rate-capped per window)",
                    "The auto-evolve-and-ship half is built + fully tested but NOT yet auto-running (labeled PROTOTYPE): the AdversarialPromoteGate encodes the promote rule — a self-written capability ships ONLY if the regression gate is green AND an INDEPENDENT adversary can't break it (never self-certify). ~32 tests across FailureClassifier/Router/Ownership/Ledger/Discovery/PromoteGate/Engine, all pinned to Luke's real screenshot failures",
                ]),
        Release(version: "0.17.33", date: "2026-08-06",
                headline: "cobc is a build — COBOL work can finally verify (dogfood round 1 fix #4)",
                changes: [
                    "Dogfood find: attempt 5 ran CLEAN — zero tool errors, compiled with cobc, ran the binary — and STILL failed 'unverified': the command classifier didn't know cobc, so no COBOL task could ever satisfy verify-before-done (and the re-verify replay had nothing to capture). Exact same lesson as nasm on 2026-08-04, one compiler later",
                    "`cobc` with a project COBOL source (.cbl/.cob/.cobol/.cpy) now classifies as a build; --version/no-source/foreign-path invocations still don't. Pinned in CompletionVerifierTests (5 shapes incl. the literal dogfood command line)",
                ]),
        Release(version: "0.17.32", date: "2026-08-06",
                headline: "One-shot iteration budget 12 → 40 — real tasks stop dying at the ceiling (dogfood fix)",
                changes: [
                    "Dogfood find: SIX consecutive real runs (COBOL build, win98 app) all died at 'nearIterationBudget' — 12 plan→act steps is enough to write code but not to compile, run, read the failure, fix, and re-verify it. Each attempt burned ~$1.30/1M tokens and restarted from zero; twice the model's final CORRECT fix was cut off one step before proving itself",
                    "Default --max-iterations is now 40. Runaway spend stays bounded by the existing guards that actually judge progress: the runaway-cycle detector, the budget ledger, and verify-before-done (a run that stops progressing still ends; a run that IS progressing no longer gets guillotined)",
                    "--max-iterations <n> still overrides both ways; KistOptionsTests pins the new default",
                ]),
        Release(version: "0.17.31", date: "2026-08-06",
                headline: "External-action scripts verify by RUNNING THERE — vm proof beats an impossible host build (dogfood round 2 fix)",
                changes: [
                    "Dogfood find (win98 round): kist wrote HELLO.VBS/RUNHELLO.BAT into the guest, ran it via command.com + vm_type, captured vm_ocr proof of 'HELLO FROM KIST' on the VM screen — and the verifier STILL failed the turn demanding a host build/test for the .bat/.vbs 'source' edits. No such build exists for a guest script",
                    "Fix: for an EXTERNAL-ACTION turn, a successful external-state action recorded AFTER the last source edit is accepted as its verification (the script ran in the system it was written for — grounded tool evidence, not a model claim). Build/answer/mutation turns keep the strict build-or-test demand unchanged, and external evidence BEFORE the final edit still fails",
                    "Pinned in CompletionVerifierTests: accept-on-post-edit-guest-run, reject-on-pre-edit-evidence-only, and the non-external strict path — all three shapes",
                    "(Also this build: the perslis side of the same round shipped separately — win98_run_command refusals now steer to the command.com + vm_type + vm_key path; perslis unified release ddbc6e40, doctor passed)",
                ]),
        Release(version: "0.17.30", date: "2026-08-06",
                headline: "Model routing (\"as deepseek\"), no research-expeditions on a plain review, Next/Continue is typeable",
                changes: [
                    "Routing fix (Luke's live fail): \"can u review this as deepseek then\" printed \"routed to mimo (staying on current model)\" and never switched. The parser didn't handle \"…as PROVIDER\" (provider AFTER the word \"as\"). Now it switches and keeps the task. Guarded against mentions: \"as claude said…\", \"same as gemini\", \"as good as claude\" do NOT switch (ControlIntentParser a-bis)",
                    "\"Too much research, not listening\" fix: an interactive CHAT/REVIEW turn no longer gets `spawn_agent`, so a weak model can't turn a trivial \"review this\" into a runaway web-research SUB-agent (Luke hit a 34-char review ask that spawned 3 web searches + fetch_url for ~200k tokens). Delegation still works for /effort, /fleet, /council, /dive and build/research intents; a single bounded web_search stays. Pinned by ConversationalToolsetTests",
                    "Next/Continue is now discoverable: typing `next` or `continue` already ran the board task, but the → arrow made it look like a menu to select. The dashboard now says \"type next or continue to run this (there's no cursor to select)\"",
                ]),
        Release(version: "0.17.29", date: "2026-08-06",
                headline: "Failing tools show the model their real output — no more blind compiler retries (dogfood round 1 fix #3)",
                changes: [
                    "Dogfood find (Luke's screenshot): cobc failed, the model got ONLY 'exit code 1' — the compiler's full diagnostics were captured in the tool output but the observation dropped them on failure. The model patched blind, tried a denied `2>&1` re-run, and finally reported it 'cannot access stderr' — which was never true",
                    "Fix: failed tool observations now carry the error verdict PLUS the tool's actual output (failureAwareRaw), at BOTH loop observation sites (text + native) and the re-verify replay; the trajectory recorder's failureDetail (feeds self-heal diagnosis) gets the same upgrade at all 3 sites",
                    "Pinned by FailureObservationTests: helper semantics (verdict+diagnostics, no duplication, timeout-only case) + per-file source pins so the error-only observation can't come back",
                ]),
        Release(version: "0.17.28", date: "2026-08-06",
                headline: "Symbolic re-verify — the loop replays the last passing build/test itself (dogfood round 1 fix #2)",
                changes: [
                    "Dogfood find: kist compiled + ran the COBOL app, made ONE more (correct!) edit, said done — verify-before-done demanded a fresh build, the model kept insisting done, burned the nudge budget, and a correct result failed 'unverified'",
                    "Fix (Captain-owns-the-loop): on a done-claim with an unverified source edit, the loop now REPLAYS the last passing build/test of the run itself — identical tool+args+approved context, no new authority — and re-judges on the real result. The model only gets nudged when no replay exists or the replay fails; a failing replay still ends in an honest unverified failure, never laundered success",
                    "Wired at BOTH done sites (text + native tool-call paths) with per-site source pins; VerificationReplayTests proves accept-via-replay and honest-fail end-to-end with a scripted provider",
                ]),
        Release(version: "0.17.27", date: "2026-08-06",
                headline: "run_command can finally run what it just built (./binary) — dogfood round 1 fix",
                changes: [
                    "Dogfood find: kist wrote a COBOL payroll app, compiled it clean with cobc, then run_command rejected `./payroll_report` with a FALSE \"executable not found or not executable\" (relative-with-slash names were rejected outright). The model chased a phantom dyld problem and the whole iteration budget burned on a tool bug",
                    "Fix: relative executables (`./app`, `build/tool`) now resolve against the tool call's CONFINED cwd, in both structured executable mode and promoted no-metacharacter command mode. Adds no capability — the same binary was always runnable by absolute path, and the deny gate still fires on the RESOLVED path",
                    "Pinned by RunCommandRelativeExecTests: both execute() sites end-to-end + resolver unit pins (no-cwd behavior unchanged: bare names still walk PATH only)",
                ]),
        Release(version: "0.17.26", date: "2026-08-05",
                headline: "/dive — multi-model read of OUR OWN code (local, no web) + 3-role team routing",
                changes: [
                    "NEW /dive <question> — the multi-agent codebase deep-dive you asked for: it reads the ACTUAL files under the current repo, grounds a dossier in them, then fans that real code out to every reachable model for a synthesized, file-cited answer. LOCAL and repo-scoped — no web search, no cross-repo /Volumes sweep. Run it from inside the repo you mean (it warns if you're in your home dir). This is the honest tool for \"what does our code actually do / is X hardcoded\", not the web-research pipeline",
                    "Fixed 3-role team routing: \"use deepseek to code, grok to review, gemini to plan\" now binds coder=deepseek, critic=grok, planner=gemini AND recognizes there's no task to run (it just sets the team and waits). Before, the role-verbs \"code/review/plan\" leaked into a bogus \"code review plan\" task that then ran as a team. Single-role forms with a real task (\"have gemini review this\") still keep and run the task",
                ]),
        Release(version: "0.17.25", date: "2026-08-05",
                headline: "Hardcoded-fallback sweep — endpoints, coder default, and paths go dynamic",
                changes: [
                    "Removed the last user-specific literal in Sources: the local-model attestation PATH fallback derived `/Users/lukekist/bin` — now built from NSHomeDirectory(), correct on any machine",
                    "AnthropicProvider (BYOK API path) honors ANTHROPIC_API_URL for proxy/staging routing — it was the only provider with zero endpoint override (claude-cli is unaffected; it never touches this endpoint)",
                    "Bare `/code` no longer bakes in deepseek-v4-pro: KIST_CODER_DEFAULT=<prov[:model]> overrides the shipped default; explicit `/code <prov[:model]>` unchanged",
                    "LiveModelMetadataGate's Ollama /api/show fetch now honors OLLAMA_HOST — same override the chat provider already respected, so the metadata gate can't query a different daemon than the one serving the model; kist-operator's health probe honors it too",
                    "FileKeyStore survives a missing $HOME (falls back to NSHomeDirectory() instead of an empty path that silently resolved no keys); DesignFlowKit OpenAI client honors OPENAI_BASE_URL and TagTeamKit DeepSeek reviewer honors DEEPSEEK_BASE_URL",
                    "Test-harness receipt keys are env-overridable (${KIST_RECEIPT_KEY:-…}) and the deployment-protocol test temps under $HOME, not a literal user path. Every fixed site is pinned by a per-site regression test (HardcodedFallbackRegressionTests)",
                ]),
        Release(version: "0.17.24", date: "2026-08-05",
                headline: "Router stops web-researching questions about OUR OWN code",
                changes: [
                    "Fixed the mis-route you hit: asking \"why does our build queue never change / is it hardcoded / deep dive our code\" fired the WEB-research pipeline and swept ALL of /Volumes (matching an unrelated TinkySpeak-Web build-queue spec). The router now knows: reading OUR OWN code/config/state is `chat` (read the local files), NOT research — research is for the outside world (web/docs/prior-art) only",
                    "Cleanup (from /code-review): the scorecard failure-reason categorizer is now one shared `CaptainLearningSample.scorecardReason(...)` instead of duplicated in the great-loop and turn-end writers, so the two can't drift",
                ]),
        Release(version: "0.17.23", date: "2026-08-05",
                headline: "/fix + /effort no longer false-block on a pre-existing dirty monolith (review fix)",
                changes: [
                    "Fixed (found by /code-review): the /fix and /effort NO-MONOLITHS gate measured max file size over ALL working-tree-changed files, so an unrelated already-dirty >1500-line file would falsely block a small correct fix forever. Now it baselines the dirty set before the drive and judges only the files THIS run touched — the gate still fires for a monolith your fix actually grew",
                ]),
        Release(version: "0.17.22", date: "2026-08-05",
                headline: "/audit — the security audit surface goes live (roadmap #2)",
                changes: [
                    "New `/audit` (aliases `/security`, `/vuln`, `/sast`): runs the built-in scanners over the project — committed-secret scan, SAST (shell/SQL/eval injection, weak crypto), insecure-config, and risky/unpinned dependency checks — and prints a severity-ranked report",
                    "`/audit owasp` prints the OWASP-Top-10-Agentic (2026) governance posture: each risk mapped to the runtime mechanism that addresses it (satisfied/partial/gap), grounded in concrete file/type evidence",
                    "The whole scanner suite (SecurityAuditor/SecretScanner/StaticAnalyzer/DependencyAuditor/ComplianceMapper) already existed — this exposes it as a command. Findings are static-analysis leads: verify before acting",
                ]),
        Release(version: "0.17.21", date: "2026-08-05",
                headline: "Semantic memory now fills itself — verified wins are auto-remembered (roadmap #3)",
                changes: [
                    "On a VERIFIED win (grounded + settled success), kist now auto-captures a durable lesson into semantic (vector) memory — into the SAME store the `recall` tool reads. The vector infra existed (SemanticMemory/VectorStore/embeddings) but nothing filled it; now it does, so `recall` actually returns your past solutions across sessions",
                    "Gated on an embedder (local Ollama via KIST_EMBEDDER=ollama, or a Gemini key) and --no-memory; fire-and-forget + fail-soft so it never blocks or slows a turn",
                    "Deferred (next): auto-RECALL injection at turn start (blast-radius on the turn context) + a recall prompt-nudge",
                ]),
        Release(version: "0.17.20", date: "2026-08-05",
                headline: "Eval harness — golden suite + baseline + regression detection (roadmap #1)",
                changes: [
                    "New `/eval suite` (or `/eval-suite`): replays a FIXED golden task set against the live agent, scores it with deterministic trajectory-grounded assertions, and compares to the last baseline — so a score drop is CAUGHT, not discovered live. The direct cure for 'one day works, one day not'",
                    "Regression gate: a case going passed→fail, or a pass-rate drop, is flagged (and returns non-zero so it can gate a deploy); a first run just records the baseline. History persists to ~/.kist/eval/history.jsonl per suite version",
                    "Extensible: drop project-specific cases in .kist/eval/suite.json (name/prompt/assertions) — they run alongside the built-ins; malformed files are ignored fail-soft",
                    "Built on the existing eval framework (EvalRunner/assertions/LLM-judge) — just added the three missing pieces (fixed suite, baseline, regression)",
                ]),
        Release(version: "0.17.19", date: "2026-08-05",
                headline: "\"have claude assess\" routes to Claude now — plus 3 Codex fixes",
                changes: [
                    "Fixed routing: an imperative directive before a model — \"have claude assess now\", \"make deepseek do it\", \"get gemini on this\" — now SWITCHES to that model. Before, \"have\" wasn't a switch verb and \"assess\" isn't a role, so it silently stayed on the current (often weak) model. Descriptive mentions (\"built with gemini\", \"my own claude\") still never switch",
                    "Codex fix: /dashboard is now fire-and-forget — it can never block/freeze the REPL waiting on the launcher's server process",
                    "Codex fix (correctness): /fix and /effort now measure each attempt against a working-tree BASELINE — on an already-dirty repo they no longer false-complete as 'done' when the attempt actually changed nothing",
                    "Codex fix: read_file never masks a denied/path-escape read as 'is a directory' — the escape message is preserved",
                ]),
        Release(version: "0.17.18", date: "2026-08-05",
                headline: "Model scorecard fully wired + /scorecard read-out",
                changes: [
                    "The per-model scorecard now steers ALL selection sites, not just /fix: session default, self-heal escalation, the great-loop cycle pick, and the team-reviewer pick all route around chronically-failing/looping models now (each still cold-start neutral and never stranded)",
                    "New `/scorecard` (aliases `/models`, `/trackrecord`): shows each model's runs · % ok · % looped · top failure reasons, and the Captain's rank nudge (▲ preferred / ▼ down-ranked / ⛔ routed around) — so you can SEE why a model was picked or avoided",
                    "Explicit --provider/config still always wins; the scorecard only steers the AUTO picks",
                ]),
        Release(version: "0.17.17", date: "2026-08-05",
                headline: "The Captain now tracks each model's failure/loop record and routes around losers",
                changes: [
                    "New per-model SCORECARD: every build cycle and every turn now records which model ran, whether it truly succeeded (referee-measured — verified/grounded, never self-report), why it failed (providerFault/flaky/verificationFail/runawayLoop/failureSpike/noToolProgress/toolFailures), the loop kinds it hit, and when — persisted to ~/.kist/captain-learning.jsonl (two stores that existed but were never written finally get populated)",
                    "The Captain READS it when picking a model (/fix, /effort): a model that keeps failing or looping is down-ranked and, if chronic, routed around — 'don't burn shit'. Cold-start neutral (behaves exactly like before until there's real data), never permanently blacklists (stale offenders get a probe), and never strands the only option",
                    "Foundation + functioning slice. Remaining wiring (the other selection sites + a /scorecard read-out so you can SEE each model's record) lands next",
                ]),
        Release(version: "0.17.16", date: "2026-08-05",
                headline: "/effort is now the escalation ladder — cheap first, hostile on failure",
                changes: [
                    "`/effort <goal>` is no longer the flat `/dig` council. It's the CONFLICT-ESCALATION LADDER: build solo (L1) → on a FAILED hard gate, a DISTINCT-vendor adversarial reviewer enters and rips it apart (L2) → a rater scores success probability (L3) → the full gauntlet (ultra). Cheap path ships fast; only failure spends more minds",
                    "The escalation IS real: each rung's critique is fed into the next build order, so the work actually changes — not models politely agreeing. The terminal authority is the compile/verify gate (the /fix judge: verified, non-monolith artifact), never a model vote",
                    "Cross-vendor by design: strongest builder, a different reviewer, a third rater. `/effort <1|2|3|ultra> <goal>` starts at a chosen rung; `/dig`/`/minds` remain the flat all-at-once council",
                ]),
        Release(version: "0.17.15", date: "2026-08-05",
                headline: "The Captain picks the model for /fix — no more routing roulette",
                changes: [
                    "`/fix` now runs on the STRONGEST reachable model the Captain can pick — never a known-weak/dead one (MiMo, cold local endpoints). Kills the 'one day strong model, one day weak' luck for fixes",
                    "Deterministic + honest: it uses the same frontier-tier rule as strong-on-repair, prints '⚓ Captain routing → <model>' so you see the pick, and does NOT override when you're already on the strongest",
                    "Scoped + safe: this is opt-in via /fix only — the global per-turn router is unchanged. First step of the Captain owning model selection",
                ]),
        Release(version: "0.17.14", date: "2026-08-04",
                headline: "/fix now reviews its own work — build, then bust its balls",
                changes: [
                    "`/fix` completes the full arc you asked for: plan → force action → build a VERIFIED artifact → then automatically ball-bust the result (the skeptical no-gaslight review of what it just built)",
                    "The review is advisory — it names flaws and proposes fixes; it does not auto-apply. Only runs on a real completion (nothing to review if /fix couldn't produce an artifact)",
                ]),
        Release(version: "0.17.13", date: "2026-08-04",
                headline: "/ballbusting is back — a no-mercy review that never gaslights",
                changes: [
                    "New `/ballbusting` (aliases `/ballbust`, `/roast`): points a DISTINCT skeptical reviewer at your current work — the working-tree diff by default, or `/ballbusting <plan>` to roast an idea — and busts its balls: no praise-opening, no gaslighting, every flaw named with a CONCRETE fix, and an honest 🟥/🟧/🟨/🟩 rating",
                    "Restores the ACTION that had decayed into just a tone (`/mode nobs`): the review engine + the brutal contract, fused. Honest, not theatrical — it won't invent problems to sound tough, but it defaults to skepticism",
                    "Advisory: it proposes changes, never self-reviews (picks a reviewer ≠ the current model), and does not auto-apply",
                ]),
        Release(version: "0.17.12", date: "2026-08-04",
                headline: "/fix — the Captain drives the build and won't accept analysis as done",
                changes: [
                    "New `/fix <goal>` (alias `/repair`): the Captain sits on top and DRIVES the proven /build worker in a bounded force-retry loop — it will not stop until there's a VERIFIED, non-monolith artifact. Analysis/plan-only output is rejected and re-ordered as a real build",
                    "The deterministic SymbolicCaptain is the judge of 'done' — not the model. It adds a real NO-MONOLITHS gate (max line count over the actually-changed files), so a /fix that balloons a file past 1500 lines is refused",
                    "Safety preserved: /fix reuses the /build worker, so it inherits the CaptainSimulationEnforcer preflight + mutation gate + critic — no parallel unsafe path. Bounded to 3 attempts; ESC-interruptible",
                    "`/fix` alone fixes the problem you just described; `/fix <goal>` fixes that. First live piece of putting the symbolic Captain back on top (the loop-owner spine shipped as CaptainController)",
                ]),
        Release(version: "0.17.11", date: "2026-08-04",
                headline: "/dashboard is back — the full Fallout/Pip-Boy GUI",
                changes: [
                    "Fixed: the dashboard was DEAD because an uncommitted syntax error (a half-applied retry wrapper, IndentationError) in `~/.kist/cortex/generated_tool_executor.py` crashed the runtime import on every launch — reverted it to the last-good version; the :7777 server boots again",
                    "Restored the `/dashboard` command (dropped when kist-loops was re-homed as the captain) — plus aliases `/kanban`, `/pipboy`, `/pip-boy`, `/fallout-dashboard`, `/kist-dashboard`. Optional view: /dashboard [conversation|flow|timeline|fleet|vms|plan]",
                    "The full GUI (talent/tech tree, history, arch/cortex/sessions/vms views) was intact on disk the whole time under ~/.kist — only the launch path was broken",
                    "The command runs the canonical deployed `~/bin/kist-dashboard` launcher (server + provenance + browser-open live there) on a detached task so the readiness probe never blocks the REPL",
                ]),
        Release(version: "0.17.10", date: "2026-08-04",
                headline: "read_file stops lying that a directory 'doesn't exist'",
                changes: [
                    "Fixed: `read_file` on a DIRECTORY (including the project root itself) reported 'not found — it doesn't exist here', a flat lie. It now says '<path> is a directory — use list_files' and steers you to the right tool",
                    "This is what sent the self-heal diagnostic researcher in circles: its first move was `read_file /Users/lukekist` (the root), it was told the root 'doesn't exist', and it couldn't orient — so the repair mission flailed instead of fixing anything",
                    "A genuinely missing file still reports not-found; real files read normally",
                ]),
        Release(version: "0.17.9", date: "2026-08-04",
                headline: "view_image can look at a dragged-in screenshot without a cp",
                changes: [
                    "Fixed: view_image (and every read-only vision/media tool) refused a screenshot you dragged/pasted in — it lives in macOS's `…/T/TemporaryItems/…` inbox, which counts as 'escapes the project root'. The agent had to `cp` it into the project first (an irreversible action needing approval) just to look at a file you already handed it",
                    "The per-user drag/screenshot inbox is now auto-readable read-only — attaching the file IS the grant. No --allow-read needed",
                    "Evaluated live per call, so it works even when the inbox is created after a long-lived session started",
                    "Scoped to TemporaryItems only (not all of $TMPDIR) and read-only — writes are unaffected and stay project-confined",
                ]),
        Release(version: "0.17.8", date: "2026-08-04",
                headline: "symbols outline works on a whole directory/module",
                changes: [
                    "Fixed: `symbols outline` on a directory (e.g. Sources/AgentCore) errored 'unsupported file type' — it now outlines every supported source file inside the directory (bounded, per-file caps)",
                    "A genuinely unsupported FILE still gives the honest error; only directories get the new walk",
                ]),
        Release(version: "0.17.7", date: "2026-08-04",
                headline: "Builds don't choke on the model's essay anymore",
                changes: [
                    "Fixed the real DOS/code-build failure (caught by a VISUAL test): when the model wraps code in prose + markdown fences (\"Okay, here's the code:\" + ```asm``` + ```bash``` samples), the whole essay was written into the source file and the compile died on line 1",
                    "generate now extracts the actual code — the largest fenced block — out of any surrounding explanation and sibling samples",
                    "The planner now tells file-bound generate steps to output ONLY the raw file contents (no prose, no ``` fences)",
                    "Verified visually end-to-end: a real DOS .COM built + assembled with nasm + verified — 4/4 steps green",
                ]),
        Release(version: "0.17.6", date: "2026-08-04",
                headline: "It builds its own DOS apps now — end to end",
                changes: [
                    "Dogfooded: `/build a DOS program` now generates the assembly, assembles it with nasm, verifies it, and reports ● done — proven producing a real 30-byte hello.com",
                    "Fixed the #1 build-breaker: `generate` was wrapping code in ```markdown fences``` and writing the backticks into the file (nasm choked on line 1) — fences are now stripped",
                    "Legacy builds go NATIVE-first: assembling/compiling uses nasm/dosbox-x directly; the Perslis VM is only for RUNNING real Win9x/DOS software (no more routing a nasm build into the VM)",
                    "Repair loop now SEES the real error: a failing command's stderr (e.g. nasm's message) reaches the fixer instead of a blind 'exit code 1'",
                    "Hands-off verify works under --sandbox: raw shell (pipes/strings/grep) auto-approves when the OS sandbox confines it; un-sandboxed still needs approval",
                    "The completion gate learned that `nasm` IS a build and `strings`/`xxd`/`nm`/… are read-only inspection — a correct binary is no longer reported 'unverified' forever",
                    "Steps can chain a FIELD of a prior tool's JSON output: ${E1.qmp}; and the planner is taught the real Perslis calling convention (image is a path, qmp is a reused socket)",
                ]),
        Release(version: "0.17.5", date: "2026-08-04",
                headline: "Your build command is an order, not a suggestion",
                changes: [
                    "The simulation gate no longer vetoes an explicit build: when YOU type /build (or /pe, --plan-execute), a sub-threshold estimate is shown as an ADVISORY and the build proceeds — no more 'captain refused: 64% is below 70%' on work you asked for",
                    "Safety kept where it's real: critical-risk signals (production, delete, payments, secrets) still hard-block, autonomous flows keep the fail-closed gate, and a failed evidence write still stops the run",
                    "3 new tests pin it: advisory-proceeds on user request, critical still blocks, and the call site declares the user-request initiator",
                ]),
        Release(version: "0.17.4", date: "2026-08-04",
                headline: "Colors back, resize fixed, legacy work routes to Perslis",
                changes: [
                    "Fixed the white-out: the neon dashboard, confidence gauge, and all turn colors are back — the sticky-turn stdout capture was making every color check think the terminal wasn't a terminal (TTY-ness is now snapshotted at launch)",
                    "Fixed screen corruption when moving/stretching the terminal window: the pinned-during-turns bar (--sticky-turns) is opt-in again per the project contract — the input box still appears between turns as always",
                    "Fixed 'executable not found: brew/nasm/dosbox-x': the launcher was scrubbing Homebrew and ~/bin off PATH; the real toolchain (and the perslis/legacy bridges) now resolve",
                    "DOS/Win9x/legacy goals now route through the Perslis system (perslis VM tools when the gateway is up, the perslis/legacy-fetch CLIs otherwise) — the planner is forbidden from brew-installing emulators, and a lint backstop rejects such plans",
                    "17 new regression tests + 3 updated pins cover every fixed site (color sites, wrapper contract + PATH order, resolution tiers, both planner branches, lint)",
                ]),
        Release(version: "0.17.3", date: "2026-08-03",
                headline: "IBM watsonx.ai as a model — hand the thinking to Watson",
                changes: [
                    "watsonx (IBM) is now a built-in provider — talk to it with /model watsonx, or let kist drive the conversation and hand the hard reasoning to Watson via /roles critic watsonx, /roles planner watsonx, or /copilot co watsonx",
                    "Models: Llama 3.3 70B, Mistral Large, Granite 3 8B, Llama 3.2 90B Vision (pick with /model watsonx:<id> or WATSONX_MODEL)",
                    "Handles IBM's real auth: IAM API-key→bearer-token exchange (cached ~1h, auto-refresh) — not a static key",
                    "Setup: export WATSONX_API_KEY and WATSONX_PROJECT_ID (region via WATSONX_URL, default us-south). Missing project id fails fast with exact guidance",
                    "Routes through the universal text tool-protocol, so Watson keeps full tool access and won't break on multi-turn tool histories",
                ]),
        Release(version: "0.17.2", date: "2026-08-03",
                headline: "/chain — a visual automation center",
                changes: [
                    "/chain — opens a local visual workflow builder (Zapier × LangGraph for Kist): drag a trigger into a graph of Kist steps + conditions, connect them, Save and Run",
                    "Chains are saved as JSON in .kist/chains/ and can be run from the terminal too: /chain list · /chain run <name>",
                    "Each 'Kist step' passes its output to the next ({{input}}); conditions branch on the text; schedule triggers are ready for daily automations",
                    "Next: real tool-using turns per step + Scribe import + daily-email→respond wiring",
                ]),
        Release(version: "0.17.1", date: "2026-08-03",
                headline: "Action-first builds, /mode, honest goals",
                changes: [
                    "/build — fire the plan→execute worker on a plan (stop researching, start building); a clear build request now auto-runs it",
                    "/mode — set how Kist talks: conversation · science · build · friend · nobs; /mode level <grade..college>; /mode persona <write your own voice>",
                    "/competitive <target> — deep R&D cross-compare OUR project vs a competitor/product/URL",
                    "Routing: 'ask/use/bring <model>' actually switches models now; the strongest keyed provider is the default (no more defaulting to MiMo, which 400s)",
                    "BUILD STATUS: every build turn ends with a PATCH→APPLY→FILES→BUILD/TEST→BOARD checklist, so 'done' can't be faked",
                    "Self-heal: the researcher hands the builder a clean machine-readable spec (not the whole transcript), reproduces the failure first, halts instead of churning more research, and escalates to a heavy-hitter model",
                    "Goals & research now reflect YOUR project — the hardcoded Cursor/OpenHands/Claude-Code watch-list only appears when developing Kist itself",
                    "Fixed: mouse-scroll no longer cancels your turn or eats Enter at the approval prompt",
                    "Fixed: Gemini's private thinking no longer leaks into the answer",
                    "Internal: KistREPL's 2,992-line run() decomposed into focused modules (720-line core), fully test-verified",
                ]),
        Release(version: "0.17.0", date: "2026-08-02",
                headline: "Readable terminal — color, confidence, sticky bar",
                changes: [
                    "Neon per-category dashboard sections + green battery confidence gauge",
                    "/confidence (/why): why the score is what it is and how to raise it",
                    "Tool lane: an emoji per tool, category colors, dimmed metadata",
                    "Streamed answers get markdown coloring (bold / code / headers / lists); code fences stay raw",
                    "Bottom input bar now stays glued through turns (sticky-turns on by default; --no-sticky-turns opts out)",
                    "NO_COLOR + mono screen-reader theme honored on every surface",
                    "/version: this changelog view, as a bordered card",
                    "/usage: in-depth card — per-provider (incl. claude-cli / codex-cli subscription) tokens + cost, subagents, tools, MCP servers, weekly split",
                    "/usage: cost-by-activity — attributes budget to Architecture / Code / Review & tests / Research / Orchestration",
                    "/autonomy: where the time went — Thinking / Researching / Coding / Running / Delegating bars",
                ]),
        Release(version: "0.16.0", date: "2026-08-01",
                headline: "Consensus reviews + self-fixing captain",
                changes: [
                    "/ultra: consensus of minds — each model reviews then fixes until flawless",
                    "/bughunt: a fleet of isolated hunters for real-world bug hunting",
                    "The reviewer now auto-fixes what it finds",
                    "Auto-explore: answers lookup questions from our own files instead of hallucinating",
                    "Keyless claude-cli / codex-cli subscription providers",
                ]),
    ]

    /// The release matching the running binary's version, else the newest known.
    static func current(version: String = KistBuildInfo.productVersion) -> Release? {
        releases.first { $0.version == version } ?? releases.first
    }

    /// Render the `/version` panel as a bordered CARD (like Codex's `/status`): version + headline in
    /// the top border, the real build stamp (commit/branch/date from the manifest), the current
    /// release's changes in full, and earlier releases compact. Every row is padded to the same cell
    /// width so the box stays square even with emoji + ANSI inside (widths via TerminalCellText).
    static func render(provenance: KistBuildInfo.Provenance,
                       version: String = KistBuildInfo.productVersion,
                       color: Bool,
                       width: Int = 76) -> String {
        let cur = current(version: version)
        return TerminalCard.build(title: "🚀 kist v\(version)", color: color, width: width) { b in
            if let h = cur?.headline { b.bullet(" ", glyphCode: "2", h, textCode: "37;1") }
            b.blank()

            // Build stamp — the honest "when / what shipped" line.
            var stamp: [String] = []
            if let sc = provenance.shortCommit { stamp.append(b.c("94", sc)) }
            if let br = provenance.branch { stamp.append(b.c("94", br)) }
            if let d = provenance.builtAt { stamp.append(b.c("94", isoStamp(d))) }
            if provenance.sourceDirty == true { stamp.append(b.c("33;1", "dirty")) }
            b.row(stamp.isEmpty ? b.c("2", "build stamp unavailable (unmanaged build)")
                                : b.c("2", "build ") + stamp.joined(separator: b.c("2", " · ")))
            b.blank()

            if let cur {
                b.row(b.c("95;1", "What's new in \(cur.version)") + b.c("2", " · \(cur.date)"))
                for change in cur.changes { b.bullet("•", glyphCode: "92;1", change) }
                b.blank()
            }

            let earlier = releases.filter { $0.version != (cur?.version ?? version) }
            if !earlier.isEmpty {
                b.heading("Earlier releases", "2")
                for r in earlier {
                    b.bullet("▪", glyphCode: "94;1", "\(r.version) · \(r.date) · \(r.headline)")
                }
            }
        }
    }

    /// A stable `YYYY-MM-DD HH:MM` in the local zone (no Date.now — takes the instant explicitly).
    private static func isoStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
