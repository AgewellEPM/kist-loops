import Foundation

/// Read-only adapter over existing, timestamped research evidence. It never opens a mutable
/// ResearchRunStore, re-dates a report, or treats a search snippet as a fetched primary source.
enum AgentResearchRecall {
    struct Projection {
        var entries: [AgentMemoryEntry] = []
        var issues: [String] = []
    }

    static func load(project: BuilderWorkspaceRootIdentity, at now: Date) -> Projection {
        var result = Projection()
        do {
            let root = try ConfinedRoot(root: project.canonicalPath, readOnly: true)
            let directory = ".kist/research-runs"
            let directories: [(name: String, isDir: Bool)]
            do { directories = try root.entries(directory).filter(\.isDir) }
            catch ToolError.notFound { return result }
            let selected = directories.sorted { $0.name > $1.name }.prefix(128)
            if directories.count > selected.count {
                result.issues.append("research recall scanned 128 of \(directories.count) run directories; inspect .kist/research-runs for older evidence")
            }
            var remainingBytes = 8 * 1_024 * 1_024
            for entry in selected {
                let base = directory + "/" + entry.name
                do {
                    guard (try? ResearchRunStore.validRunID(entry.name)) == entry.name else { continue }
                    let manifest = try JSONDecoder().decode(ResearchRunManifest.self,
                        from: root.readStableData(base + "/manifest.json", maxBytes: 64_000))
                    guard manifest.runID == entry.name, manifest.projectRoot == project.canonicalPath,
                          manifest.createdAt.isFinite, manifest.updatedAt.isFinite,
                          manifest.createdAt > 0, manifest.updatedAt >= manifest.createdAt else {
                        result.issues.append("invalid research manifest: \(base)"); continue
                    }
                    guard remainingBytes > 0 else {
                        result.issues.append("research recall byte budget reached; remaining runs are unscanned"); break
                    }
                    let evidence: Data
                    do { evidence = try root.readStableData(base + "/evidence.jsonl", maxBytes: min(2_097_152, remainingBytes)) }
                    catch ToolError.notFound { continue }
                    remainingBytes -= evidence.count
                    // A partial append is not a complete evidence snapshot.
                    guard evidence.isEmpty || evidence.last == 10 else {
                        result.issues.append("partial research evidence: \(base)"); continue
                    }
                    let lines = evidence.split(separator: 10, omittingEmptySubsequences: false)
                    for (ordinal, line) in lines.enumerated() where !line.isEmpty {
                        guard line.count <= 256_000,
                              let item = try? JSONDecoder().decode(ResearchEvidence.self, from: Data(line)),
                              item.sequence > 0, item.at.isFinite, item.at >= manifest.createdAt else {
                            result.issues.append("invalid research row: \(base):L\(ordinal + 1)"); continue
                        }
                        guard item.kind == "fetch_url" else { continue }
                        guard let primary = ResearchEvidencePolicy.verifiedPrimarySources(in: [item]).first else {
                            result.issues.append("unbound research fetch: \(base):L\(ordinal + 1)"); continue
                        }
                        guard let temporal = try? MemoryTemporalEnvelope(createdAt: Date(timeIntervalSince1970: item.at), decayRate: .fast),
                              temporal.evaluate(at: now).isRetrievalEligible,
                              temporal.evaluate(at: now).salience >= MemoryTemporalEnvelope.confidenceFloor else { continue }
                        result.entries.append(AgentMemoryEntry(
                            id: "research-\(entry.name)-\(item.id)",
                            title: "Fetched research: \(primary.title) · \(Date(timeIntervalSince1970: item.at).ISO8601Format())",
                            text: "URL: \(primary.url)\nContent SHA-256: \(primary.contentSHA256)\n" + primary.text,
                            locator: project.canonicalPath + "/" + base + "/evidence.jsonl:L\(ordinal + 1)",
                            observedAt: Date(timeIntervalSince1970: item.at),
                            provenanceHint: .researchEvidence))
                    }
                } catch { result.issues.append("research recall unavailable for \(base): \(error)") }
            }
        } catch { result.issues.append("research recall unavailable: \(error)") }
        result.issues = Array(result.issues.prefix(16))
        return result
    }
}
