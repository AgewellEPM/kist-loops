import XCTest
@testable import AgentCore

final class HardProcessContainmentTests: XCTestCase {
    private let now: Int64 = 2_000_000_000_000
    private let digestA = String(repeating: "a", count: 64)
    private let digestB = String(repeating: "b", count: 64)
    private let digestC = String(repeating: "c", count: 64)

    private func limits(cpu: UInt64 = 3_000_000, memory: UInt64 = 256 * 1_024 * 1_024,
                        pids: UInt32 = 32) -> HardProcessContainmentLimits {
        HardProcessContainmentLimits(
            aggregateCPUTimeMicros: cpu,
            aggregateMemoryBytes: memory,
            aggregateProcessCount: pids)
    }

    private func requirement(scopeID: String = "11111111-1111-4111-8111-111111111111",
                             mechanism: HardProcessContainmentMechanism = .linuxDelegatedCgroupV2,
                             limits requested: HardProcessContainmentLimits? = nil,
                             mechanismDigest: String? = nil,
                             policyDigest: String? = nil,
                             executionDigest: String? = nil) -> HardProcessContainmentRequirement {
        HardProcessContainmentRequirement(
            scopeID: scopeID, mechanism: mechanism, limits: requested ?? limits(),
            mechanismDigest: mechanismDigest ?? digestA,
            policyDigest: policyDigest ?? digestB,
            expectedExecutionDigest: executionDigest ?? digestC)
    }

    private func membership(scope: Bool = true, joined: Bool = true, atomic: Bool = true,
                            inherited: Bool = true, escapePrevented: Bool = true,
                            cpu: Bool = true, memory: Bool = true, pids: Bool = true,
                            created: Int64? = nil, member: Int64? = nil,
                            started: Int64? = nil) -> HardProcessContainmentMembershipEvidence {
        HardProcessContainmentMembershipEvidence(
            scopeEstablishedBeforeExec: scope, launcherJoinedBeforeExec: joined,
            membershipEstablishedAtomically: atomic, descendantsInheritMembership: inherited,
            descendantEscapePrevented: escapePrevented, aggregateCPUTimeEnforced: cpu,
            aggregateMemoryEnforced: memory, aggregateProcessCountEnforced: pids,
            scopeCreatedAtMillis: created ?? now - 1_000,
            membershipVerifiedAtMillis: member ?? now - 900,
            executionStartedAtMillis: started ?? now - 800)
    }

    private func cleanup(killIssued: Bool = true, killCompleted: Bool = true,
                         empty: Bool = true, remaining: UInt32 = 0,
                         killedAt: Int64? = nil, emptyAt: Int64? = nil)
        -> HardProcessContainmentCleanupEvidence {
        HardProcessContainmentCleanupEvidence(
            killAllIssued: killIssued, killAllCompleted: killCompleted,
            scopeEmptyVerified: empty, remainingProcessCount: remaining,
            killAllIssuedAtMillis: killedAt ?? now - 500,
            emptyVerifiedAtMillis: emptyAt ?? now - 300)
    }

    private func receipt(scopeID: String = "11111111-1111-4111-8111-111111111111",
                         platform: HardProcessContainmentPlatform = .linux,
                         mechanism: HardProcessContainmentMechanism = .linuxDelegatedCgroupV2,
                         limits applied: HardProcessContainmentLimits? = nil,
                         mechanismDigest: String? = nil, policyDigest: String? = nil,
                         executionDigest: String? = nil,
                         membership member: HardProcessContainmentMembershipEvidence? = nil,
                         cleanup cleanupEvidence: HardProcessContainmentCleanupEvidence? = nil,
                         issued: Int64? = nil, validUntil: Int64? = nil)
        -> HardProcessContainmentReceipt {
        HardProcessContainmentReceipt(
            scopeID: scopeID, platform: platform, mechanism: mechanism,
            limits: applied ?? limits(), mechanismDigest: mechanismDigest ?? digestA,
            policyDigest: policyDigest ?? digestB, executionDigest: executionDigest ?? digestC,
            membership: member ?? membership(), cleanup: cleanupEvidence ?? cleanup(),
            issuedAtMillis: issued ?? now - 100, validUntilMillis: validUntil ?? now + 60_000)
    }

