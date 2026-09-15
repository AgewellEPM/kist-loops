import Foundation

/// Q5: the procedure type — a reinforced how-to. Distinct semantics from facts and episodes:
/// persistence GROWS with verified reuse (each reinforcement moves the decay anchor and adds a
/// reinforcement boost), decays by DISUSE (slow half-life anchored on the last verified
/// confirmation), is retrieved by APPLICABILITY to the current task, and is updated by
/// reinforcement or supersession — never silently overwritten.
public struct Procedure: Codable, Sendable, Equatable {
    public static let maximumTextUTF8Bytes = 16 * 1_024
    public static let maximumSources = 16
    public static let maximumRecordBytes = 64 * 1_024

    public let id: String
    public let version: Int
    public let title: String
    /// What task this procedure applies to — the retrieval key (applicability, not similarity
    /// to arbitrary queries).
    public let task: String
    public let steps: String
    public let keywords: [String]
    /// Required provenance references supplied by the host. A source string does not
    /// authenticate a receipt; this store only governs advisory relevance.
    public let sources: [String]
    public let temporal: MemoryTemporalEnvelope

    init?(id: String, version: Int, title: String, task: String, steps: String,
          sources: [String], temporal: MemoryTemporalEnvelope) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSteps = steps.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSources = sources.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard version >= 1, version <= ProcedureStore.maximumVersionsPerProcedure,
              id == Self.identity(title: cleanTitle, task: cleanTask),
              !cleanTitle.isEmpty, !cleanTask.isEmpty, !cleanSteps.isEmpty,
              !cleanSources.isEmpty, cleanSources.count <= Self.maximumSources,
              cleanTitle.utf8.count <= 512, cleanTask.utf8.count <= 1_024,
              cleanSteps.utf8.count <= Self.maximumTextUTF8Bytes,
              cleanSources.allSatisfy({ $0.utf8.count <= 1_024 }) else { return nil }
        self.id = id
        self.version = version
        self.title = cleanTitle
        self.task = cleanTask
        self.steps = SecretMasker.mask(cleanSteps)
        self.keywords = Lesson.extractKeywords(cleanTitle + " " + cleanTask)
        self.sources = cleanSources
        self.temporal = temporal
    }

    static func identity(title: String, task: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(BuilderEvidenceDigest.sha256(
            "\(title.utf8.count):\(title)\(task.utf8.count):\(task)").prefix(16))
    }

    public var relativePath: String {
        ProcedureStore.directory + "/" + ProcedureStore.fileName(id: id, version: version)
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, title, task, steps, keywords, sources, temporal
    }

    // Route every decoded record through the validating initializer so a hand-edited file
    // cannot smuggle in an empty source list, oversized text, or a forged keyword set.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let validated = Procedure(
            id: try values.decode(String.self, forKey: .id),
            version: try values.decode(Int.self, forKey: .version),
            title: try values.decode(String.self, forKey: .title),
            task: try values.decode(String.self, forKey: .task),
            steps: try values.decode(String.self, forKey: .steps),
            sources: try values.decode([String].self, forKey: .sources),
            temporal: try values.decode(MemoryTemporalEnvelope.self, forKey: .temporal)) else {
            throw ToolError.execution("stored procedure record failed validation")
        }
        self = validated
    }
}

/// Project-scoped procedure store using append-only versioned records: every deposit,
/// reinforcement, and supersession publishes a new immutable version file (no-replace), so the
/// full reinforcement history is itself an audit trail. Reads take the highest valid version
/// per procedure. Retrieval filters LIFECYCLE only — the admission gate owns the salience floor
/// (single enforcement point), which also lets a dormant procedure reactivate on context
/// recurrence like any other memory.
public struct ProcedureStore {
    public static let directory = ".kist/memory/procedures/v1"
    public static let maximumRecords = 4_096
    public static let maximumVersionsPerProcedure = 1_024
    public static let defaultDecay = MemoryDecayRate.slow

    let projectRoot: String

    public init(projectRoot: String) {
        self.projectRoot = projectRoot
    }

    static func fileName(id: String, version: Int) -> String {
        String(format: "%@-v%06d.json", id, version)
    }

