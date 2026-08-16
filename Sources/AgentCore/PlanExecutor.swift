import Foundation
import CryptoKit

/// Secret-safe facts captured while the executor still owns the exact resolved arguments. The outer
/// PlanExecute loop later binds these facts to its immutable contract and durable ordering envelope.
public struct PlanCommandExecutionCapture: Sendable, Equatable, Codable {
    public let executable: String
    public let argv: [String]
    public let workingDirectory: String?
    public let hasStandardInput: Bool
    public let standardInputDigest: String?
    public let standardInputByteCount: Int
    public var standardInputSourceKind: PlanStandardInputSourceKind = .none
    public var standardInputRelativePath: String? = nil
    public let allowedExitCodes: [Int]
    public let actualExitCode: Int
    public let wasSignalled: Bool
    public let timedOut: Bool
    public let semanticStatus: String
    public let verificationEligible: Bool
    public let success: Bool
    public let argsFingerprint: String
    public let commandFingerprint: String
    public let outputDigest: String
    public var trustedCommandReference: BuilderTrustedCommandReference? = nil
    public let boundedRedactedOutputExcerpt: String
    public let effectObservation: ToolEffectObservation
    public let executionPhase: Int?
    public let completedAt: Date
    public let governedWorkspaceDigest: String
}

/// Result of running one plan step.
public struct StepResult: Sendable, Equatable {
    public let stepId: String
    public let tool: String
    public let success: Bool
    public let output: String        // success output, or the error text (bounded)
    public let error: String?
    /// Post-call evidence (for example `changed=true`) needed to distinguish attempted from actual work.
    public var metadata: [String: String] = [:]
    /// Effect of the arguments that ACTUALLY produced this final result. A repaired retry can run
    /// different arguments from the frozen plan, so verification must not reclassify the original step.
    public var effectObservation: ToolEffectObservation? = nil
    /// The user said no at the approval gate — a structured flag, not an error-string sniff.
    /// Declined steps are never self-repaired (the decline was a decision, not a malfunction).
    public var declinedAtGate: Bool = false
    /// Executor phase in which this invocation ran. All initial calls in one dependency wave share a
    /// phase because they overlap; every repaired retry gets a later phase. nil preserves the legacy
    /// meaning for manually-constructed StepResults: declaration order is sequential evidence.
    public var executionPhase: Int? = nil
    /// Fingerprint of the arguments THIS invocation actually ran. Repairs can change arguments, so the
    /// frozen plan template is only a compatibility fallback for old/manual results.
    public var argsFingerprint: String? = nil
    public var commandExecutionCapture: PlanCommandExecutionCapture? = nil
    public var supportingCommandReceipt: PlanSupportingCommandReceipt? = nil
    /// Host-coordinated workspace transition for this exact invocation. PlanExecute persists this
    /// atomically with the node receipt; ordinary standalone PlanExecutor users leave it nil.
    public var workspaceActionReceipt: DurableWorkspaceActionCompletionReceipt? = nil

    public init(stepId: String, tool: String, success: Bool, output: String, error: String?,
                metadata: [String: String] = [:], effectObservation: ToolEffectObservation? = nil,
                declinedAtGate: Bool = false, executionPhase: Int? = nil,
                argsFingerprint: String? = nil) {
        self.stepId = stepId; self.tool = tool; self.success = success; self.output = output
        self.error = error; self.metadata = metadata; self.effectObservation = effectObservation
        self.declinedAtGate = declinedAtGate; self.executionPhase = executionPhase
        self.argsFingerprint = argsFingerprint
    }
}

public struct PlanCoordinatedActionResult: Sendable {
    public let toolResult: ToolResult
    public let workspaceReceipt: DurableWorkspaceActionCompletionReceipt?

    public init(toolResult: ToolResult,
                workspaceReceipt: DurableWorkspaceActionCompletionReceipt? = nil) {
        self.toolResult = toolResult
        self.workspaceReceipt = workspaceReceipt
    }
}

