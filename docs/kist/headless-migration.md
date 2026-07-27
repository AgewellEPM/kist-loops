# Headless Migration Spec — making the agent RUNTIME run inside `Kist` (terminal)

**Status:** RESEARCH + SPEC ONLY (no code changed). Label: PROTOTYPE plan.
**Goal:** the agent loop (plan → act → observe → re-plan → checkpoint → resume) runs with
**zero GUI / AppKit / SwiftUI** dependency, so the SAME runtime drives both the existing
SwiftUI app and a new Foundation-only `Kist` terminal app — sharing AgentCore's
`ProviderRegistry`.

This spec is scoped to the runtime. It does NOT redesign tools or providers beyond what the
headless seam requires.

---

## 0. Where the code actually lives (ground truth)

- App sources: `FloatingChatApp/Sources/...` (Xcode target, **no SPM**).
- Foundation-only library: `Sources/AgentCore/...` (SPM `Package.swift` at repo root). Providers
  already ported here (`ChatProvider`, `ProviderRegistry`, `ProviderCatalog`, 10 providers).
- The runtime to port lives in `FloatingChatApp/Sources/Services/AgentLoop/`.

The migration target is: **move the loop into a new AgentCore module** (`AgentRuntime`) that the
Xcode app links and that a new SPM executable target `Kist` links.

---

## 1. Coupling inventory

Grep run over `FloatingChatApp/Sources/Services` and `.../AgentLoop` for:
`@MainActor`, `import SwiftUI`, `import AppKit`, `import Combine`, `: ObservableObject`, `@Published`.

### 1a. Runtime core (must go headless) — `Services/AgentLoop/`

| File | Coupling | Why coupled | Effort → headless |
|---|---|---|---|
| `UnifiedAgentRuntime.swift` (1452 LOC) | `@MainActor` class, `ObservableObject`, 9 `@Published`, `import Combine`, `postUpdate { @MainActor }` (~87 state mutations) | The core loop publishes state for SwiftUI binding | **HIGH** — biggest single piece; strip `@MainActor`, replace `@Published` mutation with event-sink emit |
| `UnifiedAgentRuntime+Resume.swift` (loop body) | same actor, `postUpdate`, `ProviderManager.shared`, `ToolRegistry.shared`, `AgentRuntimeService.shared` | loop body emits via `postUpdate`; pulls provider/tools from GUI singletons | **HIGH** — emit via sink; inject provider+tools+runtime-service |
| `AgentLoopEngine.swift` (46 KB) + `+Resume`/`+Messaging`/`+SubTeams` | `@MainActor`, `ObservableObject`, 5 `@Published`, `Combine` | multi-agent orchestration, UI-bound | **HIGH** — same treatment; lower priority (Kist v1 can ship single-runtime) |
| `AgentOrchestrator.swift` (23 KB) | `@MainActor`, `ObservableObject`, 4 `@Published`, `Combine`; owns `ExecutionState` enum | orchestration modes + state | **MED** — `ExecutionState` itself is a plain enum (good); class is UI-bound |
| `AgentRuntimeService.swift` | `@MainActor`, `ObservableObject`, 8 `@Published`, `Combine` | auto-build/retry/project-state; `executeWithRuntime` is `@MainActor` | **MED** — logic is shell/FS, not GUI; coupling is incidental |
| `AgentMessageBus.swift` | `@MainActor` (1) | inter-agent bus | **LOW** — actor isolation only |
| `AgentTools.swift` | `@MainActor` on ONE method (`executeWithRuntime` helper) | bridges to `AgentRuntimeService.shared` | **LOW** — `AgentTool` protocol + `ToolRegistry` are already Foundation-only |
| `Tools/RunCommandTool.swift` | `import Combine` only | none real | **TRIVIAL** — drop import |
| `Tools/CreateXcodeAppTool.swift` | `import SwiftUI` appears only inside generated-template STRINGS | none real | **TRIVIAL** — it's literal source text, not a dependency |