    private func consume(_ receipt: HardProcessContainmentReceipt,
                         requirement: HardProcessContainmentRequirement? = nil,
                         guard replayGuard: HardProcessContainmentReplayGuard = .init(),
                         platform: HardProcessContainmentPlatform = .linux,
                         nowMillis: Int64? = nil) throws -> ValidatedHardProcessContainment {
        try replayGuard.consume(receipt, satisfying: requirement ?? self.requirement(),
                                hostPlatform: platform, nowMillis: nowMillis ?? now)
    }

    private func assertError(_ expected: HardProcessContainmentError,
                             file: StaticString = #filePath, line: UInt = #line,
                             _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? HardProcessContainmentError, expected, file: file, line: line)
        }
    }

    func testCurrentBackendExplicitlyReportsHardContainmentUnavailable() {
        let status = HardProcessContainmentRuntime.currentAvailability
        XCTAssertFalse(status.available)
        XCTAssertTrue(status.reason.contains("hard containment unavailable"))
        #if os(macOS)
        XCTAssertEqual(status.platform, .macOS)
        XCTAssertEqual(status.mechanism, .macOSSeatbeltProcessGroup)
        XCTAssertTrue(status.reason.contains("Seatbelt"))
        XCTAssertTrue(status.reason.contains("aggregate CPU"))
        let publicGuard = HardProcessContainmentReplayGuard()
        assertError(.unavailable(status.reason)) {
            _ = try publicGuard.consume(
                receipt(), satisfying: requirement(),
                now: Date(timeIntervalSince1970: Double(now) / 1_000))
        }
        XCTAssertEqual(publicGuard.consumedScopeCount, 0)
        #elseif os(Linux)
        XCTAssertEqual(status.platform, .linux)
        XCTAssertEqual(status.mechanism, .linuxBubblewrapProcessGroup)
        #endif
    }

    func testAdvisoryMechanismsCanNeverSatisfyHardRequirement() {
        for mechanism in HardProcessContainmentMechanism.allCases where !mechanism.isQualifyingHardBackend {
            let requested = requirement(mechanism: mechanism)
            let evidence = receipt(mechanism: mechanism)
            assertError(.advisoryMechanism(mechanism)) {
                _ = try consume(evidence, requirement: requested)
            }
        }
    }

    func testCompleteLinuxContractValidatesAndScopeIsOneUse() throws {
        let replay = HardProcessContainmentReplayGuard()
        let evidence = receipt()
        let validated = try consume(evidence, guard: replay)
        XCTAssertEqual(validated.scopeID, requirement().scopeID)
        XCTAssertEqual(validated.executionDigest, digestC)
        XCTAssertEqual(validated.limits, limits())
        XCTAssertEqual(validated.mechanism, .linuxDelegatedCgroupV2)
        XCTAssertEqual(replay.consumedScopeCount, 1)
        assertError(.replayedScope) { _ = try consume(evidence, guard: replay) }
        XCTAssertEqual(replay.consumedScopeCount, 1)
    }

    func testScopeMustBeCanonicalAndMatchWithoutBurningOneUseID() throws {
        let replay = HardProcessContainmentReplayGuard()
        let wrong = receipt(scopeID: "22222222-2222-4222-8222-222222222222")
        assertError(.bindingMismatch("scopeID")) {
            _ = try consume(wrong, guard: replay)
        }
        XCTAssertEqual(replay.consumedScopeCount, 0)
        assertError(.invalidField("scopeID")) {
            _ = try consume(receipt(scopeID: "not-a-scope"), guard: replay)
        }
        XCTAssertEqual(replay.consumedScopeCount, 0)
        _ = try consume(receipt(), guard: replay)
        XCTAssertEqual(replay.consumedScopeCount, 1)
    }

    func testEveryAggregateLimitMustBePositiveAndMatchExactly() {
        let cases: [(HardProcessContainmentLimits, HardProcessContainmentError)] = [
            (limits(cpu: 3_000_001), .limitMismatch("aggregateCPUTimeMicros")),
            (limits(memory: 256 * 1_024 * 1_024 + 1), .limitMismatch("aggregateMemoryBytes")),
            (limits(pids: 33), .limitMismatch("aggregateProcessCount")),
        ]
        for (applied, expected) in cases {
            assertError(expected) { _ = try consume(receipt(limits: applied)) }
        }
        assertError(.invalidField("requirement.aggregateCPUTimeMicros")) {
            _ = try consume(receipt(), requirement: requirement(limits: limits(cpu: 0)))
        }
        assertError(.invalidField("receipt.aggregateMemoryBytes")) {
            _ = try consume(receipt(limits: limits(memory: 0)))
        }
        assertError(.invalidField("receipt.aggregateProcessCount")) {
            _ = try consume(receipt(limits: limits(pids: 0)))
        }
    }

    func testMechanismPolicyAndExecutionDigestsAreStrictlyBound() {
        assertError(.bindingMismatch("mechanismDigest")) {
            _ = try consume(receipt(mechanismDigest: String(repeating: "d", count: 64)))
        }
        assertError(.bindingMismatch("policyDigest")) {
            _ = try consume(receipt(policyDigest: String(repeating: "d", count: 64)))
        }
        assertError(.bindingMismatch("executionDigest")) {
            _ = try consume(receipt(executionDigest: String(repeating: "d", count: 64)))
        }
        assertError(.invalidField("receipt policyDigest")) {
            _ = try consume(receipt(policyDigest: "NOT-A-DIGEST"))
        }
    }

    func testAllPreExecAndAggregateEnforcementFactsAreRequired() {
        let membershipCases: [(HardProcessContainmentMembershipEvidence, HardProcessContainmentError)] = [
            (membership(scope: false), .preExecMembershipUnproven("scopeEstablishedBeforeExec")),
            (membership(joined: false), .preExecMembershipUnproven("launcherJoinedBeforeExec")),
            (membership(atomic: false), .preExecMembershipUnproven("membershipEstablishedAtomically")),
            (membership(inherited: false), .preExecMembershipUnproven("descendantsInheritMembership")),
            (membership(escapePrevented: false), .preExecMembershipUnproven("descendantEscapePrevented")),
            (membership(cpu: false), .aggregateLimitUnproven("aggregateCPUTime")),
            (membership(memory: false), .aggregateLimitUnproven("aggregateMemory")),
            (membership(pids: false), .aggregateLimitUnproven("aggregateProcessCount")),
        ]
        for (member, expected) in membershipCases {
            assertError(expected) { _ = try consume(receipt(membership: member)) }
        }
    }

    func testKillAllAndVerifiedEmptyAreMandatory() {
        let cleanupCases: [(HardProcessContainmentCleanupEvidence, HardProcessContainmentError)] = [
            (cleanup(killIssued: false), .cleanupUnproven("killAllIssued")),
            (cleanup(killCompleted: false), .cleanupUnproven("killAllCompleted")),
            (cleanup(empty: false), .cleanupUnproven("scopeEmptyVerified")),
            (cleanup(remaining: 1), .cleanupUnproven("remainingProcessCount")),
        ]
        for (cleanupEvidence, expected) in cleanupCases {
            assertError(expected) { _ = try consume(receipt(cleanup: cleanupEvidence)) }
        }
    }

    func testTimelineMustProveMembershipBeforeExecAndCleanupBeforeIssue() {
        assertError(.invalidTimeline) {
            _ = try consume(receipt(membership: membership(member: now - 700, started: now - 800)))
        }
        assertError(.invalidTimeline) {
            _ = try consume(receipt(cleanup: cleanup(killedAt: now - 200, emptyAt: now - 300)))
        }
        assertError(.invalidTimeline) {
            _ = try consume(receipt(cleanup: cleanup(emptyAt: now - 31_000)))
        }
        assertError(.invalidTimeline) {
            _ = try consume(receipt(issued: now - 100, validUntil: now + 300_001))
        }
    }

    func testFreshnessRejectsFutureAndExpiredEvidence() {
        assertError(.notYetValid) {
            _ = try consume(receipt(issued: now + 5_001, validUntil: now + 60_000))
        }
        assertError(.expired) {
            let oldMembership = membership(
                created: now - 61_000, member: now - 60_900, started: now - 60_800)
            let oldCleanup = cleanup(killedAt: now - 60_500, emptyAt: now - 60_300)
            _ = try consume(receipt(membership: oldMembership, cleanup: oldCleanup,
                                    issued: now - 60_000, validUntil: now - 1))
        }
    }

    func testMacOSCannotAcceptLinuxHardReceiptAndWrongPlatformsFail() {
        let evidence = receipt()
        assertError(.unavailable(HardProcessContainmentRuntime.unavailableReason(for: .macOS))) {
            _ = try consume(evidence, platform: .macOS)
        }
        assertError(.platformMismatch) {
            _ = try consume(receipt(platform: .unsupported), platform: .linux)
        }
    }
}
