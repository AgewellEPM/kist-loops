import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Rebuildable lexical acceleration for immutable raw history. Indexes never carry
/// authority: every returned hit is read and checked against its original archive bytes.
/// Cache clocks only invalidate derived data; event clocks always come from the archive.
struct AgentHistoryIndex {
    let source: AgentHistoryStore
    let cacheProject: BuilderWorkspaceRootIdentity
    var maximumRecords = 30_000
    var maximumBuildReads = 10_000
    var maximumCandidateReads = 1_000
    var buildSeconds: TimeInterval = 5
    static let maximumShardBytes = 4_000_000

    struct Search {
        let page: AgentHistoryStore.Page
        let indexedRecords: Int
        let issues: [String]
        var retryRequired = false
        var projects: [BuilderWorkspaceRootIdentity] = []
        var authorizedProjectCount = 1
        var complete: Bool { issues.isEmpty && page.nextCursor == nil && page.rejected == 0 }
    }
    private struct Row: Codable {
        let id: String
        let digest: String?
        let terms: [String]
    }
    private struct Shard: Codable {
        let schema: Int
        let sourceStamp: String
        let rows: [Row]
    }

    func search(query: String, before: String? = nil, limit: Int = 100,
                runID: String? = nil, rootRunID: String? = nil,
                eligibleAt: Date? = nil, excludingRunID: String? = nil) throws -> Search {
        guard maximumRecords > 0, maximumBuildReads >= 0, maximumCandidateReads > 0,
              buildSeconds.isFinite, buildSeconds >= 0,
              try BuilderWorkspaceRootIdentity.capture(rootPath: source.project.canonicalPath) == source.project,
              try BuilderWorkspaceRootIdentity.capture(rootPath: cacheProject.canonicalPath) == cacheProject else {
            throw ToolError.configuration("history index limits or project identity changed")
        }
        let root = try ConfinedRoot(root: source.project.canonicalPath, readOnly: true)
        let names: [String]
        do {
            names = try root.entries(AgentHistoryStore.directory).filter {
                !$0.isDir && $0.name.hasSuffix(".json")
            }.map { String($0.name.dropLast(5)) }.sorted(by: >)
        } catch ToolError.notFound {
            return Search(page: .init(events: [], nextCursor: nil, scanned: 0, rejected: 0, total: 0),
                          indexedRecords: 0, issues: [])
        }
        let requested = LexicalSearch.queryTerms(query)
        guard !names.isEmpty, !requested.isEmpty else {
            return Search(page: .init(events: [], nextCursor: nil, scanned: 0, rejected: 0, total: names.count),
                          indexedRecords: 0, issues: [])
        }
        let directoryFD = try root.openPrivateDirectoryDescriptor(AgentHistoryStore.directory, create: false)
        defer { close(directoryFD) }
        let selected = Array(names.filter { before == nil || $0 < before! }.prefix(maximumRecords))
        var issues: [String] = []
        if names.filter({ before == nil || $0 < before! }).count > selected.count {
            issues.append("archive exceeds the indexed record window; continue with next_cursor")
        }
        let cache = try ConfinedRoot(root: cacheProject.canonicalPath)
        let identityEncoder = JSONEncoder(); identityEncoder.outputFormatting = [.sortedKeys]
        let identityData = try identityEncoder.encode(source.project)
        let cachePath = ".kist/cache/agent-history-index/v1/" + Self.digest(identityData)
        let cacheFD = try cache.openPrivateDirectoryDescriptor(cachePath, create: true)
        defer { close(cacheFD) }
        let buckets = Dictionary(grouping: selected) { id in
            Int(Self.digest(Data(id.utf8)).prefix(2), radix: 16)! % 64
        }
        let deadline = ProcessInfo.processInfo.systemUptime + buildSeconds
        var builtReads = 0, readCount = 0, indexed = 0, rejected = 0
        var retryRequired = false
        var candidates: [Row] = []
        let requireAll = query.split(whereSeparator: \.isWhitespace).count == 1
        for bucket in buckets.keys.sorted() {
            let ids = buckets[bucket]!
            let stamp = try Self.stamp(ids, directoryFD: directoryFD)
            let path = cachePath + "/\(bucket).json"
            var shard: Shard?
            do {
                let data = try cache.readStableOwnerOnlyData(path, maxBytes: Self.maximumShardBytes)
                let cached = try JSONDecoder().decode(Shard.self, from: data)
                if cached.schema == 1, cached.sourceStamp == stamp, cached.rows.map(\.id) == ids,
                   cached.rows.allSatisfy({ $0.terms.count <= 32_000 }) {
                    shard = cached
                }
            } catch ToolError.notFound { }
            catch { issues.append("index shard \(bucket) was unreadable; rebuilding from raw history") }
            if shard == nil {
                var rows: [Row] = []
                for id in ids {
                    guard builtReads < maximumBuildReads,
                          ProcessInfo.processInfo.systemUptime < deadline else { break }
                    builtReads += 1; readCount += 1
                    do {
                        let record = try source.read(id: id, root: root)
                        let tokens = Set(LexicalSearch.terms(Self.title(record.event) + " " + record.event.detail)).sorted()
                        rows.append(Row(id: id, digest: Self.digest(record.data), terms: tokens))
                    } catch { rows.append(Row(id: id, digest: nil, terms: [])) }
                }
                let candidate = Shard(schema: 1, sourceStamp: stamp, rows: rows)
                if rows.count == ids.count, try Self.stamp(ids, directoryFD: directoryFD) == stamp {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let data = try encoder.encode(candidate)
                    if data.count <= Self.maximumShardBytes {
                        try Self.writeCache(data, name: "\(bucket).json", directoryFD: cacheFD)
                        shard = candidate
                    } else {
                        issues.append("index shard \(bucket) exceeds its byte allowance; raw chronological history remains available")
                    }
                } else {
                    issues.append("index build is incomplete or source changed; repeat search to continue building")
                    retryRequired = true
                }
                // Partial freshly checked rows are still useful, with incompleteness disclosed.
                if shard == nil { shard = candidate }
            }
            for row in shard!.rows {
                if row.digest == nil { rejected += 1; continue }
                indexed += 1
                let matched = requested.intersection(row.terms).count
                if matched > 0, !requireAll || matched == requested.count {
                    // Keep only source references between shards, not every matching token array.
                    candidates.append(Row(id: row.id, digest: row.digest, terms: []))
                }
            }
        }
        candidates.sort { $0.id > $1.id }
        let chosen = Array(candidates.prefix(maximumCandidateReads))
        if candidates.count > chosen.count { issues.append("matching history exceeds the candidate window; continue with next_cursor") }
        var events: [AgentHistoryEvent] = []
        for row in chosen {
            readCount += 1
            do {
                let record = try source.read(id: row.id, root: root)
                guard Self.digest(record.data) == row.digest else {
                    issues.append("indexed source changed before hit revalidation"); continue
                }
                let event = record.event
                if let runID, event.agent.runID != runID { continue }
                if let rootRunID, event.agent.rootRunID != rootRunID { continue }
                if let excludingRunID, event.agent.runID == excludingRunID { continue }
                if let eligibleAt {
                    guard ["run_started", "tool_finished", "failed"].contains(event.kind),
                          let temporal = try? MemoryTemporalEnvelope(createdAt: event.at, decayRate: .medium),
                          temporal.evaluate(at: eligibleAt).isRetrievalEligible,
                          temporal.evaluate(at: eligibleAt).salience >= MemoryTemporalEnvelope.confidenceFloor else { continue }
                }
                events.append(event)
            } catch { rejected += 1 }
        }
        guard try BuilderWorkspaceRootIdentity.capture(rootPath: source.project.canonicalPath) == source.project,
              try BuilderWorkspaceRootIdentity.capture(rootPath: cacheProject.canonicalPath) == cacheProject else {
            throw ToolError.configuration("history project identity changed during search")
        }
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        let ranked = LexicalSearch.rank(events.map {
            .init(id: $0.id, title: Self.title($0), text: $0.detail)
        }, query: query, limit: max(1, min(100, limit))).compactMap { byID[$0.id] }
        if events.count > ranked.count { issues.append("search returns a ranked result window, not every matching event") }
        var next = selected.last.flatMap { last in names.contains { $0 < last } ? last : nil }
        if candidates.count > chosen.count { next = chosen.last?.id }
        return Search(page: .init(events: ranked, nextCursor: next, scanned: readCount,
                                  rejected: rejected, total: names.count), indexedRecords: indexed,
                      issues: Array(Set(issues)).sorted(), retryRequired: retryRequired)
    }

