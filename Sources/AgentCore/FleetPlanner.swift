import Foundation

/// Decomposes a build goal into DISJOINT, parallelizable subtasks — the upstream half of the fleet
/// launch (the orchestrator then VALIDATES the proposed scopes into a trustworthy disjoint lease). Asks
/// the PLANNER-role vendor for a JSON array of subtasks, each with its own file scope. The model is
/// ASKED, never trusted: the scope it proposes is validated (and over-broad/overlapping globs are
/// dropped) by `FleetScopeValidator` inside `CaptainOrchestrator.launchFleet`.
///
/// The PARSE is pure + tolerant (fences/prose stripped) and unit-tested; the model CALL is a thin wrapper.
/// Ported in spirit from TinkySDR's AgentPlanner (Stage 2, last mile). LABEL: PROTOTYPE.
public struct FleetPlanner: Sendable {
    private let providers: ProviderRegistry
    private let binding: ProviderBinding

    public init(providers: ProviderRegistry, binding: ProviderBinding) {
        self.providers = providers; self.binding = binding
    }

    /// Decompose `goal` into at most `maxAgents` disjoint subtasks, choosing scopes from `scopeContext`
    /// (the repo's real dir tree). Returns [] on any model/parse failure (the caller reports "no subtasks").
    public func plan(goal: String, scopeContext: String, maxAgents: Int,
                     budget: BudgetLedger? = nil, projectBrief: String? = nil,
                     repairFeedback: String? = nil) async -> [FleetSubtask] {
        // The planner call counts against the SAME fleet budget the workers draw from, so total fleet
        // spend ≈ --budget (not planning + N×budget). Halt before planning if the cap is already gone.
        if let budget, await budget.isExceeded() { return [] }
        let messages = [
            ChatMessage(role: .system, content: Self.systemPrompt),
            ChatMessage(role: .user, content: Self.userPrompt(goal: goal, scopeContext: scopeContext,
                                                               maxAgents: maxAgents,
                                                               projectBrief: projectBrief,
                                                               repairFeedback: repairFeedback)),
        ]
        let text: String
        do {
            text = try await providers.complete(providerId: binding.providerId, model: binding.model, messages: messages)
            // `complete` exposes no usage; account the planner call by estimate (tokens + $) so both
            // caps still bound it.
            let promptChars = messages.reduce(0) { $0 + $1.content.count }
            let est = TokenUsage.estimate(promptChars: promptChars, completionChars: text.count)
            let usd = CompetitiveBenchmark.priceUSD(vendor: binding.providerId,
                                                    promptTokens: est.promptTokens,
                                                    completionTokens: est.completionTokens) ?? 0
            await budget?.add(tokens: est.total, usd: usd)
        } catch {
            if ProcessInfo.processInfo.environment["MYTHOS_DEBUG"] != nil {
                FileHandle.standardError.write(Data("fleet-planner · provider error: \(error)\n".utf8))
            }
            return []
        }
        let subtasks = Array(Self.parse(text).prefix(max(1, maxAgents)))
        if subtasks.isEmpty, ProcessInfo.processInfo.environment["MYTHOS_DEBUG"] != nil {
            FileHandle.standardError.write(Data("fleet-planner · raw reply (\(text.count) chars):\n\(text.prefix(800))\n".utf8))
        }
        return subtasks
    }

    // MARK: - Prompt

    public static let systemPrompt = """
    You are the PLANNER for a parallel BUILD fleet. Split a goal into INDEPENDENT coding subtasks that \
    touch SEPARATE files/modules, so several agents work at the same time WITHOUT editing the same file. \
    Each subtask is one self-contained unit of work with a DISJOINT file scope.

    Captain operating order: Objective Received -> Captain -> Research -> Research Plan -> Research Checklist \
    -> Knowledge Gap Analysis -> Become Subject Matter Expert -> Execution Plan -> Assemble Existing Specialists \
    -> Create New Specialists -> Build -> Self Review -> Independent AI Review -> Cross Compare -> Benchmarks \
    -> Evidence -> Accept or Reject -> Retrospective -> Knowledge Gained -> Knowledge Debt -> Research Queue \
    -> Platform Evolution -> Memory -> Ready For Next Objective.
    Captain rules: never build before researching; never research without a plan; never plan without understanding; \
    never execute without evidence; never trust one AI; always seek independent review; always compare against \
    industry standards, competitors, papers, and open source; always identify knowledge gaps; always leave the \
    organization smarter than before.
    Do not jump straight to workers when the objective is under-understood. If research/architecture discovery \
    is needed, make the first subtask a bounded evidence/architecture brief with a real non-overlapping scope.

    Reply with ONLY a JSON array (no prose, no code fences). Each element:
    {
      "title": "short label",
      "intent": "what this agent must build, in 1-2 sentences",
      "scopeGlobs": ["Dir/*"],            // its file lease — directories from the provided tree; keep DISJOINT from siblings
      "acceptanceCriterion": "the testable done-condition (the agent must add a test proving it)"
    }
    Rules: scopes MUST NOT overlap between subtasks; prefer one directory subtree per agent; if the goal \
    is small, return ONE subtask; never invent directories not in the tree.
    """

