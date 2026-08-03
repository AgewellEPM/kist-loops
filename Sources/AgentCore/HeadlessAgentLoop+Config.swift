import Foundation

// Runtime configuration: value-type toggles the REPL flips on a held loop (plan mode,
// extended thinking, approval tier), status accessors, and operator-request scope
// extraction. Extracted verbatim from HeadlessAgentLoop.swift — behavior unchanged.
extension HeadlessAgentLoop {
    /// Value-type copy with plan mode flipped — lets the REPL toggle `/plan` on a held loop.
    public func planModeEnabled(_ on: Bool) -> HeadlessAgentLoop {
        var copy = self
        copy.planMode = on
        return copy
    }

    /// Value-type copy with extended thinking flipped — lets the REPL toggle `/think` on a held loop.
    public func extendedThinkingEnabled(_ on: Bool) -> HeadlessAgentLoop {
        var copy = self
        copy.extendedThinking = on
        return copy
    }

    /// Value-type copy with a new approval-tool set — lets the REPL switch the permission tier
    /// (normal / accept-edits / bypass) on a held loop via shift+tab without rebuilding it.
    public func approving(_ tools: Set<String>) -> HeadlessAgentLoop {
        var copy = self
        copy.approvalTools = tools
        return copy
    }

    /// The tools that currently require approval (for the REPL to reason about the active tier).
    public var currentApprovalTools: Set<String> { approvalTools }

    /// Whether plan mode is currently active (for the REPL prompt/status).
    public var isPlanMode: Bool { planMode }

    /// Whether extended thinking is currently active (for the REPL prompt/status).
    public var isExtendedThinking: Bool { extendedThinking }

    /// The Agent-Skills menu projected into the system prompt (for `/skills` / auditing). Empty
    /// when no skills were discovered.
    public var skillsMenu: String { skillsXML }

    /// Names of skills the model actually loaded this session (telemetry). Empty when skills are off.
    public func loadedSkillNames() async -> [String] {
        await skillTracker?.loadedNames() ?? []
    }

    /// Return the operator's actual request from a compiled/scoped/memory-wrapped goal.
    /// Public so Kist's learning layer can label a turn without persisting injected context.
    public static func scopeRequestSource(for goal: String) -> String {
        let source = extractBetween(goal, start: PromptCompiler.scopeSourceStart, end: PromptCompiler.scopeSourceEnd)
            ?? extractAfterMemoryGoalMarker(goal)
            ?? strippingAppendedMemory(goal)
            ?? extractOriginalUserRequest(from: goal)
            ?? goal
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? goal : trimmed
    }

    /// KistRunner's plan-execute wrap prefixes injected memory ("MEMORY — …\n---\nGOAL:\n<user
    /// goal>"). Scope must be judged on the USER'S ask — remembered context is not a request
    /// (2026-07-29 dogfood catch: cortex text containing "server"/"production" reclassified every
    /// mission into plan-only serverDiagnostics, blocking all mutating steps).
    private static func extractAfterMemoryGoalMarker(_ text: String) -> String? {
        guard let r = text.range(of: "\n---\nGOAL:\n", options: .backwards) else { return nil }
        return String(text[r.upperBound...])
    }

    /// The great-loop wrap APPENDS memory after the goal — the sibling shape of the prefix wrap
    /// above (same poisoning, opposite end).
    private static func strippingAppendedMemory(_ text: String) -> String? {
        guard let r = text.range(of: "\n\nMEMORY — what kist knows about you & this project:") else { return nil }
        return String(text[..<r.lowerBound])
    }

    private static func extractBetween(_ text: String, start: String, end: String) -> String? {
        guard let s = text.range(of: start), let e = text.range(of: end, range: s.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[s.upperBound..<e.lowerBound])
    }

    private static func extractOriginalUserRequest(from text: String) -> String? {
        guard let marker = text.range(of: "Original user request:") else { return nil }
        let after = text[marker.upperBound...]
        let lines = after.split(separator: "\n", omittingEmptySubsequences: false)
        let requestLines = lines.drop(while: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .prefix { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let request = requestLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return request.isEmpty ? nil : request
    }
}
