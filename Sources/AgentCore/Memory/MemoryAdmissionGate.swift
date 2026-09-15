import Foundation

/// The unified typed schema (Q5): four memory types with mutually incompatible correct
/// policies. Every provenance class maps onto exactly one type; the gate's per-class policy is
/// the per-type policy applied at the admission seam.
///
/// | Type          | Persistence            | Decay                    | Update semantics        |
/// |---------------|------------------------|--------------------------|-------------------------|
/// | fact          | long; timeless         | supersession only        | replacement             |
/// | episode       | relevance window       | by age                   | append-only, never overwritten |
/// | procedure     | grows with verified reuse | by disuse; supersession | reinforcement           |
/// | working_state | task-scoped only       | discarded at task end    | never enters durable recall |
public enum MemoryRecordType: String, Codable, Sendable, CaseIterable {
    case fact
    case episode
    case procedure
    case workingState = "working_state"
}

/// The provenance class of a recall candidate. Admission policy is per-class because the four
/// memory types have incompatible correct policies: a curated fact is governed by supersession,
/// an episode by age, research evidence by fast decay, and a lesson by its recorded envelope.
public enum MemoryProvenanceClass: String, Codable, Sendable, CaseIterable {
    /// Operator-curated project context (facts.md / AGENTS.md / CLAUDE.md). Timeless by contract;
    /// removed by editing the file, not by decay.
    case curatedFact = "curated_fact"
    /// A row from the immutable agent-history archive, clocked by its original event time.
    case historyEvent = "history_event"
    /// A timestamped episodic record. Append-only; a later episode never overwrites an earlier one.
    case episode
    /// Content-bound fetched research. Observations age fast; stale fetches are not evidence.
    case researchEvidence = "research_evidence"
    /// A durable lesson carrying its own temporal envelope (or at least an event clock).
    case supplementalLesson = "supplemental_lesson"
    /// Host-supplied organizational rows whose temporal projection runs inside the host store
    /// before the closure returns them. The gate verifies host binding and scope and labels the
    /// admission as upstream-projected instead of silently trusting it. Follow-up: thread the
    /// projection through when OrganizationalLearningStore is split per the monolith rule.
    case hostProjectedLesson = "host_projected_lesson"
    /// A reinforced how-to from the ProcedureStore: slow disuse decay anchored on the last
    /// verified confirmation, retrieved by task applicability.
    case procedure
    /// Task-scoped scratch state. Must NEVER become durable recall; the gate denies it
    /// unconditionally so no future source can leak finished-task residue into the corpus.
    case workingState = "working_state"

    /// The Q5 type this provenance class instantiates. Lessons are procedure-typed: reinforced
    /// advisory know-how (a proven win or an obstacle to avoid re-attempting).
    public var recordType: MemoryRecordType {
        switch self {
        case .curatedFact: return .fact
        case .historyEvent, .episode, .researchEvidence: return .episode
        case .supplementalLesson, .hostProjectedLesson, .procedure: return .procedure
        case .workingState: return .workingState
        }
    }
}

/// One recall candidate presented to the admission gate. `sourceProject` is the canonical path of
/// the project the bytes were read from, captured at the read site — never inferred from content.
public struct MemoryAdmissionCandidate: Sendable {
    public let entry: AgentMemoryEntry
    public let provenance: MemoryProvenanceClass
    public let sourceProject: String

    public init(entry: AgentMemoryEntry, provenance: MemoryProvenanceClass, sourceProject: String) {
        self.entry = entry
        self.provenance = provenance
        self.sourceProject = sourceProject
    }
}

public enum MemoryAdmissionDenialReason: String, Codable, Sendable, CaseIterable {
    case outOfScope = "out_of_scope"
    case unknownAge = "unknown_age"
    case temporalIneligible = "temporal_ineligible"
    case belowSalienceFloor = "below_salience_floor"
    case emptyContent = "empty_content"
    case evaluationFailure = "evaluation_failure"
    case workingStateLeak = "working_state_leak"
}

