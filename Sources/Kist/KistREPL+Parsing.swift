import Foundation
import AgentCore

// Pure parsers + small prompt helpers: model-spec / slash-command / fleet / council /
// forge-intent / role parsing, plus the y/N/a confirmation helpers and invocations.
// Extracted verbatim from KistREPL.swift (Pass-1 modularization; no behavior change).
extension KistREPL {
    struct FleetInvocation: Equatable {
        let goal: String
        let agents: Int
    }


    /// Resolve a `/model` argument into the new SESSION-DEFAULT binding.
    /// - `provider` / `provider:model` → that provider (model nil = provider default).
    /// - `:model` → keep the CURRENT provider, switch model.
    /// - a bare token that names a model of the CURRENT provider → keep provider, switch model.
    /// Returns nil when it can't be resolved to a known provider/model.
    static func resolveModelSpec(_ args: String, currentProvider: String,
                                 knownProviders: [String: String],
                                 providerModels: [String: [String]]) -> ProviderBinding? {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // ":model" → change only the model on the current provider.
        if trimmed.hasPrefix(":") {
            let model = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !model.isEmpty else { return nil }
            return ProviderBinding(providerId: currentProvider, model: model)
        }

        guard let binding = ProviderBinding.parse(trimmed) else { return nil }

        // Explicit, known provider (or eager validation off) → use as-is.
        if knownProviders.isEmpty || knownProviders[binding.providerId.lowercased()] != nil {
            return binding
        }

        // Bare token (no colon) that names a model of the CURRENT provider → switch model only.
        if binding.model == nil {
            let models = providerModels[currentProvider.lowercased()] ?? []
            if models.contains(where: { $0.lowercased() == binding.providerId.lowercased() }) {
                return ProviderBinding(providerId: currentProvider, model: binding.providerId)
            }
        }
        return nil
    }


    /// A leading "/" is a slash command ONLY when the first token is command-shaped —
    /// letters/digits/`-`/`_`, no path separators or dots. A dragged-in file path like
    /// `/Users/luke/untitled folder` or `/tmp/a.txt` is NOT a command (it falls through
    /// to the agent as a normal message). This is the screenshot bug: a folder drop was
    /// parsed as `/Users…` → "unknown command", blocking the message entirely.
    static func isSlashCommand(_ input: String) -> Bool {
        guard input.hasPrefix("/") else { return false }
        let name = input.dropFirst().prefix { $0 != " " }
        guard !name.isEmpty else { return false }   // a bare "/" is not a command
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }


    static func parseFleetArgs(_ args: String, defaultAgents: Int) -> FleetInvocation? {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fallbackAgents = max(1, defaultAgents)

        func parseAgentsAndGoal(_ rest: Substring) -> FleetInvocation? {
            let body = rest.trimmingCharacters(in: .whitespaces)
            let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let agents = Int(parts[0]), agents > 0 else { return nil }
            let goal = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !goal.isEmpty else { return nil }
            return FleetInvocation(goal: goal, agents: agents)
        }

        if trimmed == "--agents" { return nil }
        if trimmed.hasPrefix("--agents ") {
            return parseAgentsAndGoal(trimmed.dropFirst("--agents ".count))
        }
        if trimmed.hasPrefix("--agents=") {
            return parseAgentsAndGoal(trimmed.dropFirst("--agents=".count))
        }

        return FleetInvocation(goal: trimmed, agents: fallbackAgents)
    }


    struct CouncilInvocation: Equatable {
        let goal: String
        let execute: Bool
    }


    static func parseCouncilArgs(_ args: String) -> CouncilInvocation? {
        var trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var execute = false
        for flag in ["--execute", "--build", "--start"] {
            if trimmed == flag { return nil }
            if trimmed.hasPrefix(flag + " ") {
                execute = true
                trimmed = String(trimmed.dropFirst(flag.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        guard !trimmed.isEmpty else { return nil }
        return CouncilInvocation(goal: trimmed, execute: execute)
    }


    static func parseForgeIntent(_ input: String) -> String? {
        let original = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return nil }
        let normalized = original.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let lower = normalized.lowercased()
        let starters = [
            "make me an agent", "make an agent", "create an agent", "create a specialist",
            "create a persona", "forge an agent", "forge a specialist", "spin up an agent",
            "spin up a specialist", "build me an agent", "build an agent", "new agent",
            "make me a persona", "make a persona"
        ]
        guard let starter = starters.first(where: { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasPrefix($0 + ":") }) else {
            return nil
        }
        var desc = String(normalized.dropFirst(starter.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":,-"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["that can ", "that ", "who can ", "who ", "for ", "to "] where desc.lowercased().hasPrefix(prefix) {
            desc = String(desc.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return desc.count >= 8 ? desc : nil
    }


    static func parseRoleCommand(_ args: String) -> RoleCommand? {
        let normalizedArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if let eq = normalizedArgs.firstIndex(of: "=") {
            let rolePart = String(normalizedArgs[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let bindingPart = String(normalizedArgs[normalizedArgs.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let role = parseRoleName(rolePart), let binding = ProviderBinding.parse(bindingPart) else { return nil }
            return .assign(role, binding)
        }

        let parts = normalizedArgs.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !parts.isEmpty else { return .show }
        if parts.count == 1 {
            switch parts[0].lowercased() {
            case "show", "list": return .show
            case "reset", "clear", "default", "defaults": return .reset
            case "profiles", "profile", "presets", "teams": return .profiles
            default: return nil
            }
        }

        var tokens = parts
        if tokens.first?.lowercased() == "set" { tokens.removeFirst() }
        if tokens.count == 2 {
            switch tokens[0].lowercased() {
            case "save": return .save(tokens[1])
            case "load", "use": return .load(tokens[1])
            case "delete", "remove", "rm": return .delete(tokens[1])
            default: break
            }
        }
        guard tokens.count == 2,
              let role = parseRoleName(tokens[0]),
              let binding = ProviderBinding.parse(tokens[1]) else { return nil }
        return .assign(role, binding)
    }


    static func parseRoleName(_ raw: String) -> AgentRole? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "planner", "plan": return .planner
        case "worker", "research", "researcher", "analyst": return .worker
        case "coder", "code", "builder", "build", "developer", "dev": return .coder
        case "critic", "review", "reviewer", "verify", "verifier", "judge": return .critic
        default: return nil
        }
    }


    static func isAffirmative(_ answer: String) -> Bool {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return a == "y" || a == "yes"
    }


    static func isAlways(_ answer: String) -> Bool {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return a == "a" || a == "all" || a == "always" || a == "yolo"
    }


    static func pasteConfirmationPrompt(attachment: MediaAttachment, provider: String) -> String {
        let bytes = attachment.inlineByteCount > 0 ? "\(attachment.inlineByteCount) bytes" : "provider file reference"
        return "Send clipboard \(attachment.kind.rawValue) (\(attachment.mimeType), \(bytes)) to \(provider) for vision analysis? [y/N/a] "
    }
}