public typealias PlanActionCoordinator = @Sendable (
    _ step: PlanStep,
    _ resolvedArguments: [String: Any],
    _ executionPhase: Int,
    _ invoke: @escaping @Sendable () async -> ToolResult
) async -> PlanCoordinatedActionResult

/// Result of running a whole plan: per-step results, the captured outputs (id → text) usable for
/// `${id}` references, and the first failing step id (nil on full success).
public struct PlanExecution: Sendable, Equatable {
    public let success: Bool
    public let stepResults: [StepResult]      // final state per step, in stable plan order
    /// Append-only invocation ledger. Unlike `stepResults`, this retains a failed initial attempt when a
    /// repaired retry replaces that step's final state. Plan verification consumes this ledger.
    public let attemptResults: [StepResult]
    public let outputs: [String: String]      // id → output text
    public let failedStepId: String?

    /// `attemptResults` defaults to the legacy final rows so existing/manual PlanExecution values retain
    /// their old sequential verification behavior. The executor always supplies its richer ledger.
    public init(success: Bool, stepResults: [StepResult], attemptResults: [StepResult]? = nil,
                outputs: [String: String], failedStepId: String?) {
        self.success = success
        self.stepResults = stepResults
        self.attemptResults = attemptResults ?? stepResults
        self.outputs = outputs
        self.failedStepId = failedStepId
    }

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
    /// R3: per-step self-repair. When a step fails, ask for corrected arguments and retry ONCE —
    /// the failure stays micro-task-sized instead of failing the wave and replanning the whole
    /// mission. The middle parameter is the RESOLVED arguments the step actually ran with
    /// (`${id}` references substituted) — the repairer must diagnose what executed, not the
    /// template. nil ⇒ no repair (old behavior). Bounded to `maxStepRepairs` per plan run.
    private let repairStep: (@Sendable (PlanStep, [String: Any], StepResult) async -> [String: Any]?)?
    private let coordinateAction: PlanActionCoordinator?
    private static let maxStepRepairs = 3