/// The gate's ruling on one candidate. Admission carries the evaluated salience and an explicit
/// note naming which policy admitted it, so the audit trail never shows a bare "yes".
public struct MemoryAdmissionDecision: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case admitted(salience: Double, note: String)
        case denied(MemoryAdmissionDenialReason, detail: String)
    }

    public let candidateID: String
    public let locator: String
    public let provenance: MemoryProvenanceClass
    public let verdict: Verdict
    /// True only when THIS decision admitted a below-floor memory on context recurrence — the
    /// signal that a reconsolidation overlay record should be written. A sustained (previously
    /// reactivated) admission is not a new reactivation event.
    public let reactivated: Bool
    /// True when a below-floor memory was admitted because a still-live overlay boost lifted it
    /// over the floor. Like fresh reactivations, sustained memories are query-dissimilar by
    /// construction and must be surfaced past lexical ranking; unlike them, they write no new
    /// overlay record.
    public let sustained: Bool

    public var isAdmitted: Bool {
        if case .admitted = verdict { return true }
        return false
    }
}

public struct MemoryAdmissionScreen: Sendable {
    public let admitted: [AgentMemoryEntry]
    public let decisions: [MemoryAdmissionDecision]

    public var reactivations: [MemoryAdmissionDecision] { decisions.filter(\.reactivated) }
    public var sustainedReactivations: [MemoryAdmissionDecision] { decisions.filter(\.sustained) }

    public var admittedCount: Int { admitted.count }
    public var deniedCount: Int { decisions.count - admitted.count }
    public var denialReasons: [String: Int] {
        var out: [String: Int] = [:]
        for decision in decisions {
            if case .denied(let reason, _) = decision.verdict {
                out[reason.rawValue, default: 0] += 1
            }
        }
        return out
    }
}

/// The single admission gate between memory recall and model influence (Q9: suppression/gating).
///
/// Principle enforced: retrieval is not authorization. That a record is retrievable does not
/// entail it may shape behavior; every candidate passes this gate and the gate's default under
/// ambiguity is to deny. The gate never mutates any store and never throws — an internal
/// evaluation failure is itself a denial, not an exception.
///
/// Deliberately outside the gate: raw `history` / `history_search` pages. They are the append-only
/// forensic surface, already labeled "raw event; not current knowledge"; suppressing rows there
/// would corrupt the audit trail, not protect the knowledge path.
public struct MemoryAdmissionGate: Sendable {
    public let hostProject: String
    public let authorizedProjects: Set<String>

    public init(hostProject: String, authorizedProjects: Set<String>) {
        self.hostProject = hostProject
        self.authorizedProjects = authorizedProjects.union([hostProject])
    }

    public func screen(_ candidates: [MemoryAdmissionCandidate], at now: Date,
                       advisor: MemoryRecurrenceAdvisor? = nil) -> MemoryAdmissionScreen {
        var admitted: [AgentMemoryEntry] = []
        var decisions: [MemoryAdmissionDecision] = []
        for candidate in candidates {
            let ruling = decideDetailed(candidate, at: now, advisor: advisor)
            decisions.append(MemoryAdmissionDecision(
                candidateID: candidate.entry.id, locator: candidate.entry.locator,
                provenance: candidate.provenance, verdict: ruling.verdict,
                reactivated: ruling.reactivated, sustained: ruling.sustained))
            if case .admitted = ruling.verdict { admitted.append(candidate.entry) }
        }
        return MemoryAdmissionScreen(admitted: admitted, decisions: decisions)
    }

    public func decide(_ candidate: MemoryAdmissionCandidate, at now: Date,
                       advisor: MemoryRecurrenceAdvisor? = nil) -> MemoryAdmissionDecision.Verdict {
        decideDetailed(candidate, at: now, advisor: advisor).verdict
    }

