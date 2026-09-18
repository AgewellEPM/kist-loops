import Foundation
import AgentCore

extension KistRunner {
    private static let smlRecoveryConfigurationNames: Set<String> = [
        "authority.json", "catalog.json", "policy.json", "models.json", "retrieval.json",
        "http-auth.json", "mcp.json", "limits.json",
    ]
    private static let smlRecoveryFileLimit = 8 * 1_024 * 1_024
    private static let smlRecoveryTotalLimit = 64 * 1_024 * 1_024

    /// Capture the owner-held SML configuration together with the validated runtime. Credentials
    /// in http-auth.json stay inside the private backup. External provider keys, retrieval data,
    /// tool executables, and MCP servers remain independently provisioned host dependencies.
    static func captureSMLRecoveryFiles(project: URL, snapshot: SMLRuntimeSnapshot) throws -> [String: Data] {
        let root = try ConfinedRoot(root: project.path, readOnly: true)
        func readConfiguration() throws -> [String: Data] {
            var paths = smlRecoveryConfigurationNames.map { ".kist/sml/" + $0 }
            let endpoints = SMLHTTPEndpointRegistry.relativeDirectory
            if try root.fileType(endpoints).exists {
                paths += try root.entries(endpoints).filter { $0.name.hasSuffix(".json") }.map {
                    guard !$0.isDir, safeSMLRecoveryLeaf($0.name) else {
                        throw SMLRuntimeStoreError.io("invalid HTTP endpoint bundle path during backup")
                    }
                    return endpoints + "/" + $0.name
                }
            }
            guard paths.count <= 256 else { throw SMLRuntimeStoreError.io("too many SML recovery files") }
            var files: [String: Data] = [:]
            var bytes = 0
            for path in paths.sorted() {
                do {
                    let data = try root.readStableOwnerOnlyData(path, maxBytes: smlRecoveryFileLimit, permissions: 0o600)
                    bytes += data.count
                    guard bytes <= smlRecoveryTotalLimit else { throw SMLRuntimeStoreError.io("SML recovery files exceed 64 MiB") }
                    files[path] = data
                } catch ToolError.notFound { continue }
            }
            return files
        }
        var files = try readConfiguration()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let active = try snapshot.activeWorkflowVersions.keys.sorted().map { id -> SMLRuntimeWorkflowRecord in
            let key = SMLRuntimeSnapshot.workflowStorageKey(id: id, version: snapshot.activeWorkflowVersions[id]!)
            guard let record = snapshot.workflows[key] else { throw SMLRuntimeStoreError.io("active workflow is missing during backup") }
            return record
        }
        if !active.isEmpty {
            let digest = MythosCrypto.sha256(try encoder.encode(active)).map { String(format: "%02x", $0) }.joined()
            let base = ".kist/sml/recovery-sources/" + digest
            var sources: [SMLRuntimeHostSourceSetEntry] = []
            for (index, record) in active.enumerated() {
                let name = "workflow-\(index).json"
                files[base + "/" + name] = try encoder.encode(record.workflow)
                sources.append(SMLRuntimeHostSourceSetEntry(path: name, role: record.role))
            }
            files[base + "/source-set.json"] = try encoder.encode(SMLRuntimeHostSourceSet(sources: sources))
        }
        // Human configuration edits do not take the runtime lock. A second stable read must
        // match the captured set exactly, including added/removed endpoint bundles.
        let current = try readConfiguration()
        for (path, data) in current where files[path] != data {
            throw SMLRuntimeStoreError.io("SML host configuration changed during backup: \(path)")
        }
        guard current.count == files.keys.filter({ !$0.contains("/recovery-sources/") }).count else {
            throw SMLRuntimeStoreError.io("SML host configuration changed during backup")
        }
        try validateSMLRecoveryFiles(files)
        return files
    }

    /// Existing configurations must match: a runtime digest never authorizes replacing a newer
    /// host policy or credential. A fresh project can be populated and retried after interruption;
    /// runtime.json is published only after every recovery file is durably present.
    static func restoreSMLRecoveryFiles(_ files: [String: Data], project: URL, replacingRuntime: Bool) throws {
        try validateSMLRecoveryFiles(files)
        let root = try ConfinedRoot(root: project.path)
        var missing: [String] = []
        for path in files.keys.sorted() {
            do {
                let existing = try root.readStableOwnerOnlyData(path, maxBytes: smlRecoveryFileLimit, permissions: 0o600)
                guard existing == files[path] else {
                    throw SMLRuntimeStoreError.io("recovery file differs at \(path); restore into a fresh project or reconcile host configuration first")
                }
            } catch ToolError.notFound {
                if replacingRuntime && !path.contains("/recovery-sources/") {
                    throw SMLRuntimeStoreError.io("existing runtime lacks backed-up host configuration at \(path); restore into a fresh project")
                }
                missing.append(path)
            }
        }
        for path in missing {
            try root.createDataIfMissing(path, files[path]!, createParents: true)
        }
        for path in files.keys.sorted() {
            guard try root.readStableOwnerOnlyData(path, maxBytes: smlRecoveryFileLimit, permissions: 0o600) == files[path] else {
                throw SMLRuntimeStoreError.io("recovery file changed before runtime publication: \(path)")
            }
        }
    }

    private static func safeSMLRecoveryLeaf(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 192 && name.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }

    private static func validateSMLRecoveryFiles(_ files: [String: Data]) throws {
        guard files.count <= 512 else { throw SMLRuntimeStoreError.io("too many SML recovery files") }
        var total = 0
        for (path, data) in files {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            var allowed = parts.count == 3 && parts[0] == ".kist" && parts[1] == "sml"
                && smlRecoveryConfigurationNames.contains(parts[2])
            if parts.count == 4 && parts[0] == ".kist" && parts[1] == "sml" && parts[2] == "http-endpoints" {
                allowed = safeSMLRecoveryLeaf(parts[3]) && parts[3].hasSuffix(".json")
            }
            if parts.count == 5 && parts[0] == ".kist" && parts[1] == "sml" && parts[2] == "recovery-sources" {
                allowed = parts[3].count == 64 && parts[3].utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                    && safeSMLRecoveryLeaf(parts[4]) && parts[4].hasSuffix(".json")
            }
            total += data.count
            guard allowed, data.count <= smlRecoveryFileLimit, total <= smlRecoveryTotalLimit else {
                throw SMLRuntimeStoreError.io("invalid or oversized SML recovery file")
            }
        }
    }
}
