import Foundation
import AgentCore

/// Deterministic REPL transcript export. The model can always write summaries/specs
/// with `write_file`, but saving the actual conversation should not depend on a tool call.
struct ConversationExporter {
    static func markdown(transcript: [ChatMessage], exportedAt: Date = Date()) -> String {
        var lines: [String] = [
            "# Kist Conversation",
            "",
            "Exported: \(iso8601.string(from: exportedAt))",
            "",
        ]

        if transcript.isEmpty {
            lines.append("_No conversation turns yet._")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        for (idx, message) in transcript.enumerated() {
            lines.append("## \(idx + 1). \(title(for: message.role))")
            lines.append("")
            if let toolCallId = message.toolCallId {
                lines.append("Tool call id: `\(toolCallId)`")
                lines.append("")
            }
            if let calls = message.toolCalls, !calls.isEmpty {
                lines.append("Tool calls:")
                for call in calls {
                    lines.append("- `\(call.name)` id `\(call.id)` args: `\(singleLine(call.argumentsJSON))`")
                }
                lines.append("")
            }
            let body = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(body.isEmpty ? "_No text content._" : body)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    @discardableResult
    static func writeMarkdown(transcript: [ChatMessage], path: String, projectRoot: String,
                              exportedAt: Date = Date()) throws -> String {
        let requested = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputPath = requested.isEmpty ? "kist-conversation.md" : requested
        let confined = try ToolContext(projectRoot: projectRoot).confinedRoot()
        try confined.writeString(outputPath, markdown(transcript: transcript, exportedAt: exportedAt), createParents: true)
        return try ToolContext(projectRoot: projectRoot).resolvedPath(outputPath, mustExist: true)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func title(for role: ChatMessage.Role) -> String {
        switch role {
        case .system: return "System"
        case .user: return "User"
        case .assistant: return "Assistant"
        case .tool: return "Tool"
        }
    }

    private static func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: "\\n")
    }
}
