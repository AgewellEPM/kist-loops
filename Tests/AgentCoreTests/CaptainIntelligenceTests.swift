import XCTest
@testable import AgentCore

final class CaptainIntelligenceTests: XCTestCase {

    func testAssignmentChoosesCodingAndCriticModelsFromSnapshot() {
        let snapshot = ProjectSnapshot(
            repo: "/repo",
            trackedFileCount: 120,
            directorySnapshot: "Sources\nTests",
            knownDirectories: ["", "Sources", "Tests"],
            manifests: ["Package.swift"],
            testEntrypoints: ["swift test"],
            languages: ["Swift"],
            changedFiles: [],
            providers: [
                .init(binding: ProviderBinding(providerId: "mimo", model: "mimo-v2.5-pro"),
                      displayName: "MiMo",
                      capabilities: ModelCapabilities(nativeTools: true, reasoning: true,
                                                      contextWindowTokens: 128_000,
                                                      structuredOutput: true),
                      keyed: true),
                .init(binding: ProviderBinding(providerId: "deepseek", model: "deepseek-v4-pro"),
                      displayName: "DeepSeek",
                      capabilities: ModelCapabilities(nativeTools: true, reasoning: true,
                                                      contextWindowTokens: 128_000,
                                                      codeExecution: true,
                                                      structuredOutput: true),
                      keyed: true),
                .init(binding: ProviderBinding(providerId: "gemini", model: "gemini-2.5-pro"),
                      displayName: "Gemini",
                      capabilities: ModelCapabilities(nativeTools: true, vision: true, reasoning: true,
                                                      contextWindowTokens: 1_000_000,
                                                      grounding: true, urlContext: true,
                                                      structuredOutput: true),
                      keyed: true),
            ])
        let fallback = RoleBindings(default: ProviderBinding(providerId: "mimo", model: "mimo-v2.5-pro"))
        let task = FleetSubtask(title: "Refactor parser routing",
                                intent: "refactor the parser and routing logic",
                                scopeGlobs: ["Sources/*"],
                                acceptanceCriterion: "swift test passes")

        let assigned = ModelAssignmentEngine.assign(subtasks: [task], snapshot: snapshot, defaultRoles: fallback)

        XCTAssertEqual(assigned.count, 1)
        XCTAssertEqual(assigned[0].roles.binding(for: .coder).providerId, "deepseek")
        XCTAssertEqual(assigned[0].roles.binding(for: .critic).providerId, "gemini")
        XCTAssertTrue(assigned[0].assignment.capabilityTags.contains("reasoning"))
        XCTAssertGreaterThan(assigned[0].assignment.confidence, 0.5)
    }

    // MARK: C4 — interactive (single-turn) routing uses the SAME project-data scoring

    private func team() -> ProjectSnapshot {
        ProjectSnapshot(
            repo: "/repo", trackedFileCount: 120, directorySnapshot: "Sources\nTests",
            knownDirectories: ["", "Sources", "Tests"], manifests: ["Package.swift"],
            testEntrypoints: ["swift test"], languages: ["Swift"], changedFiles: [],
            providers: [
                .init(binding: ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"),
                      displayName: "Gemini",
                      capabilities: ModelCapabilities(nativeTools: true, vision: true,
                                                      contextWindowTokens: 1_000_000, grounding: true,
                                                      urlContext: true, structuredOutput: true),
                      keyed: true),
                .init(binding: ProviderBinding(providerId: "deepseek", model: "deepseek-v4-pro"),
                      displayName: "DeepSeek",
                      capabilities: ModelCapabilities(nativeTools: true, reasoning: true,
                                                      contextWindowTokens: 128_000, codeExecution: true,
                                                      structuredOutput: true),
                      keyed: true),
            ])
    }