### 1b. Already platform-neutral (no rework)

| File | Note |
|---|---|
| `AgentCheckpoint.swift` | Pure `Codable` DTOs + `AnyCodableValue(any:)` bridge. **No GUI.** Ready. |
| `CheckpointStore.swift` / `JSONDirectoryStore.swift` / `OrchestrationCheckpoint.swift` | Foundation-only durable JSON store (`~/Library/Application Support/...`). Ready (see §3 caveat). |
| `ReplanEngine.swift` | Foundation-only; takes a provider as a param already. Ready. |
| `AgentPrompts.swift` | Pure strings. Ready. |
| `Models/ExecutionPlan.swift` | `ExecutionPlan/PlanStep/ExecutableAction/ActionExecutionResult` + `AnyCodableValue` — plain models (note: `[String:Any]` params, not Codable; that's handled by the checkpoint DTOs). Ready. |
| `Sources/AgentCore/*` | `ChatProvider` (Sendable, stateless), `ProviderRegistry` (Sendable), 10 providers, `KeyStore`. Ready and **is the target provider layer.** |

### 1c. GUI-only (NEVER move into the runtime; Kist re-implements thin equivalents)

`ProviderManager.swift` (GUI provider, `@MainActor`/`ObservableObject`), `AIProvider.swift`
(the GUI `sendMessage` provider protocol), `Views/*`, `App/*`, plus GUI services
(`ScreenCaptureService`, `VoiceInputManager`, `SpeechOutputService`, `HotkeyService`,
`AppPreviewService`, `AppLinkService`, `Memory/FrontalCortex`, the `AgentPipeline/*`
ObservableObjects). The runtime must NOT reach into any of these.

**Two provider worlds exist today:** the runtime calls `ProviderManager.shared.currentProvider`
(GUI, `AIProvider.sendMessage`), but AgentCore ships the stateless `ProviderRegistry`/`ChatProvider`.
**The migration's central swap is: runtime stops using `ProviderManager`/`AIProvider` and uses
AgentCore's `ProviderRegistry`/`ChatProvider` instead** (see §4 + §5 step 2).

---

## 2. The event-sink seam

Replace every `postUpdate { @MainActor self.<published> = ... }` with a call to an injected
**event sink**. The loop emits; consumers render. The GUI adapter re-publishes to `@Published`;
the Kist adapter prints to the terminal.

### 2a. Protocol (lives in AgentCore, Foundation-only)

```swift
// Sources/AgentCore/RuntimeEvent.swift
public enum RuntimeEvent: Sendable {
    case stateChanged(RuntimeState)                       // idle/analyzing/planning/executing/...
    case intentResolved(intent: String, confidence: Double)
    case planReady(summary: String, stepCount: Int)
    case tokenDelta(String)                               // streamed assistant text (token stream)
    case reasoningDelta(String)                           // hidden reasoning chunk
    case actionStarted(index: Int, tool: String?, description: String)
    case actionFinished(index: Int, success: Bool, output: String, error: String?)
    case replanStarted(reason: String)
    case checkpointSaved(id: String, iteration: Int)
    case checkpointFailed(String)                         // surface lost durability (today's lastCheckpointError)
    case awaitingApproval(planSummary: String)
    case awaitingInput(question: String)
    case completed(summary: String)
    case failed(String)
    case cancelled
}

public enum RuntimeState: String, Sendable {
    case idle, analyzing, planning, executing, completed, failed, cancelled
}

/// The loop emits to this. Sendable so it crosses the loop's task/actor boundary.
public protocol RuntimeEventSink: Sendable {
    func emit(_ event: RuntimeEvent)
}

/// Two-way control the loop needs from the host (approval / interactive answers).
/// Headless one-shot supplies an auto-approver; the TUI/GUI prompt the human.
public protocol RuntimeInteractor: Sendable {
    func requestApproval(planSummary: String) async -> Bool
    func requestInput(question: String) async -> String
}
```

> Why an enum, not a delegate-with-many-methods: it mirrors AgentCore's existing `StreamEvent`
> sum type, is `Sendable`, trivially serializable (useful later for mcp-server / remote drive),
> and lets a consumer ignore events it doesn't care about with a `default:`.

### 2b. How `UnifiedAgentRuntime` changes

Today (UI-coupled):

```swift
@MainActor final class UnifiedAgentRuntime: ObservableObject {
    @Published var executionState: ExecutionState = .idle
    @Published var actionResults: [ActionExecutionResult] = []
    func postUpdate(_ u: @escaping @MainActor () -> Void) { Task { @MainActor in u() } }
    // ... loop:
    postUpdate { self.executionState = .executing }
    postUpdate { self.actionResults.append(result) }
}
```

Headless (event-emitting):

```swift
final class UnifiedAgentRuntime {                 // no @MainActor, no ObservableObject
    private let sink: RuntimeEventSink
    private let interactor: RuntimeInteractor
    private let providers: ProviderRegistry        // AgentCore — replaces ProviderManager.shared
    private let providerId: String
    private let model: String?
    private let tools: ToolRegistry                // injected (was ToolRegistry.shared)
    private let checkpoints: CheckpointStore        // already headless

    init(sink:, interactor:, providers:, providerId:, model:, tools:, checkpoints:) { ... }

    // ... loop body, instead of postUpdate:
    sink.emit(.stateChanged(.executing))
    sink.emit(.actionStarted(index: i, tool: action.tool, description: action.description))
    let result = await executeAction(action)
    sink.emit(.actionFinished(index: i, success: result.success, output: result.output, error: result.error))
}
```

The runtime keeps `activeRun: AgentCheckpoint` as its **single source of truth** for serializable
state (already true today). The removed `@Published` vars were a *projection* of that — the GUI now
derives the same projection from events instead. Approval/input flows (`waitForApproval`,
`pendingQuestion`) move from "set a `@Published` flag + await a continuation" to
`await interactor.requestApproval(...)`.

### 2c. The token stream already has the right shape

`callLLMForNextAction` already does `for try await chunk in stream { response += chunk }`. Swap the
GUI `provider.sendMessage(...stream:true)` for `providers.stream(providerId:model:messages:settings:)`
which yields `StreamEvent`s, and map each `.delta` → `sink.emit(.tokenDelta(d))` while accumulating
the full text for the parser. No new streaming plumbing required.

### 2d. The two adapters

```swift
// GUI: keeps the app working unchanged. Re-publishes events onto an ObservableObject.
@MainActor final class GUIEventSink: ObservableObject, RuntimeEventSink {
    @Published var executionState: RuntimeState = .idle
    @Published var actionResults: [ActionExecutionResult] = []
    nonisolated func emit(_ e: RuntimeEvent) { Task { @MainActor in self.apply(e) } }
    private func apply(_ e: RuntimeEvent) { /* same writes the loop used to do via postUpdate */ }
}

// Kist: prints to the terminal (mirrors the colors/format already in AgentCLI.swift).
struct TerminalEventSink: RuntimeEventSink {
    func emit(_ e: RuntimeEvent) {
        switch e {
        case .tokenDelta(let t):       FileHandle.standardOutput.write(Data(t.utf8))
        case .actionStarted(_, let tool, let d): print("\u{001B}[33m▶ \(tool ?? "action"): \(d)\u{001B}[0m")
        case .actionFinished(_, let ok, let out, let err):
            print(ok ? "\u{001B}[32m✓\u{001B}[0m \(out.prefix(200))" : "\u{001B}[31m✗ \(err ?? out)\u{001B}[0m")
        case .completed(let s): print("\u{001B}[32m● done:\u{001B}[0m \(s)")
        case .failed(let s):    print("\u{001B}[31m● failed:\u{001B}[0m \(s)")
        default: break
        }
    }
}
```

This adapter approach is what keeps the GUI green throughout (§5).

---

## 3. Resume / replan / checkpoint in headless

**Good news: this layer is already headless.** `AgentCheckpoint`, `CheckpointStore`,
`JSONDirectoryStore`, `OrchestrationCheckpoint`, `ReplanEngine` are pure Foundation. The
resumable loop (`UnifiedAgentRuntime+Resume.swift`) already drives fresh AND resumed runs through
one code path, persists after every iteration, brackets the side effect with `pendingAction`
(Codex HIGH-1), seeds failure streak + re-plan budget from the checkpoint, and reconciles an
interrupted action on resume with a verify-state note. None of that touches the GUI.

GUI assumptions to break (all small):

1. **Emission inside resume.** The resume path also calls `postUpdate {}`
   (e.g. `executionState`, `actionResults`). Route these through the sink like the main loop.
2. **`@Published var lastCheckpointError`.** Replace its read-by-GUI with the
   `.checkpointFailed(String)` event. The internal `lastCheckpointError` can stay as a plain
   stored property for `persistActiveRun()`'s fail-closed logic; only its *surfacing* changes.
3. **`ProviderManager.shared.currentProvider` inside `requestReplan`.** `ReplanEngine` already
   takes a `provider:` param — pass the injected AgentCore provider instead of the GUI singleton.
   (One-line change at the call site; `ReplanEngine` needs to accept a `ChatProvider`/registry
   rather than the GUI `AIProvider` — small adapter or overload.)
4. **Checkpoint directory.** `CheckpointStore` defaults to the app's Application Support folder.
   For Kist that's fine (same user, same machine → resume a GUI-started run from the terminal and
   vice-versa, which is a feature). Make the directory injectable via the Kist entry point
   (it already is via `CheckpointStore(directory:)`); document `KIST_CHECKPOINT_DIR` override.
