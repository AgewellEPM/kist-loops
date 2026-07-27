import Foundation

public struct A2AAgentSkill: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let description: String

    public init(id: String, name: String, description: String) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct A2AAgentCard: Sendable, Codable, Equatable {
    public let name: String
    public let description: String
    public let version: String
    public let url: String?
    public let skills: [A2AAgentSkill]

    public init(name: String, description: String, version: String = "0.1.0",
                url: String? = nil, skills: [A2AAgentSkill]) {
        self.name = name
        self.description = description
        self.version = version
        self.url = url
        self.skills = skills
    }

    public func jsonString(pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

public struct A2ATaskEnvelope: Sendable, Codable, Equatable {
    public let taskId: String
    public let goal: String
    public let role: String?
    public let createdAtEpoch: Double

    public init(taskId: String = UUID().uuidString, goal: String, role: String? = nil,
                createdAtEpoch: Double = Date().timeIntervalSince1970) {
        self.taskId = taskId
        self.goal = goal
        self.role = role
        self.createdAtEpoch = createdAtEpoch
    }
}

public enum KistA2A {
    public static func agentCard(version: String = "0.1.0", url: String? = nil) -> A2AAgentCard {
        A2AAgentCard(
            name: "Kist / Mythos",
            description: "Local-first, provider-agnostic coding agent runtime with MCP tools, role-bound model teams, fleet supervision, evals, and computer-control verification.",
            version: version,
            url: url,
            skills: [
                A2AAgentSkill(id: "chat-build", name: "Conversational Build",
                              description: "Discuss, inspect, edit, test, and summarize work in one terminal conversation."),
                A2AAgentSkill(id: "plan-execute", name: "Plan Execute",
                              description: "Create a typed plan DAG, execute it with role-bound models, and verify the result."),
                A2AAgentSkill(id: "fleet", name: "Supervised Fleet",
                              description: "Split work into disjoint leases, run isolated agents, verify, sign, and join only trusted branches."),
                A2AAgentSkill(id: "council", name: "AI Council",
                              description: "Run research, architecture, coder, critic, UX, and memory minds before producing a task graph."),
                A2AAgentSkill(id: "computer-verify", name: "Computer Verification",
                              description: "Use browser/computer-control/MCP app testing tools to verify behavior, not just code diffs."),
            ]
        )
    }
}
