import XCTest
@testable import AgentCore

/// Activation (store save/load → callable ScriptTool) and the P2 script gate (acceptance test under the
/// contained runner). Uses a real bash tool so the round-trip is end-to-end.
final class SelfAuthoredStoreGateTests: XCTestCase {

    #if os(macOS)
    private let nowMillis: Int64 = 2_000_000_000_000
    private let promotionDigest = String(repeating: "d", count: 64)
    private let smokeDigest = String(repeating: "c", count: 64)
    private let routeAttestationDigest = String(repeating: "f", count: 64)

    override func setUp() {
        super.setUp()
        ForgeSeal.forceEphemeralKeyForTesting()
    }

    override func tearDown() {
        ForgeSeal.resetCacheForTesting()
        super.tearDown()
    }

    private func tmpRoot() -> String {
        let d = (NSTemporaryDirectory() as NSString).appendingPathComponent("kist-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    // A self__ tool that upper-cases its --text arg (a real, verifiable capability).
    private func upperManifest() -> SelfAuthoredManifest {
        SelfAuthoredManifest(
            name: "self__upper", description: "upper-case the --text argument",
            interpreter: "/bin/bash", scriptFile: "upper.sh",
            parameters: [.init(name: "text", description: "text to upper-case")],
            contract: "given --text T, prints T upper-cased",
            testArgs: ["text": "hello"], testExpectSubstring: "HELLO")
    }
    private let upperScript = """
    #!/bin/bash
    text=""
    while [[ $# -gt 0 ]]; do case "$1" in --text) text="$2"; shift 2;; *) shift;; esac; done
    echo "$text" | tr '[:lower:]' '[:upper:]'
    """

    private func independentReview() -> EvolutionReviewReceipt {
        EvolutionReviewReceipt(
            grade: .independent, independent: true,
            authorIdentity: "codex-cli:gpt-5.6-sol",
            criticIdentity: "claude-cli:claude-opus-4-1",
            authorInvocationID: "author-invocation",
            criticInvocationID: "critic-invocation",
            freshConversation: true, separateInvocation: true)
    }

    private func validatedReview(_ review: EvolutionReviewReceipt? = nil,
                                 promotionDigest: String? = nil) throws
        -> ValidatedIdentityDistinctEvolutionReview {
        try IdentityDistinctEvolutionReviewValidator.validateForTesting(
            review ?? independentReview(),
            reviewedPromotionEvidenceDigest: promotionDigest ?? self.promotionDigest,
            actualRouteAttestationDigest: routeAttestationDigest)
    }

    /// Produce the opaque value that only the trusted hard-containment validator can return. This uses the
    /// contract's internal cross-platform test seam; production callers must use the public runtime method,
    /// which currently refuses because no qualifying backend is wired.
    private func validatedContainment(executionDigest: String? = nil) throws
        -> ValidatedHardProcessContainment {
        let scopeID = UUID().uuidString.lowercased()
        let limits = HardProcessContainmentLimits(
            aggregateCPUTimeMicros: 3_000_000,
            aggregateMemoryBytes: 256 * 1_024 * 1_024,
            aggregateProcessCount: 32)
        let mechanismDigest = String(repeating: "a", count: 64)
        let policyDigest = String(repeating: "b", count: 64)
        let exactExecution = executionDigest ?? smokeDigest
        let requirement = HardProcessContainmentRequirement(
            scopeID: scopeID, mechanism: .linuxDelegatedCgroupV2, limits: limits,
            mechanismDigest: mechanismDigest, policyDigest: policyDigest,
            expectedExecutionDigest: exactExecution)
        let membership = HardProcessContainmentMembershipEvidence(
            scopeEstablishedBeforeExec: true, launcherJoinedBeforeExec: true,
            membershipEstablishedAtomically: true, descendantsInheritMembership: true,
            descendantEscapePrevented: true, aggregateCPUTimeEnforced: true,
            aggregateMemoryEnforced: true, aggregateProcessCountEnforced: true,
            scopeCreatedAtMillis: nowMillis - 1_000,
            membershipVerifiedAtMillis: nowMillis - 900,
            executionStartedAtMillis: nowMillis - 800)
        let cleanup = HardProcessContainmentCleanupEvidence(
            killAllIssued: true, killAllCompleted: true, scopeEmptyVerified: true,
            remainingProcessCount: 0, killAllIssuedAtMillis: nowMillis - 500,
            emptyVerifiedAtMillis: nowMillis - 300)
        let receipt = HardProcessContainmentReceipt(
            scopeID: scopeID, platform: .linux, mechanism: .linuxDelegatedCgroupV2,
            limits: limits, mechanismDigest: mechanismDigest, policyDigest: policyDigest,
            executionDigest: exactExecution, membership: membership, cleanup: cleanup,
            issuedAtMillis: nowMillis - 100, validUntilMillis: nowMillis + 60_000)
        return try HardProcessContainmentReplayGuard().consume(
            receipt, satisfying: requirement, hostPlatform: .linux, nowMillis: nowMillis)
    }

    func testStoreRoundTripLoadsButProductionExecutionRefusesWithoutHardScope() async throws {
        let store = SelfAuthoredToolStore(projectRoot: tmpRoot())
        let home = try store.savePromoted(
            manifest: upperManifest(), scriptBody: upperScript,
            reviewAuthority: validatedReview(), promotionEvidenceDigest: promotionDigest,
            smokeEvidenceDigest: smokeDigest,
            containment: validatedContainment())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (home as NSString).appendingPathComponent("activation.receipt.json")))
        XCTAssertTrue(store.load().isEmpty,
                      "public runtime load must reject a test-minted review authority")
        let tools = store.loadForTesting()
        XCTAssertEqual(tools.count, 1)
        let tool = try XCTUnwrap(tools.first)
        XCTAssertEqual(tool.name, "self__upper")
        let r = try await tool.execute(arguments: ["text": "world"], context: ToolContext(projectRoot: "/tmp"))
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("hard containment unavailable") == true, "\(String(describing: r.error))")
        XCTAssertEqual(r.metadata["hard_containment"], "unavailable")
    }

    func testUnsignedLegacyManifestAndScriptLoadZeroTools() throws {
        let store = SelfAuthoredToolStore(projectRoot: tmpRoot())
        let home = try store.stageForTesting(manifest: upperManifest(), scriptBody: upperScript)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (home as NSString).appendingPathComponent("activation.receipt.json")))
        XCTAssertTrue(store.load().isEmpty, "unsigned legacy manifest/script pairs are never load authority")
    }

    func testPublicLoadRejectsTestMintedActivationInDebugBuild() throws {
        let store = SelfAuthoredToolStore(projectRoot: tmpRoot())
        _ = try store.savePromoted(
            manifest: upperManifest(), scriptBody: upperScript,
            reviewAuthority: validatedReview(), promotionEvidenceDigest: promotionDigest,
            smokeEvidenceDigest: smokeDigest, containment: validatedContainment())

        XCTAssertTrue(store.load().isEmpty)
        XCTAssertTrue(store.names().isEmpty)
        XCTAssertEqual(store.loadForTesting().map(\.name), ["self__upper"],
                       "only the internal XCTest loader may opt into test authority")
    }

    func testSaveRefusesNonSelfNamespace() {
        let store = SelfAuthoredToolStore(projectRoot: tmpRoot())
        var m = upperManifest()
        m = SelfAuthoredManifest(name: "sneaky_tool", description: m.description, interpreter: m.interpreter,
                                 scriptFile: m.scriptFile, parameters: m.parameters, contract: m.contract,
                                 testArgs: m.testArgs, testExpectSubstring: m.testExpectSubstring)
        XCTAssertThrowsError(
            try store.savePromoted(
                manifest: m, scriptBody: upperScript,
                reviewAuthority: validatedReview(), promotionEvidenceDigest: promotionDigest,
                smokeEvidenceDigest: smokeDigest,
                containment: validatedContainment()),
            "only self__ may be saved")
    }

    func testSameModelReviewCanNeverActivate() throws {
        let store = SelfAuthoredToolStore(projectRoot: tmpRoot())
        let review = EvolutionReviewReceipt(
            grade: .freshContextSameModel, independent: false,
            authorIdentity: "codex-cli:gpt-5.6-sol",
            criticIdentity: "codex-cli:gpt-5.6-sol",
            authorInvocationID: "author-invocation",
            criticInvocationID: "critic-invocation",
            freshConversation: true, separateInvocation: true)
        XCTAssertThrowsError(try validatedReview(review)) { error in
                guard case IdentityDistinctEvolutionReviewValidationError.invalidReview = error else {
                    return XCTFail("expected identity validator invalidReview, got \(error)")
                }
            }
        XCTAssertTrue(store.load().isEmpty)
    }

    func testRawReviewCannotBecomeProductionActivationAuthority() {
        let availability = IdentityDistinctEvolutionReviewValidator.currentAvailability
        XCTAssertFalse(availability.available)
        XCTAssertTrue(availability.reason.contains("actual-route"))
        XCTAssertThrowsError(try IdentityDistinctEvolutionReviewValidator.validate(
            independentReview(), reviewedPromotionEvidenceDigest: promotionDigest)) { error in
                guard case IdentityDistinctEvolutionReviewValidationError.unavailable = error else {
                    return XCTFail("raw review must remain unavailable as production authority: \(error)")
                }
            }
    }

    func testContainmentMustBindExactSmokeDigest() throws {
        let store = SelfAuthoredToolStore(projectRoot: tmpRoot())
        XCTAssertThrowsError(try store.savePromoted(
            manifest: upperManifest(), scriptBody: upperScript,
            reviewAuthority: validatedReview(), promotionEvidenceDigest: promotionDigest,
            smokeEvidenceDigest: smokeDigest,
            containment: validatedContainment(executionDigest: String(repeating: "e", count: 64)))) { error in
                guard case SelfAuthoredToolStoreError.invalidContainment = error else {
                    return XCTFail("expected invalidContainment, got \(error)")
                }
            }
        XCTAssertTrue(store.load().isEmpty)
    }

    func testContainmentScopeCanAuthorizeOnlyOneActivation() throws {
        let containment = try validatedContainment()
        let authority = try validatedReview()
        let first = SelfAuthoredToolStore(projectRoot: tmpRoot())
        _ = try first.savePromoted(
            manifest: upperManifest(), scriptBody: upperScript,
            reviewAuthority: authority, promotionEvidenceDigest: promotionDigest,
            smokeEvidenceDigest: smokeDigest, containment: containment)

        let secondRoot = tmpRoot()
        let second = SelfAuthoredToolStore(projectRoot: secondRoot)
        XCTAssertThrowsError(try second.savePromoted(
            manifest: upperManifest(), scriptBody: upperScript,
            reviewAuthority: authority, promotionEvidenceDigest: promotionDigest,
            smokeEvidenceDigest: smokeDigest, containment: containment)) { error in
                guard case SelfAuthoredToolStoreError.replayedContainmentScope = error else {
                    return XCTFail("expected process-wide scope replay refusal, got \(error)")
                }
            }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (secondRoot as NSString).appendingPathComponent(".kist/self-tools/self__upper")))
    }

    func testReviewAuthorityIsBoundToPromotionEvidence() throws {
        let store = SelfAuthoredToolStore(projectRoot: tmpRoot())
        let otherPromotion = String(repeating: "e", count: 64)
        XCTAssertThrowsError(try store.savePromoted(
            manifest: upperManifest(), scriptBody: upperScript,
            reviewAuthority: validatedReview(promotionDigest: otherPromotion),
            promotionEvidenceDigest: promotionDigest,
            smokeEvidenceDigest: smokeDigest,
            containment: validatedContainment())) { error in
                guard case SelfAuthoredToolStoreError.invalidReview = error else {
                    return XCTFail("expected promotion/review binding refusal, got \(error)")
                }
            }
        XCTAssertTrue(store.load().isEmpty)
    }

    func testTamperedOrLooseModeArtifactLoadsZeroTools() throws {
        let root = tmpRoot()
        let store = SelfAuthoredToolStore(projectRoot: root)
        let home = try store.savePromoted(
            manifest: upperManifest(), scriptBody: upperScript,
            reviewAuthority: validatedReview(), promotionEvidenceDigest: promotionDigest,
            smokeEvidenceDigest: smokeDigest, containment: validatedContainment())
        let script = (home as NSString).appendingPathComponent("upper.sh")
        try (upperScript + "\necho tampered\n").write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script)
        XCTAssertTrue(store.loadForTesting().isEmpty,
                      "the sealed exact script bytes must be recomputed on load")

        try upperScript.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script)
        XCTAssertTrue(store.loadForTesting().isEmpty,
                      "a group/world-readable activation artifact is loose-mode")
    }

    func testSymlinkHardlinkAndNonregularArtifactsLoadZeroTools() throws {
        let symlinkRoot = tmpRoot()
        let symlinkStore = SelfAuthoredToolStore(projectRoot: symlinkRoot)
        let symlinkHome = try symlinkStore.savePromoted(
            manifest: upperManifest(), scriptBody: upperScript,
            reviewAuthority: validatedReview(), promotionEvidenceDigest: promotionDigest,
            smokeEvidenceDigest: smokeDigest, containment: validatedContainment())
        let scriptPath = (symlinkHome as NSString).appendingPathComponent("upper.sh")
        let outside = (symlinkRoot as NSString).appendingPathComponent("outside.sh")
        try upperScript.write(toFile: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: scriptPath)
        try FileManager.default.createSymbolicLink(atPath: scriptPath, withDestinationPath: outside)
        XCTAssertTrue(symlinkStore.loadForTesting().isEmpty,
                      "O_NOFOLLOW must reject a symlinked script")

        let hardlinkRoot = tmpRoot()
        let hardlinkStore = SelfAuthoredToolStore(projectRoot: hardlinkRoot)
        let hardlinkHome = try hardlinkStore.savePromoted(
            manifest: upperManifest(), scriptBody: upperScript,
            reviewAuthority: validatedReview(), promotionEvidenceDigest: promotionDigest,
            smokeEvidenceDigest: smokeDigest, containment: validatedContainment())
        let hardlinkScript = (hardlinkHome as NSString).appendingPathComponent("upper.sh")
        let secondLink = (hardlinkRoot as NSString).appendingPathComponent("second-link.sh")
        try FileManager.default.linkItem(atPath: hardlinkScript, toPath: secondLink)
        XCTAssertTrue(hardlinkStore.loadForTesting().isEmpty,
                      "an artifact with st_nlink != 1 is not load authority")

        let nonregularRoot = tmpRoot()
        let nonregularStore = SelfAuthoredToolStore(projectRoot: nonregularRoot)
        let nonregularHome = try nonregularStore.savePromoted(
            manifest: upperManifest(), scriptBody: upperScript,
            reviewAuthority: validatedReview(), promotionEvidenceDigest: promotionDigest,
            smokeEvidenceDigest: smokeDigest, containment: validatedContainment())
        let receiptPath = (nonregularHome as NSString).appendingPathComponent("activation.receipt.json")
        try FileManager.default.removeItem(atPath: receiptPath)
        try FileManager.default.createDirectory(atPath: receiptPath, withIntermediateDirectories: false)
        XCTAssertTrue(nonregularStore.loadForTesting().isEmpty,
                      "a directory cannot impersonate a regular receipt file")
    }

    func testLoadDoesNotCreateAMissingForgeSealKey() throws {
        let root = tmpRoot()
        let store = SelfAuthoredToolStore(projectRoot: root)
        _ = try store.savePromoted(
            manifest: upperManifest(), scriptBody: upperScript,
            reviewAuthority: validatedReview(), promotionEvidenceDigest: promotionDigest,
            smokeEvidenceDigest: smokeDigest, containment: validatedContainment())

        ForgeSeal.resetCacheForTesting()
        let absentKeyDirectory = (tmpRoot() as NSString).appendingPathComponent("keys")
        ForgeSeal.keyDirectoryOverrideForTesting = absentKeyDirectory
        XCTAssertTrue(store.loadForTesting().isEmpty, "an unverifiable seal must fail closed")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (absentKeyDirectory as NSString).appendingPathComponent("forgeseal-v1.key")),
            "read-only activation loading must not create missing key material")
    }

    func testProductionGateRefusesAWorkingToolWithoutHardContainment() async throws {
        let root = tmpRoot()
        let store = SelfAuthoredToolStore(projectRoot: root)
        let home = try store.stageForTesting(manifest: upperManifest(), scriptBody: upperScript)
        let gate = ScriptCandidateGate()
        let cand = CapabilityCandidate(toolName: "self__upper", workdir: home, contract: "x", authorProvider: "deepseek")
        let v = await gate.verify(cand)
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.reason.contains("hard containment unavailable"), v.reason)
    }

    func testGateRejectsAToolThatFailsItsOwnTest() async throws {
        let root = tmpRoot()
        let store = SelfAuthoredToolStore(projectRoot: root)
        // A script that does the WRONG thing (lower-cases) → acceptance test (expects HELLO) fails.
        let badScript = "#!/bin/bash\necho hello\n"
        let m = upperManifest()
        let home = try store.stageForTesting(manifest: m, scriptBody: badScript)
        let gate = ScriptCandidateGate()
        let cand = CapabilityCandidate(toolName: "self__upper", workdir: home, contract: "x", authorProvider: "deepseek")
        let v = await gate.verify(cand)
        XCTAssertFalse(v.passed, "a tool that fails its own acceptance test must not pass the gate")
    }
    #endif
}
