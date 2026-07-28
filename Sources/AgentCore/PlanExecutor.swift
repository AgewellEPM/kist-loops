import Foundation

/// Result of running one plan step.
public struct StepResult: Sendable, Equatable {
    public let stepId: String
    public let tool: String
    public let success: Bool
    public let output: String        // success output, or the error text (bounded)
    public let error: String?
}

/// Result of running a whole plan: per-step results, the captured outputs (id → text) usable for
/// `${id}` references, and the first failing step id (nil on full success).
public struct PlanExecution: Sendable, Equatable {
    public let success: Bool
    public let stepResults: [StepResult]      // in execution order
    public let outputs: [String: String]      // id → output text
    public let failedStepId: String?

    /// A compact transcript of what ran — fed to the replan/verify nodes (next increment).
    public var summary: String {
        stepResults.map { "\($0.stepId) \($0.tool): \($0.success ? "ok" : "FAILED")" }.joined(separator: "\n")
    }
}

/// Runs an `ExecutablePlan` to completion: dependency waves, `${id}` reference resolution from
/// earlier outputs, output capture, stop-on-first-failure for downstream work. Independent ready
/// steps run concurrently; each wave is reported in stable topological order so transcripts remain
/// deterministic even though the actual work overlaps.
public struct PlanExecutor: Sendable {
    private let tools: ToolRegistry
    private let context: ToolContext
    private let sink: RuntimeEventSink
    private let maxOutputBytes: Int
    /// Approval hook for `.dangerous` steps. The DAG must not be an approval bypass: a plan step
    /// that classifies dangerous (unconfined MCP mutation, escaping write, run_command) is gated
    /// here just like the main loop. nil ⇒ autonomous/no-gate (fleet, sandboxed by design).
    private let approveDangerous: (@Sendable (String, [String: Any]) async -> Bool)?

    public init(tools: ToolRegistry, context: ToolContext,
                sink: RuntimeEventSink = NullEventSink(), maxOutputBytes: Int = 8_000,
                approveDangerous: (@Sendable (String, [String: Any]) async -> Bool)? = nil) {
        self.tools = tools; self.context = context; self.sink = sink
        self.maxOutputBytes = maxOutputBytes; self.approveDangerous = approveDangerous
    }

    public func execute(_ plan: ExecutablePlan) async -> PlanExecution {
        // A plan must be valid before it runs; an invalid plan fails fast with no side effects.
        let ordered: [PlanStep]
        do { ordered = try plan.orderedSteps() }
        catch {
            sink.emit(.failed("plan invalid: \(error)"))
            return PlanExecution(success: false, stepResults: [], outputs: [:], failedStepId: nil)
        }

        var outputs: [String: String] = [:]
        var results: [StepResult] = []
        var completed = Set<String>()
        var remaining = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        let orderIndex = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
        sink.emit(.stateChanged(.executing))

        while !remaining.isEmpty {
            // R1: ESC stops the DAG at the next WAVE boundary. Task cancellation propagates to the
            // current wave's children: cancellation-OBLIVIOUS tools (run_command's blocking runner)
            // finish; cancellation-AWARE tools (URLSession fetch/search, generate) abort and land
            // as failed StepResults — partial side effects are possible mid-tool. No new wave
            // launches. Completed step results are preserved.
            if Task.isCancelled {
                sink.emit(.cancelled)
                return PlanExecution(success: false, stepResults: results, outputs: outputs, failedStepId: nil)
            }
            let ready = ordered.filter { step in
                remaining[step.id] != nil && plan.effectiveDependencies(of: step).isSubset(of: completed)
            }
            guard !ready.isEmpty else {
                sink.emit(.failed("plan invalid: no executable DAG frontier"))
                return PlanExecution(success: false, stepResults: results, outputs: outputs, failedStepId: nil)
            }

            let outputSnapshot = outputs
            let waveResults = await withTaskGroup(of: (Int, String, String, StepResult).self) { group in
                // Declined-at-gate steps never enter the parallel group; they're merged in as failures.
                var preempted: [(Int, String, String, StepResult)] = []
                for step in ready {
                    let idx = (orderIndex[step.id] ?? 0) + 1
                    let args = ExecutablePlan.resolveArguments(step.argumentsJSON, outputs: outputSnapshot)
                    // GATE: a dangerous step (unconfined MCP mutation, escaping write, run_command)
                    // is approved SERIALLY before launch — the DAG can't be an approval bypass.
                    if let approve = approveDangerous,
                       ReversibilityClassifier.assess(tool: step.tool, args: args, projectRoot: context.projectRoot) == .dangerous,
                       await approve(step.tool, args) == false {
                        let sr = StepResult(stepId: step.id, tool: step.tool, success: false,
                                            output: "", error: "declined at approval gate (dangerous step)")
                        sink.emit(.actionStarted(index: idx, tool: step.tool, description: step.intent))
                        sink.emit(.actionFinished(index: idx, success: false, output: "", error: sr.error))
                        preempted.append((idx, step.id, "", sr))
                        continue
                    }
                    sink.emit(.actionStarted(index: idx, tool: step.tool, description: step.intent))
                    group.addTask {
                        let result = await tools.execute(name: step.tool, arguments: args, context: context)
                        let body = String((result.success ? result.output : (result.error ?? result.output)).prefix(maxOutputBytes))
                        return (idx, step.id, body, StepResult(stepId: step.id, tool: step.tool,
                                                              success: result.success, output: body, error: result.error))
                    }
                }

                var wave: [(Int, String, String, StepResult)] = preempted
                for await item in group { wave.append(item) }
                return wave.sorted { $0.0 < $1.0 }
            }

            for (idx, stepId, body, stepResult) in waveResults {
                sink.emit(.actionFinished(index: idx, success: stepResult.success,
                                          output: stepResult.success ? body : "", error: stepResult.error))
                outputs[stepId] = body
                results.append(stepResult)
                completed.insert(stepId)
                remaining.removeValue(forKey: stepId)
            }

            if let failed = waveResults.first(where: { !$0.3.success })?.3.stepId {
                // Same-wave siblings may already have completed; no downstream work runs.
                return PlanExecution(success: false, stepResults: results, outputs: outputs, failedStepId: failed)
            }
        }
        return PlanExecution(success: true, stepResults: results, outputs: outputs, failedStepId: nil)
    }
}
