import Foundation

/// Terminal-native, trustworthy-by-construction observability for a multi-vendor run. The span shape
/// follows OpenTelemetry's GenAI semantic conventions (`gen_ai.*`) so it's a standard, vendor-neutral
/// data model — but it renders to a TTY, not a SaaS dashboard.
///
/// CORE INVARIANT (ahead of the literature, from our own fleet discipline): a span carries only
/// MEASURED facts — token counts, durations, finish reasons, which vendor/model ran. It never carries
/// a claim about whether the work was *correct*; that stays the critic's job. Measured spans may drive
/// display freely; anything an agent asserts is advisory until verified. Observability must not mint trust.
public enum SpanKind: String, Sendable, Codable { case llmCall, toolCall }
public enum SpanStatus: String, Sendable, Codable { case ok, error }

public struct AgentSpan: Sendable, Codable, Equatable, Identifiable {
    public let id: String                 // spanId
    public let traceId: String
    public let parentSpanId: String?
    public let kind: SpanKind
    public let role: String?              // planner / coder / critic (gen_ai.agent.name)
    public let vendor: String?            // providerId (gen_ai.system)
    public let model: String?             // gen_ai.request.model
    public let toolName: String?          // for a toolCall span
    public let promptTokens: Int          // gen_ai.usage.input_tokens (measured; 0 if provider omits)
    public let completionTokens: Int      // gen_ai.usage.output_tokens
    public let finishReason: String?
    /// Bounded, host-measured attributes. Tool spans use digest/count metadata only; raw arguments,
    /// output, errors, and remote result metadata never enter the trace.
    public let attributes: [String: String]?
    public let startedAt: Date
    public let endedAt: Date
    public let status: SpanStatus

    public init(id: String, traceId: String, parentSpanId: String? = nil, kind: SpanKind,
                role: String? = nil, vendor: String? = nil, model: String? = nil, toolName: String? = nil,
                promptTokens: Int = 0, completionTokens: Int = 0, finishReason: String? = nil,
                attributes: [String: String]? = nil,
                startedAt: Date, endedAt: Date, status: SpanStatus = .ok) {
        self.id = id; self.traceId = traceId; self.parentSpanId = parentSpanId; self.kind = kind
        self.role = role; self.vendor = vendor; self.model = model; self.toolName = toolName
        self.promptTokens = promptTokens; self.completionTokens = completionTokens
        self.finishReason = finishReason; self.attributes = attributes
        self.startedAt = startedAt; self.endedAt = endedAt; self.status = status
    }

    public var totalTokens: Int { promptTokens + completionTokens }
    public var durationMs: Double { max(0, endedAt.timeIntervalSince(startedAt) * 1000) }

    /// A one-line label for the terminal tree.
    public var label: String {
        switch kind {
        case .llmCall:
            let who = [role, vendor].compactMap { $0 }.joined(separator: "/")
            return "\(who.isEmpty ? "llm" : who)  \(totalTokens) tok"
        case .toolCall:
            return "\(toolName ?? "tool")"
        }
    }
}

/// A rollup over a trace's spans — what the terminal renders + what the cost layer reads.
public struct TraceSummary: Sendable, Codable, Equatable {
    public let traceId: String
    public let spanCount: Int
    public let totalTokens: Int
    public let tokensByRole: [String: Int]
    public let tokensByVendor: [String: Int]
    public let errorCount: Int
}

/// Thread-safe span collector (an actor, so it's safe once parallel workers exist). Accumulates spans
/// for one run and computes the rollups the terminal + budget layers consume.
public actor TraceRecorder {
    public let traceId: String
    private var spans: [AgentSpan] = []

    public init(traceId: String) { self.traceId = traceId }

    public func record(_ span: AgentSpan) { spans.append(span) }
    public func all() -> [AgentSpan] { spans }
    public func totalTokens() -> Int { spans.reduce(0) { $0 + $1.totalTokens } }

    public func tokensByRole() -> [String: Int] {
        var out: [String: Int] = [:]
        for s in spans where s.totalTokens > 0 { out[s.role ?? "(none)", default: 0] += s.totalTokens }
        return out
    }

    public func tokensByVendor() -> [String: Int] {
        var out: [String: Int] = [:]
        for s in spans where s.totalTokens > 0 { out[s.vendor ?? "(none)", default: 0] += s.totalTokens }
        return out
    }

    public func summary() -> TraceSummary {
        TraceSummary(traceId: traceId, spanCount: spans.count, totalTokens: totalTokens(),
                     tokensByRole: tokensByRole(), tokensByVendor: tokensByVendor(),
                     errorCount: spans.filter { $0.status == .error }.count)
    }
}

public extension TraceSummary {
    /// Terminal-renderable lines: the run's total + per-role + per-vendor token attribution (the
    /// "which vendor burned budget" view), sorted by spend. Empty when nothing was recorded.
    func terminalLines() -> [String] {
        guard spanCount > 0 else { return [] }
        func fmt(_ d: [String: Int]) -> String {
            d.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .map { "\($0.key) \($0.value)" }.joined(separator: " · ")
        }
        var lines = ["trace · \(totalTokens) tokens · \(spanCount) calls" + (errorCount > 0 ? " · \(errorCount) error\(errorCount == 1 ? "" : "s")" : "")]
        if !tokensByRole.isEmpty   { lines.append("  by role:   " + fmt(tokensByRole)) }
        if !tokensByVendor.isEmpty { lines.append("  by vendor: " + fmt(tokensByVendor)) }
        return lines
    }
}

public enum TraceID {
    /// A fresh trace/span id (hex, like OTel). UUID-derived → unique without a global counter.
    public static func make() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}
