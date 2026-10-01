import Foundation
import Crypto

/// Search width, not an instruction to launch additional agents or load additional models.
public struct PlanSearchPolicy: Sendable, Equatable {
    public let candidateLimit: Int
    public static let single = PlanSearchPolicy(candidateLimit: 1)
    public init(candidateLimit: Int = 2) {
        self.candidateLimit = min(4, max(1, candidateLimit))
    }

    var prompt: String {
        """

        BOUNDED PLAN SEARCH — output one JSON object {"candidates":[<plan>,<plan>]}.
        Each candidate uses the exact goal/steps schema above. Propose at most \(candidateLimit)
        materially different approaches, ranked best first for the user's goal and constraints.
        One candidate is enough when there is only one useful approach. Prefer the smallest
        evidence-gathering step when the environment is unknown; use its actual result to adapt.
        Compare cost, available tools, reversibility and concrete verification before choosing
        your ranking. Return only executable plans, not private deliberation or confidence scores.
        Use generate for bounded code/content tasks: it uses the separately bound coder model.
        Include the checks needed to prove the result. Imagined test results are not evidence.
        The host discards invalid and previously attempted plans, then executes ONLY the first
        eligible candidate through the existing permission and verification gates. Unselected
        candidates are discarded; failures require fresh planning against actual tool receipts.
        Never repeat a completed mutation or an unchanged failed plan. Do not relax permissions,
        checks or the goal to make a candidate pass. The same output and shared token caps apply
        to the whole candidate set; fewer concise candidates are better than truncated plans.
        """
    }

    struct Selection {
        let plan: ExecutablePlan?
        let json: String?
        let ordinal: Int?
        let considered: Int
        let findings: [String]
    }

    /// No model vote, confidence score or claimed test result is an acceptance signal.
    /// Only the first structurally eligible plan proceeds to the host's full preflight.
    func select(_ raw: String, tools: ToolRegistry, hostOwnedFinalReview: Bool,
                excluding: Set<String>) -> Selection {
        func rejected(_ reason: String) -> Selection {
            Selection(plan: nil, json: nil, ordinal: nil, considered: 0, findings: [reason])
        }
        guard raw.utf8.count <= 65_536,
              let json = ActionParser.extractJSONObject(raw), let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return rejected("Planner output must be a JSON object within 64 KiB.") }
        let candidates: [[String: Any]]
        if let value = object["candidates"] {
            guard let array = value as? [[String: Any]], !array.isEmpty,
                  array.count <= candidateLimit else {
                return rejected("candidates must contain 1...\(candidateLimit) complete plan objects.")
            }
            candidates = array
        } else {
            // Small local models may retain the single-plan format. It is still fully checked.
            candidates = [object]
        }
        var seen = excluding
        var findings: [String] = []
        for (index, candidate) in candidates.enumerated() {
            let label = "candidate \(index + 1)"
            guard let steps = candidate["steps"] as? [[String: Any]], !steps.isEmpty,
                  steps.count <= 24,
                  let data = try? JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8),
                  let plan = PlanParser.parse(json), plan.steps.count == steps.count else {
                findings.append("\(label): requires 1...24 complete steps; no malformed step may be dropped.")
                continue
            }
            var issues = plan.validate(hostOwnedFinalReview: hostOwnedFinalReview)
                .map { PlanExecuteLoop.describe([$0]) }
            issues += PlanLint.findings(for: plan)
            issues += PlanExecuteLoop.durablePlanPersistencePreflight(plan)
            for step in plan.steps {
                guard let tool = tools.tool(named: step.tool) else {
                    issues.append("unavailable tool: \(step.tool.prefix(80))"); continue
                }
                guard let bytes = step.argumentsJSON.data(using: .utf8),
                      let arguments = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
                else { issues.append("step arguments must be a JSON object"); continue }
                let canonical = tools.canonicalArguments(name: step.tool, arguments: arguments)
                if let issue = ToolGate.argumentValidationError(parameters: tool.parameters, arguments: canonical) {
                    issues.append("step \(step.id.prefix(80)): \(issue)")
                }
            }
            if !seen.insert(Self.fingerprint(plan)).inserted {
                issues.append("duplicate or previously attempted plan; use the actual failure evidence to change approach")
            }
            if issues.isEmpty {
                return Selection(plan: plan, json: json, ordinal: index + 1,
                                 considered: candidates.count, findings: findings)
            }
            findings.append("\(label): " + issues.prefix(4).joined(separator: "; "))
        }
        return Selection(plan: nil, json: nil, ordinal: nil,
                         considered: candidates.count, findings: findings)
    }

    /// Cosmetic IDs, intent text and argument key ordering do not make a failed plan new.
    static func fingerprint(_ plan: ExecutablePlan) -> String {
        var ids: [String: Int] = [:]
        for (index, step) in plan.steps.enumerated() { ids[step.id] = index }
        func normalize(_ value: Any) -> Any {
            if let string = value as? String {
                // Replace all references in one pass, avoiding collisions with generated IDs.
                guard let re = try? NSRegularExpression(pattern: #"\$\{([^}]+)\}"#) else { return string }
                var result = string
                for match in re.matches(in: string, range: NSRange(string.startIndex..., in: string)).reversed() {
                    guard let keyRange = Range(match.range(at: 1), in: string),
                          let index = ids[String(string[keyRange])],
                          let range = Range(match.range, in: result) else { continue }
                    result.replaceSubrange(range, with: "${step:\(index)}")
                }
                return result
            }
            if let array = value as? [Any] { return array.map(normalize) }
            if let object = value as? [String: Any] { return object.mapValues(normalize) }
            return value
        }
        let rows: [[String: Any]] = plan.steps.map { step in
            let args = step.argumentsJSON.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            return ["tool": step.tool, "arguments": normalize(args ?? step.argumentsJSON),
                    "dependencies": plan.effectiveDependencies(of: step).compactMap { ids[$0] }.sorted()]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
