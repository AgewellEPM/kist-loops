import Foundation
import AgentCore

/// Operator surface, extracted from KistRunner (RED-zone modular split, behavior-preserving):
/// health / bench / eval / protocol-status / replay / provider-listing reporting. These answer the
/// "is this thing working, and how much did it cost?" operator questions, not the run routes themselves.
extension KistRunner {

    static func replayRun(projectRoot: String, id: String) -> Int32 {
        note(RunReplayStore.render(projectRoot: projectRoot, id: id))
        return 0
    }

    /// Live model-id preflight: GET /models per keyed provider, diff vs the catalog, flag dead ids.
    static func providerDoctorReport(_ registry: ProviderRegistry) async -> String {
        let reports = await ProviderDoctor.check(
            providers: ProviderCatalog.openAICompatible,
            apiKey: { registry.apiKey(forProviderId: $0.id) },
            fetch: { url, key in await ProviderDoctor.liveFetch(modelsURL: url, apiKey: key) })
        return ProviderDoctor.render(reports)
    }

    static func providerHealth(_ registry: ProviderRegistry, probe: Bool) async -> Int32 {
        let report: ProviderHealthReport
        if probe {
            let bindings = registry.providers.map { ProviderBinding(providerId: $0.id, model: $0.defaultModel) }
            report = await ProviderHealthChecker.liveProbe(registry, bindings: bindings)
        } else {
            report = ProviderHealthChecker.catalogReport(registry)
        }
        note(report.render())
        if probe, report.rows.contains(where: { $0.state == .staleCatalog }) {
            note("router · stale model detected; fallback is enabled for availability/model/key failures")
        }
        return report.rows.contains(where: { $0.state == .failed || $0.state == .staleCatalog }) ? 1 : 0
    }

    static func protocolStatus(projectRoot: String) -> Int32 {
        note(protocolStatusText(projectRoot: projectRoot))
        let (_, issues) = MCPClientConfig.load(projectRoot: ToolContext.canonicalize(projectRoot) ?? projectRoot)
        return issues.isEmpty ? 0 : 1
    }

    static func protocolStatusText(projectRoot: String) -> String {
        let root = ToolContext.canonicalize(projectRoot) ?? projectRoot
        let (servers, issues) = MCPClientConfig.load(projectRoot: root)
        var lines = ["protocols · \(root)"]
        lines.append("MCP · \(servers.count) configured server(s)" + (servers.contains { $0.name == "isolated-tester" } ? " · IsolatedTester app verification present" : ""))
        for server in servers.sorted(by: { $0.name < $1.name }) {
            lines.append("  ✓ \(server.name) · \(server.command) \(server.args.joined(separator: " "))")
        }
        for issue in issues {
            lines.append("  ! \(issue.server): \(issue.reason)")
        }
        lines.append("A2A · native agent-card/task schema ready · endpoint not exposed yet")
        lines.append("browser · first-class browse tool with SSRF entry-host guard")
        lines.append("computer_control · first-class approval-gated desktop/app control tool")
        return lines.joined(separator: "\n")
    }

    struct BenchRow {
        let provider: String
        let model: String?
        let success: Bool
        let latencyMs: Int
        let toolFailures: Int
        let steps: Int
        let usage: UsageCostSummary
        let summary: String
    }

