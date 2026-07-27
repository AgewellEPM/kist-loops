import Foundation

/// The specialist stages of the assembly line. The Coordinator is intentionally
/// absent — the loop itself is the coordinator; there is no agent that merely
/// narrates. Each kind maps to exactly one artifact it must produce.
public enum AgentKind: String, CaseIterable, Codable, Sendable {
    case uiDesigner
    case designAnalyst
    case developer
    case buildArchitect

    public var displayName: String {
        switch self {
        case .uiDesigner: return "UI Designer"
        case .designAnalyst: return "Design Analyst"
        case .developer: return "Developer"
        case .buildArchitect: return "Build Architect"
        }
    }

    /// Relative path (within the project workspace) of the artifact this stage
    /// must write. The trust gate verifies this file exists and is non-empty
    /// before the pipeline is allowed to advance.
    public var artifactPath: String {
        switch self {
        case .uiDesigner: return "design/analysis.md"
        case .designAnalyst: return "spec/features.md"
        case .developer: return "Sources/App/Generated.swift"
        case .buildArchitect: return "BUILD.md"
        }
    }
}