5. **`reset()` touches `@Published`.** It must emit `.stateChanged(.idle)` + clear internal state
   instead of writing published vars.

No serialization format change is needed — checkpoints written by the GUI are byte-compatible with
Kist.

---

## 4. The `Kist` entry point

New SPM executable target (`Sources/Kist/`), product added to root `Package.swift`. Depends on
`AgentCore` (which by then exports the `AgentRuntime` module / the ported loop).

```
.executableTarget(name: "Kist", dependencies: ["AgentCore"])
```

### 4a. Argument surface

```
kist "do X"                         # one-shot: run to completion, stream to stdout, exit
kist                                # interactive REPL (mirrors AgentCLI.swift commands)
kist --resume <checkpointId>        # resume a checkpointed run
kist --resume-last                  # resume newest resumable checkpoint
kist --list                         # list resumable checkpoints (id, title, iter/max, status)
kist --project <path>               # set project root (default: cwd)
kist --provider <id> --model <id>   # pick AgentCore provider/model (default: env/config)
kist --yes                          # auto-approve plans (non-interactive one-shot)
kist --max-iterations N
```

### 4b. Wiring

```swift
// Sources/Kist/main.swift
let opts = KistOptions.parse(CommandLine.arguments)               // tiny hand-rolled parser; no extra deps
let registry = ProviderRegistry()                                  // AgentCore: ProviderCatalog.all + DefaultKeyStore
let sink: RuntimeEventSink = TerminalEventSink()
let interactor: RuntimeInteractor = opts.oneShot
    ? AutoApprove()                                                // --yes / one-shot: approve, no prompts
    : TerminalInteractor()                                         // REPL: readLine() prompts
let tools = ToolRegistry()                                         // headless default tool set (see §5 note)
let checkpoints = CheckpointStore(directory: opts.checkpointDir)

let runtime = UnifiedAgentRuntime(
    sink: sink, interactor: interactor,
    providers: registry, providerId: opts.providerId, model: opts.model,
    tools: tools, checkpoints: checkpoints
)
runtime.projectPath = opts.project ?? FileManager.default.currentDirectoryPath
runtime.maxIterations = opts.maxIterations
runtime.oneShotMode = opts.oneShot

switch opts.mode {
case .oneShot(let msg): _ = await runtime.process(msg)
case .resume(let id):   _ = await runtime.resume(checkpointId: id)
case .resumeLast:       if let c = checkpoints.resumable().first { _ = await runtime.resume(checkpointId: c.id) }
case .list:             checkpoints.resumable().forEach { print("\($0.id)  \($0.title)  \($0.iterationCount)/\($0.maxIterations)  \($0.status.rawValue)") }
case .repl:             await KistREPL(runtime: runtime, sink: sink, checkpoints: checkpoints).run()
}
```

