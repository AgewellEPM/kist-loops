import Foundation

/// What kind of project a workspace holds — drives Dockerfile + run-spec generation.
public enum ProjectKind: String, Sendable, Equatable, CaseIterable {
    case swift, node, python, staticSite, unknown

    public var displayName: String {
        switch self {
        case .swift: return "Swift package"
        case .node: return "Node.js app"
        case .python: return "Python app"
        case .staticSite: return "Static site"
        case .unknown: return "Unknown"
        }
    }
}

/// Detects a project's kind from marker files. Pure (filesystem read only).
public struct ProjectProber: Sendable {
    public init() {}

    public func probe(_ dir: URL) -> ProjectKind {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        if has("Package.swift") { return .swift }
        if has("package.json") { return .node }
        if has("requirements.txt") || has("pyproject.toml") { return .python }
        if has("index.html") { return .staticSite }
        return .unknown
    }
}
