import Foundation

/// A pipeline is nothing more than an ordered subset of agents. Every recipe runs
/// through the same inner loop; the only difference is which stages are switched on.
public struct Pipeline: Codable, Sendable, Equatable {
    public let name: String
    public let agents: [AgentKind]

    public init(name: String, agents: [AgentKind]) {
        self.name = name
        self.agents = agents
    }

    public static let designOnly = Pipeline(name: "Design Enhancement Only", agents: [.uiDesigner])
    public static let designAndAnalysis = Pipeline(name: "Design + Feature Analysis", agents: [.uiDesigner, .designAnalyst])
    public static let analysisAndCode = Pipeline(name: "Analysis + Code Generation", agents: [.designAnalyst, .developer])
    public static let full = Pipeline(name: "Complete Pipeline", agents: [.uiDesigner, .designAnalyst, .developer, .buildArchitect])

    public static let all: [Pipeline] = [designOnly, designAndAnalysis, analysisAndCode, full]

    /// Resolve a pipeline by short key; defaults to the full assembly line.
    public static func named(_ key: String?) -> Pipeline {
        switch key?.lowercased() {
        case "design", "designonly": return .designOnly
        case "designanalysis", "design-analysis": return .designAndAnalysis
        case "analysiscode", "analysis-code", "code": return .analysisAndCode
        case "full", "complete", nil, "": return .full
        default: return .full
        }
    }
}
