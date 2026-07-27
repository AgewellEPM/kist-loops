import Foundation

/// The structured, OBSERVED facts the symbolic Captain judges. The split is a TYPE boundary, not a
/// comment:
///   • BuildFacts — what the process produced. Structural rules see ONLY these.
///   • WorldFacts — the outside signal. Only proxy rules see it.
///
/// FACT PROVENANCE: a judge is only as honest as its facts. BuildFacts cannot be built from bare
/// asserted bools — it is DERIVED from artifact EVIDENCE (a real test exit code, a real diff, the
/// review-gate record). You cannot say `testsGreen: true`; you supply the exit code and the engine
/// computes it. This removes the trivial "a model said tests pass" forgery.
///
/// HONEST RESIDUAL: the evidence values are still only as true as their producer. Ultimate
/// un-forgeability requires the producers (test runner, review gate, GitIsolation diff) to SIGN their
/// measurements. In Mythos the producer is the Foreman, which derives these from GitIsolation's
/// COMMITTED diff + the real `swift test` exit code — measured, not claimed.
///
/// Ported from TinkySDR's Captain (Stage 1.4). The `WorldFacts.forBuild(conscience:)` factory was
/// dropped (the Conscience organ isn't ported); `.none` + the public memberwise init remain, so a
/// fleet with no external world-signal simply runs ungrounded (drift-flagged on a shippable-looking
/// build), which is the correct fail-safe.

// MARK: Artifact evidence (the only legitimate inputs to BuildFacts)

/// A real test run's outcome. `green` is DERIVED, not asserted.
public struct TestRunEvidence: Equatable, Sendable {
    public let exitCode: Int32
    public var green: Bool { exitCode == 0 }
    public init(exitCode: Int32) { self.exitCode = exitCode }
}

/// A real diff's shape. `present` and the max file size are measured, not claimed.
public struct DiffEvidence: Equatable, Sendable {
    public let changedLines: Int
    public let maxFileLines: Int
    public var present: Bool { changedLines > 0 }
    public init(changedLines: Int, maxFileLines: Int) {
        self.changedLines = changedLines; self.maxFileLines = maxFileLines
    }
}

/// The review gate's record for this build.
public struct CodexEvidence: Equatable, Sendable {
    public let reviewed: Bool
    public init(reviewed: Bool) { self.reviewed = reviewed }
}

/// Process facts. Structural rules see ONLY this — never the world-signal. Built from artifact
/// evidence, never from bare asserted bools.
public struct BuildFacts: Equatable, Sendable {
    public let buildID: String
    public let claimedDone: Bool
    public let testsGreen: Bool
    public let diffPresent: Bool
    public let codexReviewed: Bool
    public let maxFileLines: Int
    public let stepCapHit: Bool
    /// The run ended without a clean done (killed / step-capped / aborted). Checked unconditionally so
    /// an incomplete run can't fall through every done-gated rule to a false green. Defaults false.
    public let runIncomplete: Bool

    /// The ONLY constructor: derive every process fact from a concrete artifact.
    public init(buildID: String, claimedDone: Bool, tests: TestRunEvidence, diff: DiffEvidence,
                codex: CodexEvidence, stepCapHit: Bool, runIncomplete: Bool = false) {
        self.buildID = buildID
        self.claimedDone = claimedDone
        self.testsGreen = tests.green
        self.diffPresent = diff.present
        self.maxFileLines = diff.maxFileLines
        self.codexReviewed = codex.reviewed
        self.stepCapHit = stepCapHit
        self.runIncomplete = runIncomplete
    }

    /// Read a flag by name — used by the structural predicate interpreter, which can reach build facts
    /// but (by the `BuildFlag` vocabulary) never world facts.
    public func value(of flag: BuildFlag) -> Bool {
        switch flag {
        case .claimedDone: return claimedDone
        case .testsGreen: return testsGreen
        case .diffPresent: return diffPresent
        case .codexReviewed: return codexReviewed
        case .stepCapHit: return stepCapHit
        case .runIncomplete: return runIncomplete
        }
    }
}

/// The outside signal — sourced ONLY from a trusted external conscience. Proxy rules may read it.
public struct WorldFacts: Equatable, Sendable {
    /// TRUSTED, externally-signed confirmed real-world outcomes credited to THIS BUILD (build-scoped,
    /// NOT lineage — a fresh build cannot inherit a past success and false-green). 0 == the world has
    /// not confirmed THIS build, yet.
    public let confirmedHelpForBuild: Int
    /// The conscience ledger failed its integrity check (tamper) — treat as drift.
    public let signalBroken: Bool
    /// Is an external signal even wired? If false, every help-proxy is ungrounded.
    public let hasSignal: Bool

    public init(confirmedHelpForBuild: Int, signalBroken: Bool, hasSignal: Bool) {
        self.confirmedHelpForBuild = confirmedHelpForBuild
        self.signalBroken = signalBroken
        self.hasSignal = hasSignal
    }

    public static let none = WorldFacts(confirmedHelpForBuild: 0, signalBroken: false, hasSignal: false)

    /// The internal world-signal for a single agent's subtask, derived PURELY from its MEASURED test
    /// run (the VerifierGate pattern, inlined). A real test was run, so `hasSignal` is true; the build is
    /// confirmed (`confirmedHelpForBuild: 1`) ONLY on a clean exit 0. This is correctly per-agent isolated
    /// by construction — each agent's Foreman computes its OWN WorldFacts from its OWN exit code, so one
    /// agent's failing run can never clobber another's confirmed pass (no shared mutable conscience).
    public static func fromMeasuredTest(exitCode: Int32) -> WorldFacts {
        WorldFacts(confirmedHelpForBuild: exitCode == 0 ? 1 : 0, signalBroken: false, hasSignal: true)
    }
}

/// The full fact-set for one judgment: build facts + the world-signal.
public struct CaptainFacts: Equatable, Sendable {
    public let build: BuildFacts
    public let world: WorldFacts
    public init(build: BuildFacts, world: WorldFacts) { self.build = build; self.world = world }
}
