import Foundation
import AgentCore

/// Renders the loop's `RuntimeEvent`s to the terminal: streams assistant text inline, frames each
/// tool action in its own colored lane, dims reasoning, and prints a clear final status. The sole
/// stdout writer. The goal is a Claude-Code-style read: prose flows, tool work is visually set
/// apart, results are tight, and the eye always knows which "lane" it's in.
struct TerminalEventSink: RuntimeEventSink {
    enum Style: Sendable { case standard, calm }
    private final class State: @unchecked Sendable {
        private let lock = NSRecursiveLock()
        var lastTool: String?
        // index → tool, so a finished action is attributed to the tool that STARTED it, not merely the
        // most-recent one. Under parallel plan waves several actions start before any finish, so a bare
        // "last tool" mis-attributes results (and, now that the tool drives failure framing, could invert
        // "Nothing was committed"). Keyed by the event's action index; entry is cleared on finish.
        var toolByIndex: [Int: String] = [:]
        var liveStartedAt: Date?
        var liveLabel = "thinking"
        var liveSeed = 0              // varies the starting spinner word per live session
        var streamedChars = 0
        var promptTokens = 0
        var completionTokens = 0
        var usageEstimated = false
        var liveLineActive = false
        var timer: DispatchSourceTimer?

        func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        deinit { timer?.cancel() }
    }

    private let color: Bool
    private let showReasoning: Bool
    private let style: Style
    private let proofStore: TurnProofStore?
    private let state = State()

    init(color: Bool = isatty(fileno(stdout)) != 0,
         showReasoning: Bool = false,
         style: Style = .standard,
         proofStore: TurnProofStore? = nil) {
        self.color = color
        self.showReasoning = showReasoning
        self.style = style
        self.proofStore = proofStore
    }

    private func c(_ code: String, _ s: String) -> String { Self.color(code, s, enabled: color) }
    private static func color(_ code: String, _ s: String, enabled: Bool) -> String {
        enabled ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s
    }
    private func write(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }

    func emit(_ event: RuntimeEvent) {
        state.withLock { emitLocked(event) }
    }

