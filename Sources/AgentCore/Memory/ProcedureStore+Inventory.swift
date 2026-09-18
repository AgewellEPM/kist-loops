import Foundation

public struct ProcedureSearchResult: Sendable {
    public let procedures: [Procedure]
    public let issues: [String]
    public var complete: Bool { issues.isEmpty }
}

extension ProcedureStore {
    struct Inventory {
        var latest: [String: Procedure] = [:]
        var sourceDigests: [String: Set<String>] = [:]
        var invalidVersions: [String: Int] = [:]
        var issues: [String] = []
        var unavailable = false
    }

    private static func namedVersion(_ name: String) -> (id: String, version: Int)? {
        guard name.utf8.count == 29, name.hasSuffix(".json") else { return nil }
        let id = String(name.prefix(16))
        guard id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              name.dropFirst(16).hasPrefix("-v"),
              let version = Int(name.dropFirst(18).prefix(6)),
              fileName(id: id, version: version) == name else { return nil }
        return (id, version)
    }

    func inventory() -> Inventory {
        var result = Inventory()
        do {
            let confined = try ConfinedRoot(root: projectRoot, readOnly: true)
            let names: [String]
            do { names = try confined.entries(Self.directory).map(\.name).sorted() }
            catch ToolError.notFound { return result }
            guard names.count <= Self.maximumRecords else {
                result.issues = ["procedure inventory exceeds \(Self.maximumRecords) entries; retrieval is incomplete"]
                result.unavailable = true
                return result
            }
            var invalid = 0
            for name in names {
                guard let identity = Self.namedVersion(name) else {
                    invalid += 1
                    continue
                }
                guard let data = try? confined.readStableData(Self.directory + "/" + name,
                                                              maxBytes: Procedure.maximumRecordBytes),
                      let record = try? JSONDecoder().decode(Procedure.self, from: data),
                      record.id == identity.id, record.version == identity.version else {
                    invalid += 1
                    result.invalidVersions[identity.id] = max(result.invalidVersions[identity.id] ?? 0,
                                                              identity.version)
                    continue
                }
                result.sourceDigests[record.id, default: []].formUnion(
                    record.sources.map { BuilderEvidenceDigest.sha256($0) })
                if (result.latest[record.id]?.version ?? 0) < record.version {
                    result.latest[record.id] = record
                }
            }
            if invalid > 0 {
                result.issues.append("procedure inventory contains \(invalid) unreadable or invalid entries; retrieval is incomplete")
            }
            if try confined.entries(Self.directory).map(\.name).sorted() != names {
                result.issues.append("procedure inventory changed during retrieval; retry")
                result.unavailable = true
            }
        } catch {
            result.issues.append("procedure inventory unavailable: \(error)")
            result.unavailable = true
        }
        return result
    }

    /// A malformed newer record cannot make an older active version current again. Return
    /// degradation explicitly so the host can distinguish no matches from unavailable memory.
    public func retrieveWithIssues(applicability task: String, limit: Int = 10,
                                  at now: Date) -> ProcedureSearchResult {
        guard limit > 0 else { return ProcedureSearchResult(procedures: [], issues: []) }
        let snapshot = inventory()
        guard !snapshot.unavailable else {
            return ProcedureSearchResult(procedures: [], issues: snapshot.issues)
        }
        let eligible = snapshot.latest.values.filter {
            (snapshot.invalidVersions[$0.id] ?? 0) < $0.version
                && $0.temporal.evaluate(at: now).isRetrievalEligible
        }
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        let documents = eligible.map {
            LexicalSearch.Document(id: $0.id, title: $0.title + " " + $0.task,
                                   text: $0.keywords.joined(separator: " ") + "\n" + $0.steps)
        }
        let procedures = LexicalSearch.rank(documents, query: task, limit: limit)
            .compactMap { byID[$0.id] }
        return ProcedureSearchResult(procedures: procedures, issues: snapshot.issues)
    }
}
