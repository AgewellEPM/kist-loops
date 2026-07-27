import Foundation

// MARK: - Human-only submission + durable outcome tracking
//
// There is NO auto-submit path. The only way to record a submission is `recordSubmission`, which demands
// a HUMAN submitter identity and runs the submit action through `BountyGate` (which refuses an automated
// submission and an out-of-scope asset). The tracker then keeps the outcome (accepted / dup / rejected /
// paid) so the reputation asset — the thing that actually compounds — is measurable, per program.

public struct SubmissionRecord: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable, CaseIterable {
        case submitted, triaged, accepted, duplicate, informative, rejected, resolved, paid
        /// Outcomes that count as "signal" (the report was valid/useful), for the reputation ratio.
        public var isSignal: Bool {
            switch self { case .accepted, .resolved, .paid, .triaged: return true
                          case .submitted, .duplicate, .informative, .rejected: return false }
        }
    }
    public let id: String
    public let program: String
    public let findingId: String
    public let title: String
    public let submittedBy: String       // the HUMAN who submitted — never the model
    public let submittedAtISO: String
    public var outcome: Outcome
    public var payoutUSD: Int?
    public var note: String
}

public struct ReputationSummary: Sendable, Equatable {
    public let program: String
    public let total: Int
    public let signal: Int               // accepted/resolved/paid/triaged
    public let duplicates: Int
    public let rejected: Int
    public let paidUSD: Int
    /// signal / total — the metric triagers implicitly track; a high ratio gets you triaged faster.
    public var signalRatio: Double { total == 0 ? 0 : Double(signal) / Double(total) }
}

public enum SubmissionError: Error, Equatable {
    case notReportReady
    case emptySubmitter
    case submissionRefused(reason: String)
    case notFound(id: String)
}

public struct SubmissionTracker {
    public let root: String
    public let gate: BountyGate

    public init(root: String = SubmissionTracker.defaultRoot(), gate: BountyGate = BountyGate()) {
        self.root = root; self.gate = gate
    }

    public static func defaultRoot() -> String {
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? (NSHomeDirectory() + "/.kist")
        return base + "/bounty-submissions"
    }

    /// Record a HUMAN submission of a report-ready finding. Fail-closed on every axis: the finding must be
    /// report-ready, the submitter must be a non-empty human identity, and the submit action must pass the
    /// gate (in scope, NOT automated). `atISO` is passed in — never wall-clock-read here.
    @discardableResult
    public func recordSubmission(report: DisclosureReport,
                                 verified: VerifiedBountyFinding,
                                 submittedBy: String,
                                 atISO: String,
                                 engagement: SecurityEngagement,
                                 rules: BountyProgramRules) throws -> SubmissionRecord {
        guard verified.isReportReady, let poc = verified.poc else { throw SubmissionError.notReportReady }
        let who = submittedBy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw SubmissionError.emptySubmitter }

        // The submit action: a HUMAN filing on an in-scope asset. isAutomated:false is the ONLY value the
        // tracker ever sends — so the gate's `submit.no-auto-submit` rule can never be tripped from here,
        // and an out-of-scope asset is refused.
        let action = BountyAction(targetHost: poc.targetHost, targetRepo: poc.targetRepo,
                                  vulnClass: poc.vulnClass, method: .passiveRecon,
                                  isAutomated: false, isSubmission: true)
        let decision = gate.evaluate(action, engagement: engagement, rules: rules)
        guard decision.isAllowed else { throw SubmissionError.submissionRefused(reason: decision.reason) }

        let rec = SubmissionRecord(
            id: report.findingId, program: report.program, findingId: report.findingId,
            title: report.title, submittedBy: who, submittedAtISO: atISO,
            outcome: .submitted, payoutUSD: nil, note: "")
        try persist(rec)
        return rec
    }

    /// Update an existing submission's outcome (triager verdict / payout). Loud on a missing record.
    @discardableResult
    public func update(id: String, outcome: SubmissionRecord.Outcome, payoutUSD: Int? = nil, note: String? = nil) throws -> SubmissionRecord {
        guard var rec = try load(id: id) else { throw SubmissionError.notFound(id: id) }
        rec.outcome = outcome
        if let payoutUSD { rec.payoutUSD = payoutUSD }
        if let note { rec.note = note }
        try persist(rec)
        return rec
    }

    public func list(program: String? = nil) -> [SubmissionRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        var out: [SubmissionRecord] = []
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: root + "/" + name)),
                  let r = try? JSONDecoder().decode(SubmissionRecord.self, from: data) else { continue }  // fail-closed: skip corrupt
            if let program, r.program != program { continue }
            out.append(r)
        }
        return out.sorted { $0.submittedAtISO < $1.submittedAtISO }
    }

    public func reputation(program: String) -> ReputationSummary {
        let recs = list(program: program)
        let signal = recs.filter { $0.outcome.isSignal }.count
        let dups = recs.filter { $0.outcome == .duplicate }.count
        let rej = recs.filter { $0.outcome == .rejected }.count
        let paid = recs.compactMap { $0.payoutUSD }.reduce(0, +)
        return ReputationSummary(program: program, total: recs.count, signal: signal,
                                 duplicates: dups, rejected: rej, paidUSD: paid)
    }

    // MARK: persistence (mirrors EngagementStore: atomic, path-safe, fail-closed on corrupt)

    func load(id: String) throws -> SubmissionRecord? {
        let path = filePath(id)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(SubmissionRecord.self, from: data)
    }

    private func persist(_ rec: SubmissionRecord) throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(rec)
        try data.write(to: URL(fileURLWithPath: filePath(rec.id)), options: .atomic)
    }

    func filePath(_ id: String) -> String { root + "/" + SubmissionTracker.safe(id) + ".json" }

    static func safe(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(s.map { allowed.contains($0) ? $0 : "-" })
        return cleaned.isEmpty ? "untitled" : cleaned
    }
}