    static func runBench(_ opts: KistOptions, goal: String, registry: ProviderRegistry,
                                 root: String, tools: ToolRegistry, context: ToolContext) async -> Int32 {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            err("usage: kist --bench \"<task>\"")
            return 2
        }
        let preferred = ["mimo", "deepseek", "gemini", "openai"]
        let candidates = preferred.compactMap { id -> (any ChatProvider)? in
            guard let p = registry.provider(id: id), registry.hasKey(for: p) else { return nil }
            return p
        }
        guard !candidates.isEmpty else {
            err("bench · no preferred providers have keys (wanted: \(preferred.joined(separator: ", ")))")
            return 2
        }
        note("bench · \(candidates.map(\.id).joined(separator: ", ")) · \(goal)")
        var rows: [BenchRow] = []
        for provider in candidates {
            let trajectory = TrajectoryRecorder()
            let trace = TraceRecorder(traceId: TraceID.make())
            let started = Date()
            let loop = makeLoop(registry: registry, providerId: provider.id, model: nil, context: context,
                                tools: tools, checkpoints: LoopCheckpointStore(), maxIterations: opts.maxIterations,
                                budget: opts.makeBudget(),
                                interactor: AutoApproveInteractor(), approvalTools: [],
                                planMode: opts.planMode, extendedThinking: opts.extendedThinking, toolMode: ToolMode(rawValue: opts.toolMode) ?? .auto,
                                roles: RoleBindings(default: ProviderBinding(providerId: provider.id)),
                                delegationDepth: 0, sinkOverride: NullEventSink(),
                                recorder: trajectory, traceRecorder: trace,
                                traceRole: "bench")
            let outcome = await loop.run(goal: goal)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            let steps = trajectory.snapshot()
            let spans = await trace.all()
            let usage = UsageCost.summarize(spans: spans)
            rows.append(BenchRow(provider: provider.id, model: provider.defaultModel,
                                 success: outcome.success, latencyMs: latency,
                                 toolFailures: steps.filter { !$0.success }.count,
                                 steps: steps.count, usage: usage,
                                 summary: outcome.summary))
        }
        note(renderBench(rows))
        return rows.contains(where: \.success) ? 0 : 1
    }

    static func renderBench(_ rows: [BenchRow]) -> String {
        var out = "bench result\n"
        out += "| Provider | Result | Latency | Steps | Tool failures | Usage |\n"
        out += "| --- | --- | ---: | ---: | ---: | --- |\n"
        for row in rows {
            let result = row.success ? "pass" : "fail"
            out += "| \(row.provider) | \(result) | \(row.latencyMs)ms | \(row.steps) | \(row.toolFailures) | \(row.usage.render(label: "").trimmingCharacters(in: .whitespaces)) |\n"
        }
        out += "\nproof metrics · success, latency, tool failures, token/cost estimate. Run this across 20 real tasks and 3 role profiles before claiming production maturity."
        return out
    }

    static func runEval(_ opts: KistOptions, goal: String, registry: ProviderRegistry,
                                root: String, tools: ToolRegistry, context: ToolContext,
                                providerId: String, model: String?) async -> Int32 {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            err("usage: kist --eval \"<task>\"")
            return 2
        }
        let trace = TraceRecorder(traceId: TraceID.make())
        let runner = EvalRunner(maxIterations: opts.maxIterations)
        let report = await runner.run([
            EvalCase(name: "agent-behavior", prompt: goal,
                     assertions: [.trajectoryHealthy, .maxSteps(opts.maxIterations), .noToolFailures])
        ], agent: { prompt in
            let trajectory = TrajectoryRecorder()
            let loop = makeLoop(registry: registry, providerId: providerId, model: model, context: context,
                                tools: tools, checkpoints: LoopCheckpointStore(), maxIterations: opts.maxIterations,
                                budget: opts.makeBudget(),
                                interactor: AutoApproveInteractor(), approvalTools: [],
                                planMode: opts.planMode, extendedThinking: opts.extendedThinking, toolMode: ToolMode(rawValue: opts.toolMode) ?? .auto,
                                roles: RoleBindings(default: ProviderBinding(providerId: providerId, model: model)),
                                delegationDepth: 0, sinkOverride: TerminalEventSink(),
                                recorder: trajectory, traceRecorder: trace,
                                traceRole: "eval")
            let outcome = await loop.run(goal: prompt)
            return EvalRunner.RunOutcome(output: outcome.summary, trajectory: trajectory.snapshot())
        })
        note(report.render())
        printUsageDelta(from: [], to: await trace.all(), label: "eval usage", projectRoot: root)
        return report.allPassed ? 0 : 1
    }

    static func printUsageDelta(from before: [AgentSpan], to after: [AgentSpan],
                                        label: String, projectRoot: String? = nil) {
        let oldIds = Set(before.map(\.id))
        let delta = after.filter { !oldIds.contains($0.id) }
        if let projectRoot, !UsageLedger.append(projectRoot: projectRoot, spans: delta) {
            note("usage ledger warning · could not persist local usage accounting")
        }
        let summary = UsageCost.summarize(spans: delta)
        guard summary.tokens > 0 else { return }
        note(summary.render(label: label))
    }
}
