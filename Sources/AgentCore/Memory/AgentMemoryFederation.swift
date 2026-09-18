import Foundation

extension AgentMemoryAccess {
    struct ProjectSelection {
        let projects: [BuilderWorkspaceRootIdentity]
        let issues: [String]
    }

    /// No filesystem crawl: discover only explicit roots and projects registered by the host.
    /// The catalog is advisory; authorization and physical identity are checked on every query.
    func selectedProjects(_ requested: String?) throws -> ProjectSelection {
        if requested != nil || scope != .user {
            return ProjectSelection(projects: [try selectedProject(requested)], issues: [])
        }
        guard try selectedProject(nil) == project else {
            throw ToolError.configuration("shared memory project identity changed")
        }
        var selected = [project], issues = catalogIssue.map { [$0] } ?? []
        var paths: Set<String> = [project.canonicalPath]
        let grants = authorizedRoots.filter { allowed in
            let stable = (try? BuilderWorkspaceRootIdentity.capture(rootPath: allowed.canonicalPath)) == allowed
            if !stable { issues.append("an authorized memory read root is unavailable or its identity changed") }
            return stable
        }
        for allowed in grants where paths.insert(allowed.canonicalPath).inserted { selected.append(allowed) }
        if let catalog {
            do {
                let loaded = try catalog.load()
                issues += loaded.issues
                for candidate in loaded.projects {
                    guard !paths.contains(candidate.canonicalPath), grants.contains(where: {
                        candidate.canonicalPath == $0.canonicalPath
                            || candidate.canonicalPath.hasPrefix($0.canonicalPath + "/")
                    }) else { continue }
                    guard (try? selectedProject(candidate.canonicalPath)) == candidate else {
                        issues.append("a cataloged authorized memory project is unavailable or its identity changed")
                        continue
                    }
                    paths.insert(candidate.canonicalPath); selected.append(candidate)
                }
            } catch { issues.append("memory project catalog unavailable: \(error)") }
        }
        selected = [project] + selected.dropFirst().sorted { $0.canonicalPath < $1.canonicalPath }
        return ProjectSelection(projects: selected, issues: Array(Set(issues)).sorted())
    }

    private struct Cursor: Codable {
        let binding: String
        var offset: Int
        var before: [String?]
        var finished: [Bool]
        var degraded: Bool
    }
    private struct CursorBinding: Encodable {
        let projects: [BuilderWorkspaceRootIdentity]
        let query: String
        let runID: String?
        let scope: String
        let rootRunID: String?
        let excludingRunID: String?
        let eligibleOnly: Bool
    }
    private static let cursorPrefix = "shared1:"
    static let projectsPerSearch = 8

