import Foundation

// MARK: - The flywheel: Goal → Research → Plan → Build(sandbox) → Test → Review → Consensus →
//         (reject: improve→test→review) → (accept: merge) → Remember.
//
// This file is the DATA + the STAGE SEAM. The orchestrator (FlywheelOrchestrator) owns the control flow —
// especially the consensus-repair LOOP, which is the genuinely new logic. Each stage is a protocol method
// so the REAL implementations (research pipeline, fleet build, council review, merge gate, lesson memory)
// plug in behind it, and tests inject deterministic stubs.

public struct ResearchNotes: Sendable, Equatable {
    public let summary: String
    public let sources: [String]
    public init(summary: String, sources: [String] = []) { self.summary = summary; self.sources = sources }
}

public struct BuildResult: Sendable, Equatable {
    public let branch: String          // the isolated worktree/branch the specialist built on
    public let changedFiles: [String]
    public let createdTools: [String]  // tools the agent had to build because a capability was missing
    public let ok: Bool                // did the build itself complete (compile/apply)?
    public let note: String
    public init(branch: String, changedFiles: [String] = [], createdTools: [String] = [],
                ok: Bool, note: String = "") {
        self.branch = branch; self.changedFiles = changedFiles; self.createdTools = createdTools
        self.ok = ok; self.note = note
    }
}

public struct TestResult: Sendable, Equatable {
    public let passed: Bool
    public let summary: String
    public init(passed: Bool, summary: String) { self.passed = passed; self.summary = summary }
}

/// Typed severity so a reviewer can't emit a free-form string, and so a CRITICAL/HIGH finding is ALWAYS
/// treated as blocking regardless of the `mustFix` flag (a "critical" that claims not-must-fix is a
/// contradiction a fail-closed gate must not trust). (Panel review, GPT/DeepSeek.)
public enum ReviewSeverity: String, Sendable, Equatable, CaseIterable {
    case critical, high, med, low, nit
    public var blocksByDefault: Bool { self == .critical || self == .high }
}

/// One independent reviewer's finding. `blocks` — the real gate — is true when the reviewer marked it
/// mustFix OR when its severity is critical/high. Reviewers can only RAISE issues; they never mint an
/// "accept" — acceptance is the ABSENCE of blocking findings across a QUORUM of completed reviewers.
public struct ReviewFinding: Sendable, Equatable {
    public let reviewer: String
    public let severity: ReviewSeverity
    public let issue: String
    public let mustFix: Bool
    public init(reviewer: String, severity: ReviewSeverity, issue: String, mustFix: Bool) {
        self.reviewer = reviewer; self.severity = severity; self.issue = issue; self.mustFix = mustFix
    }
    public var blocks: Bool { mustFix || severity.blocksByDefault }
}

/// One reviewer's REPORT — not just its findings. `completed == false` (or a missing report) means the
/// review did NOT actually run (timeout / transport error / misconfig), which must fail closed. A clean
/// review is a COMPLETED report with no blocking findings — NOT an empty findings array of unknown origin.
public struct ReviewReport: Sendable, Equatable {
    public let reviewer: String
    public let completed: Bool
    public let findings: [ReviewFinding]
    public init(reviewer: String, completed: Bool, findings: [ReviewFinding] = []) {
        self.reviewer = reviewer; self.completed = completed; self.findings = findings
    }
    public var blockingFindings: [ReviewFinding] { findings.filter(\.blocks) }
}

public enum ConsensusVerdict: Sendable, Equatable {
    case accept(reason: String)
    case reject(mustFix: [ReviewFinding])
    public var isAccept: Bool { if case .accept = self { return true }; return false }
    public var blockers: [ReviewFinding] { if case .reject(let m) = self { return m }; return [] }
}

public struct MergeResult: Sendable, Equatable {
    public let merged: Bool
    public let into: String
    public let note: String
    public init(merged: Bool, into: String, note: String) { self.merged = merged; self.into = into; self.note = note }
}

/// One trip through the build→test→review→consensus loop, kept for the audit trail.
public struct FlywheelRound: Sendable, Equatable {
    public let round: Int
    public let build: BuildResult
    public let tests: TestResult
    public let reviews: [ReviewReport]
    public let verdict: ConsensusVerdict
}

public enum FlywheelResult: Sendable, Equatable {
    /// Invariant: `.accepted` is produced ONLY with `MergeResult.merged == true`. A consensus-accept whose
    /// merge gate refused is returned as `.rejected` (see FlywheelOrchestrator), never `.accepted`.
    case accepted(MergeResult, rounds: [FlywheelRound])
    case rejected(rounds: [FlywheelRound], reason: String)
    public var didMerge: Bool { if case .accepted(let m, _) = self { return m.merged }; return false }
    public var rounds: [FlywheelRound] {
        switch self { case .accepted(_, let r): return r; case .rejected(let r, _): return r }
    }
}

/// What the flywheel remembers at the end — proven lesson on accept, obstacle on give-up.
public struct FlywheelMemory: Sendable, Equatable {
    public let goal: String
    public let accepted: Bool
    public let rounds: Int
    public let note: String
}

/// The stage seam. Real implementations wire: research → ResearchRunTool, plan → AgentPlanner, build →
/// FleetSupervisor/CaptainOrchestrator (isolated worktree + custom_tool when a capability is missing),
/// test → FleetIntegrationVerifier, review → CouncilPromotionJudge (ONE ReviewReport per independent
/// reviewer), merge → joinSignedBranches, remember → FleetLessonStore. `build` receives prior open blocking
/// findings so it can IMPROVE, not rebuild blind.
public protocol FlywheelStages: Sendable {
    func research(goal: String) async -> ResearchNotes
    func plan(goal: String, research: ResearchNotes) async -> String
    func build(goal: String, plan: String, feedback: [ReviewFinding]) async -> BuildResult
    func test(_ build: BuildResult) async -> TestResult
    func review(_ build: BuildResult, tests: TestResult) async -> [ReviewReport]
    func merge(_ build: BuildResult) async -> MergeResult
    func remember(_ memory: FlywheelMemory) async
}