    private func emitLocked(_ event: RuntimeEvent) {
        switch event {
        case .stateChanged(let runtimeState):
            switch runtimeState {
            case .analyzing:
                beginLiveStatus("thinking")
            case .planning:
                beginLiveStatus("planning")
            case .executing:
                beginLiveStatus("working")
            case .idle, .completed, .failed, .cancelled:
                finishLiveStatus()
            }
        case .tokenDelta(let t):
            proofStore?.record(.init(kind: .assistant, tool: nil, success: nil, text: t))   // proof keeps raw
            state.streamedChars += t.count
            finishLiveStatus(clearOnly: true)
            write(Self.spaceListItems(t))                                  // assistant prose, list-spaced
        case .usage(let promptTokens, let completionTokens, let estimated):
            state.promptTokens += max(0, promptTokens)
            state.completionTokens += max(0, completionTokens)
            state.usageEstimated = state.usageEstimated || estimated
            if state.liveStartedAt != nil { renderLiveStatus() }
        case .reasoningDelta(let r):
            proofStore?.record(.init(kind: .reasoning, tool: nil, success: nil, text: r))
            state.streamedChars += r.count
            if state.liveStartedAt == nil { beginLiveStatus("thinking") }
            guard showReasoning else { break }
            finishLiveStatus(clearOnly: true)
            write(c("37;3", r))                                            // readable + italic scratch thought
        case .actionStarted(let index, let tool, let desc):
            finishLiveStatus(clearOnly: true)
            let label = tool ?? "action"
            let detail = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            state.lastTool = label
            state.toolByIndex[index] = label
            proofStore?.record(.init(kind: .actionStarted, tool: label, success: nil, text: detail))
            if style == .calm {
                var line = "\n" + c("36", "│ ") + c("36;1", glyph(for: label) + " " + label) + c("37", " working")
                if !detail.isEmpty, detail != label { line += c("2", " · " + truncate(detail, 110)) }
                print(line)
                break
            }
            // A tool block opens its own lane: a bright gutter + the tool, dimmed detail on the side.
            var line = "\n" + c("36", "│ ") + c("36;1", glyph(for: label) + " " + label)
            if !detail.isEmpty, detail != label { line += c("37", "  " + truncate(detail, 80)) }
            print(line)
        case .actionFinished(let index, let ok, let output, let error):
            finishLiveStatus(clearOnly: true)
            // Attribute to the tool that STARTED this action index (parallel-wave safe); fall back to
            // the most-recent tool only if the start wasn't seen. Clear the entry to bound the map.
            let finishedTool = state.toolByIndex.removeValue(forKey: index) ?? state.lastTool
            proofStore?.record(.init(kind: .actionFinished, tool: finishedTool, success: ok, text: ok ? output : (error ?? output)))
            if ok {
                if style == .calm {
                    // Show what web research actually looked at: the query + the source URLs it found.
                    if finishedTool == "web_search", let trail = Self.searchTrail(output: output, color: color) {
                        print(tokenAnnotatedSearchTrail(trail, output: output))
                    } else {
                        print(c("36", "│ ") + c("32;1", "✓ ") + c("37", tokenAnnotated(Self.calmSuccessSummary(tool: finishedTool, output: output), output: output)))
                    }
                    break
                }
                let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
                let preview = lines.prefix(6).joined(separator: "\n" + c("36", "│ ") + "  ")
                let more = lines.count > 6 ? c("37", "  … +\(lines.count - 6) more lines") : ""
                let body = preview.isEmpty ? c("37", "(no output)") : preview
                print(c("36", "│ ") + c("32;1", "✓ ") + body + more + c("37", tokenSuffix()))
            } else {
                // Recovery language, not a raw status code (#11): say what failed + the next move.
                let raw = (error ?? output).trimmingCharacters(in: .whitespacesAndNewlines)
                print(c("36", "│ ") + c("31;1", "✗ ") + c("31", truncate(ErrorHumanizer.humanize(raw, tool: finishedTool), 220)))
            }
        case .replanStarted(let reason):
            finishLiveStatus(clearOnly: true)
            proofStore?.record(.init(kind: .replan, tool: nil, success: nil, text: reason))
            print("\n" + c("35;1", "↻ re-planning ") + c("35", "· " + reason))
        case .awaitingApproval(let summary):
            finishLiveStatus()
            proofStore?.record(.init(kind: .awaitingApproval, tool: nil, success: nil, text: summary))
            if style == .calm {
                print("\n" + c("33;1", "◷ waiting for approval") + c("2", " · press Enter to run, n to skip"))
            }
        case .awaitingInput(let question):
            finishLiveStatus()
            proofStore?.record(.init(kind: .awaitingInput, tool: "ask_user", success: nil, text: question))
            if style == .calm {
                print("\n" + c("36;1", "◷ waiting for answer"))
            }
        case .completed(let summary):
            finishLiveStatus()
            proofStore?.record(.init(kind: .completed, tool: nil, success: true, text: summary))
            // The final answer was ALREADY streamed live (tokenDelta). Don't reprint the whole thing on the
            // "done" line — only surface the summary when nothing visible was streamed (e.g. a tool-only
            // turn). Otherwise every answer showed twice.
            let tail = (state.streamedChars > 0 || summary.isEmpty) ? "" : c("37", " · " + summary)
            print("\n" + c("32;1", "●") + c("32", " done") + tail)
        case .failed(let reason):
            finishLiveStatus()
            proofStore?.record(.init(kind: .failed, tool: nil, success: false, text: reason))
            print("\n" + c("31;1", "●") + c("31", " failed") + c("37", " · " + ErrorHumanizer.humanize(reason)))
        case .contextCompacted(let omitted):
            finishLiveStatus(clearOnly: true)
            print(c("2", "⟢ compacted \(omitted) earlier step(s) into a summary — staying within context"))
        case .cancelled:
            finishLiveStatus()
            print("\n" + c("33;1", "●") + c("33", " stopped"))
        default:
            break
        }
    }

    private func beginLiveStatus(_ label: String) {
        guard color else { return }
        if state.liveStartedAt == nil {
            state.liveStartedAt = Date()
            state.streamedChars = 0
            state.liveSeed = Int(Date().timeIntervalSince1970)   // fresh starting bar each live session
        }
        state.liveLabel = label
        renderLiveStatus()
        startLiveTimer()
    }

