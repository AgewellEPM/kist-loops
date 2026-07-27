import Foundation

/// Detects turns where the user means "Kist's own source", not the broad directory the REPL
/// was launched from. This is advisory prompt context only; it never changes the sandbox root.
struct SelfProjectResolver {
    static func promptContextIfNeeded(input: String,
                                      currentRoot: String,
                                      environment: [String: String] = ProcessInfo.processInfo.environment,
                                      fileManager: FileManager = .default) -> String? {
        guard let sourceRoot = sourceRootIfRequested(input: input,
                                                     currentRoot: currentRoot,
                                                     environment: environment,
                                                     fileManager: fileManager) else { return nil }
        return promptContext(sourceRoot: sourceRoot, currentRoot: currentRoot)
    }

    static func sourceRootIfRequested(input: String,
                                      currentRoot: String,
                                      environment: [String: String] = ProcessInfo.processInfo.environment,
                                      fileManager: FileManager = .default) -> String? {
        guard isSelfProjectRequest(input) else { return nil }
        return resolveKistSourceRoot(currentRoot: currentRoot,
                                     environment: environment,
                                     fileManager: fileManager)
    }

    static func promptContext(sourceRoot: String, currentRoot: String) -> String {
        let relative = projectRelative(sourceRoot, root: currentRoot)
        let rootNote = relative == sourceRoot
            ? "Kist source root: \(sourceRoot)"
            : "Kist source root: \(sourceRoot)\nRelative path from this session root: \(relative)"
        return """
        SELF PROJECT RESOLUTION
        The user is asking about Kist's own codebase. Do not treat the broad current directory as the project.
        \(rootNote)
        Start inspection inside that source root: Package.swift, Sources/Kist, Sources/AgentCore, and Tests.
        Prefer targeted searches within this Kist source root before asking which project the user meant.
        If the user explicitly gives another path or repository, follow the explicit path instead.
        """
    }

    static func isSelfProjectRequest(_ input: String) -> Bool {
        let lower = normalized(input)
        guard !lower.isEmpty else { return false }
        let exactSignals = [
            "your codebase", "your code base", "your source", "your sources",
            "your repo", "your repository", "your own code", "your own source",
            "your own repo", "kist codebase", "kist code base", "kist source",
            "kist sources", "kist repo", "kist repository", "kist project",
            "check yourself", "audit yourself", "review yourself"
        ]
        if exactSignals.contains(where: { lower.contains($0) }) {
            return true
        }
        let mentionsKist = lower.split(separator: " ").contains("kist")
        let mentionsCode = ["code", "source", "repo", "repository", "project", "implementation"]
            .contains { lower.contains($0) }
        return mentionsKist && mentionsCode
    }

    static func resolveKistSourceRoot(currentRoot: String,
                                      environment: [String: String] = ProcessInfo.processInfo.environment,
                                      fileManager: FileManager = .default) -> String? {
        for candidate in candidateRoots(currentRoot: currentRoot, environment: environment, fileManager: fileManager) {
            let resolved = canonicalPath(candidate)
            if looksLikeKistSourceRoot(resolved, fileManager: fileManager) {
                return resolved
            }
        }
        return nil
    }

    static func looksLikeKistSourceRoot(_ path: String, fileManager: FileManager = .default) -> Bool {
        let root = (path as NSString).expandingTildeInPath
        var isDir = ObjCBool(false)
        guard fileManager.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { return false }
        let required = [
            "Package.swift",
            "Sources/Kist/KistRunner.swift",
            "Sources/AgentCore/CaptainOrchestrator.swift",
            "Tests/KistTests/KistOptionsTests.swift",
        ]
        return required.allSatisfy {
            fileManager.fileExists(atPath: (root as NSString).appendingPathComponent($0))
        }
    }

    static func candidateRoots(currentRoot: String,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               fileManager: FileManager = .default) -> [String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        var candidates: [String] = []
        func add(_ path: String?) {
            guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            candidates.append(path)
        }

        add(environment["KIST_SOURCE_ROOT"])
        add(environment["KIST_PROJECT_ROOT"])
        add(currentRoot)
        for ancestor in ancestors(of: currentRoot) {
            add(ancestor)
        }

        let named = ["kist-loops", "kist", "Kist", "mythos-primitives"]
        let bases = [
            home,
            (home as NSString).appendingPathComponent("Downloads"),
            (home as NSString).appendingPathComponent("Developer"),
            (home as NSString).appendingPathComponent("Projects"),
            (home as NSString).appendingPathComponent("Code"),
            (home as NSString).appendingPathComponent("src"),
        ]
        for base in bases {
            for name in named {
                add((base as NSString).appendingPathComponent(name))
            }
        }

        // Bounded shallow scan of common project folders catches renamed checkouts without walking the
        // whole home directory during every prompt.
        for base in bases.dropFirst() where fileManager.fileExists(atPath: base) {
            let entries = (try? fileManager.contentsOfDirectory(atPath: base)) ?? []
            for entry in entries.prefix(200) {
                let path = (base as NSString).appendingPathComponent(entry)
                add(path)
            }
        }

        var seen = Set<String>()
        return candidates.compactMap { raw in
            let path = standardizedPath(raw)
            guard seen.insert(path).inserted else { return nil }
            return path
        }
    }

    private static func ancestors(of path: String) -> [String] {
        var out: [String] = []
        var current = standardizedPath(path)
        while current != "/" {
            current = (current as NSString).deletingLastPathComponent
            guard current != "/" && !current.isEmpty else { break }
            out.append(current)
        }
        return out
    }

    private static func normalized(_ input: String) -> String {
        input.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    private static func projectRelative(_ path: String, root: String) -> String {
        let cleanPath = canonicalPath(path)
        let cleanRoot = canonicalPath(root)
        if cleanPath == cleanRoot { return "." }
        if cleanPath.hasPrefix(cleanRoot + "/") {
            return String(cleanPath.dropFirst(cleanRoot.count + 1))
        }
        return cleanPath
    }

    private static func standardizedPath(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private static func canonicalPath(_ path: String) -> String {
        (standardizedPath(path) as NSString).resolvingSymlinksInPath
    }
}
