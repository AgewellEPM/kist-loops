import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Discovery only: a catalog entry never grants access to its project. Each recall applies the
/// current host's read grants and rechecks the original physical directory identity. Entries carry
/// no freshness clock and no copied history; reopening a project cannot rejuvenate its events.
struct AgentMemoryProjectCatalog: Sendable {
    static let directory = "agent-memory-projects/v1"
    static let maximumEntries = 1_024
    let root: BuilderWorkspaceRootIdentity

    struct Record: Codable {
        let schema: Int
        let project: BuilderWorkspaceRootIdentity
    }

    init(rootPath: String) throws {
        root = try BuilderWorkspaceRootIdentity.capture(rootPath: rootPath)
        guard root.canonicalPath != "/" else { throw ToolError.configuration("invalid memory catalog root") }
    }

    private func confined() throws -> ConfinedRoot {
        guard try BuilderWorkspaceRootIdentity.capture(rootPath: root.canonicalPath) == root else {
            throw ToolError.configuration("memory catalog root identity changed")
        }
        return try ConfinedRoot(root: root.canonicalPath)
    }

    func register(_ project: BuilderWorkspaceRootIdentity) throws {
        guard project.canonicalPath != "/",
              try BuilderWorkspaceRootIdentity.capture(rootPath: project.canonicalPath) == project else {
            throw ToolError.configuration("memory catalog project identity changed")
        }
        let root = try confined()
        let fd = try root.openPrivateDirectoryDescriptor(Self.directory, create: true)
        defer { close(fd) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Record(schema: 1, project: project))
        let name = BuilderEvidenceDigest.sha256(String(decoding: data, as: UTF8.self)) + ".json"
        _ = try root.createDataIfMissing(Self.directory + "/" + name, data, createParents: false)
    }

    func load() throws -> (projects: [BuilderWorkspaceRootIdentity], issues: [String]) {
        let root = try confined()
        let names: [String]
        do { names = try root.entries(Self.directory).filter { !$0.isDir && $0.name.hasSuffix(".json") }.map(\.name) }
        catch ToolError.notFound { return ([], []) }
        var projects: [BuilderWorkspaceRootIdentity] = [], rejected = 0
        let fd = try root.openPrivateDirectoryDescriptor(Self.directory, create: false)
        defer { close(fd) }
        for name in names.prefix(Self.maximumEntries) {
            do {
                let data = try root.readStableOwnerOnlyData(Self.directory + "/" + name, maxBytes: 16_000)
                let record = try JSONDecoder().decode(Record.self, from: data)
                guard record.schema == 1, record.project.canonicalPath.hasPrefix("/"),
                      record.project.canonicalPath != "/",
                      name == BuilderEvidenceDigest.sha256(String(decoding: data, as: UTF8.self)) + ".json" else {
                    throw ToolError.configuration("invalid memory catalog entry")
                }
                projects.append(record.project)
            } catch { rejected += 1 }
        }
        var issues: [String] = []
        if rejected > 0 { issues.append("memory project catalog rejected \(rejected) invalid entries") }
        if names.count > Self.maximumEntries {
            issues.append("memory project catalog exceeds its discovery window; select an explicit authorized project")
        }
        return (projects, issues)
    }
}
