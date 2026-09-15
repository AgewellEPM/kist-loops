import Foundation

/// Q5: the procedure type — a reinforced how-to. Distinct semantics from facts and episodes:
/// persistence GROWS with verified reuse (each reinforcement moves the decay anchor and adds a
/// reinforcement boost), decays by DISUSE (slow half-life anchored on the last verified
/// confirmation), is retrieved by APPLICABILITY to the current task, and is updated by
/// reinforcement or supersession — never silently overwritten.
public struct Procedure: Codable, Sendable, Equatable {
    public static let maximumTextUTF8Bytes = 16 * 1_024
    public static let maximumSources = 16

    public let id: String
    public let version: Int
    public let title: String
    /// What task this procedure applies to — the retrieval key (applicability, not similarity
    /// to arbitrary queries).
    public let task: String
    public let steps: String
    public let keywords: [String]
    /// Evidence locators (run ids, signoffs) this procedure was proven or re-proven by. A
    /// procedure without a source cannot exist — an unproven how-to is a guess, not memory.
    public let sources: [String]
    public let temporal: MemoryTemporalEnvelope

    init?(id: String, version: Int, title: String, task: String, steps: String,
          sources: [String], temporal: MemoryTemporalEnvelope) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSteps = steps.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSources = sources.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard version >= 1, !cleanTitle.isEmpty, !cleanTask.isEmpty, !cleanSteps.isEmpty,
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
        String(BuilderEvidenceDigest.sha256(
            "\(title.utf8.count):\(title)\(task.utf8.count):\(task)").prefix(16))
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

    private let projectRoot: String

    public init(projectRoot: String) {
        self.projectRoot = projectRoot
    }

    private static func fileName(id: String, version: Int) -> String {
        String(format: "%@-v%06d.json", id, version)
    }

    /// Create a new procedure proven by `source`. Returns the stored procedure, or an issue
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
        if latest(id: id) != nil {
            return (nil, "procedure already exists (\(id)); reinforce or supersede it instead")
        }
        return publish(procedure)
    }

    /// Record a verified re-use. Moves the decay anchor and increments the reinforcement count
    /// via the temporal kernel, which refuses unverified or retired/superseded reinforcement.
    public func reinforce(id: String, verifiedSource: String,
                          at now: Date) -> (procedure: Procedure?, issue: String?) {
        guard let current = latest(id: id) else { return (nil, "unknown procedure: \(id)") }
        var envelope = current.temporal
        do { try envelope.reinforce(verified: true, confirmedAt: now, now: now) }
        catch { return (nil, "reinforcement refused: \(error)") }
        let sources = Array((current.sources + [verifiedSource]).suffix(Procedure.maximumSources))
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
        latestByID()[id]
    }

    /// Applicability-ranked, lifecycle-eligible procedures. Deliberately does NOT apply the
    /// salience floor — that is the admission gate's decision, made once, with reactivation.
    public func retrieve(applicability task: String, limit: Int = 10, at now: Date) -> [Procedure] {
        guard limit > 0 else { return [] }
        let eligible = latestByID().values.filter {
            $0.temporal.evaluate(at: now).isRetrievalEligible
        }
        guard !eligible.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        let documents = eligible.map {
            LexicalSearch.Document(id: $0.id, title: $0.title + " " + $0.task,
                                   text: $0.keywords.joined(separator: " ") + "\n" + $0.steps)
        }
        return LexicalSearch.rank(documents, query: task, limit: limit)
            .compactMap { byID[$0.id] }
    }

    private func latestByID() -> [String: Procedure] {
        guard let confined = try? ConfinedRoot(root: projectRoot, readOnly: true) else { return [:] }
        let names: [String]
        do { names = try confined.entries(Self.directory).filter { !$0.isDir }.map(\.name) }
        catch { return [:] }
        var best: [String: Procedure] = [:]
        for name in names.sorted().prefix(Self.maximumRecords) {
            guard let data = try? confined.readStableData(Self.directory + "/" + name,
                                                          maxBytes: Procedure.maximumTextUTF8Bytes + 8_192),
                  let decoded = try? JSONDecoder().decode(Procedure.self, from: data),
                  name == Self.fileName(id: decoded.id, version: decoded.version),
                  decoded.id == Procedure.identity(title: decoded.title, task: decoded.task) else { continue }
            if let existing = best[decoded.id], existing.version >= decoded.version { continue }
            best[decoded.id] = decoded
        }
        return best
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