    /// Create an advisory procedure with a host-supplied source reference. Returns it, or an issue
    /// string explaining the refusal — never a silent drop.
    public func deposit(title: String, task: String, steps: String, source: String,
                        at now: Date) -> (procedure: Procedure?, issue: String?) {
        let id = Procedure.identity(title: title, task: task)
        guard let envelope = try? MemoryTemporalEnvelope(createdAt: now, lastConfirmedAt: now,
                                                         decayRate: Self.defaultDecay),
              let procedure = Procedure(id: id, version: 1, title: title, task: task,
                                        steps: steps, sources: [source], temporal: envelope) else {
            return (nil, "procedure rejected: missing or oversized title/task/steps/source")
        }
        let snapshot = inventory()
        guard snapshot.issues.isEmpty else {
            return (nil, "procedure inventory is incomplete; resolve it before deposition")
        }
        if snapshot.latest[id] != nil {
            return (nil, "procedure already exists (\(id)); reinforce or supersede it instead")
        }
        return publish(procedure)
    }

    /// Record an externally verified reuse. The host must authenticate the source before calling;
    /// this store rejects blank and replayed references without granting completion authority.
    public func reinforce(id: String, verifiedSource: String,
                          at now: Date) -> (procedure: Procedure?, issue: String?) {
        let source = verifiedSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, source.utf8.count <= 1_024 else {
            return (nil, "reinforcement requires a bounded, nonempty new source")
        }
        let inventory = inventory()
        guard inventory.issues.isEmpty else {
            return (nil, "procedure version conflict or unreadable inventory; resolve it before reinforcement")
        }
        guard let current = inventory.latest[id] else { return (nil, "unknown procedure: \(id)") }
        guard inventory.sourceDigests[id]?.contains(BuilderEvidenceDigest.sha256(source)) != true else {
            return (nil, "reinforcement refused: source evidence was already recorded")
        }
        var envelope = current.temporal
        do { try envelope.reinforce(verified: true, confirmedAt: now, now: now) }
        catch { return (nil, "reinforcement refused: \(error)") }
        let sources = Array((current.sources + [source]).suffix(Procedure.maximumSources))
        guard let next = Procedure(id: id, version: current.version + 1, title: current.title,
                                   task: current.task, steps: current.steps, sources: sources,
                                   temporal: envelope) else {
            return (nil, "reinforcement rejected: invalid successor record")
        }
        return publish(next)
    }

    /// Retire a procedure in favor of a better one. The superseded version chain remains on
    /// disk as history; retrieval and the admission gate refuse it from now on.
    public func supersede(id: String, by replacementID: String,
                          at now: Date) -> (procedure: Procedure?, issue: String?) {
        guard let current = latest(id: id) else { return (nil, "unknown procedure: \(id)") }
        var envelope = current.temporal
        do { try envelope.markSuperseded(by: replacementID, now: now) }
        catch { return (nil, "supersession refused: \(error)") }
        guard let next = Procedure(id: id, version: current.version + 1, title: current.title,
                                   task: current.task, steps: current.steps,
                                   sources: current.sources, temporal: envelope) else {
            return (nil, "supersession rejected: invalid successor record")
        }
        return publish(next)
    }

    public func latest(id: String) -> Procedure? {
        // A forensic last-valid record can remain inspectable when a newer record is damaged.
        // Retrieval uses the inventory's stricter lifecycle and incompleteness checks.
        inventory().latest[id]
    }

    /// Applicability-ranked, lifecycle-eligible procedures. Deliberately does NOT apply the
    /// salience floor — that is the admission gate's decision, made once, with reactivation.
    public func retrieve(applicability task: String, limit: Int = 10, at now: Date) -> [Procedure] {
        retrieveWithIssues(applicability: task, limit: limit, at: now).procedures
    }

    private func publish(_ procedure: Procedure) -> (procedure: Procedure?, issue: String?) {
        guard procedure.version <= Self.maximumVersionsPerProcedure else {
            return (nil, "procedure version chain at capacity (\(procedure.id))")
        }
        do {
            let confined = try ConfinedRoot(root: projectRoot)
            let existing: Int
            do { existing = try confined.entries(Self.directory).count }
            catch ToolError.notFound { existing = 0 }
            guard existing < Self.maximumRecords else {
                return (nil, "procedure store at capacity (\(Self.maximumRecords) records); pruning required")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(procedure)
            guard data.count <= Procedure.maximumRecordBytes else {
                return (nil, "encoded procedure exceeds the bounded record size")
            }
            let path = Self.directory + "/" + Self.fileName(id: procedure.id, version: procedure.version)
            do {
                // `false` means identical bytes were already published (an idempotent concurrent
                // writer); different bytes under the same version name throw, which is a real
                // conflict — the original record is preserved, never replaced.
                _ = try confined.createDataIfMissing(path, data, createParents: true)
                return (procedure, nil)
            } catch {
                return (nil, "procedure version conflict for \(procedure.id); re-read and retry: \(error)")
            }
        } catch {
            return (nil, "procedure publication unavailable: \(error)")
        }
    }
}