    func testInteractiveReasoningTurnPicksProjectCoderNotGemini() {
        // A coding/architecture turn with no pinned model → the Captain picks the project's coder
        // (deepseek), NOT gemini-flash — project-data scoring, and the wantsReasoning signal is set so the
        // REPL is allowed to switch off the fallback.
        let a = ModelAssignmentEngine.assignInteractive(
            turn: "refactor the parser and routing architecture",
            snapshot: team(), fallback: ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"))
        XCTAssertEqual(a.binding.providerId, "deepseek")
        XCTAssertTrue(a.wantsReasoning, "an architecture/refactor turn carries the reasoning signal")
        XCTAssertGreaterThanOrEqual(a.confidence, 0.5)
    }

    func testInteractivePlainTurnCarriesNoSwitchSignal() {
        // A plain chat turn carries NO reasoning/research signal → the REPL's stability guard keeps it on
        // the current model (this test pins the SIGNAL the guard reads, so ordinary turns don't thrash).
        let a = ModelAssignmentEngine.assignInteractive(
            turn: "thanks, looks good", snapshot: team(),
            fallback: ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"))
        XCTAssertFalse(a.wantsReasoning)
        XCTAssertFalse(a.prefersResearch)
    }

    func testInteractiveResearchTurnPrefersGroundedProvider() {
        // A research turn prefers a grounded/url-context provider (gemini here) — the research signal is set.
        let a = ModelAssignmentEngine.assignInteractive(
            turn: "research and compare the current market docs on this",
            snapshot: team(), fallback: ProviderBinding(providerId: "deepseek", model: "deepseek-v4-pro"))
        XCTAssertTrue(a.prefersResearch)
        XCTAssertEqual(a.binding.providerId, "gemini", "grounding+urlContext wins the research profile")
    }

    func testInteractiveExplicitCodingTurnCarriesCodingSignal() {
        // An explicit coding turn (keyword match) sets wantsCoding → the REPL guard is allowed to switch to
        // the project coder. A plain turn only gets the empty-tags DEFAULT 'coding' tag, which is NOT the
        // signal — so it must NOT set wantsCoding (that was the muted-common-case bug).
        let coding = ModelAssignmentEngine.assignInteractive(
            turn: "fix the login bug in the auth code", snapshot: team(),
            fallback: ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"))
        XCTAssertTrue(coding.wantsCoding, "an explicit code/fix turn carries the coding signal")
        XCTAssertEqual(coding.binding.providerId, "deepseek", "routes to the project coder")

        let plain = ModelAssignmentEngine.assignInteractive(
            turn: "thanks, looks good", snapshot: team(),
            fallback: ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"))
        XCTAssertFalse(plain.wantsCoding, "a plain turn's DEFAULT coding tag is NOT the explicit signal")
    }

    func testInteractiveConfidenceIsWorkerOwnScoreNotAggregate() {
        // A coding turn's confidence reflects the CHOSEN worker (deepseek coder), not the best cross-role
        // score (gemini would score high as critic) — so the REPL's switch floor measures the right binding.
        let a = ModelAssignmentEngine.assignInteractive(
            turn: "fix the parser and edit the source", snapshot: team(),
            fallback: ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"))
        XCTAssertEqual(a.binding.providerId, "deepseek")
        XCTAssertGreaterThan(a.confidence, 0.55, "confidence derives from the strong coder's own score")
        XCTAssertLessThanOrEqual(a.confidence, 0.95)
    }

    func testInteractiveNoBetterThanFallbackStaysBelowSwitchFloor() {
        // Non-empty snapshot, but the only candidate scores no better than the fallback baseline (45) as a
        // coder → chosen binding IS the fallback and confidence is 0.45 (< the REPL's 0.5 switch floor), so
        // the guard stays. This pins the real anti-thrash guarantee via the WORKER's own score (not aggregate).
        let weak = ProjectSnapshot(
            repo: "/r", trackedFileCount: 1, directorySnapshot: "", knownDirectories: [], manifests: [],
            testEntrypoints: [], languages: ["Swift"], changedFiles: [],
            providers: [ .init(binding: ProviderBinding(providerId: "ollama", model: "llama"),
                               displayName: "Ollama", capabilities: ModelCapabilities(nativeTools: false),
                               keyed: true) ])
        let fb = ProviderBinding(providerId: "mimo", model: "mimo-v2.5-pro")
        let a = ModelAssignmentEngine.assignInteractive(turn: "fix and edit the source code",
                                                        snapshot: weak, fallback: fb)
        XCTAssertEqual(a.binding, fb, "no candidate beats the fallback baseline → stay on fallback")
        XCTAssertLessThan(a.confidence, 0.5, "fallback-baseline confidence is below the switch floor")
        // (The guard's below-floor ⇒ stay behavior is pinned in AutoModelRouterTests.captainDecision.)
    }

    func testInteractiveNoProvidersStaysOnFallback() {
        // Empty snapshot (no keyed providers) ⇒ stay on the fallback, never invent a switch.
        let empty = ProjectSnapshot(repo: "/r", trackedFileCount: 0, directorySnapshot: "",
                                    knownDirectories: [], manifests: [], testEntrypoints: [],
                                    languages: [], changedFiles: [], providers: [])
        let fb = ProviderBinding(providerId: "mimo", model: "mimo-v2.5-pro")
        let a = ModelAssignmentEngine.assignInteractive(turn: "architect a distributed system",
                                                        snapshot: empty, fallback: fb)
        XCTAssertEqual(a.binding, fb)
    }

    func testProjectBriefingIncludesEvidence() {
        let snapshot = ProjectSnapshot(
            repo: "/repo",
            trackedFileCount: 42,
            directorySnapshot: "Sources",
            knownDirectories: ["", "Sources"],
            manifests: ["Package.swift"],
            testEntrypoints: ["swift test"],
            languages: ["Swift"],
            changedFiles: ["Sources/App.swift"],
            providers: [
                .init(binding: ProviderBinding(providerId: "gemini", model: "gemini-2.5-pro"),
                      displayName: "Gemini",
                      capabilities: ModelCapabilities(nativeTools: true, vision: true,
                                                      contextWindowTokens: 1_000_000),
                      keyed: true)
            ])

        let brief = snapshot.briefing

        XCTAssertTrue(brief.contains("tracked files: 42"))
        XCTAssertTrue(brief.contains("languages: Swift"))
        XCTAssertTrue(brief.contains("manifests: Package.swift"))
        XCTAssertTrue(brief.contains("tests: swift test"))
        XCTAssertTrue(brief.contains("available models: gemini"))
    }

    func testLearningEvidenceStaysShadowUntilPromotionThreshold() {
        let snapshot = ProjectSnapshot(
            repo: "/repo",
            trackedFileCount: 20,
            directorySnapshot: "Sources",
            knownDirectories: ["", "Sources"],
            manifests: ["Package.swift"],
            testEntrypoints: ["swift test"],
            languages: ["Swift"],
            changedFiles: [],
            providers: [
                .init(binding: ProviderBinding(providerId: "openai", model: "gpt-5"),
                      displayName: "OpenAI",
                      capabilities: ModelCapabilities(nativeTools: true, structuredOutput: true),
                      keyed: true),
                .init(binding: ProviderBinding(providerId: "swiftbench", model: "swiftbench-code"),
                      displayName: "SwiftBench",
                      capabilities: ModelCapabilities(nativeTools: true, codeExecution: true),
                      keyed: true),
            ])
        let fallback = RoleBindings(default: ProviderBinding(providerId: "openai", model: "gpt-5"))
        let task = FleetSubtask(title: "Implement data mapper",
                                intent: "write Swift code",
                                scopeGlobs: ["Sources/*"],
                                acceptanceCriterion: "swift test passes")
        let shadowSamples = (0..<2).map { idx in
            CaptainLearningSample(taskSignature: "mapper", taskTags: ["coding"], language: "Swift",
                                  role: "coder", providerId: "swiftbench", model: "swiftbench-code",
                                  source: .benchmark, success: true, atEpoch: Double(idx))
        }
        let shadow = ModelAssignmentLearningContext(summaries: CaptainLearningStore.summarize(shadowSamples))

        let shadowAssigned = ModelAssignmentEngine.assign(subtasks: [task], snapshot: snapshot,
                                                          defaultRoles: fallback, learning: shadow)

        XCTAssertEqual(shadowAssigned[0].roles.binding(for: .coder).providerId, "openai",
                       "two wins are evidence, but not enough to override the deterministic baseline")
        XCTAssertFalse(shadowAssigned[0].assignment.capabilityTags.contains("learning"))
    }

    func testPromotedLearningCanBiasCoderAssignment() {
        let snapshot = ProjectSnapshot(
            repo: "/repo",
            trackedFileCount: 20,
            directorySnapshot: "Sources",
            knownDirectories: ["", "Sources"],
            manifests: ["Package.swift"],
            testEntrypoints: ["swift test"],
            languages: ["Swift"],
            changedFiles: [],
            providers: [
                .init(binding: ProviderBinding(providerId: "openai", model: "gpt-5"),
                      displayName: "OpenAI",
                      capabilities: ModelCapabilities(nativeTools: true, structuredOutput: true),
                      keyed: true),
                .init(binding: ProviderBinding(providerId: "swiftbench", model: "swiftbench-code"),
                      displayName: "SwiftBench",
                      capabilities: ModelCapabilities(nativeTools: true, codeExecution: true),
                      keyed: true),
            ])
        let fallback = RoleBindings(default: ProviderBinding(providerId: "openai", model: "gpt-5"))
        let task = FleetSubtask(title: "Implement data mapper",
                                intent: "write Swift code",
                                scopeGlobs: ["Sources/*"],
                                acceptanceCriterion: "swift test passes")
        let promotedSamples = (0..<3).map { idx in
            CaptainLearningSample(taskSignature: "mapper", taskTags: ["coding"], language: "Swift",
                                  role: "coder", providerId: "swiftbench", model: "swiftbench-code",
                                  source: .fleetSignoff, success: true, judgeScore: 0.9,
                                  atEpoch: Double(idx))
        }
        let learning = ModelAssignmentLearningContext(summaries: CaptainLearningStore.summarize(promotedSamples))

        let assigned = ModelAssignmentEngine.assign(subtasks: [task], snapshot: snapshot,
                                                    defaultRoles: fallback, learning: learning)

        XCTAssertEqual(assigned[0].roles.binding(for: .coder).providerId, "swiftbench")
        XCTAssertTrue(assigned[0].assignment.capabilityTags.contains("learning"))
        XCTAssertTrue(assigned[0].assignment.reason.contains("promoted"))
    }

    /// PINS THE FIX ITSELF — `preference(...) * namePrior` on EVERY role branch. The scalar curve
    /// `namePriorWeight(samples:)` is pinned in ModelAssignmentPriorTests, but the MULTIPLIER at the role
    /// branches was a mutation-survivor (dropping `* namePrior` on any single branch left the suite green),
    /// which would silently reinstate the audited bug: name-bias that evidence can never demote. For each role a
    /// name-FAVORED but capability-weaker model wins at COLD start (prior full), then LOSES to a
    /// capability-stronger challenger once the favored model carries enough UNPROMOTED evidence (successRate
    /// 1/3 < 0.67 ⇒ scoreBoost stays 0, so ONLY the decayed prior can cause the flip). One named assertion per
    /// branch (multi-site-invariant discipline). (Router-audit review 2026-08-15.)
    func testNamePriorMultiplierIsLiveOnEveryRoleBranch() {
        // (role, favored provider present in THAT role's preference table, a challenger capability that scores in
        //  that role's branch). Challenger id "challenger" matches no preference table ⇒ its only edge is capability.
        let coding = "write Swift code"
        let scenarios: [(role: AgentRole, favored: String, favModel: String,
                         challengerCaps: ModelCapabilities, intent: String, tags: [String])] = [
            (.coder,   "deepseek", "deepseek-v4-pro", ModelCapabilities(nativeTools: true, codeExecution: true),   coding, ["coding"]), // coder branch: codeExecution +8
            (.critic,  "gemini",   "gemini-2.5-pro",  ModelCapabilities(nativeTools: true, reasoning: true),       coding, ["coding"]), // critic branch: reasoning +7
            (.planner, "openai",   "gpt-5",           ModelCapabilities(nativeTools: true, reasoning: true),       coding, ["coding"]), // planner branch: reasoning +8
            // worker DELEGATES to .coder unless prefersResearch (CaptainIntelligence.swift:233), so the .worker
            // branch is only reachable via a RESEARCH task. Favored "deepseek" is in the worker table (11) only;
            // a contextWindow challenger (+9) pins the worker branch's `* namePrior`.
            (.worker,  "deepseek", "deepseek-v4-pro", ModelCapabilities(nativeTools: true, contextWindowTokens: 900_000),
             "research and compare external market docs and web sources", ["research"]),
        ]
        // fallback default is a THIRD provider so neither favored nor challenger picks up the +4 default bonus.
        let fallback = RoleBindings(default: ProviderBinding(providerId: "fallbackonly", model: "fb"))

        for s in scenarios {
            let task = FleetSubtask(title: "task", intent: s.intent,
                                    scopeGlobs: ["Sources/*"], acceptanceCriterion: "done")
            let snapshot = ProjectSnapshot(
                repo: "/repo", trackedFileCount: 20, directorySnapshot: "Sources",
                knownDirectories: ["", "Sources"], manifests: ["Package.swift"],
                testEntrypoints: ["swift test"], languages: ["Swift"], changedFiles: [],
                providers: [
                    .init(binding: ProviderBinding(providerId: s.favored, model: s.favModel),
                          displayName: s.favored,
                          capabilities: ModelCapabilities(nativeTools: true),   // in the name table, capability-minimal
                          keyed: true),
                    .init(binding: ProviderBinding(providerId: "challenger", model: "challenger-1"),
                          displayName: "Challenger",
                          capabilities: s.challengerCaps,                        // no table entry, a real capability edge
                          keyed: true),
                ])

            // COLD start: no evidence ⇒ namePrior 1.0 ⇒ the favored model's full preference wins.
            let cold = ModelAssignmentEngine.assign(subtasks: [task], snapshot: snapshot, defaultRoles: fallback)
            XCTAssertEqual(cold[0].roles.binding(for: s.role).providerId, s.favored,
                           "\(s.role): name-favored model must win at cold start (prior full)")

            // 60 UNPROMOTED samples on the favored model (1/3 success ⇒ not promoted ⇒ scoreBoost 0). The name
            // prior decays to ~0.12, dropping its preference (11–14) below the challenger's capability edge (7–8).
            let samples = (0..<60).map { idx in
                CaptainLearningSample(taskSignature: "mapper", taskTags: s.tags, language: "Swift",
                                      role: s.role.rawValue, providerId: s.favored, model: s.favModel,
                                      source: .benchmark, success: idx % 3 == 0, atEpoch: Double(idx))
            }
            let learning = ModelAssignmentLearningContext(summaries: CaptainLearningStore.summarize(samples))
            let decayed = ModelAssignmentEngine.assign(subtasks: [task], snapshot: snapshot,
                                                       defaultRoles: fallback, learning: learning)
            XCTAssertEqual(decayed[0].roles.binding(for: s.role).providerId, "challenger",
                           "\(s.role): once unpromoted evidence decays the name prior, the capability-stronger challenger must win — FAILS if `* namePrior` is dropped from the .\(s.role) branch")
        }
    }
}
