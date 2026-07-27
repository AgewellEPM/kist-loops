import Foundation

/// AGENTFORGE — the headline feature: turn a plain-English role description into a VALIDATED specialist
/// identity (name + when-to-use + system prompt + scoped tools + model), exactly like Claude Code's
/// "describe a role → generate the agent" flow. The model proposes; this code VALIDATES. An LLM is writing
/// another agent's permissions, so every output passes the trust spine below before it can become real.
///
/// TRUST SPINE (all enforced in pure `validate`, unit-pinned):
///  1. No privilege escalation — the generated tool allowlist is INTERSECTED with the spawner's `ceiling`;
///     a tool the ceiling lacks is DROPPED, never granted. (Same guarantee as `ToolRegistry.scoped`.)
///  2. Name is command-shaped — rejected (not sanitized) if it has path chars (the name is a filename).
///  3. Hallucinated-only tools fail closed — a non-empty request that intersects the ceiling to EMPTY is
///     an error, not a silently toolless agent.
///  4. source is forced to "forged" — provenance, never authority.
public struct AgentForge: Sendable {
    private let providers: ProviderRegistry
    private let roles: RoleBindings
    private let recorder: TraceRecorder?

    public init(providers: ProviderRegistry, roles: RoleBindings, recorder: TraceRecorder? = nil) {
        self.providers = providers; self.roles = roles; self.recorder = recorder
    }

    public enum ForgeError: Error, Equatable {
        case modelFailed(String)        // the generation call errored
        case unparseable(String)        // couldn't extract a candidate from the reply
        case invalidName(String)        // name not command-shaped
        case emptyField(String)         // description or system prompt missing
        case noUsableTools(String)      // requested tools all fell outside the ceiling
    }

    /// What the model proposes, before validation. `tools`: nil ⇒ ABSENT ("no preference" → inherit the
    /// bounded ceiling); `[]` ⇒ explicit empty (fail-closed, no tools); `[…]` ⇒ a requested subset.
    public struct ForgeCandidate: Equatable, Sendable {
        public var name: String
        public var description: String
        public var systemPrompt: String
        public var tools: [String]?
        public var modelSpec: String?
        public init(name: String, description: String, systemPrompt: String,
                    tools: [String]? = nil, modelSpec: String? = nil) {
            self.name = name; self.description = description; self.systemPrompt = systemPrompt
            self.tools = tools; self.modelSpec = modelSpec
        }
    }

    /// Forge a specialist from a NL description, bounded by the spawner's tool `ceiling`. Live (LLM) +
    /// FAIL-CLOSED. The generation is non-deterministic; the validation is not.
    public func forge(roleDescription: String, ceiling: [String]) async -> Result<SpecialistDefinition, ForgeError> {
        let binding = roles.binding(for: .planner)
        let prompt = Self.forgePrompt(roleDescription: roleDescription, ceiling: ceiling)
        let settings = ModelSettings(temperature: 0.1, maxTokens: 1200,
                                     systemPrompt: Self.systemPrompt, disableThinking: true)
        let started = Date()
        let text: String
        do {
            let (out, usage) = try await providers.completeWithUsage(
                providerId: binding.providerId, model: binding.model,
                messages: [ChatMessage(role: .user, content: prompt)], settings: settings)
            await record(binding: binding, usage: usage, promptChars: prompt.count,
                         completionChars: out.count, started: started, status: .ok)
            text = out
        } catch {
            await record(binding: binding, usage: .zero, promptChars: prompt.count,
                         completionChars: 0, started: started, status: .error)
            return .failure(.modelFailed("\(error)"))
        }
        guard let candidate = Self.parseCandidate(text) else {
            return .failure(.unparseable("no JSON object with name/description/systemPrompt in the reply"))
        }
        return Self.validate(candidate, ceiling: ceiling)
    }

    // MARK: - Pure, unit-tested core

    /// Extract a candidate from a model reply: strip ``` fences, take the first balanced `{…}`, decode JSON
    /// with tolerant key aliases. Returns nil if required fields are absent.
    public static func parseCandidate(_ text: String) -> ForgeCandidate? {
        guard let json = firstJSONObject(in: text),
              let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func str(_ keys: [String]) -> String? {
            for k in keys { if let v = obj[k] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty { return v } }
            return nil
        }
        guard let name = str(["name"]),
              let description = str(["description", "when", "whenToUse"]),
              let systemPrompt = str(["systemPrompt", "system_prompt", "prompt", "instructions", "body"])
        else { return nil }
        // tdistinguish ABSENT tools (nil) from PRESENT. A present `tools` that isn't an array of strings is
        // MALFORMED → reject the whole candidate (H2): never let `"tools":"rm_rf"` or `[{…}]` silently fall
        // through to "no preference" and inherit the full ceiling.
        let tools: [String]?
        if let raw = obj["tools"] {
            guard let arr = raw as? [Any] else { return nil }
            let strs = arr.compactMap { $0 as? String }
            guard strs.count == arr.count else { return nil }   // any non-string element → malformed
            tools = strs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            tools = nil                                          // absent
        }
        let modelSpec = str(["model"])
        return ForgeCandidate(name: name.trimmingCharacters(in: .whitespaces),
                              description: description.trimmingCharacters(in: .whitespaces),
                              systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                              tools: tools, modelSpec: modelSpec)
    }

