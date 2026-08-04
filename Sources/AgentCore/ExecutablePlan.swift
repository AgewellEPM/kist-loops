import Foundation

/// A single node in an executable plan DAG. Unlike a prose plan, this is a typed, runnable artifact:
/// the scheduler runs each step's `tool` with `argumentsJSON`, in dependency order, feeding earlier
/// step outputs into later steps via `${id}` references (ReWOO-style chaining — steps compose
/// WITHOUT re-invoking the planner).
public struct PlanStep: Sendable, Codable, Equatable {
    /// Unique within the plan (e.g. "E1"). Referenced by other steps as `${E1}`.
    public let id: String
    /// One-line human description of what this step accomplishes.
    public let intent: String
    /// The tool to run.
    public let tool: String
    /// Tool arguments as a JSON object string. String values may contain `${otherId}` placeholders
    /// that resolve to that step's output at run time (kept as a string, like `ToolCallRef`).
    public let argumentsJSON: String
    /// Explicit predecessor step ids. The EFFECTIVE dependencies are these UNION any `${id}` refs
    /// found in `argumentsJSON` — so a step that uses another's output is ordered after it even if
    /// `dependsOn` is omitted.
    public let dependsOn: [String]
    /// Which role/agent owns this step (planner/worker/coder/critic). Optional now; the seam for
    /// vendor-per-role multi-agent execution in a later phase.
    public let ownerRole: String?

    public init(id: String, intent: String, tool: String, argumentsJSON: String = "{}",
                dependsOn: [String] = [], ownerRole: String? = nil) {
        self.id = id; self.intent = intent; self.tool = tool
        self.argumentsJSON = argumentsJSON; self.dependsOn = dependsOn; self.ownerRole = ownerRole
    }
}

/// A typed, executable plan: a goal + a DAG of steps. Produced by the planner (parsed from the
/// model), validated, frozen on approval, then run by the scheduler. Codable so it can be
/// checkpointed/resumed like the rest of the loop state.
public struct ExecutablePlan: Sendable, Codable, Equatable {
    public let goal: String
    public let steps: [PlanStep]

    public init(goal: String, steps: [PlanStep]) {
        self.goal = goal; self.steps = steps
    }

    // MARK: - Variable references

    /// The pattern for an inter-step output reference. `${id}` = the whole output of step `id`;
    /// `${id.field.sub}` = a dotted path into `id`'s output parsed as JSON, so a step can chain a
    /// FIELD of a structured MCP tool result (e.g. `${E1.qmp}` after a vm_launch). Group 1 = id,
    /// group 2 = optional dotted field path.
    static let refPattern = try! NSRegularExpression(pattern: #"\$\{([A-Za-z0-9_-]+)(?:\.([A-Za-z0-9_.-]+))?\}"#)

    /// Step ids referenced via `${id}` / `${id.field}` inside a step's argumentsJSON (base id only,
    /// so dependency detection is unchanged by the optional field suffix).
    public static func referencedIds(in argumentsJSON: String) -> Set<String> {
        let range = NSRange(argumentsJSON.startIndex..., in: argumentsJSON)
        var ids = Set<String>()
        for m in refPattern.matches(in: argumentsJSON, range: range) {
            if let r = Range(m.range(at: 1), in: argumentsJSON) { ids.insert(String(argumentsJSON[r])) }
        }
        return ids
    }

    /// Effective dependencies of a step = explicit `dependsOn` ∪ `${id}` refs in its arguments.
    public func effectiveDependencies(of step: PlanStep) -> Set<String> {
        Set(step.dependsOn).union(Self.referencedIds(in: step.argumentsJSON))
    }

    /// Resolve a step's arguments against completed-step outputs: parse the JSON, then replace every
    /// `${id}` inside string values with `outputs[id]` (operating on PARSED values, not the raw JSON
    /// string, so substituted text can't break JSON escaping). Unknown refs resolve to "".
    public static func resolveArguments(_ argumentsJSON: String, outputs: [String: String]) -> [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return substitute(obj, outputs: outputs) as? [String: Any] ?? [:]
    }

    /// Recursively substitute `${id}` / `${id.field}` in every string value of a parsed JSON tree.
    private static func substitute(_ value: Any, outputs: [String: String]) -> Any {
        switch value {
        case let s as String:
            return substituteRefs(in: s, outputs: outputs)
        case let dict as [String: Any]:
            return dict.mapValues { substitute($0, outputs: outputs) }
        case let arr as [Any]:
            return arr.map { substitute($0, outputs: outputs) }
        default:
            return value
        }
    }

    /// Replace each `${id}` / `${id.field}` token in one string. Whole-ref → the step's raw output;
    /// field-ref → the dotted path resolved against that output parsed as JSON. Unresolved refs
    /// (unknown id, non-JSON output for a field-ref, missing field) become "" — the same fail-soft
    /// contract as before, so an unresolvable ref never leaks the literal `${...}` token downstream.
    private static func substituteRefs(in s: String, outputs: [String: String]) -> String {
        let ns = s as NSString
        let matches = refPattern.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var result = ""
        var cursor = 0
        for m in matches {
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let id = ns.substring(with: m.range(at: 1))
            let fieldRange = m.range(at: 2)
            if fieldRange.location != NSNotFound {
                result += extractField(from: outputs[id], path: ns.substring(with: fieldRange)) ?? ""
            } else {
                result += outputs[id] ?? ""
            }
            cursor = m.range.location + m.range.length
        }
        result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        return result
    }

    /// Resolve a dotted `path` into `json` (a step's output). Scalars stringify; a nested
    /// object/array re-serializes to compact JSON. nil if the output is absent/not-JSON or the path
    /// misses — the caller substitutes "" so a bad field-ref can't inject the literal token.
    private static func extractField(from json: String?, path: String) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var current: Any = root
        for component in path.split(separator: ".") {
            guard let dict = current as? [String: Any], let next = dict[String(component)] else { return nil }
            current = next
        }
        switch current {
        case let str as String: return str
        case let num as NSNumber: return num.stringValue
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: current),
                  let encoded = String(data: data, encoding: .utf8) else { return nil }
            return encoded
        }
    }
}

