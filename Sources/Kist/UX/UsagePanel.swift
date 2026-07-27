import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum UsageLedger {
    struct Snapshot {
        var spans: [AgentSpan]
        var malformedLines: Int
    }

    private static let lock = NSLock()

    @discardableResult
    static func append(projectRoot: String, spans: [AgentSpan]) -> Bool {
        guard !spans.isEmpty else { return true }
        let root = ToolContext.canonicalize(projectRoot) ?? projectRoot
        let dir = root + "/.kist"
        let path = usagePath(projectRoot: root)
        lock.lock()
        defer { lock.unlock() }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var lines = Data()
            for span in spans {
                var data = try encoder.encode(span)
                data.append(0x0a)
                lines.append(data)
            }
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try appendBytes(lines, to: path)
            return true
        } catch {
            // Usage is observability, not the action path. Never fail a run because local accounting
            // could not be persisted.
            return false
        }
    }

    static func load(projectRoot: String) -> [AgentSpan] {
        loadSnapshot(projectRoot: projectRoot).spans
    }

    static func loadSnapshot(projectRoot: String) -> Snapshot {
        let root = ToolContext.canonicalize(projectRoot) ?? projectRoot
        let path = usagePath(projectRoot: root)
        lock.lock()
        defer { lock.unlock() }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return Snapshot(spans: [], malformedLines: 0)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var byID: [String: AgentSpan] = [:]
        var malformed = 0
        for line in text.split(separator: "\n") {
            if let span = try? decoder.decode(AgentSpan.self, from: Data(line.utf8)) {
                if byID[span.id] == nil {
                    byID[span.id] = span
                }
            } else {
                malformed += 1
            }
        }
        return Snapshot(spans: byID.values.sorted { $0.startedAt < $1.startedAt },
                        malformedLines: malformed)
    }

    static func usagePath(projectRoot: String) -> String {
        (ToolContext.canonicalize(projectRoot) ?? projectRoot) + "/.kist/usage.jsonl"
    }

    private static func appendBytes(_ data: Data, to path: String) throws {
        #if canImport(Darwin) || canImport(Glibc)
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o600))
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                if written == 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                offset += written
            }
        }
        #else
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            guard !FileManager.default.fileExists(atPath: path) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        #endif
    }
}

struct UsagePanel {
    static func render(sessionSpans: [AgentSpan],
                       projectRoot: String,
                       now: Date = Date(),
                       color: Bool = true) -> String {
        let ledger = UsageLedger.loadSnapshot(projectRoot: projectRoot)
        let warning = ledger.malformedLines > 0
            ? "Ledger warning: \(ledger.malformedLines) unreadable usage line(s) were skipped."
            : nil
        return render(sessionSpans: sessionSpans, ledgerSpans: ledger.spans,
                      ledgerWarning: warning, now: now, color: color)
    }

    static func render(sessionSpans: [AgentSpan],
                       ledgerSpans: [AgentSpan],
                       ledgerWarning: String? = nil,
                       now: Date = Date(),
                       color: Bool = true) -> String {
        let session = dedupe(sessionSpans)
        let weekStart = startOfWeek(containing: now)
        let combined = dedupe(ledgerSpans + session)
        let week = combined.filter { $0.startedAt >= weekStart && $0.startedAt <= now }
        let sessionSummary = UsageCost.summarize(spans: session)
        let weekSummary = UsageCost.summarize(spans: week)

        var lines: [String] = []
        lines.append(c("1;37", "Usage", color))
        lines.append("")
        lines.append(c("1", "Session", color))
        if session.isEmpty || sessionSummary.tokens == 0 {
            lines.append("No token usage recorded in this session yet.")
        } else {
            let modelCalls = session.filter { $0.kind == .llmCall }.count
            let toolCalls = session.filter { $0.kind == .toolCall }.count
            let errors = session.filter { $0.status == .error }.count
            lines.append("Total cost:        \(formatCost(sessionSummary))")
            lines.append("Total duration:    \(formatDuration(session))")
            lines.append("Total tokens:      \(formatTokens(sessionSummary.tokens))")
            lines.append("Calls:             \(modelCalls) model, \(toolCalls) tool" + (errors > 0 ? ", \(errors) error" : ""))
            lines.append("")
            lines.append(c("1", "Usage by model", color))
            lines.append(contentsOf: bucketLines(session, by: modelKey))
            lines.append("")
            lines.append(c("1", "Usage by role", color))
            lines.append(contentsOf: bucketLines(session, by: roleKey))
        }

        lines.append("")
        lines.append(c("1", "Local Week", color))
        if week.isEmpty || weekSummary.tokens == 0 {
            lines.append("No local traced token usage this week.")
        } else {
            let sessionTokens = sessionSummary.tokens
            let weekTokens = max(weekSummary.tokens, sessionTokens)
            lines.append("Current session:   \(bar(value: sessionTokens, total: weekTokens)) \(share(sessionTokens, of: weekTokens)) of local week")
            lines.append("Local week trace:  \(bar(value: weekSummary.tokens, total: weekTokens)) \(formatTokens(weekSummary.tokens)) · \(formatCost(weekSummary))")
        }
        lines.append("Account quota:     unavailable locally; provider plan limits are not exposed by Kist yet.")
        if let ledgerWarning { lines.append(ledgerWarning) }

        lines.append("")
        lines.append(c("1", "What's Contributing", color))
        lines.append(contentsOf: contributionLines(session: session, week: week))
        lines.append("")
        lines.append(c("2", "Commands: /logs for proof · /replay latest for run evidence · /clear to drop chat context", color))
        return lines.joined(separator: "\n")
    }

