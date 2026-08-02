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
        let mutating: Set<String> = ["write_file", "edit_file", "apply_patch", "notebook_edit",
                                     "create_directory", "make_dir", "move_file"]

        return TerminalCard.build(title: "📊 Usage", color: color, width: 76) { b in
            b.heading("Session", "96;1")
            if session.isEmpty || sessionSummary.tokens == 0 {
                b.row("No token usage recorded in this session yet.")
            } else {
                let llm = session.filter { $0.kind == .llmCall }
                let tools = session.filter { $0.kind == .toolCall }
                let errors = session.filter { $0.status == .error }.count
                let inTok = llm.reduce(0) { $0 + $1.promptTokens }
                let outTok = llm.reduce(0) { $0 + $1.completionTokens }
                let apiSec = Int((llm.reduce(0.0) { $0 + $1.durationMs } / 1000).rounded())
                let edits = tools.filter { mutating.contains($0.toolName ?? "") && $0.status == .ok }.count
                b.kv("Cost", priceLabel(llm.compactMap { $0.vendor }, sessionSummary))
                b.kv("Duration", "\(formatDuration(session)) wall · \(formatSeconds(apiSec)) in model")
                b.kv("Tokens", "\(formatTokens(sessionSummary.tokens)) · \(formatTokens(inTok)) in · \(formatTokens(outTok)) out")
                b.kv("Calls", "\(llm.count) model · \(tools.count) tool" + (errors > 0 ? " · \(errors) error" : ""))
                if edits > 0 { b.kv("Edits", "\(edits) file write/edit call(s)") }

                // Cost by activity — the headline: WHERE the reasoning/budget actually went, by the
                // engineering task each model call served. Lets you see "monitoring burned 17%" and
                // decide to switch a cheaper model for it. Share is by tokens (a reasoning-time proxy).
                let acts = activityBuckets(llm)
                if !acts.isEmpty {
                    b.blank(); b.heading("Cost by activity — where the reasoning went", "93;1")
                    let totalTok = max(1, acts.reduce(0) { $0 + $1.tokens })
                    for a in acts.prefix(8) {
                        b.kv("  " + a.name,
                             "\(share(a.tokens, of: totalTok)) · \(formatTokens(a.tokens)) · \(priceLabel(a.vendors, a.cost))",
                             keyWidth: 20)
                    }
                }

                b.blank(); b.heading("By model — who did the work")
                let models = modelBuckets(llm)
                if models.isEmpty { b.row(b.c("2", "(no model token spans)")) }
                for m in models.prefix(8) {
                    b.bullet("•", glyphCode: "92;1",
                             "\(m.name) — \(formatTokens(m.input)) in · \(formatTokens(m.output)) out · \(priceLabel([m.name], m.cost))")
                }

                let toolCounts = countBuckets(tools.compactMap { $0.toolName }.filter { !$0.hasPrefix("mcp__") })
                if !toolCounts.isEmpty {
                    b.blank(); b.heading("Where the work went — tools")
                    let total = max(1, toolCounts.reduce(0) { $0 + $1.1 })
                    for (name, n) in toolCounts.prefix(8) { b.kv("  " + name, "\(n) · \(share(n, of: total))") }
                }

                let subs = subagentBuckets(llm)
                if !subs.isEmpty {
                    b.blank(); b.heading("Subagents — delegated minds")
                    let total = max(1, subs.reduce(0) { $0 + $1.1 })
                    for (role, tok) in subs.prefix(6) { b.kv("  " + role, "\(formatTokens(tok)) · \(share(tok, of: total))") }
                }

                let mcp = countBuckets(tools.compactMap { $0.toolName }.filter { $0.hasPrefix("mcp__") }.map(mcpServer))
                if !mcp.isEmpty {
                    b.blank(); b.heading("MCP servers")
                    for (server, n) in mcp.prefix(6) { b.kv("  " + server, "\(n) call(s)") }
                }
            }

            b.blank(); b.heading("This week (local kist usage)", "94;1")
            if week.isEmpty || weekSummary.tokens == 0 {
                b.row(b.c("2", "No local traced token usage this week."))
            } else {
                // Bar = THIS session's share of the week (session-in-week tokens ÷ week tokens), so a
                // session that began before the week can't read a misleading 100% (Codex catch).
                let sessionInWeek = session.filter { $0.startedAt >= weekStart && $0.startedAt <= now }
                    .reduce(0) { $0 + $1.totalTokens }
                b.row(b.c("2", "this session ") + bar(value: sessionInWeek, total: weekSummary.tokens)
                      + " " + share(sessionInWeek, of: weekSummary.tokens) + b.c("2", " of the week"))
                b.kv("  week total", formatTokens(weekSummary.tokens))
                b.kv("  week cost", priceLabel(week.compactMap { $0.vendor }, weekSummary))
                // Per-provider week split — how hard each subscription / key was leaned on.
                for m in modelBuckets(week.filter { $0.kind == .llmCall }, byVendor: true).prefix(6) {
                    b.kv("  " + m.name, "\(formatTokens(m.input + m.output)) · \(priceLabel([m.name], m.cost))")
                }
            }

            b.blank(); b.heading("Subscription providers", "93;1")
            b.bullet("▪", glyphCode: "93;1",
                     "claude-cli / codex-cli are keyless subscription providers — the tokens above are what KIST drove through them (cost shown at list rates, not your plan).",
                     textCode: "2")
            b.bullet("▪", glyphCode: "93;1",
                     "Global weekly plan % (across Claude Code / Codex, all apps) is owned by those CLIs — not yet aggregated here.",
                     textCode: "2")

            if !session.isEmpty, sessionSummary.tokens > 0 {
                b.blank(); b.heading("What's driving it", "95;1")
                for insight in contributionLines(session: session, week: week).prefix(5) {
                    b.bullet("→", glyphCode: "96;1", insight)
                }
            }
            if let ledgerWarning { b.blank(); b.row(b.c("33", ledgerWarning)) }
        }
    }

    // MARK: - Rich breakdown helpers

    /// Map an agent role to a human ENGINEERING ACTIVITY, so cost/reasoning can be attributed to what
    /// the work actually was — the thing token counts alone never tell you. (Background-watch / idle-poll
    /// are session MODES, not roles; attributing those needs session-mode tagging on spans — a follow-up.)
    static func activity(for role: String?) -> String {
        let r = (role ?? "").lowercased()
        if r.contains("architect") || r.contains("planner") || r.contains("design") { return "Architecture" }
        if r.contains("coder") || r.contains("builder") || r.contains("developer") || r.contains("implement") { return "Code generation" }
        if r.contains("critic") || r.contains("review") || r.contains("verif") || r.contains("test") || r.contains("audit") { return "Review & tests" }
        if r.contains("research") { return "Deep research" }
        if r.contains("council") || r.contains("fleet") || r.contains("consensus") { return "Council" }
        if r.contains("analyst") || r.contains("worker") { return "Analysis" }
        if r.isEmpty || r.contains("captain") || r.contains("default") || r.contains("orchestr") { return "Orchestration" }
        return "Other"
    }

    struct ActivityBucket { let name: String; let tokens: Int; let cost: UsageCostSummary; let vendors: [String] }

    private static func activityBuckets(_ llm: [AgentSpan]) -> [ActivityBucket] {
        let priced = llm.filter { $0.totalTokens > 0 }
        let groups = Dictionary(grouping: priced, by: { activity(for: $0.role) })
        var out = groups.map { name, spans in
            ActivityBucket(name: name,
                           tokens: spans.reduce(0) { $0 + $1.totalTokens },
                           cost: UsageCost.summarize(spans: spans),
                           vendors: spans.compactMap { $0.vendor })
        }
        out.sort { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.name < $1.name }
        return out
    }

    struct ModelBucket { let name: String; let input: Int; let output: Int; let cost: UsageCostSummary }

    private static func modelBuckets(_ llm: [AgentSpan], byVendor: Bool = false) -> [ModelBucket] {
        let priced = llm.filter { $0.totalTokens > 0 }
        let groups = Dictionary(grouping: priced, by: { byVendor ? ($0.vendor ?? "(unknown)") : modelKey($0) })
        var out: [ModelBucket] = groups.map { name, spans in
            ModelBucket(name: name,
                        input: spans.reduce(0) { $0 + $1.promptTokens },
                        output: spans.reduce(0) { $0 + $1.completionTokens },
                        cost: UsageCost.summarize(spans: spans))
        }
        out.sort { ($0.input + $0.output) != ($1.input + $1.output) ? ($0.input + $0.output) > ($1.input + $1.output) : $0.name < $1.name }
        return out
    }

    /// Delegated-role LLM spans (worker/coder/critic/researcher/council/fleet/reviewer/verifier), by tokens.
    private static func subagentBuckets(_ llm: [AgentSpan]) -> [(String, Int)] {
        let delegated = ["worker", "coder", "builder", "critic", "reviewer", "verifier",
                         "researcher", "research", "council", "fleet", "analyst", "planner", "architect"]
        let spans = llm.filter { span in
            let r = (span.role ?? "").lowercased()
            return delegated.contains { r.contains($0) }
        }
        return Dictionary(grouping: spans, by: roleKey)
            .mapValues { $0.reduce(0) { $0 + $1.totalTokens } }
            .filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    private static func countBuckets(_ names: [String]) -> [(String, Int)] {
        Dictionary(grouping: names, by: { $0 }).mapValues { $0.count }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    /// `mcp__<server>__<tool>` → `<server>`.
    private static func mcpServer(_ tool: String) -> String {
        let parts = String(tool.dropFirst("mcp__".count)).components(separatedBy: "__")
        let server = parts.first ?? ""
        return server.isEmpty ? "(mcp)" : server
    }

    private static func formatSeconds(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
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

    /// Keyless subscription providers (Claude Max / ChatGPT plan) — no per-token charge, so their
    /// cost reads "subscription", not "unpriced". Local runtimes are free.
    private static let subscriptionVendors = ["claude-cli", "codex-cli"]
    private static let localVendors = ["mlx", "ollama"]

    /// An honest cost label for a set of vendor names + a cost summary. Metered $ wins; a zero-$ bucket
    /// reads "subscription" (Claude/Codex plan), "free (local)" (mlx/ollama), else "unpriced". Mixed
    /// metered+subscription is annotated so a real $ figure never hides subscription burn.
    private static func priceLabel(_ vendorNames: [String], _ cost: UsageCostSummary) -> String {
        let v = vendorNames.map { $0.lowercased() }
        let hasSub = v.contains { name in subscriptionVendors.contains { name.hasPrefix($0) } }
        let hasLocal = v.contains { name in localVendors.contains { name.hasPrefix($0) } }
        if cost.knownUSD > 0 { return formatCost(cost) + (hasSub ? " + subscription" : "") }
        if hasSub { return "subscription" }
        if hasLocal { return "free (local)" }
        return "unpriced"
    }

    private static func formatCost(_ summary: UsageCostSummary) -> String {
        if summary.knownUSD == 0 { return "unpriced" }
        let dollars = summary.knownUSD < 0.0001 ? "~<$0.0001" : String(format: "~$%.4f", summary.knownUSD)
        return summary.unknownTokens > 0 ? "\(dollars) + \(formatTokens(summary.unknownTokens)) unpriced" : dollars
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
