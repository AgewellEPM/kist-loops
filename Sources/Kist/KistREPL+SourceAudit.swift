import Foundation
import AgentCore

// Self-codebase audit: intent detection, repair-seed heuristic, and Kist source-root
// resolution/validation helpers. Extracted verbatim from KistREPL.swift.
extension KistREPL {
    struct SelfCodebaseAuditRequest: Equatable {
        var projectRoot: String
        var seedRepairs: Bool
    }

    static func selfCodebaseAuditRequest(_ input: String,
                                         currentProjectRoot: String,
                                         environment: [String: String] = ProcessInfo.processInfo.environment) -> SelfCodebaseAuditRequest? {
        guard isSelfCodebaseAuditIntent(input) else { return nil }
        let current = ToolContext.canonicalize(currentProjectRoot) ?? currentProjectRoot
        if isKistSourceRoot(current) {
            return SelfCodebaseAuditRequest(projectRoot: current,
                                            seedRepairs: selfCodebaseAuditShouldSeedRepairs(input))
        }
        guard !isConcreteCodeProjectRoot(current) else { return nil }
        guard let root = resolveKistSourceRoot(currentProjectRoot: current, environment: environment) else {
            return nil
        }
        return SelfCodebaseAuditRequest(projectRoot: root,
                                        seedRepairs: selfCodebaseAuditShouldSeedRepairs(input))
    }

    static func isSelfCodebaseAuditIntent(_ input: String) -> Bool {
        let lower = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        let selfRefs = [
            "your codebase", "your code base", "your source", "your repo", "your repository",
            "your project", "your own code", "kist codebase", "kist source", "kist repo",
            "check yourself", "audit yourself", "self-test", "self test", "immune"
        ]
        guard selfRefs.contains(where: { lower.contains($0) }) else { return false }
        let auditWords = [
            "check", "chck", "audit", "review", "go through", "look through", "scan",
            "error", "errors", "bug", "bugs", "issue", "issues", "broken", "self-test",
            "self test", "immune", "fix", "repair", "heal"
        ]
        return auditWords.contains { lower.contains($0) }
    }

    static func selfCodebaseAuditShouldSeedRepairs(_ input: String) -> Bool {
        let lower = input.lowercased()
        let repairWords = ["fix", "repair", "heal", "patch", "apply", "resolve", "build it", "install"]
        return repairWords.contains { lower.contains($0) }
    }

    static func resolveKistSourceRoot(currentProjectRoot: String,
                                      environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let current = ToolContext.canonicalize(currentProjectRoot) ?? currentProjectRoot
        if isKistSourceRoot(current) { return current }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let envRoot = environment["KIST_SOURCE_ROOT"].flatMap { ToolContext.canonicalize($0) }
        var candidates = [
            envRoot,
            home + "/Downloads/kist-loops",
            home + "/kist-loops",
            home + "/Projects/kist-loops",
            home + "/Developer/kist-loops",
        ].compactMap { $0 }
        candidates.append(contentsOf: shallowKistSourceCandidates(in: home + "/Downloads"))
        candidates.append(contentsOf: shallowKistSourceCandidates(in: home))
        for candidate in uniquePaths(candidates) {
            if isKistSourceRoot(candidate) {
                return ToolContext.canonicalize(candidate) ?? candidate
            }
        }
        return nil
    }

    static func isKistSourceRoot(_ path: String) -> Bool {
        let root = ToolContext.canonicalize(path) ?? path
        let fm = FileManager.default
        return fm.fileExists(atPath: root + "/Package.swift")
            && fm.fileExists(atPath: root + "/Sources/Kist/KistREPL.swift")
            && fm.fileExists(atPath: root + "/Sources/AgentCore")
    }

    static func isConcreteCodeProjectRoot(_ path: String) -> Bool {
        let root = ToolContext.canonicalize(path) ?? path
        let fm = FileManager.default
        let markers = ["Package.swift", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "deno.json"]
        if markers.contains(where: { fm.fileExists(atPath: root + "/" + $0) }) { return true }
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return false }
        return names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    static func shallowKistSourceCandidates(in directory: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return names
            .filter { name in
                let lower = name.lowercased()
                return lower.contains("kist") || lower.contains("mythos")
            }
            .map { (directory as NSString).appendingPathComponent($0) }
    }

    static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in paths {
            let clean = ToolContext.canonicalize(path) ?? path
            guard !seen.contains(clean) else { continue }
            seen.insert(clean)
            out.append(clean)
        }
        return out
    }
}