/// What can be wrong with a plan DAG. Collected by `validate()` so the planner can be told ALL the
/// problems at once (not one-at-a-time).
public enum PlanValidationError: Error, Equatable, Sendable {
    case empty                                   // no steps at all
    case duplicateId(String)
    case emptyTool(stepId: String)
    case unknownDependency(stepId: String, missing: String)
    case cycle(involving: [String])              // ids that form / feed a cycle (sorted)
}

public extension ExecutablePlan {
    /// Collect ALL validation problems (does not throw). Empty array ⇒ the plan is runnable.
    func validate() -> [PlanValidationError] {
        var errors: [PlanValidationError] = []
        if steps.isEmpty { errors.append(.empty); return errors }

        var seen = Set<String>()
        for s in steps {
            if seen.contains(s.id) { errors.append(.duplicateId(s.id)) }
            seen.insert(s.id)
            if s.tool.trimmingCharacters(in: .whitespaces).isEmpty { errors.append(.emptyTool(stepId: s.id)) }
        }
        // Dependency targets (explicit + ref) must exist.
        for s in steps {
            for dep in effectiveDependencies(of: s) where !seen.contains(dep) {
                errors.append(.unknownDependency(stepId: s.id, missing: dep))
            }
        }
        // Cycle detection (only meaningful when deps resolve) — Kahn's algorithm.
        if !errors.contains(where: { if case .unknownDependency = $0 { return true }; return false }),
           topologicalOrderIds() == nil {
            errors.append(.cycle(involving: cycleParticipants()))
        }
        return errors
    }

    /// Steps in a valid run order (each step after all its effective dependencies), or throws the
    /// first validation error. Stable: ties broken by the steps' original declaration order.
    func orderedSteps() throws -> [PlanStep] {
        if let first = validate().first { throw first }
        let order = topologicalOrderIds()!          // validate() guarantees this succeeds
        let byId = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0) })
        return order.map { byId[$0]! }
    }

    /// Kahn topological sort over effective dependencies → ordered ids, or nil if a cycle exists.
    /// Ready nodes are taken in original declaration order for determinism.
    private func topologicalOrderIds() -> [String]? {
        let order = steps.map { $0.id }
        var indegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]      // dep -> [steps that depend on it]
        for s in steps { indegree[s.id] = 0 }
        for s in steps {
            for dep in effectiveDependencies(of: s) where indegree[dep] != nil {
                indegree[s.id, default: 0] += 1
                dependents[dep, default: []].append(s.id)
            }
        }
        var ready = order.filter { indegree[$0] == 0 }
        var out: [String] = []
        while !ready.isEmpty {
            let n = ready.removeFirst()
            out.append(n)
            for m in dependents[n] ?? [] {
                indegree[m]! -= 1
                if indegree[m] == 0 { ready.append(m); ready.sort { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! } }
            }
        }
        return out.count == steps.count ? out : nil
    }

    /// The ids still carrying unmet in-degree after a topological pass — i.e. those in/feeding a cycle.
    private func cycleParticipants() -> [String] {
        var indegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]
        for s in steps { indegree[s.id] = 0 }
        for s in steps {
            for dep in effectiveDependencies(of: s) where indegree[dep] != nil {
                indegree[s.id, default: 0] += 1
                dependents[dep, default: []].append(s.id)
            }
        }
        var ready = steps.map { $0.id }.filter { indegree[$0] == 0 }
        var removed = Set<String>()
        while !ready.isEmpty {
            let n = ready.removeFirst(); removed.insert(n)
            for m in dependents[n] ?? [] { indegree[m]! -= 1; if indegree[m] == 0 { ready.append(m) } }
        }
        return steps.map { $0.id }.filter { !removed.contains($0) }.sorted()
    }
}
