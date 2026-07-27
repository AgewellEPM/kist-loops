import Foundation

/// The concrete proof-of-work a stage produces. An artifact is only trusted once
/// the gate confirms the file physically exists on disk and is non-empty.
public struct Artifact: Codable, Sendable, Equatable {
    public let stage: AgentKind
    public let relativePath: String
    public let summary: String
    public var commitSHA: String?

    public init(stage: AgentKind, relativePath: String, summary: String, commitSHA: String? = nil) {
        self.stage = stage
        self.relativePath = relativePath
        self.summary = summary
        self.commitSHA = commitSHA
    }
}

/// Accumulated state threaded through the inner loop. Each stage's output becomes
/// the next stage's context — the assembly-line invariant.
public struct PipelineContext: Sendable {
    public let seedBrief: String
    public private(set) var artifacts: [Artifact]
    public private(set) var transcript: [String: String]  // stage.rawValue -> produced text

    public init(seedBrief: String) {
        self.seedBrief = seedBrief
        self.artifacts = []
        self.transcript = [:]
    }

    public mutating func record(_ artifact: Artifact, text: String) {
        artifacts.append(artifact)
        transcript[artifact.stage.rawValue] = text
    }

    public func text(for stage: AgentKind) -> String? { transcript[stage.rawValue] }

    /// Everything produced so far, formatted as context for the next agent's prompt.
    public var accumulatedContext: String {
        guard !artifacts.isEmpty else { return "No prior work. This is the first stage." }
        return artifacts.map { a in
            "## \(a.stage.displayName)\n\(transcript[a.stage.rawValue] ?? a.summary)"
        }.joined(separator: "\n\n")
    }
}
