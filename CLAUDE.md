# FloatingChatApp — Project Context (CLAUDE.md)

## What this is
A macOS SwiftUI floating-chat agent app — a Claude-Code-style autonomous coding/desktop agent.
Goal of current work: make it behave like a **full open-source agent-orchestration runtime**
(plan → act → observe → self-correct → re-plan → persist/resume → multi-provider).

## Build / run
- **Build system:** Xcode project (NO SPM). `FloatingChatApp.xcodeproj`, target+scheme `FloatingChatApp`.
- **Bundle id:** `com.floatingchat.app`.
- **Compile check:** `xcodebuild -project FloatingChatApp.xcodeproj -scheme FloatingChatApp -configuration Debug build`
- **Tests:** target `FloatingChatAppTests` (`xcodebuild test ...`).
- **Adding source files:** classic Xcode groups — new `.swift` files MUST be added to the target.
  The `xcodeproj` ruby gem is installed; use a ruby script (see `Tools/`, `add_*.rb` in root for the pattern).
  A new file on disk that isn't in `project.pbxproj` will NOT compile into the app.

## Architecture (agent runtime)
- `Sources/Services/AgentLoop/UnifiedAgentRuntime.swift` — **the core loop.** ⚠️ MONOLITH (1452 LOC, RED zone).
  Mixes orchestration + action dispatch + parsing + recovery + state + UI binding. Do NOT grow it;
  extract into sibling files / extensions. New runtime logic goes in its own file.
- `Sources/Services/AgentLoop/AgentLoopEngine.swift` — multi-agent loop + sub-agent orchestration (sequential/parallel/collaborative/debate).
- `Sources/Services/AgentLoop/AgentOrchestrator.swift` — orchestration modes + `ExecutionState`.
- `Sources/Models/ExecutionPlan.swift` — plan/step/action/result models + `AnyCodableValue` + `ExecutionPlanBuilder`.
- `Sources/Services/AgentRuntimeService.swift` — auto-build, error parsing, retry prompt, project-state persistence.
- `Sources/Services/Providers/*` + `AIProvider.swift` + `ProviderManager.swift` — pluggable provider protocol (6 providers).
- `Sources/Services/Reflection/*` — POST-HOC reflection only (writes lessons for future sessions; NOT live re-plan).
- `Sources/Services/ConversationStore.swift` — saves conversation + agents (NOT execution cursor).

## Known gaps being closed (this work)
1. **True mid-loop resume** — the iterative loop's `conversationHistory`/`iterationCount` are LOCAL vars in
   `process()` → die on return/crash. New: `AgentCheckpoint` (Codable) + `CheckpointStore`, checkpoint after
   every iteration, `resume(from:)` entry point.
2. **Live re-plan on failure** — nothing rebuilds a failing plan mid-run. New: `ReplanEngine`.

## Serialization rules (important)
- `ExecutableAction.parameters` is `[String: Any]` → NOT Codable. Round-trip via `AnyCodableValue`
  (`.value` gives `[String:Any]`; use the `AnyCodableValue(any:)` init to go the other way).
- `ExecutionPlan`/`PlanStep`/`ExecutableAction`/`ActionExecutionResult` are NOT Codable — mirror them with
  Codable DTOs in `AgentCheckpoint.swift`; do not bolt Codable onto the live models.

## Rules of the road (inherits global CLAUDE.md)
- Files ≤1000 lines target; UnifiedAgentRuntime is already RED — split, don't pile on.
- Commit each tested increment to its own branch. Work branch: `feat/runtime-orchestration`.
- Label deliverables honestly (PROTOTYPE / PILOT-READY / PRODUCTION-READY).
- This is a real product, not a demo: build foundation-to-ship, verify with `xcodebuild`.
- Codex review gate before declaring done.
