import XCTest
@testable import AgentCore

/// End-to-end self-evolution: discovery, the promote gate, and the composed engine — all exercised on the
/// REAL failures Luke hit, proving each one now produces an ACTION instead of a give-up.
final class SelfEvolutionEngineTests: XCTestCase {

    // MARK: - CapabilityDiscovery

    func testPerslisRunCommandDiscoversItsCommandList() {
        // The exact perslis win98 case: refused + "(search: win98_run_commands)"; the sibling list tool exists.
        let step = CapabilityDiscovery.step(
            tool: "perslis__win98_run_command",
            hint: "this tool launches only cataloged Run-prompt commands (search: win98_run_commands)",
            availableTools: ["perslis__win98_run_command", "perslis__win98_run_commands", "perslis__vm_key"])
        XCTAssertEqual(step.listTool, "perslis__win98_run_commands")
        XCTAssertTrue(step.brief.contains("DISCOVER"))
    }

    func testPluralSiblingUsedWhenNoHint() {
        let step = CapabilityDiscovery.step(
            tool: "perslis__win98_run_command", hint: nil,
            availableTools: ["perslis__win98_run_command", "perslis__win98_run_commands"])
        XCTAssertEqual(step.listTool, "perslis__win98_run_commands")
    }

    func testVmKeyRetriesFromInlineQcodeList() {
        // "Use e.g. ret, esc, tab…" inlines the valid values — retry straight from the hint, no list call.
        let step = CapabilityDiscovery.step(
            tool: "perslis__vm_key",
            hint: "Use e.g. ret, esc, tab, up/down/left/right, ctrl, alt",
            availableTools: ["perslis__vm_key"])
        XCTAssertNil(step.listTool)
        XCTAssertTrue(step.brief.contains("RETRY"))
    }

    func testNoDiscoveryFallsBackToContractReread() {
        let step = CapabilityDiscovery.step(tool: "weird_tool", hint: nil, availableTools: [])
        XCTAssertNil(step.listTool)
        XCTAssertTrue(step.brief.contains("RE-READ"))
    }

    // MARK: - AdversarialPromoteGate (the promote rule)

    func testRedBuildNeverPromotes() {
        let d = AdversarialPromoteGate.decide(ownTestsPassed: false,
                                              adversary: AdversaryVerdict(survived: true, confidence: 1.0))
        XCTAssertFalse(d.promote)
    }

    func testAdversaryBreakingItRejects() {
        let d = AdversarialPromoteGate.decide(ownTestsPassed: true,
            adversary: AdversaryVerdict(survived: false, attackFound: "test asserts nothing", confidence: 0.9))
        XCTAssertFalse(d.promote)
        XCTAssertTrue(d.reason.contains("test asserts nothing"))
    }

    func testSurvivedButLowConfidenceHolds() {
        let d = AdversarialPromoteGate.decide(ownTestsPassed: true,
                                              adversary: AdversaryVerdict(survived: true, confidence: 0.4))
        XCTAssertFalse(d.promote, "a shrug isn't a vouch — hold for a human")
    }

    func testGreenPlusConfidentSurvivalPromotes() {
        let d = AdversarialPromoteGate.decide(ownTestsPassed: true,
                                              adversary: AdversaryVerdict(survived: true, confidence: 0.9))
        XCTAssertTrue(d.promote, "the ONLY path that ships: green gate AND confident independent survival")
    }

    func testSameModelSurvivalIsAdvisoryAndNeverPromotes() {
        let d = AdversarialPromoteGate.decide(
            ownTestsPassed: true,
            adversary: AdversaryVerdict(survived: true, confidence: 1.0),
            reviewGrade: .freshContextSameModel)
        XCTAssertFalse(d.promote)
        XCTAssertTrue(d.reason.contains("identity-distinct"), d.reason)
        XCTAssertTrue(d.reason.contains("quarantined"), d.reason)
    }

    // MARK: - Engine end-to-end

    func testEnginePerslisKnowledgeGapProducesDiscoverAndRetry() {
        let signals = FailureSignals(toolFailures: [ToolFailure(
            tool: "perslis__win98_run_command",
            error: "unknown Windows 98 run command: C:\\HELLO.VBS, hint: (search: win98_run_commands)")])
        let d = SelfEvolutionEngine.decide(
            signals: signals,
            availableTools: ["perslis__win98_run_command", "perslis__win98_run_commands"], now: 1000)
        XCTAssertEqual(d.kind, .discoverAndRetry)
        XCTAssertEqual(d.discovery?.listTool, "perslis__win98_run_commands")
        XCTAssertNil(d.skipped)
    }

    func testEngineForeignToolLimitIsSpecOnly() {
        let signals = FailureSignals(toolFailures: (0..<2).map {
            ToolFailure(tool: "perslis__win98_run_command", error: "unknown Windows 98 run command: cmd\($0)")})
        let d = SelfEvolutionEngine.decide(signals: signals, availableTools: [], now: 1000)
        XCTAssertEqual(d.kind, .extendTool)
        XCTAssertEqual(d.ownership, .foreign)
        XCTAssertEqual(d.foreignServer, "perslis")
        XCTAssertTrue(d.brief.contains("do NOT edit that repo"), "never blend repos")
    }

    func testEngineKistToolLimitAutoEvolves() {
        let signals = FailureSignals(toolFailures: (0..<2).map {
            ToolFailure(tool: "run_command", error: "unsupported flag --frobnicate attempt\($0)")})
        let d = SelfEvolutionEngine.decide(signals: signals, availableTools: [], now: 1000)
        XCTAssertEqual(d.kind, .extendTool)
        XCTAssertEqual(d.ownership, .kist)
        XCTAssertTrue(d.brief.contains("adversarial review"), "kist tools auto-evolve but never self-certify")
        XCTAssertNotNil(d.signature)
    }

    func testEngineLedgerGuardSkipsRepeatEvolution() {
        let signals = FailureSignals(toolFailures: (0..<2).map {
            ToolFailure(tool: "run_command", error: "unsupported flag --frobnicate a\($0)")})
        let sig = SelfEvolutionLedger.signature(
            tool: "run_command",
            evidence: FailureClassifier.classify(signals).evidence)
        let history = [SelfEvolutionAttempt(tool: "run_command", category: "toolLimit",
                                            signature: sig, outcome: "rejected", atEpoch: 990)]
        let d = SelfEvolutionEngine.decide(signals: signals, availableTools: [],
                                           ledgerHistory: history, now: 1000)
        XCTAssertNotNil(d.skipped, "an already-rejected evolution must not be retried unattended")
    }
}