    private func decideDetailed(_ candidate: MemoryAdmissionCandidate, at now: Date,
                                advisor: MemoryRecurrenceAdvisor?)
        -> (verdict: MemoryAdmissionDecision.Verdict, reactivated: Bool, sustained: Bool) {
        let entry = candidate.entry
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (.denied(.emptyContent, detail: "candidate has no recallable content"), false, false)
        }
        guard authorizedProjects.contains(candidate.sourceProject) else {
            return (.denied(.outOfScope,
                            detail: "source project is not in this query's authorized set"), false, false)
        }

        switch candidate.provenance {
        case .curatedFact:
            // Fact-typed context: persistence is supersession-governed (edit or delete the file),
            // not decay-governed. Admitted at full salience with an explicit policy note.
            return (.admitted(salience: 1, note: "curated fact; supersession-governed"), false, false)

        case .hostProjectedLesson:
            guard candidate.sourceProject == hostProject else {
                return (.denied(.outOfScope,
                                detail: "host-projected lessons are host-project only"), false, false)
            }
            // If the supplier attached temporal truth anyway, honor it — an attached envelope
            // that says ineligible must win over the upstream-projection contract.
            if hasTemporalIdentity(entry) {
                return temporalVerdict(entry, defaultDecay: .medium, at: now, advisor: advisor,
                                       note: "host lesson; envelope-checked at gate")
            }
            return (.admitted(salience: MemoryTemporalEnvelope.confidenceFloor,
                              note: "upstream temporal projection (host-supplied closure)"), false, false)

        case .historyEvent, .episode:
            return temporalVerdict(entry, defaultDecay: .medium, at: now, advisor: advisor,
                                   note: candidate.provenance.rawValue + "; temporal governance")

        case .researchEvidence:
            return temporalVerdict(entry, defaultDecay: .fast, at: now, advisor: advisor,
                                   note: "research evidence; fast-decay governance")

        case .supplementalLesson:
            return temporalVerdict(entry, defaultDecay: .medium, at: now, advisor: advisor,
                                   note: "supplemental lesson; temporal governance")

        case .procedure:
            // Procedure type: slow disuse decay anchored on the last verified confirmation;
            // reinforcement (via the temporal kernel) is what keeps a procedure retrievable.
            return temporalVerdict(entry, defaultDecay: ProcedureStore.defaultDecay, at: now,
                                   advisor: advisor, note: "procedure; reinforcement-governed")

        case .workingState:
            // Working state is task-scoped by definition. Admitting it would poison future
            // retrieval with finished-task residue; there is no envelope that makes it durable.
            return (.denied(.workingStateLeak,
                            detail: "working state is task-scoped and never enters durable recall"),
                    false, false)
        }
    }

    private func hasTemporalIdentity(_ entry: AgentMemoryEntry) -> Bool {
        entry.temporal != nil || entry.observedAt != nil
    }

    private func temporalVerdict(_ entry: AgentMemoryEntry, defaultDecay: MemoryDecayRate,
                                 at now: Date, advisor: MemoryRecurrenceAdvisor?,
                                 note: String) -> (verdict: MemoryAdmissionDecision.Verdict,
                                                   reactivated: Bool, sustained: Bool) {
        let envelope: MemoryTemporalEnvelope
        if let attached = entry.temporal {
            envelope = attached
        } else if let observedAt = entry.observedAt {
            do {
                envelope = try MemoryTemporalEnvelope(createdAt: observedAt, decayRate: defaultDecay)
            } catch {
                return (.denied(.evaluationFailure,
                                detail: "conservative envelope rejected: \(error)"), false, false)
            }
        } else {
            // Fail-closed: no envelope and no event clock means the age is unknown, and
            // unknown-age data must not become current knowledge.
            return (.denied(.unknownAge, detail: "no temporal envelope or event clock"), false, false)
        }
        let evaluation = envelope.evaluate(at: now)
        guard evaluation.isRetrievalEligible else {
            // Lifecycle and validity denials are absolute: reactivation lifts decay, it never
            // resurrects a retired, superseded, expired, or future-dated claim.
            return (.denied(.temporalIneligible, detail: evaluation.state.rawValue), false, false)
        }
        if evaluation.salience >= MemoryTemporalEnvelope.confidenceFloor {
            return (.admitted(salience: evaluation.salience, note: note), false, false)
        }
        // Q3 reactivation, decided only in the decay band. A prior reactivation sustains the
        // memory (overlay boost, itself fast-decaying); a fresh context recurrence reactivates
        // it at the floor and signals a reconsolidation record. An explicitly off-season memory
        // is owner-declared suppression, not decay — reactivation must not override it.
        if let advisor, evaluation.inSeason != false {
            let sustained = min(1, evaluation.salience * advisor.priorBoost(entry, at: now))
            if sustained >= MemoryTemporalEnvelope.confidenceFloor {
                return (.admitted(salience: sustained, note: note + "; sustained by prior reactivation"), false, true)
            }
            if advisor.canReactivate(entry) {
                return (.admitted(salience: MemoryTemporalEnvelope.confidenceFloor,
                                  note: note + "; reactivated: context recurrence"), true, false)
            }
        }
        return (.denied(.belowSalienceFloor,
                        detail: String(format: "salience %.4f", evaluation.salience)), false, false)
    }
}

