import Foundation

/// Operator requests to register reusable runtime roles use fixed-path metadata tools. The prose
/// recognizer selects a smaller action surface; it never grants a general source or shell mutation.
public enum AgentMetadataRequest {
    public static let actionTools: Set<String> = [
        "create_agent", "list_agents", "shared_memory", "read_file", "read_files", "list_files", "glob_files",
        "search_code", "context_brain", "symbols", "ast_grep", "ask_user",
    ]

    /// Keep registration feedback separate from the source build checklist. Any other attempted
    /// mutation, including an unknown or failed source write, retains the ordinary build contract.
    public static func isRegistrationOnly(_ trajectory: [ActionRecord]) -> Bool {
        let mutations = trajectory.filter { $0.observedEffects.mutation != .none }
        return !mutations.isEmpty && mutations.allSatisfy {
            $0.tool == "create_agent" && $0.observedEffects.mutation == .nonSource
        }
    }

    public static func matches(_ request: String) -> Bool {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefix = #"^(?:please\s+)?(?:(?:can|could|would)\s+you\s+)?"#
        let patterns = [
            prefix + #"(?:use|call)\s+(?:the\s+)?create_agent\b"#,
            prefix + #"(?:create|register|add|make)\s+(?:(?:a|an|one|new)\s+)?(?:reusable\s+(?:agent|specialist)|agent\s+definition)\b"#,
            prefix + #"(?:create|register|add|make)\s+(?:(?:a|an|one|new|specialist)\s+){0,3}(?:agent|specialist)\s+(?:named|called|definition)\b"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}
