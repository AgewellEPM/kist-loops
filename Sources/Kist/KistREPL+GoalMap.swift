import Foundation
import AgentCore

extension KistREPL {
    static func handleGoalMap(_ args: String, projectRoot: String,
                              sessionStartedAt: Date? = nil) -> String {
        let argument = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = Int(argument)
        guard argument.isEmpty || (id.map { $0 > 0 } ?? false) else {
            return "usage: /goalmap [task-id] — inspect the board without a model call"
        }
        do {
            let plan = try PlanGoalMap.load(projectRoot: projectRoot)
            return PlanGoalMap.render(plan, projectRoot: projectRoot,
                                      sessionStartedAt: sessionStartedAt, taskID: id)
        } catch {
            return "Goal map unavailable: \(error). The board was not changed."
        }
    }
}
