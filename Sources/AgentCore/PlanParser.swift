import Foundation

/// Parses an `ExecutablePlan` out of a planner model's response. The planner is asked to emit a
/// single JSON object `{goal, steps:[{id,intent,tool,arguments,dependsOn}]}`; models drift on field
/// names and wrap JSON in prose/fences, so this is tolerant (like `ActionParser`): it extracts the
/// outermost JSON object and accepts common field aliases.
///
/// Returns nil when there's no parseable object or no steps — the caller then re-prompts the planner.
/// It does NOT validate the DAG; the caller runs `plan.validate()` and feeds errors back for a fix.
public enum PlanParser {

    public static func parse(_ raw: String) -> ExecutablePlan? {
        guard let json = ActionParser.extractJSONObject(raw),
              let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let goal = (obj["goal"] as? String) ?? (obj["objective"] as? String) ?? ""
        // Accept "steps" or "plan" as the step list.
        guard let rawSteps = (obj["steps"] as? [[String: Any]]) ?? (obj["plan"] as? [[String: Any]]),
              !rawSteps.isEmpty else { return nil }

        var steps: [PlanStep] = []
        var autoIndex = 0
        for s in rawSteps {
            autoIndex += 1
            // id: explicit, else synthesize a stable E<n> so a planner that omits ids still works.
            let id = (s["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "E\(autoIndex)"
            // tool / name — required; skip a malformed step rather than fail the whole plan.
            guard let tool = ((s["tool"] as? String) ?? (s["name"] as? String) ?? (s["action"] as? String)),
                  !tool.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let intent = (s["intent"] as? String) ?? (s["description"] as? String) ?? (s["goal"] as? String) ?? tool

            // arguments: object (serialize to a stable JSON string) OR already a string.
            let argumentsJSON: String
            if let argsObj = (s["arguments"] as? [String: Any]) ?? (s["args"] as? [String: Any]) ?? (s["parameters"] as? [String: Any]) ?? (s["input"] as? [String: Any]) {
                argumentsJSON = serialize(argsObj)
            } else if let argsStr = (s["arguments"] as? String) ?? (s["args"] as? String) {
                argumentsJSON = argsStr
            } else {
                argumentsJSON = "{}"
            }

            // dependsOn: array of ids under several spellings; tolerate a single string.
            let dependsOn = stringArray(s["dependsOn"] ?? s["depends_on"] ?? s["deps"] ?? s["after"])
            let ownerRole = (s["ownerRole"] as? String) ?? (s["role"] as? String) ?? (s["owner"] as? String)

            steps.append(PlanStep(id: id, intent: intent, tool: tool,
                                  argumentsJSON: argumentsJSON, dependsOn: dependsOn, ownerRole: ownerRole))
        }
        guard !steps.isEmpty else { return nil }
        return ExecutablePlan(goal: goal, steps: steps)
    }

    /// Stable JSON string for an arguments object (sorted keys → deterministic, testable).
    private static func serialize(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Coerce a JSON value into a [String] (accepts an array of strings, or a single string).
    private static func stringArray(_ value: Any?) -> [String] {
        if let arr = value as? [String] { return arr }
        if let arr = value as? [Any] { return arr.compactMap { $0 as? String } }
        if let s = value as? String, !s.isEmpty { return [s] }
        return []
    }
}