    /// THE TRUST SPINE. Validate + bound a candidate into a real specialist, or fail closed.
    public static func validate(_ candidate: ForgeCandidate, ceiling: [String]) -> Result<SpecialistDefinition, ForgeError> {
        guard SpecialistDefinition.isValidName(candidate.name) else {
            return .failure(.invalidName("forged name '\(candidate.name)' is not command-shaped"))
        }
        guard !candidate.description.isEmpty else { return .failure(.emptyField("description")) }
        // Single-line invariant (H1): a description with a newline could inject a frontmatter fence.
        guard !candidate.description.contains(where: { $0.isNewline }) else {
            return .failure(.emptyField("description must be single-line (no newlines)"))
        }
        guard !candidate.systemPrompt.isEmpty else { return .failure(.emptyField("systemPrompt")) }

        // No-escalation. A forge ALWAYS yields an EXPLICIT allowlist (never nil/inherit-all):
        //   • absent (nil)      ⇒ snapshot the spawner's bounded ceiling (empty ceiling stays []),
        //   • explicit []       ⇒ fail-closed, no tools,
        //   • requested […]     ⇒ intersect with the ceiling; if that's empty ⇒ noUsableTools (hallucinated).
        let ceilingSet = Set(ceiling)
        let allowlist: [String]
        switch candidate.tools {
        case .none:
            allowlist = ceiling
        case .some(let requested) where requested.isEmpty:
            allowlist = []
        case .some(let requested):
            let scoped = requested.filter { ceilingSet.contains($0) }
            guard !scoped.isEmpty else {
                return .failure(.noUsableTools("requested tools \(requested) are all outside the ceiling \(ceiling)"))
            }
            allowlist = scoped
        }
        let model = candidate.modelSpec.flatMap { ProviderBinding.parse($0) }
        let def = SpecialistDefinition(name: candidate.name, description: candidate.description,
                                       systemPrompt: candidate.systemPrompt, toolAllowlist: allowlist,
                                       model: model, source: "forged")
        return def.isValid ? .success(def) : .failure(.emptyField("definition failed final validity check"))
    }

    /// First balanced top-level `{…}` in a string (after stripping code fences). STRING/ESCAPE-AWARE (L2):
    /// braces inside JSON string literals are ignored, so a `systemPrompt` value containing `{` or `}`
    /// can't terminate the scan early.
    static func firstJSONObject(in text: String) -> String? {
        let stripped = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let start = stripped.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < stripped.endIndex {
            let c = stripped[idx]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(stripped[start...idx]) }
            }
            idx = stripped.index(after: idx)
        }
        return nil
    }

    // MARK: - prompt

    static let systemPrompt = """
    You forge a single-responsibility AI specialist from a role description. Output ONLY a JSON object:
    {"name": "...", "description": "...", "systemPrompt": "...", "tools": ["..."], "model": "provider:model"}
    Rules: name is lowercase-hyphen (letters/digits/-/_ only). description is a "Use proactively when…"
    trigger so the runtime knows WHEN to delegate. systemPrompt is focused instructions for the specialist.
    tools MUST be chosen ONLY from the allowed tool list given — never invent a tool. Keep tools minimal
    (a reviewer needs no write tool). Omit "model" to inherit. No prose outside the JSON.
    """

    static func forgePrompt(roleDescription: String, ceiling: [String]) -> String {
        """
        Role description:
        \(roleDescription)

        Allowed tools (choose a MINIMAL subset; do not invent any):
        \(ceiling.isEmpty ? "(none — omit tools)" : ceiling.joined(separator: ", "))

        Output the specialist JSON object now.
        """
    }

    private func record(binding: ProviderBinding, usage: TokenUsage, promptChars: Int,
                        completionChars: Int, started: Date, status: SpanStatus) async {
        guard let recorder else { return }
        let measured = usage.isZero
            ? TokenUsage.estimate(promptChars: promptChars, completionChars: completionChars) : usage
        await recorder.record(AgentSpan(id: TraceID.make(), traceId: recorder.traceId, kind: .llmCall,
                                        role: "agent_forge", vendor: binding.providerId, model: binding.model,
                                        promptTokens: measured.promptTokens,
                                        completionTokens: measured.completionTokens,
                                        finishReason: nil, startedAt: started, endedAt: Date(), status: status))
    }
}