    private static func dedupe(_ spans: [AgentSpan]) -> [AgentSpan] {
        var seen = Set<String>()
        var out: [AgentSpan] = []
        for span in spans.sorted(by: { $0.startedAt < $1.startedAt }) where !seen.contains(span.id) {
            seen.insert(span.id)
            out.append(span)
        }
        return out
    }

    private static func bucketLines(_ spans: [AgentSpan], by key: (AgentSpan) -> String) -> [String] {
        let llm = spans.filter { $0.kind == .llmCall && $0.totalTokens > 0 }
        guard !llm.isEmpty else { return ["(no model token spans)"] }
        let groups = Dictionary(grouping: llm, by: key)
        var buckets: [(String, UsageCostSummary)] = []
        for (name, spans) in groups {
            let summary = UsageCost.summarize(spans: spans)
            buckets.append((name, summary))
        }
        buckets.sort { lhs, rhs in
            lhs.1.tokens > rhs.1.tokens || (lhs.1.tokens == rhs.1.tokens && lhs.0 < rhs.0)
        }
        var lines = buckets.prefix(8).map { name, summary in
            "  \(name.padding(toLength: 30, withPad: " ", startingAt: 0)) \(formatTokens(summary.tokens)) · \(formatCost(summary))"
        }
        if buckets.count > 8 {
            lines.append("  ... and \(buckets.count - 8) more")
        }
        return lines
    }

    private static func contributionLines(session: [AgentSpan], week: [AgentSpan]) -> [String] {
        let base = session.filter { $0.kind == .llmCall && $0.totalTokens > 0 }
        guard !base.isEmpty else { return ["No model-token contributors yet."] }
        var lines: [String] = []
        let total = max(1, base.reduce(0) { $0 + $1.totalTokens })
        let vendors = Dictionary(grouping: base, by: { $0.vendor ?? "(unknown)" })
            .mapValues { $0.reduce(0) { $0 + $1.totalTokens } }
            .sorted { $0.value > $1.value }
        if let top = vendors.first {
            lines.append("\(share(top.value, of: total)) of session tokens came from \(top.key).")
        }
        let roleHeavy = Dictionary(grouping: base, by: roleKey)
            .mapValues { $0.reduce(0) { $0 + $1.totalTokens } }
            .sorted { $0.value > $1.value }
        if let top = roleHeavy.first {
            lines.append("Top role path: \(top.key) at \(share(top.value, of: total)) of session tokens.")
        }
        let longContext = base.filter { $0.promptTokens >= 150_000 }.reduce(0) { $0 + $1.totalTokens }
        if longContext > 0 {
            lines.append("\(share(longContext, of: total)) came from >150k-input calls; use /clear or narrower dossiers when it spikes.")
        } else {
            lines.append("No >150k-input calls in this session.")
        }
        let subagentTokens = base.filter {
            let role = ($0.role ?? "").lowercased()
            return role.contains("council") || role.contains("fleet") || role.contains("worker") || role.contains("critic") || role.contains("coder")
        }.reduce(0) { $0 + $1.totalTokens }
        if subagentTokens > 0 {
            lines.append("\(share(subagentTokens, of: total)) of session usage came from delegated/council roles.")
        }
        let weekTokens = week.filter { $0.kind == .llmCall }.reduce(0) { $0 + $1.totalTokens }
        if weekTokens > total {
            lines.append("Local week total is \(formatTokens(weekTokens)); this session is \(share(total, of: weekTokens)) of it.")
        }
        lines.append("Cache read/write tokens are not reported by the current provider span schema.")
        return lines
    }

    private static func modelKey(_ span: AgentSpan) -> String {
        let vendor = span.vendor ?? "(unknown)"
        guard let model = span.model, !model.isEmpty else { return vendor }
        return "\(vendor):\(model)"
    }

    private static func roleKey(_ span: AgentSpan) -> String {
        if let role = span.role, !role.isEmpty { return role }
        return "(default)"
    }

    private static func formatCost(_ summary: UsageCostSummary) -> String {
        let dollars: String
        if summary.knownUSD == 0 {
            dollars = "unpriced"
        } else if summary.knownUSD < 0.0001 {
            dollars = "~<$0.0001"
        } else {
            dollars = String(format: "~$%.4f", summary.knownUSD)
        }
        return summary.unknownTokens > 0 ? "\(dollars), \(formatTokens(summary.unknownTokens)) unpriced" : dollars
    }

    private static func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fm tok", Double(tokens) / 1_000_000.0) }
        if tokens >= 1_000 { return String(format: "%.1fk tok", Double(tokens) / 1_000.0) }
        return "\(tokens) tok"
    }

    private static func formatDuration(_ spans: [AgentSpan]) -> String {
        guard let start = spans.map(\.startedAt).min(),
              let end = spans.map(\.endedAt).max() else { return "0s" }
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    private static func bar(value: Int, total: Int, width: Int = 28) -> String {
        guard total > 0 else { return String(repeating: "░", count: width) }
        let filled = min(width, max(0, Int((Double(value) / Double(total) * Double(width)).rounded())))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }

    private static func share(_ value: Int, of total: Int) -> String {
        guard total > 0 else { return "0%" }
        return String(format: "%.0f%%", Double(value) / Double(total) * 100.0)
    }

    private static func c(_ code: String, _ text: String, _ color: Bool) -> String {
        color ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
    }

    private static func startOfWeek(containing date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }
}
