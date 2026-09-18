import Foundation
import AgentCore

/// One original-workspace audit spans preflight, retries, workers and review. Provider attempts
/// remain advisory; only Builder's applicable sealed receipts can establish accepted work.
final class BuilderRunAudit: @unchecked Sendable {
    @TaskLocal static var current: BuilderRunAudit?
    let replay: RunReplayStore
    private let root: String
    private let lock = NSLock()
    private var attempts: [AgentSpan] = []

    init(root: String, provider: String, model: String?, contractID: String) {
        self.root = root
        replay = RunReplayStore(projectRoot: root, provider: provider, model: model,
                                parentContractID: contractID)
    }

    func run(goal: String, operation: () async -> Int32) async -> Int32 {
        replay.startTurn(goal: goal)
        return await Self.$current.withValue(self) {
            await ProviderAttemptObservation.$observer.withValue({ [self] in record($0) }) {
                let status = await operation()
                KistRunner.note(usageSummary())
                replay.recordEvent(kind: "builderFinished", success: status == 0,
                                   text: "Builder process exit \(status); consult the applicable accepted/sealed receipt for completion authority.")
                return status
            }
        }
    }

    private func record(_ attempt: ProviderAttemptObservation) {
        let span = AgentSpan(
            id: attempt.id, traceId: replay.manifest.runID, kind: .llmCall,
            role: "builder." + attempt.mechanism, vendor: attempt.provider, model: attempt.model,
            promptTokens: max(0, attempt.usage.promptTokens),
            completionTokens: max(0, attempt.usage.completionTokens),
            attributes: ["accounting.source": "provider_attempt",
                         "usage.reported": String(attempt.usageReported)],
            startedAt: attempt.startedAt, endedAt: attempt.endedAt,
            status: attempt.success ? .ok : .error)
        lock.lock(); attempts.append(span); lock.unlock()
        if !UsageLedger.append(projectRoot: root, spans: [span]) {
            replay.recordEvent(kind: "usagePersistenceFailure", success: false,
                               text: "Could not persist provider attempt \(attempt.id) in the local usage ledger.")
        }
        let tokens = attempt.usageReported
            ? "\(span.promptTokens) input, \(span.completionTokens) output tokens"
            : "usage unreported; token totals are incomplete"
        replay.recordEvent(kind: "providerAttempt", success: attempt.success,
                           text: "\(attempt.id) · \(attempt.provider):\(attempt.model) · \(attempt.mechanism) · \(tokens)")
    }

    func usage() -> BuilderUsageReceipt {
        lock.lock(); let spans = attempts; lock.unlock()
        let missing = spans.filter { $0.attributes?["usage.reported"] != "true" }
            .map { "provider_attempt." + $0.id }
        return BuilderUsageReceipt(
            inputTokens: spans.reduce(0) { $0 + $1.promptTokens },
            outputTokens: spans.reduce(0) { $0 + $1.completionTokens },
            wallTimeSeconds: spans.reduce(0) { $0 + $1.durationMs / 1_000 },
            aggregateTokens: missing.isEmpty ? spans.reduce(0) { $0 + $1.totalTokens } : nil,
            unmeteredStages: missing.isEmpty ? nil : missing)
    }

    func usageSummary() -> String {
        lock.lock(); let spans = attempts; lock.unlock()
        let reported = spans.filter { $0.attributes?["usage.reported"] == "true" }
        let tokens = reported.reduce(0) { $0 + $1.totalTokens }
        let missing = spans.count - reported.count
        let detail = missing == 0 ? "\(tokens) tokens"
            : "\(tokens) reported tokens; \(missing) attempt(s) omitted usage, total incomplete"
        return "Builder total · \(spans.count) provider attempt(s) · \(detail) · includes preflight, workers, retries and review. Cost: /usage · /replay \(replay.manifest.runID)"
    }

    func recordRun(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        replay.recordEvent(kind: "builderRunRecord", text: String(decoding: data, as: UTF8.self))
    }
}