/// Durable, bounded audit trail for admission decisions: one owner-private record per recall,
/// published no-replace under the host project. Auditability is the point of the gate — a denial
/// that leaves no trace is indistinguishable from data that never existed.
public enum MemoryAdmissionAuditLog {
    public static let directory = ".kist/memory/admission/v1"
    public static let maximumRecords = 2_048
    public static let maximumDenialSamples = 16

    struct Record: Codable {
        struct DenialSample: Codable {
            let id: String
            let locator: String
            let provenance: String
            let reason: String
            let detail: String
        }

        let at: Date
        let querySHA256: String
        let admitted: Int
        let denied: Int
        let reactivated: Int
        let denialReasons: [String: Int]
        let denialSamples: [DenialSample]
    }

    /// Returns a reportable issue string instead of throwing: audit-log unavailability degrades
    /// visibly but never blocks recall, while admission verdicts themselves stay fail-closed.
    public static func record(screen: MemoryAdmissionScreen, query: String,
                              hostRoot: String, at now: Date) -> String? {
        do {
            let confined = try ConfinedRoot(root: hostRoot)
            let existing: Int
            do { existing = try confined.entries(directory).count }
            catch ToolError.notFound { existing = 0 }
            guard existing < maximumRecords else {
                return "memory admission log at capacity (\(maximumRecords) records); pruning required before further audit records"
            }
            let samples = screen.decisions.compactMap { decision -> Record.DenialSample? in
                guard case .denied(let reason, let detail) = decision.verdict else { return nil }
                return Record.DenialSample(
                    id: String(decision.candidateID.prefix(200)),
                    locator: String(decision.locator.prefix(500)),
                    provenance: decision.provenance.rawValue,
                    reason: reason.rawValue, detail: String(detail.prefix(200)))
            }.prefix(maximumDenialSamples)
            let record = Record(at: now, querySHA256: BuilderEvidenceDigest.sha256(query),
                                admitted: screen.admittedCount, denied: screen.deniedCount,
                                reactivated: screen.reactivations.count,
                                denialReasons: screen.denialReasons,
                                denialSamples: Array(samples))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let name = "\(Int(now.timeIntervalSince1970 * 1_000))-\(UUID().uuidString.lowercased().prefix(8)).json"
            _ = try confined.createDataIfMissing(directory + "/" + name,
                                                 try encoder.encode(record), createParents: true)
            return nil
        } catch {
            return "memory admission audit record unavailable: \(error)"
        }
    }
}