    private func startLiveTimer() {
        guard state.timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [state, color] in
            state.withLock {
                guard state.liveStartedAt != nil else { return }
                FileHandle.standardOutput.write(Data(Self.liveStatusLine(state: state, color: color).utf8))
                state.liveLineActive = true
            }
        }
        state.timer = timer
        timer.resume()
    }

    private func finishLiveStatus(clearOnly: Bool = false) {
        state.timer?.cancel()
        state.timer = nil
        if state.liveLineActive {
            write("\r\u{001B}[K")
            state.liveLineActive = false
        }
        if !clearOnly {
            state.liveStartedAt = nil
            state.streamedChars = 0
            state.promptTokens = 0
            state.completionTokens = 0
            state.usageEstimated = false
        }
    }

    private func renderLiveStatus() {
        write(Self.liveStatusLine(state: state, color: color))
        state.liveLineActive = true
    }

    private static func liveStatusLine(state: State, color: Bool) -> String {
        let started = state.liveStartedAt ?? Date()
        let elapsed = Date().timeIntervalSince(started)
        let word = ThinkingWords.word(phase: ThinkingWords.phase(from: state.liveLabel),
                                      elapsed: elapsed, seed: state.liveSeed)
        return "\r"
            + Self.color("35;1", "◇ \(word)", enabled: color)
            + Self.color("37", " · \(formatElapsed(elapsed)) · \(tokenText(promptTokens: state.promptTokens, completionTokens: state.completionTokens, streamedCharacters: state.streamedChars, estimated: state.usageEstimated))", enabled: color)
            + "\u{001B}[K"
    }

    static func liveStatusText(label: String, elapsed: TimeInterval, streamedCharacters: Int,
                               promptTokens: Int = 0, completionTokens: Int = 0,
                               estimated: Bool = false, color: Bool = false) -> String {
        return Self.color("35;1", "◇ \(label)", enabled: color)
            + Self.color("37", " · \(formatElapsed(elapsed)) · \(tokenText(promptTokens: promptTokens, completionTokens: completionTokens, streamedCharacters: streamedCharacters, estimated: estimated))", enabled: color)
    }

    private static func formatElapsed(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded(.down)))
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }

    private static func tokenText(promptTokens: Int, completionTokens: Int,
                                  streamedCharacters: Int, estimated: Bool) -> String {
        let measured = max(0, promptTokens) + max(0, completionTokens)
        if measured > 0 {
            return "\(estimated ? "~" : "")\(formatTokenCount(measured)) tok"
        }
        return "~\(formatTokenCount(max(0, streamedCharacters) / 4)) tok"
    }

    private static func formatTokenCount(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fm", Double(tokens) / 1_000_000.0) }
        if tokens >= 1_000 { return String(format: "%.1fk", Double(tokens) / 1_000.0) }
        return "\(tokens)"
    }

    private func tokenSuffix(fallbackOutput: String? = nil) -> String {
        let total = state.promptTokens + state.completionTokens
        if total > 0 {
            let text = Self.tokenText(promptTokens: state.promptTokens,
                                      completionTokens: state.completionTokens,
                                      streamedCharacters: state.streamedChars,
                                      estimated: state.usageEstimated)
            return " · \(text)"
        }
        guard let fallbackOutput else { return "" }
        return Self.estimatedOutputTokenSuffix(output: fallbackOutput)
    }

    private func tokenAnnotated(_ summary: String, output: String) -> String {
        let suffix = tokenSuffix(fallbackOutput: summary.contains("/logs") ? output : nil)
        return Self.annotateSummaryWithTokenCount(summary, suffix: suffix)
    }

    private func tokenAnnotatedSearchTrail(_ trail: String, output: String) -> String {
        Self.annotateFirstLineWithTokenCount(trail, suffix: tokenSuffix(fallbackOutput: output))
    }

    static func annotateSummaryWithTokenCount(_ summary: String, promptTokens: Int,
                                              completionTokens: Int, estimated: Bool) -> String {
        let total = max(0, promptTokens) + max(0, completionTokens)
        guard total > 0 else { return summary }
        let text = tokenText(promptTokens: promptTokens, completionTokens: completionTokens,
                             streamedCharacters: 0, estimated: estimated)
        return annotateSummaryWithTokenCount(summary, suffix: " · \(text)")
    }

    private static func annotateSummaryWithTokenCount(_ summary: String, suffix: String) -> String {
        guard !suffix.isEmpty else { return summary }
        if let range = summary.range(of: " · /logs") {
            return String(summary[..<range.lowerBound]) + suffix + String(summary[range.lowerBound...])
        }
        return summary + suffix
    }

    static func annotateSummaryWithEstimatedOutputTokens(_ summary: String, output: String) -> String {
        guard summary.contains("/logs") else { return summary }
        return annotateSummaryWithTokenCount(summary, suffix: estimatedOutputTokenSuffix(output: output))
    }

    private static func annotateFirstLineWithTokenCount(_ text: String, suffix: String) -> String {
        guard !suffix.isEmpty else { return text }
        guard let newline = text.firstIndex(of: "\n") else { return text + suffix }
        return String(text[..<newline]) + suffix + String(text[newline...])
    }

    private static func estimatedOutputTokenSuffix(output: String) -> String {
        let chars = output.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard chars > 0 else { return "" }
        let tokens = max(1, Int((Double(chars) / 4.0).rounded(.up)))
        return " · ~\(formatTokenCount(tokens)) tok"
    }

    /// A small glyph per common tool so the lane reads at a glance.
    private func glyph(for tool: String) -> String {
        switch tool {
        case "write_file": return "✎"
        case "edit_file": return "✎"
        case "read_file": return "◇"
        case "run_command": return "❯"
        case "list_files", "search": return "⌕"
        case "web_fetch", "web_search": return "🌐"
        case "spawn_agent": return "⚇"
        case "computer_control": return "▣"
        default: return "⚙"
        }
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count <= n ? oneLine : String(oneLine.prefix(n)) + "…"
    }

    /// A visible source trail for a web_search: the query it ran + the source URLs it surfaced, so the
    /// user can see exactly what was searched and where the answer came from (not just "9 lines · /logs").
    static func searchTrail(output: String, color: Bool) -> String? {
        var query = ""
        var engine = ""
        var urls: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Searched: ") {
                let rest = String(t.dropFirst("Searched: ".count))
                // Output is "<query> · via <engine>" — split so the shown query is EXACTLY what was
                // searched (the engine is metadata, not part of the query).
                if let r = rest.range(of: " · via ") {
                    query = String(rest[..<r.lowerBound]); engine = String(rest[r.upperBound...])
                } else { query = rest }
            } else if t.hasPrefix("URL: ") {
                urls.append(String(t.dropFirst("URL: ".count)))
            }
        }
        guard !urls.isEmpty else { return nil }
        func col(_ code: String, _ s: String) -> String { Self.color(code, s, enabled: color) }
        var head = col("36", "│ ") + col("35;1", "🔍 ") + col("37", "searched: ") + col("37;1", query)
            + col("37", " · \(urls.count) source\(urls.count == 1 ? "" : "s")")
        if !engine.isEmpty { head += col("2", " · " + engine) }
        var out = [head]
        for u in urls.prefix(6) { out.append(col("36", "│   ") + col("34", "↳ ") + col("2", u)) }
        if urls.count > 6 { out.append(col("36", "│   ") + col("2", "… +\(urls.count - 6) more")) }
        return out.joined(separator: "\n")
    }

    /// Compact success text for the calm lane. File-mutating tools should show the real artifact
    /// and line count, not a generic "captured output" message; read/search tools stay summarized
    /// with `/logs` as the proof drawer.
    static func calmSuccessSummary(tool: String?, output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let tool = tool ?? ""
        if tool == "write_file" || tool == "edit_file" || tool == "move_file" || tool == "make_dir" {
            return trimmed.isEmpty ? "file updated" : trimmed
        }
        if tool == "run_command" {
            let count = nonEmptyLineCount(trimmed)
            return count == 0 ? "command completed" : "command output · \(count) line(s) · /logs for details"
        }
        if tool == "read_file" {
            let count = nonEmptyLineCount(trimmed)
            return count == 0 ? "file read" : "read \(count) line(s) · /logs for details"
        }
        if tool == "list_files" || tool == "search" || tool == "grep" {
            let count = nonEmptyLineCount(trimmed)
            return count == 0 ? "no matches" : "\(count) result line(s) · /logs for details"
        }
        let count = nonEmptyLineCount(trimmed)
        return count == 0 ? "done" : "\(count) line(s) captured · /logs for details"
    }

    private static func nonEmptyLineCount(_ s: String) -> Int {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    /// Put a blank line before each list item so bullets/numbered lists are readable in the terminal
    /// (Luke can't read wall-of-bullets). Deterministic — works even when the model ignores the
    /// formatting instruction. Leaves fenced code blocks untouched and never double-spaces.
    static func spaceListItems(_ text: String) -> String {
        guard text.contains("\n") else { return text }                    // single line: nothing to space
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); out.append(line); continue }
            if !inFence, isListItem(trimmed), let last = out.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("")                                            // blank line before this item
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// A markdown-ish list item: `- `, `* `, `+ `, `• `, or `1.` / `2)` numbered.
    private static func isListItem(_ trimmed: String) -> Bool {
        if let f = trimmed.first, "-*+•".contains(f) {
            let rest = trimmed.dropFirst()
            return rest.first == " " || rest.isEmpty
        }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return false }
        let after = trimmed.dropFirst(digits.count)
        guard let marker = after.first, marker == "." || marker == ")" else { return false }
        let tail = after.dropFirst()
        return tail.first == " " || tail.isEmpty
    }
}
