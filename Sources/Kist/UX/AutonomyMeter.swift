import Foundation
import AgentCore

/// The autonomy meter — "what is the AI actually DOING, and why is it taking time?" Instead of a bare
/// "Working…", it attributes elapsed span time to a PHASE (Thinking / Researching / Coding / Running /
/// Delegating / Other) so the operator sees, at a glance, that a turn was 60% research or 70% test-runs.
/// Pure over its spans → unit-tested; the REPL feeds it live session spans.
enum AutonomyMeter {
    enum Phase: String, CaseIterable, Sendable {
        case thinking = "Thinking"
        case researching = "Researching"
        case coding = "Coding"
        case running = "Running"
        case delegating = "Delegating"
        case other = "Other"
        var glyphCode: String {
            switch self {
            case .thinking: return "95;1"     // magenta
            case .researching: return "94;1"  // blue
            case .coding: return "92;1"       // green
            case .running: return "93;1"      // yellow
            case .delegating: return "96;1"   // cyan
            case .other: return "2"
            }
        }
    }

    /// Which phase a span's time counts toward — tool calls by tool kind, model calls by role.
    static func phase(for span: AgentSpan) -> Phase {
        if span.kind == .toolCall {
            switch span.toolName ?? "" {
            case "read_file", "list_files", "search", "grep", "search_code", "web_search", "web_fetch":
                return .researching
            case "write_file", "edit_file", "apply_patch", "notebook_edit", "move_file", "make_dir", "create_directory":
                return .coding
            case "run_command":
                return .running
            case "spawn_agent":
                return .delegating
            default:
                return .other
            }
        }
        let r = (span.role ?? "").lowercased()
        if r.contains("research") { return .researching }
        if r.contains("coder") || r.contains("builder") || r.contains("developer") || r.contains("implement") { return .coding }
        if r.contains("critic") || r.contains("review") || r.contains("verif") || r.contains("test") || r.contains("audit") { return .running }
        if r.contains("council") || r.contains("fleet") || r.contains("worker") || r.contains("researcher") { return .delegating }
        return .thinking
    }

    struct Slice: Equatable { let phase: Phase; let seconds: Double; let calls: Int }

    /// Time (seconds) + call count per phase, richest first. Empty when there are no timed spans.
    static func slices(_ spans: [AgentSpan]) -> [Slice] {
        guard !spans.isEmpty else { return [] }
        var seconds: [Phase: Double] = [:]
        var calls: [Phase: Int] = [:]
        for span in spans {
            let p = phase(for: span)
            seconds[p, default: 0] += span.durationMs / 1000.0
            calls[p, default: 0] += 1
        }
        return seconds.map { Slice(phase: $0.key, seconds: $0.value, calls: calls[$0.key] ?? 0) }
            .filter { $0.seconds > 0 || $0.calls > 0 }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.phase.rawValue < $1.phase.rawValue }
    }

    /// Render the meter as a card: one bar per phase, proportional to time, with % and duration.
    static func render(spans: [AgentSpan], color: Bool, width: Int = 76) -> String {
        let slices = slices(spans)
        return TerminalCard.build(title: "🫀 Autonomy — where the time went", color: color, width: width) { b in
            guard !slices.isEmpty else {
                b.row(b.c("2", "No timed activity yet — run a turn first."))
                return
            }
            let total = max(0.001, slices.reduce(0) { $0 + $1.seconds })
            let labelWidth = slices.map { $0.phase.rawValue.count }.max() ?? 10
            for s in slices {
                let pct = s.seconds / total
                let label = s.phase.rawValue.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
                let bar = b.c(s.phase.glyphCode, Self.bar(pct))
                let meta = b.c("2", "\(Int((pct * 100).rounded()))% · \(fmt(s.seconds)) · \(s.calls) call\(s.calls == 1 ? "" : "s")")
                b.row("\(label)  \(bar)  \(meta)")
            }
            b.blank()
            b.row(b.c("2", "total ") + fmt(total) + b.c("2", " of measured span time"))
        }
    }

    static func bar(_ fraction: Double, width: Int = 18) -> String {
        let filled = max(0, min(width, Int((fraction * Double(width)).rounded())))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }

    private static func fmt(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