    public static func userPrompt(goal: String, scopeContext: String, maxAgents: Int,
                                  projectBrief: String? = nil, repairFeedback: String? = nil) -> String {
        """
        GOAL: \(goal)

        \(projectBrief.map { $0 + "\n" } ?? "")
        \(repairFeedback.map { "PREVIOUS PLAN WAS REJECTED BY THE CAPTAIN GATE:\n\($0)\nReturn a repaired plan with real, non-overlapping, non-empty scopes for every parallel agent.\n" } ?? "")
        REPO DIRECTORIES (choose scopes from these; scope to a real subtree):
        \(scopeContext.isEmpty ? "(none discovered — use a single subtask with an empty scope)" : scopeContext)

        Return AT MOST \(max(1, maxAgents)) disjoint subtasks as a JSON array.
        """
    }

    // MARK: - Tolerant parse (pure, unit-tested)

    /// Parse the model's reply into subtasks. Tolerant: strips ``` fences and any prose around the JSON
    /// array, accepts missing optional fields, and skips elements with no usable intent/title.
    public static func parse(_ raw: String) -> [FleetSubtask] {
        guard let jsonData = extractJSONArray(raw)?.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else { return [] }
        return arr.compactMap { obj in
            func str(_ keys: String...) -> String {
                for k in keys {
                    if let v = (obj[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
                }
                return ""
            }
            // ALIAS-TOLERANT (real models vary the schema — a live openai run emitted {scope,action,file,
            // content} instead of our {title,intent,scopeGlobs,acceptanceCriterion}): intent ← intent|
            // action|description|task|summary|instruction, else "implement <file>". title ← title|name|
            // file, else a prefix of the intent.
            let file = str("file", "path", "filename")
            var intent = str("intent", "action", "description", "task", "summary", "instruction")
            if intent.isEmpty, !file.isEmpty { intent = "implement \(file)" }
            guard !intent.isEmpty else { return nil }
            let title: String = {
                let t = str("title", "name"); if !t.isEmpty { return t }
                if !file.isEmpty { return file }
                return String(intent.prefix(40))
            }()
            // scopeGlobs ← scopeGlobs[] | scope/dir/module (string) | the file's directory. Empty ⇒
            // validated to permissive downstream.
            var scopes = (obj["scopeGlobs"] as? [Any])?.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            if scopes.isEmpty {
                let scope = str("scope", "dir", "directory", "module")
                if !scope.isEmpty { scopes = [scope] }
                else if let slash = file.lastIndex(of: "/") { scopes = [String(file[..<slash]) + "/*"] }
            }
            let crit = str("acceptanceCriterion", "criterion", "acceptance", "test")
            return FleetSubtask(title: title, intent: intent, scopeGlobs: scopes, acceptanceCriterion: crit)
        }
    }

    /// Pull the first top-level JSON array `[ … ]` out of a reply that may carry code fences or prose.
    static func extractJSONArray(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a leading ```json / ``` fence and a trailing ```.
        var body = s
        if body.hasPrefix("```") {
            if let firstNL = body.firstIndex(of: "\n") { body = String(body[body.index(after: firstNL)...]) }
            if let fence = body.range(of: "```", options: .backwards) { body = String(body[..<fence.lowerBound]) }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let chars = Array(body)
        outer: for start in chars.indices where chars[start] == "[" {
            var depth = 0
            var inString = false
            var escaped = false
            for i in start..<chars.count {
                let ch = chars[i]
                if inString {
                    if escaped {
                        escaped = false
                    } else if ch == "\\" {
                        escaped = true
                    } else if ch == "\"" {
                        inString = false
                    }
                    continue
                }
                if ch == "\"" {
                    inString = true
                } else if ch == "[" {
                    depth += 1
                } else if ch == "]" {
                    depth -= 1
                    guard depth >= 0 else { continue outer }
                    if depth == 0 {
                        let candidate = String(chars[start...i])
                        guard let data = candidate.data(using: .utf8),
                              (try? JSONSerialization.jsonObject(with: data)) is [Any] else { continue outer }
                        return candidate
                    }
                }
            }
        }
        return nil
    }
}