**One-shot vs REPL:** one-shot = single `process()` call, stream to stdout, exit code 0 on
`.completed` / 1 on `.failed`. REPL = the existing `AgentCLI.run()` loop (banner, `help/tools/
status/history`, `/project`, `/model`), but rebuilt on `UnifiedAgentRuntime` + the event sink
instead of `AgentLoopEngine` + polling `@Published` state. The current `AgentCLI` is a useful
template (commands, colors) but is `@MainActor` and polls engine state — Kist's REPL should consume
events, not poll.

**Keys:** AgentCore's `DefaultKeyStore` already resolves keychain/env. Kist gets keys from the same
keychain the GUI uses (shared machine) OR from env vars — no GUI dependency.

---

## 5. Migration steps (ordered, low-risk; GUI stays green the whole way)

The strategy: **introduce the seam first, adapt the GUI to it, THEN delete the GUI coupling.**
The `@MainActor` removal is the one HIGH-risk step; it's de-risked by doing it last, behind a
green GUI adapter, with the runtime already event-driven.

**Step 0 — Move the headless-ready files into an AgentCore module.** (LOW)
Create `AgentRuntime` target in `Package.swift` (or a folder in AgentCore). Move the *already
neutral* files (`AgentCheckpoint`, `CheckpointStore`, `JSONDirectoryStore`,
`OrchestrationCheckpoint`, `ReplanEngine`, `AgentPrompts`, `ExecutionPlan`, `AgentTool`/
`ToolRegistry`, `AgentTools` sans the one `@MainActor` helper). Keep the Xcode target compiling by
referencing the moved files (Xcode can include SPM-package files, or keep them dual-listed during
transition). **No behavior change.** Build both. *Effort: 0.5–1 day.*