    private static func title(_ event: AgentHistoryEvent) -> String {
        [event.agent.role, event.kind, event.agent.runID, event.agent.parentRunID ?? "", event.agent.rootRunID]
            .joined(separator: " ")
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Private, atomic cache replacement. Concurrent rebuilds may replace each other's
    /// derived snapshot; the source stamp forces a refresh instead of treating it as authority.
    private static func writeCache(_ data: Data, name: String, directoryFD: Int32) throws {
        let temporary = ".index-\(UUID().uuidString)"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ToolError.execution("cannot create private history index cache") }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        guard fchmod(fd, 0o600) == 0 else { throw ToolError.execution("cannot protect history index cache") }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ToolError.execution("cannot write history index cache") }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, name) == 0,
              fsync(directoryFD) == 0 else { throw ToolError.execution("cannot publish history index cache") }
    }
    /// Includes inode/change time as well as modification time, preventing an ordinary
    /// content replacement with a restored mtime from reusing stale search terms.
    private static func stamp(_ ids: [String], directoryFD: Int32) throws -> String {
        var parts: [String] = []
        for id in ids {
            var info = stat()
            guard fstatat(directoryFD, id + ".json", &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ToolError.execution("history changed while indexing")
            }
            #if canImport(Darwin)
            let changed = "\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
            let modified = "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
            #else
            let changed = "\(info.st_ctim.tv_sec):\(info.st_ctim.tv_nsec)"
            let modified = "\(info.st_mtim.tv_sec):\(info.st_mtim.tv_nsec)"
            #endif
            parts.append("\(id):\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mode):\(info.st_uid):\(info.st_nlink):\(changed):\(modified)")
        }
        return digest(Data(parts.joined(separator: "\n").utf8))
    }
}
