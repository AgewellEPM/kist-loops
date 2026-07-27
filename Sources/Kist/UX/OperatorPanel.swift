import Foundation

/// The calm "operating system for agents" panel: clear state first, internals second.
struct OperatorPanel {
    var agent: String
    var goal: String
    var mode: String
    var memory: String
    var context: String
    var cost: String
    var tools: [String]

    func render(color: Bool = true) -> String {
        func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }
        let rule = c("2", String(repeating: "─", count: 44))
        let toolLine = tools.isEmpty ? "None loaded" : tools.prefix(5).joined(separator: " · ")
        return """
        \(rule)
        \(c("36;1", "Mythos"))

        \(c("2", "Agent :")) \(agent)
        \(c("2", "Goal  :")) \(goal)

        \(c("2", "Status"))
          \(c("32", "✓")) Listening
          \(c("32", "✓")) Planning layer ready
          \(c("2", "□")) Waiting for your next instruction

        \(c("2", "Tools"))
          \(toolLine)

        \(c("2", "Context"))
          \(context) · Memory: \(memory)

        \(c("2", "Cost"))
          \(cost)
        \(rule)
        """
    }
}