**Step 1 — Define the seam (additive, nothing consumes it yet).** (LOW)
Add `RuntimeEvent`, `RuntimeEventSink`, `RuntimeInteractor`, `RuntimeState` to AgentCore.
Add `GUIEventSink` (re-publishes onto an ObservableObject) in the app. *Effort: 0.5 day.*

**Step 2 — Swap the provider layer inside the runtime.** (MED — behavior-sensitive)
Replace `ProviderManager.shared.currentProvider` / `AIProvider.sendMessage` calls in
`UnifiedAgentRuntime` + `+Resume` + `ReplanEngine` call site with AgentCore's
`ProviderRegistry.stream(...)`/`ChatProvider`. Inject `providers/providerId/model`. The GUI passes a
registry built from its current selection. Pin behavior with a test: same messages → same parsed
action. *Effort: 1–2 days.* **Multi-site: every LLM call site (`callLLMForNextAction`,
`callLLMForStructuredPlan`, replan) gets a per-site assertion.**

**Step 3 — Route ALL emission through the sink (runtime still `@MainActor`).** (MED)
Replace every `postUpdate { self.<published> = ... }` in `UnifiedAgentRuntime` and `+Resume` with
`sink.emit(...)`. Keep the class `@MainActor` for now; `GUIEventSink` writes the same `@Published`
vars the GUI already binds to, so the GUI is byte-for-byte unchanged in behavior. Replace
approval/`pendingQuestion`/`lastCheckpointError` surfacing with `interactor` + events. **At the end
of this step the loop no longer mutates its own published state — but still compiles in the app.**
*Effort: 2–3 days* (this is where the 87 mutation sites get touched; do it under a test that
asserts the event stream for a scripted run).