    func searchHistory(query: String, project requested: String? = nil, before: String? = nil,
                       limit: Int = 100, runID: String? = nil, eligibleAt: Date? = nil) throws -> AgentHistoryIndex.Search {
        let selection = try selectedProjects(requested)
        let projects = selection.projects
        let rootRun = scope == .local ? AgentExecutionScope.current?.rootRunID ?? "unbound-local" : nil
        let excluded = eligibleAt == nil ? nil : AgentExecutionScope.current?.runID
        // Preserve existing explicit-project cursors and the cost of ordinary one-project searches.
        if projects.count == 1, before?.hasPrefix(Self.cursorPrefix) != true {
            let result = try searchProjectHistory(projects[0], query: query, before: before, limit: limit,
                runID: runID, rootRun: rootRun, eligibleAt: eligibleAt, excluded: excluded)
            return AgentHistoryIndex.Search(page: result.page, indexedRecords: result.indexedRecords,
                issues: selection.issues + result.issues, retryRequired: result.retryRequired,
                projects: projects, authorizedProjectCount: projects.count)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bindingData = try encoder.encode(CursorBinding(projects: projects, query: query, runID: runID,
            scope: scope.rawValue, rootRunID: rootRun, excludingRunID: excluded, eligibleOnly: eligibleAt != nil))
        let binding = BuilderEvidenceDigest.sha256(String(decoding: bindingData, as: UTF8.self))
        func fresh(_ offset: Int) -> Cursor {
            let count = min(Self.projectsPerSearch, projects.count - offset)
            return Cursor(binding: binding, offset: offset, before: Array(repeating: nil, count: count),
                          finished: Array(repeating: false, count: count), degraded: false)
        }
        var cursor = fresh(0)
        if let before {
            guard before.utf8.count <= 4_096, before.hasPrefix(Self.cursorPrefix),
                  let data = Data(base64Encoded: String(before.dropFirst(Self.cursorPrefix.count))),
                  let decoded = try? JSONDecoder().decode(Cursor.self, from: data),
                  decoded.binding == binding, decoded.offset >= 0, decoded.offset < projects.count,
                  decoded.offset % Self.projectsPerSearch == 0,
                  decoded.before.count == min(Self.projectsPerSearch, projects.count - decoded.offset),
                  decoded.finished.count == decoded.before.count,
                  decoded.before.allSatisfy({ $0 == nil || $0!.utf8.count <= 100 }) else {
                throw ToolError.configuration("shared memory cursor does not match this query and authorized project set; restart the search")
            }
            cursor = decoded
        }
        let group = Array(projects.dropFirst(cursor.offset).prefix(Self.projectsPerSearch))
        var events: [AgentHistoryEvent] = [], issues = selection.issues
        var scanned = 0, rejected = 0, indexed = 0, total = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        for (index, selected) in group.enumerated() where !cursor.finished[index] {
            do {
                let result = try searchProjectHistory(selected, query: query, before: cursor.before[index],
                    limit: limit, runID: runID, rootRun: rootRun, eligibleAt: eligibleAt, excluded: excluded,
                    buildReads: max(1, 10_000 / group.count), candidateReads: max(1, 1_000 / group.count),
                    buildSeconds: max(0, deadline - ProcessInfo.processInfo.systemUptime))
                events += result.page.events
                scanned += result.page.scanned; rejected += result.page.rejected
                indexed += result.indexedRecords; total += result.page.total
                issues += result.issues.map { selected.canonicalPath + ": " + $0 }
                cursor.degraded = cursor.degraded || result.page.rejected > 0
                    || (!result.issues.isEmpty && !result.retryRequired && result.page.nextCursor == nil)
                // A partial index build must retry the same source window; it cannot advance past
                // rows that were never indexed. Already-completed projects need no further reads.
                if !result.retryRequired {
                    cursor.before[index] = result.page.nextCursor
                    cursor.finished[index] = result.page.nextCursor == nil
                }
            } catch {
                issues.append(selected.canonicalPath + ": history unavailable: \(error)")
                cursor.finished[index] = true
                cursor.degraded = true
            }
        }
        if cursor.degraded { issues.append("this project search encountered rejected, unavailable or omitted history; completion is not exhaustive") }
        var next: String?
        if cursor.finished.allSatisfy({ $0 }), cursor.offset + group.count < projects.count {
            let degraded = cursor.degraded
            cursor = fresh(cursor.offset + group.count)
            cursor.degraded = degraded
        }
        if !cursor.finished.allSatisfy({ $0 }) {
            next = Self.cursorPrefix + (try encoder.encode(cursor)).base64EncodedString()
            issues.append("authorized project history has another bounded page; continue with next_cursor")
        }
        // Event IDs need only be unique inside a project. A copied ID in a distinct authorized
        // project must neither trap Dictionary construction nor discard the original provenance.
        let bySource = Dictionary(uniqueKeysWithValues: events.map { ($0.locator, $0) })
        let ranked = LexicalSearch.rank(events.map {
            .init(id: $0.locator, title: [$0.agent.role, $0.kind, $0.agent.runID,
                $0.agent.parentRunID ?? "", $0.agent.rootRunID].joined(separator: " "), text: $0.detail)
        }, query: query, limit: max(1, min(100, limit))).compactMap { bySource[$0.id] }
        if ranked.count < events.count {
            issues.append("shared search returns a ranked result window, not every matching event")
            cursor.degraded = true
            if next != nil { next = Self.cursorPrefix + (try encoder.encode(cursor)).base64EncodedString() }
        }
        return AgentHistoryIndex.Search(page: .init(events: ranked, nextCursor: next, scanned: scanned,
            rejected: rejected, total: total), indexedRecords: indexed, issues: Array(Set(issues)).sorted(),
            projects: group, authorizedProjectCount: projects.count)
    }

    private func searchProjectHistory(_ selected: BuilderWorkspaceRootIdentity, query: String, before: String?,
        limit: Int, runID: String?, rootRun: String?, eligibleAt: Date?, excluded: String?,
        buildReads: Int = 10_000, candidateReads: Int = 1_000, buildSeconds: TimeInterval = 5) throws -> AgentHistoryIndex.Search {
        guard try selectedProject(selected.canonicalPath) == selected else {
            throw ToolError.configuration("memory project identity changed before search")
        }
        let source = AgentHistoryStore(project: selected)
        do {
            var index = AgentHistoryIndex(source: source, cacheProject: project)
            index.maximumBuildReads = buildReads; index.maximumCandidateReads = candidateReads
            index.buildSeconds = buildSeconds
            let result = try index.search(query: query, before: before, limit: limit, runID: runID,
                rootRunID: rootRun, eligibleAt: eligibleAt, excludingRunID: excluded)
            guard try selectedProject(selected.canonicalPath) == selected else {
                throw ToolError.configuration("authorized memory root changed during search")
            }
            return result
        } catch {
            guard try selectedProject(selected.canonicalPath) == selected else { throw error }
            let page = try source.page(before: before, limit: candidateReads, runID: runID, rootRunID: rootRun)
            return AgentHistoryIndex.Search(page: page, indexedRecords: 0,
                issues: ["history index unavailable; searched at most \(candidateReads) raw records: \(error)"])
        }
    }
}