    public init(tools: ToolRegistry, context: ToolContext,
                sink: RuntimeEventSink = NullEventSink(), maxOutputBytes: Int = 8_000,
                approveDangerous: (@Sendable (String, [String: Any]) async -> Bool)? = nil,
                repairStep: (@Sendable (PlanStep, [String: Any], StepResult) async -> [String: Any]?)? = nil,
                coordinateAction: PlanActionCoordinator? = nil) {
        self.tools = tools; self.context = context; self.sink = sink
        self.maxOutputBytes = maxOutputBytes; self.approveDangerous = approveDangerous
        self.repairStep = repairStep
        self.coordinateAction = coordinateAction
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
        var attempts: [StepResult] = []
        var completed = Set<String>()
        var remaining = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        let orderIndex = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
        var wave = 0
        var stepRepairsUsed = 0
        sink.emit(.stateChanged(.executing))

        while !remaining.isEmpty {
            // R1: ESC stops the DAG at the next WAVE boundary. Task cancellation propagates to the
            // current wave's children: cancellation-OBLIVIOUS tools (run_command's blocking runner)
            // finish; cancellation-AWARE tools (URLSession fetch/search, generate) abort and land
            // as failed StepResults — partial side effects are possible mid-tool. No new wave
            // launches. Completed step results are preserved.
            if Task.isCancelled {
                sink.emit(.cancelled)
                return PlanExecution(success: false, stepResults: results, attemptResults: attempts,
                                     outputs: outputs, failedStepId: nil)
            }
            let ready = ordered.filter { step in
                remaining[step.id] != nil && plan.effectiveDependencies(of: step).isSubset(of: completed)
            }
            guard !ready.isEmpty else {
                sink.emit(.failed("plan invalid: no executable DAG frontier"))
                return PlanExecution(success: false, stepResults: results, attemptResults: attempts,
                                     outputs: outputs, failedStepId: nil)
            }
            wave += 1
            sink.emit(.stepWave(wave: wave, stepIds: ready.map(\.id)))   // R3: mission-slice marker
            // Phase is causal, not cosmetic: every call in this wave overlaps and therefore none of its
            // verifiers can prove a sibling mutation. Repairs below advance it before they execute.
            var executionPhase = attempts.compactMap(\.executionPhase).max().map { $0 + 1 } ?? 1
            let wavePhase = executionPhase

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
                                            output: "", error: "declined at approval gate (dangerous step)",
                                            effectObservation: ToolEffectObservation.none,
                                            declinedAtGate: true,
                                            executionPhase: wavePhase,
                                            argsFingerprint: Self.fingerprint(tool: step.tool, arguments: args))
                        // Emitted INLINE (immediate feedback at the prompt); the merge loop skips
                        // declined entries so one decline never prints two ✗ lines.
                        sink.emit(.actionStarted(index: idx, tool: step.tool, description: step.intent))
                        sink.emit(.actionFinished(index: idx, success: false, output: "", error: sr.error))
                        preempted.append((idx, step.id, "", sr))
                        continue
                    }
                    sink.emit(.actionStarted(index: idx, tool: step.tool, description: step.intent))
                    group.addTask {
                        let coordinated = await coordinateAction?(step, args, wavePhase) {
                            await tools.execute(name: step.tool, arguments: args, context: context)
                        }
                        let result: ToolResult
                        if let coordinated {
                            result = coordinated.toolResult
                        } else {
                            result = await tools.execute(
                                name: step.tool, arguments: args, context: context)
                        }
                        let body = String((result.success ? result.output : (result.error ?? result.output)).prefix(maxOutputBytes))
                        let effect = ToolEffectCatalog.observe(tool: step.tool, arguments: args,
                                                               outcomeMetadata: result.metadata)
                        let fingerprint = Self.fingerprint(tool: step.tool, arguments: args)
                        var stepResult = StepResult(stepId: step.id, tool: step.tool,
                                                    success: result.success, output: body, error: result.error,
                                                    metadata: result.metadata,
                                                    effectObservation: effect,
                                                    executionPhase: wavePhase,
                                                    argsFingerprint: fingerprint)
                        stepResult.commandExecutionCapture = Self.commandCapture(
                            step: step, arguments: args, result: result, effect: effect,
                            executionPhase: wavePhase, argsFingerprint: fingerprint,
                            projectRoot: context.projectRoot)
                        stepResult.workspaceActionReceipt = coordinated?.workspaceReceipt
                        return (idx, step.id, body, stepResult)
                    }
                }

                var wave: [(Int, String, String, StepResult)] = preempted
                for await item in group { wave.append(item) }
                return wave.sorted { $0.0 < $1.0 }
            }

            for (idx, stepId, body, stepResult) in waveResults {
                if !stepResult.declinedAtGate {   // declined steps already emitted inline at the gate
                    sink.emit(.actionFinished(index: idx, success: stepResult.success,
                                              output: stepResult.success ? body : "", error: stepResult.error))
                }
                outputs[stepId] = body
                results.append(stepResult)
                attempts.append(stepResult)
                completed.insert(stepId)
                remaining.removeValue(forKey: stepId)
            }

            // R3: FAILURES STAY SMALL — a failed step gets ONE corrected-arguments retry before it
            // can fail the mission (never for gate-declined steps: the user said no). Bounded per
            // plan run so a hopeless step can't loop the repairer.
            for (_, stepId, _, stepResult) in waveResults where !stepResult.success {
                guard coordinateAction == nil,
                      let repairStep, stepRepairsUsed < Self.maxStepRepairs,
                      !stepResult.declinedAtGate,
                      !Task.isCancelled,
                      let step = ordered.first(where: { $0.id == stepId }) else { continue }
                stepRepairsUsed += 1
                // The repairer diagnoses the RESOLVED args that actually ran (same pre-wave
                // snapshot the launch used), not the ${id} template.
                let ranArgs = ExecutablePlan.resolveArguments(step.argumentsJSON, outputs: outputSnapshot)
                guard let fixedArgs = await repairStep(step, ranArgs, stepResult) else { continue }
                if Task.isCancelled { continue }   // ESC landed during the repair model call
                let idx = (orderIndex[stepId] ?? 0) + 1
                sink.emit(.actionStarted(index: idx, tool: step.tool, description: "retry (repaired args): \(step.intent)"))
                // GATE: the retry runs MODEL-invented arguments — it must clear the same approval
                // gate as the launch, re-classified on the NEW args (repair can change danger).
                if let approve = approveDangerous,
                   ReversibilityClassifier.assess(tool: step.tool, args: fixedArgs, projectRoot: context.projectRoot) == .dangerous,
                   await approve(step.tool, fixedArgs) == false {
                    sink.emit(.actionFinished(index: idx, success: false, output: "",
                                              error: "retry declined at approval gate (dangerous step)"))
                    continue
                }
                let retry = await tools.execute(name: step.tool, arguments: fixedArgs, context: context)
                let body = String((retry.success ? retry.output : (retry.error ?? retry.output)).prefix(maxOutputBytes))
                let retryEffect = ToolEffectCatalog.observe(tool: step.tool, arguments: fixedArgs,
                                                            outcomeMetadata: retry.metadata)
                executionPhase += 1
                var retryResult = retry.success
                    ? StepResult(stepId: stepId, tool: step.tool, success: true, output: body, error: nil,
                                 metadata: retry.metadata, effectObservation: retryEffect,
                                 executionPhase: executionPhase,
                                 argsFingerprint: Self.fingerprint(tool: step.tool, arguments: fixedArgs))
                    : StepResult(stepId: stepId, tool: step.tool, success: false, output: body,
                                 error: "repaired-args retry also failed: \(retry.error ?? body)",
                                 metadata: retry.metadata, effectObservation: retryEffect,
                                 executionPhase: executionPhase,
                                 argsFingerprint: Self.fingerprint(tool: step.tool, arguments: fixedArgs))
                retryResult.commandExecutionCapture = Self.commandCapture(
                    step: step, arguments: fixedArgs, result: retry, effect: retryEffect,
                    executionPhase: executionPhase,
                    argsFingerprint: Self.fingerprint(tool: step.tool, arguments: fixedArgs),
                    projectRoot: context.projectRoot)
                sink.emit(.actionFinished(index: idx, success: retry.success,
                                          output: retry.success ? body : "", error: retry.error))
                attempts.append(retryResult)
                if let i = results.lastIndex(where: { $0.stepId == stepId }) {
                    // Record the retry's FINAL state either way — a stale original error would
                    // misdirect the replan prompt and hide that a repair was attempted.
                    outputs[stepId] = body
                    results[i] = retryResult
                }
            }

            if let failed = results.first(where: { !$0.success })?.stepId {
                // Same-wave siblings may already have completed; no downstream work runs.
                return PlanExecution(success: false, stepResults: results, attemptResults: attempts,
                                     outputs: outputs, failedStepId: failed)
            }
        }
        return PlanExecution(success: true, stepResults: results, attemptResults: attempts,
                             outputs: outputs, failedStepId: nil)
    }

    private static func fingerprint(tool: String, arguments: [String: Any]) -> String {
        tool == "run_command"
            ? ToolEffectCatalog.commandFingerprint(arguments)
            : TrajectoryAnalyzer.fingerprint(arguments)
    }

    private static func commandCapture(
        step: PlanStep, arguments: [String: Any], result: ToolResult,
        effect: ToolEffectObservation, executionPhase: Int?, argsFingerprint: String,
        projectRoot: String
    ) -> PlanCommandExecutionCapture? {
        guard step.tool == "run_command", result.success,
              let executable = arguments["executable"] as? String, !executable.isEmpty,
              let actualExitCode = result.metadata["exit_code"].flatMap(Int.init),
              let trustedCommandReference = result.trustedCommandReference,
              trustedCommandReference.isValid,
              trustedCommandReference.exitCode == actualExitCode,
              trustedCommandReference.gateArgumentsDigest == AuditLog.digest(arguments).1 else {
            return nil
        }
        let argv = (arguments["args"] as? [String])
            ?? (arguments["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        let sourceKind = result.metadata["stdin_source_kind"]
            .flatMap(PlanStandardInputSourceKind.init(rawValue:))
            ?? (arguments["stdin"] == nil ? .none : .inline)
        let legacyInlineData = (arguments["stdin"] as? String).map { Data($0.utf8) }
        let stdinDigest = result.metadata["stdin_sha256"]
            ?? legacyInlineData.map(RunCommandTool.sha256)
        let stdinByteCount = Int(result.metadata["stdin_byte_count"] ?? "")
            ?? legacyInlineData?.count ?? 0
        let stdinRelativePath = result.metadata["stdin_relative_path"]
        switch sourceKind {
        case .none:
            guard arguments["stdin"] == nil, arguments["stdin_path"] == nil,
                  stdinDigest == nil, stdinByteCount == 0, stdinRelativePath == nil else { return nil }
        case .inline:
            guard arguments["stdin_path"] == nil,
                  let stdin = arguments["stdin"] as? String,
                  let stdinDigest,
                  stdinByteCount == stdin.utf8.count,
                  stdinDigest == RunCommandTool.sha256(Data(stdin.utf8)),
                  stdinRelativePath == nil else { return nil }
        case .governedPath:
            guard arguments["stdin"] == nil, arguments["stdin_path"] is String,
                  stdinDigest?.isEmpty == false, stdinByteCount >= 0,
                  stdinRelativePath?.isEmpty == false else { return nil }
        }
        let allowedExitCodes = (result.metadata["allowed_exit_codes"] ?? "")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.sorted()
        guard !allowedExitCodes.isEmpty, allowedExitCodes.contains(actualExitCode) else { return nil }
        let stdout = result.metadata["stdout"] ?? result.output
        let stderr = result.metadata["stderr"] ?? ""
        let combined = stdout + (stderr.isEmpty ? "" : "\n" + stderr)
        let canonical: String
        if JSONSerialization.isValidJSONObject(arguments),
           let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
           let value = String(data: data, encoding: .utf8) {
            canonical = value
        } else {
            canonical = String(reflecting: arguments)
        }
        func digest(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let semantic = result.metadata["semantic_status"]
            ?? (actualExitCode == 0 ? "clean_exit" : "expected_domain_status")
        let eligible = result.metadata["verification_eligible"]?.lowercased() == "true"
        let sourceBinding = [sourceKind.rawValue, stdinRelativePath ?? "-", stdinDigest ?? "-",
                             String(stdinByteCount)].joined(separator: "\u{0}")
        return PlanCommandExecutionCapture(
            executable: executable, argv: argv,
            workingDirectory: arguments["cwd"] as? String,
            hasStandardInput: sourceKind != .none,
            standardInputDigest: stdinDigest,
            standardInputByteCount: stdinByteCount,
            standardInputSourceKind: sourceKind,
            standardInputRelativePath: stdinRelativePath,
            allowedExitCodes: allowedExitCodes, actualExitCode: actualExitCode,
            wasSignalled: result.metadata["was_signalled"]?.lowercased() == "true",
            timedOut: result.metadata["timed_out"]?.lowercased() == "true",
            semanticStatus: semantic, verificationEligible: eligible,
            success: result.success, argsFingerprint: argsFingerprint,
            commandFingerprint: digest(step.tool + "\u{0}" + canonical + "\u{0}" + sourceBinding),
            outputDigest: digest(stdout + "\u{0}" + stderr),
            trustedCommandReference: trustedCommandReference,
            boundedRedactedOutputExcerpt: sourceKind == .none
                ? String(SecretMasker.mask(combined).prefix(2_000))
                : SecretMasker.marker + " stdin-bearing command output suppressed",
            effectObservation: effect, executionPhase: executionPhase, completedAt: Date(),
            governedWorkspaceDigest: PlanExecuteLoop.governedWorkspaceDigest(projectRoot: projectRoot))
    }
}