**Step 4 — Remove `@MainActor` / `ObservableObject` / `@Published` from the runtime.** (HIGH RISK)
Now that nothing inside the loop reads/writes published state and the GUI consumes events via the
adapter, drop `@MainActor`, `ObservableObject`, `@Published`, `import Combine`, and `postUpdate`.
**De-risk:** (a) the GUI keeps working because `GUIEventSink` is the only thing touching the main
actor now; (b) make the runtime an `actor` OR a plain `final class` confined to a single task — it
already enforces single-flight via `isProcessing`, so a plain class on one task is sufficient and
simplest; (c) audit `executeAction`/`executeWithRuntime` (the one `@MainActor` tool helper) and
`AgentRuntimeService` for residual main-actor assumptions — those are shell/FS ops, safe to make
`nonisolated`. Compile the **app** after this step; run the full test target. *Effort: 2–3 days +
buffer.* This is the step that can ripple; budget a fix day.

**Step 5 — Build the Kist executable target.** (MED)
`Sources/Kist/` with `main.swift`, `KistOptions` parser, `TerminalEventSink`,
`TerminalInteractor`/`AutoApprove`, and the REPL (port command surface from `AgentCLI.swift`).
Wire to the now-headless `UnifiedAgentRuntime` + AgentCore `ProviderRegistry`. *Effort: 2–3 days.*

**Step 6 — Headless tool set audit.** (MED, can parallelize with 5)
`ToolRegistry` registers desktop/GUI-flavored tools (`WindowManagementTool`, `InputControlTool`,
`PlaywrightCaptureTool`, `ScreenCapture`-adjacent). For Kist, register a **headless default set**
(file ops, build, run-command, git, search, web) and make GUI/desktop tools opt-in or no-op on a
headless host. Don't move GUI tools into AgentCore. *Effort: 1–2 days.*

**Step 7 — `AgentLoopEngine` (multi-agent) headless port.** (HIGH, DEFERRABLE)
Same treatment as the runtime. **Kist v1 can ship single-runtime** (`UnifiedAgentRuntime` only) and
defer multi-agent. Flag as a fast-follow. *Effort: 3–5 days when needed.*

**Verification each step:** `xcodebuild ... build` (app stays green) + run `FloatingChatAppTests`,
and from Step 5, `swift build`/`swift test` for the Kist/AgentCore SPM side. Codex review gate
before "done."

### Effort summary

| Step | Risk | Effort |
|---|---|---|
| 0 Move neutral files to AgentCore module | LOW | 0.5–1 d |
| 1 Define event-sink seam | LOW | 0.5 d |
| 2 Swap runtime → AgentCore providers | MED | 1–2 d |
| 3 Route emission through sink (still @MainActor) | MED | 2–3 d |
| 4 **Remove @MainActor/ObservableObject** | **HIGH** | 2–3 d + buffer |
| 5 Build Kist executable (one-shot + REPL) | MED | 2–3 d |
| 6 Headless tool-set audit | MED | 1–2 d |
| 7 AgentLoopEngine multi-agent (deferrable) | HIGH | 3–5 d (later) |
| **Total to a working single-runtime Kist (0–6)** | | **~9–14 days** |

---

## 6. Biggest risk

**Step 4 — removing `@MainActor` from `UnifiedAgentRuntime`.** It's a 1452-LOC RED-zone monolith
with ~87 state mutations and is reached by GUI bindings, the resume path, and tool execution. Pull
the actor isolation before the loop is fully event-driven and you get a cascade of Sendable/actor-
hop errors and silent UI races. **De-risk by ordering:** make it event-driven and provider-injected
FIRST (steps 2–3) while it's still `@MainActor` and the GUI is green via the adapter; only then drop
the isolation (step 4), keeping the GUI working because `GUIEventSink` is the sole main-actor
consumer. Pin a scripted-run event-stream test before step 3 so any regression in what the loop
emits is caught immediately.
