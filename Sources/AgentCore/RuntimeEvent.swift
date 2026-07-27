import Foundation

/// The headless seam between the agent loop and whatever drives it (GUI, terminal, MCP,
/// remote). The loop EMITS `RuntimeEvent`s and never touches UI state; each host adapts the
/// events it cares about. This mirrors AgentCore's existing `StreamEvent` sum type: `Sendable`
/// (crosses the loop's task/actor boundary), trivially serializable (for a future remote /
/// mcp-server driver), and `default:`-ignorable by consumers.
///
/// Replaces the GUI-coupled pattern where the runtime was an `@MainActor ObservableObject`
/// mutating `@Published` vars — those vars were only a *projection* of the loop's real state
/// (`AgentCheckpoint`), which each host now derives from events instead.
public enum RuntimeEvent: Sendable {
    /// Coarse lifecycle state (idle/analyzing/planning/executing/...).
    case stateChanged(RuntimeState)
    /// Resolved user intent + the loop's confidence in it.
    case intentResolved(intent: String, confidence: Double)
    /// A plan is ready (summary + number of steps) — may precede an approval gate.
    case planReady(summary: String, stepCount: Int)
    /// A streamed chunk of assistant text (token stream).
    case tokenDelta(String)
    /// Token usage observed for one model call. `estimated` is true when the provider omitted usage and
    /// the loop fell back to its explicit prompt/completion character estimate.
    case usage(promptTokens: Int, completionTokens: Int, estimated: Bool)
    /// A streamed chunk of hidden reasoning (display-dimmed; never re-injected verbatim).
    case reasoningDelta(String)
    /// An action/tool began executing.
    case actionStarted(index: Int, tool: String?, description: String)
    /// An action/tool finished (success + captured output + optional error).
    case actionFinished(index: Int, success: Bool, output: String, error: String?)
    /// Live re-plan triggered after repeated failure.
    case replanStarted(reason: String)
    /// Older context was summarized (compacted) to survive a long run — `omitted` = messages folded.
    case contextCompacted(omitted: Int)
    /// A checkpoint was durably written (id + iteration) — enables resume.
    case checkpointSaved(id: String, iteration: Int)
    /// A checkpoint write FAILED — surfaces lost durability (was `lastCheckpointError`).
    case checkpointFailed(String)
    /// The loop is blocked awaiting plan approval (host calls `RuntimeInteractor.requestApproval`).
    case awaitingApproval(planSummary: String)
    /// The loop is blocked awaiting a human answer (host calls `RuntimeInteractor.requestInput`).
    case awaitingInput(question: String)
    /// The run completed successfully (final summary).
    case completed(summary: String)
    /// The run failed (reason).
    case failed(String)
    /// The run was cancelled (e.g. SIGINT / user interrupt).
    case cancelled
}

/// Coarse lifecycle state a host can render (status line, spinner, etc.). The full,
/// serializable run state remains `AgentCheckpoint`; this is the projection hosts bind to.
public enum RuntimeState: String, Sendable, CaseIterable {
    case idle, analyzing, planning, executing, completed, failed, cancelled
}

/// The loop emits to this. `Sendable` so it can be held across the loop's task boundary and
/// called from any isolation. Implementations must be safe to call concurrently.
public protocol RuntimeEventSink: Sendable {
    func emit(_ event: RuntimeEvent)
}

/// Two-way control the loop needs FROM the host: plan approval and interactive answers.
/// A non-interactive one-shot supplies an auto-approver; a TUI/GUI prompts the human.
public protocol RuntimeInteractor: Sendable {
    /// Return true to approve the plan and continue, false to abort.
    func requestApproval(planSummary: String) async -> Bool
    /// Return the human's answer to a mid-run question.
    func requestInput(question: String) async -> String
    /// Approve an action whose REVERSIBILITY is known. A `dangerous` (irreversible/high-blast-radius)
    /// action should be confirmed EVEN past a session "allow all". Default ignores `dangerous` and falls
    /// back to the basic approval, so existing conformers (auto-approvers, TUI, tests) need no change.
    func requestApproval(planSummary: String, dangerous: Bool) async -> Bool
}

public extension RuntimeInteractor {
    func requestApproval(planSummary: String, dangerous: Bool) async -> Bool {
        await requestApproval(planSummary: planSummary)
    }
}

// MARK: - Built-in headless interactors

/// Approves every plan and answers every question with empty string — for `--yes` / one-shot
/// non-interactive runs (CI, scripts). Stateless and `Sendable`.
public struct AutoApproveInteractor: RuntimeInteractor {
    public init() {}
    public func requestApproval(planSummary: String) async -> Bool { true }
    public func requestInput(question: String) async -> String { "" }
}

/// Auto-approves normal tools but DENIES any action flagged `dangerous` (irreversible / high-blast-radius,
/// per ReversibilityClassifier — rm -rf, force-push, deploy, …). This is how an UNATTENDED long run
/// (`--loop` without `--yolo`) enforces `noDestructive`: build/test/edit still run, but irreversible ops
/// are refused rather than silently executed. Stateless + Sendable.
public struct NonDestructiveInteractor: RuntimeInteractor {
    public init() {}
    public func requestApproval(planSummary: String) async -> Bool { true }
    public func requestApproval(planSummary: String, dangerous: Bool) async -> Bool { !dangerous }
    public func requestInput(question: String) async -> String { "" }
}

/// Drops every event. Useful as a default when a host only needs the return value of a run,
/// or in tests that assert on the run result rather than the event stream.
public struct NullEventSink: RuntimeEventSink {
    public init() {}
    public func emit(_ event: RuntimeEvent) {}
}

/// Thread-safe event recorder for tests: assert the exact event stream a scripted run emits
/// (the regression backstop the migration spec calls for before routing emission through the
/// sink). Lock-guarded so the loop can emit from any task.
public final class RecordingEventSink: RuntimeEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [RuntimeEvent] = []
    public init() {}
    public func emit(_ event: RuntimeEvent) { lock.lock(); _events.append(event); lock.unlock() }
    public var events: [RuntimeEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    public var states: [RuntimeState] {
        events.compactMap { if case let .stateChanged(s) = $0 { return s } else { return nil } }
    }
}
