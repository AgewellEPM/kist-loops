import Foundation

/// Static checks for the shared Plan/Action/Test/Review board. This is deliberately advisory for
/// now: it surfaces missing proof and malformed cards without breaking older/simple workflows.
public enum PlanContractValidator {
    public struct Issue: Sendable, Equatable {
        public let taskId: Int
        public let field: String
        public let message: String
    }

    public static func validate(_ plan: Plan) -> [Issue] {
        plan.tasks.sorted(by: { $0.id < $1.id }).flatMap(validate)
    }

    public static func validate(_ task: PlanTask) -> [Issue] {
        var issues: [Issue] = []

        func add(_ field: String, _ message: String) {
            issues.append(Issue(taskId: task.id, field: field, message: message))
        }

        let needsContract = task.kind == .test || task.kind == .review || task.kind == .handoff
            || task.status == .done || !task.acceptance.isEmpty || !task.verification.isEmpty

        if needsContract && task.acceptance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("acceptance", "\(task.kind.label) task should define what done means")
        }
        if needsContract && task.verificationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("verification", "\(task.kind.label) task should define how acceptance will be checked")
        }
        if task.status == .done && task.evidence.isEmpty {
            add("evidence", "done task has no attached proof")
        }
        if task.kind == .test && !task.verificationText.lowercased().contains("test") {
            add("verification", "TEST task verification should name a test command/check")
        }
        return issues
    }

    public static func render(_ issues: [Issue]) -> String {
        guard !issues.isEmpty else { return "contract check: clean" }
        var out = "contract check: \(issues.count) issue\(issues.count == 1 ? "" : "s")\n"
        for i in issues {
            out += "  [\(i.taskId)] \(i.field): \(i.message)\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
