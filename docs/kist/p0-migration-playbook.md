# P0 migration playbook + P1 reframe (read before the headless surgery)

Captured from a read-only deep-scope so the `@MainActor` migration is mechanical, and a
read-only audit of the provider layer that **corrects the P1 plan**. No code changed here.

---

## P1 REFRAME — the agent loop is a TEXT protocol, not native tool-calling

Verified by reading every provider + the action parser:

- **No provider sends `tools`/`functionDeclarations` to its API.** All requests are
  messages-only. `StreamEvent.toolCall(id:name:argumentsJSON:)` is **defined but never
  yielded** (dead). `DeepSeekProvider.sendWithTools()` is **dead code** (never called).
- The loop is a **uniform text-based JSON ReAct protocol**: `AgentPrompts.iterativeAgentPrompt`
  tells the model to emit `{"thinking":...,"next_action":{"type":STRING,"tool":STRING,
  "parameters":{}},"message":...}`; `UnifiedAgentRuntime.parseIterativeResponse` (≈L398–444)
  parses that TEXT identically for all 10 providers. Recovery: `attemptManualIterativeExtraction`
  (≈L447–494) regex-scrapes `type`/`tool` when JSON parse fails.

**Consequence:** the "per-provider native-tool-format divergence" the scorecard feared mostly
**does not exist** — the loop is provider-agnostic by construction (works on Gemini/Ollama/MLX
*in code path*). The scorecard's "30%, broken on Gemini/local" was WRONG about the mechanism.

**The real P1** (hybrid, matches the BYOK research brief):
1. The existing text protocol IS the universal fallback for no-native-tool models (local/MLX).
2. Add **native tool-calling as the PREFERRED path** on providers that support it
   (Anthropic `tool_use` / OpenAI `tool_calls` / Gemini `functionCall`) **+ JSON-mode/strict
   schema** — for reliability, not portability. Gate by a `ModelCapabilities` descriptor;
   degrade to the text protocol when native tools/strict-output aren't supported.
3. Wire the loop to prefer `StreamEvent.toolCall` (currently dead) over text-parsing when present.

**STILL UNVERIFIED (needs LIVE API runs, not readable from source):** the actual per-provider
*reliability* of the text protocol (does Gemini/Ollama reliably emit valid `next_action` JSON,
or lean on the regex fallback?). Run a scripted task against ≥3 real providers and measure
JSON-parse-first-try rate BEFORE deciding how hard to push native tool-calling. This is the
first P1 verification; it's cheap and build-safe.

---

## P0 surgery map (spec steps 2→4) — exact call sites

> File `UnifiedAgentRuntime.swift` unless noted (`+Resume` = `UnifiedAgentRuntime+Resume.swift`).
> Line numbers are from the read at this commit — re-confirm before editing.

### Step 2 — provider swap (3 LLM call sites; per-site assertion each)
- **A · `callLLMForNextAction`** ≈L335–395. Provider at L336 `ProviderManager.shared.currentProvider`;
  call `provider.sendMessage(messages:settings:stream:true)` ≈L373; streams text, concats to a String.
- **B · `callLLMForStructuredPlan`** ≈L498–543 (used L121/176/288/1261). Provider L500; same call ≈L520.
- **C · `requestReplan`** in `+Resume` ≈L201–213; passes `ProviderManager.shared.currentProvider`
  into `ReplanEngine.reviseStrategy(context:provider:)` (L212). **Audit `ReplanEngine` provider param.**
- Swap all three to AgentCore `ProviderRegistry.stream(providerId:model:messages:settings:)`
  (yields `StreamEvent`; map `.delta`→accumulate + `sink.emit(.tokenDelta)`). Inject
  `providers/providerId/model`. Pin: same messages → same parsed action, one assert per site.

### Step 3 — route emission through the sink (still `@MainActor`)
~25+ `postUpdate { self.<published> = … }` sites. 9 `@Published` vars (L27–35) + `lastCheckpointError`
(L74). Map: `executionState`→`.stateChanged`; `currentActionIndex`→`.actionStarted`;
`actionResults`→`.actionFinished`; `currentPlan`(set)→`.planReady`; checkpoint write OK/'s
fail (L321 `persistActiveRun`)→`.checkpointSaved`/`.checkpointFailed`; `completed`/`failed`.
Approval: replace `isWaitingForApproval` + `approvalContinuation` (L77) + `approvePlan/rejectPlan`
(L1322/1328) and `pendingQuestion` (L847) with `await interactor.requestApproval/requestInput`.
Keep class `@MainActor` here; `GUIEventSink` writes the same `@Published` the GUI binds → GUI
unchanged. Add a `RecordingEventSink` scripted-run assertion BEFORE this step.

### Step 4 — remove `@MainActor`/Combine/ObservableObject (HIGH risk) — LANDMINES
- Class decl L21 `@MainActor final class … : ObservableObject`; `import Combine` L2.
- **Make it a `final class` confined to one task — NOT a struct** (it has identity + mutable
  run state). The single-flight `isProcessing` guard (L71) currently relies on `@MainActor`
  serialization → replace with an `NSLock` (or make the type an `actor`).
- **`approvalContinuation: CheckedContinuation<Bool,Never>?` (L77) becomes a Sendable hazard** →
  replace with an `AsyncStream`/channel; guard `approve/reject/cancel` against double-resume
  (cancel at L1344 already races).
- **`ToolRegistry.executeWithRuntime` is `@MainActor` (`AgentTools.swift` L132)**, called from
  the loop (L957/1004/1029/1052/1078) → it's shell/FS work; make `nonisolated`/headless variant.
- **Audit `AgentCheckpoint` is `Sendable`** (it's the loop's single source of truth, held across tasks).
- **`AgentRuntimeService` is `@MainActor` (L13)** with `changedFilesSinceLastBuild: Set` mutated
  without a lock (L93) → add a lock when isolation is dropped.
- De-risk: GUI stays green because `GUIEventSink` is the sole main-actor consumer. **Do NOT use
  `#if os(macOS)` for `postUpdate`** (the agent suggested this — wrong; the adapter pattern is
  the seam). Compile the **app** (`xcodebuild`) + run `FloatingChatAppTests` after this step.

### Init / DI surface
Today `private init()` (L79) + singletons. Headless init must inject: `sink: RuntimeEventSink`,
`interactor: RuntimeInteractor`, `providers: ProviderRegistry`, `providerId`, `model`,
`tools: ToolRegistry`, `runtimeService`, `checkpoints: CheckpointStore`. Config vars L39–49 →
constructor params. Drop the GUI-typed `@Published` from the public surface (events replace them).

### Verify each step
`xcodebuild -project FloatingChatApp.xcodeproj -scheme FloatingChatApp build` (app green, ~2s
incremental) + `swift test` (AgentCore) + run `FloatingChatAppTests`. Codex gate after step 2
(behavior-sensitive) and step 4 (isolation removal). Commit each step on its own branch.

Baseline at this commit: GUI **BUILD SUCCEEDED**, AgentCore **107 tests green**.
