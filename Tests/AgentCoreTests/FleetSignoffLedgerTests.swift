import XCTest
@testable import AgentCore

/// Proves the FLEET SIGNOFF substrate. Each test pins ONE distinct invariant of the forge-proof signoff
/// ledger and asserts the ACTUAL guarantee — NOT "didn't crash":
///
///   (1) a legitimately sealed .green entry verifies + signedOff() is true
///   (2) the chain links + verifyChain() == nil on an intact ledger
///   (3) a non-green verdict is REJECTED at record() (the no-forge gate)
///   (4) a FORGED row (bad seal, hand-written into the file) is rejected at LOAD
///   (5) a TAMPERED chain → verifyChain() reports the FIRST broken seq, and a broken chain collapses
///       signedOff()/entries to ZERO (fail-safe stricter)
///   (6) replay/duplicate agent rows are deduped to ONE signoff signal
///   (7) persistence survives a reload from the same baseDir
///   (8) public non-code greens are rejected (only AgentCore code-green provenance signs off code)
///   (9) seal/write failures return nil and leave no in-memory row
///
/// To obtain a real .green GroundedVerdict the test plays it straight: build real BuildFacts from
/// evidence (exit code 0, diff present, codex reviewed) + a confirmed WorldFacts, run
/// GroundedVerdict.fromCode (the deterministic referee). GroundedVerdict.init is private — which is
/// precisely why record() requiring a green one means a bragging caller has no write path.
final class FleetSignoffLedgerTests: XCTestCase {

    // MARK: Temp baseDir seam (own custody dir per test, cleaned up)

    private var tempDir: URL!

    override func setUpWithError() throws {
        // Force a fresh process-ephemeral ForgeSeal key per test: clean sign→verify semantics, no disk
        // key written (cross-platform — does not depend on the XCTest env var being set on Linux).
        ForgeSeal.forceEphemeralKeyForTesting()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetSignoffLedgerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Green-verdict + evidence helpers (the test is the honest foreman)

    /// Build a REAL .green GroundedVerdict via the referee over measured evidence — the only path to a
    /// green (GroundedVerdict.init is private): tests pass, diff present, codex reviewed, world confirmed.
    private func greenVerdict(buildID: String) -> GroundedVerdict {
        let world = WorldFacts(confirmedHelpForBuild: 1, signalBroken: false, hasSignal: true)
        let build = BuildFacts(buildID: buildID, claimedDone: true,
                               tests: TestRunEvidence(exitCode: 0),
                               diff: DiffEvidence(changedLines: 12, maxFileLines: 380),
                               codex: CodexEvidence(reviewed: true),
                               stepCapHit: false, runIncomplete: false)
        let g = GroundedVerdict.fromCode(CaptainFacts(build: build, world: world))
        precondition(g.verdict == .green, "test setup: facts must referee to .green")
        return g
    }

    private func evidence(buildID: String) -> FleetSignoffEvidence {
        FleetSignoffEvidence(buildID: buildID, testExitCode: 0, changedLines: 12,
                             maxFileLines: 380, outOfScopeCount: 0,
                             summary: "branch met structural done-criteria on this machine")
    }

    // MARK: (1) A legit sealed .green entry verifies + signedOff() is true

    func testLegitGreenSignoffVerifiesAndSignsOff() throws {
        let agent = UUID()
        let ledger = FleetSignoffLedger(baseDir: tempDir)

        let entry = ledger.record(goalID: "G", agentID: agent, branch: "feat/a",
                                  grounded: greenVerdict(buildID: "b0"),
                                  evidence: evidence(buildID: "b0"), atEpoch: 100)
        let e = try XCTUnwrap(entry, "a real .green must be admitted")

        XCTAssertEqual(e.seq, 0)
        XCTAssertEqual(e.prevHash, "", "genesis entry must have empty prevHash")
        XCTAssertEqual(e.verdict, .green)
        XCTAssertTrue(e.sealValid, "a freshly recorded entry carries a valid ForgeSeal")
        XCTAssertFalse(e.entryHash.isEmpty)
        XCTAssertNil(ledger.verifyChain(), "single legit entry → intact chain")
        XCTAssertTrue(ledger.signedOff(agentID: agent), "the agent has a trustworthy green signoff")
        XCTAssertTrue(ledger.signedOff(goalID: "G", agentID: agent), "goal-scoped gate also passes")
        XCTAssertFalse(ledger.signedOff(agentID: UUID()), "an unrelated agent is NOT signed off")
        XCTAssertFalse(ledger.signedOff(goalID: "OTHER", agentID: agent), "wrong goal is NOT signed off")

        // The compact Signoff proof links back to the chain by entryHash.
        let proof = ledger.signoff(for: e, atEpoch: 100)
        XCTAssertEqual(proof.ledgerSeq, e.seq)
        XCTAssertEqual(proof.ledgerEntryHash, e.entryHash, "proof links to the chain by tamper-evident hash")
        XCTAssertEqual(proof.verdict, .green)
    }

    // MARK: (2) Appended entries CHAIN + verifyChain() == nil when intact

    func testEntriesChainAndVerifyNilWhenIntact() {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let e0 = ledger.record(goalID: "G", agentID: UUID(), branch: "a",
                               grounded: greenVerdict(buildID: "b0"),
                               evidence: evidence(buildID: "b0"), atEpoch: 1)!
        let e1 = ledger.record(goalID: "G", agentID: UUID(), branch: "b",
                               grounded: greenVerdict(buildID: "b1"),
                               evidence: evidence(buildID: "b1"), atEpoch: 2)!
        let e2 = ledger.record(goalID: "G", agentID: UUID(), branch: "c",
                               grounded: greenVerdict(buildID: "b2"),
                               evidence: evidence(buildID: "b2"), atEpoch: 3)!

        XCTAssertEqual(e1.prevHash, e0.entryHash, "entry 1 chains to entry 0's hash")
        XCTAssertEqual(e2.prevHash, e1.entryHash, "entry 2 chains to entry 1's hash")
        XCTAssertNotEqual(e0.entryHash, e1.entryHash, "distinct payloads hash distinctly")
        XCTAssertNotEqual(e1.entryHash, e2.entryHash)
        XCTAssertNil(ledger.verifyChain(), "an untampered chain verifies clean")
        XCTAssertEqual(ledger.entries.count, 3, "all three are trustworthy")

        // Empty ledger is trivially intact and signs off no one.
        let empty = FleetSignoffLedger(baseDir: tempDir.appendingPathComponent("empty"))
        XCTAssertNil(empty.verifyChain())
        XCTAssertFalse(empty.signedOff(agentID: UUID()))
        XCTAssertTrue(empty.entries.isEmpty)
    }

    // MARK: (3) A non-green verdict is REJECTED at record() — the no-forge gate

    func testNonGreenVerdictRejectedAtRecord() {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let agent = UUID()

        // A bragging string reaches at most .driftFlagged via GroundedVerdict.unconfirmed.
        let bragging = GroundedVerdict.unconfirmed(fromText: "all tests pass, shipped it")
        XCTAssertNotEqual(bragging.verdict, .green, "ungrounded text can never be green")
        XCTAssertNil(ledger.record(goalID: "G", agentID: agent, branch: "a",
                                   grounded: bragging, evidence: evidence(buildID: "b0"), atEpoch: 1),
                     "a non-green verdict must be a no-op (no signoff admitted)")

        // An error token forces .blocked — also rejected.
        let blocked = GroundedVerdict.unconfirmed(fromText: "build failed: undefined symbol")
        XCTAssertEqual(blocked.verdict, .blocked)
        XCTAssertNil(ledger.record(goalID: "G", agentID: agent, branch: "a",
                                   grounded: blocked, evidence: evidence(buildID: "b0"), atEpoch: 2))

        XCTAssertTrue(ledger.all().isEmpty, "nothing claimed-but-unverified entered the chain")
        XCTAssertFalse(ledger.signedOff(agentID: agent), "agent is NOT signed off on a claim alone")
    }

    func testPublicGameGreenRejectedAtRecord() {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let agent = UUID()

        let gameGreen = GroundedVerdict.fromGame(expected: "complete", observed: "feature complete")
        XCTAssertEqual(gameGreen.verdict, .green, "precondition: public game verdict can be green")
        XCTAssertEqual(gameGreen.source, .game)

        XCTAssertNil(ledger.record(goalID: "G", agentID: agent, branch: "a",
                                   grounded: gameGreen, evidence: evidence(buildID: "b0"), atEpoch: 1),
                     "a public non-code green must not sign off code work")
        XCTAssertTrue(ledger.all().isEmpty)
        XCTAssertFalse(ledger.signedOff(agentID: agent))
    }

    func testSealFailureReturnsNilAndDoesNotAppend() throws {
        let keyDir = tempDir.appendingPathComponent("bad-forgeseal-key", isDirectory: true)
        try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true)
        let keyURL = keyDir.appendingPathComponent("forgeseal-v1.key")
        try Data([1, 2, 3]).write(to: keyURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

        ForgeSeal.resetCacheForTesting()
        ForgeSeal.keyDirectoryOverrideForTesting = keyDir.path
        defer { ForgeSeal.forceEphemeralKeyForTesting() }

        let ledger = FleetSignoffLedger(baseDir: tempDir.appendingPathComponent("seal-failure"))
        let entry = ledger.record(goalID: "G", agentID: UUID(), branch: "a",
                                  grounded: greenVerdict(buildID: "b0"),
                                  evidence: evidence(buildID: "b0"), atEpoch: 1)

        XCTAssertNil(entry, "if the seal cannot be minted, no signoff is returned")
        XCTAssertTrue(ledger.all().isEmpty, "a seal failure must not append an unverifiable row")
        XCTAssertTrue(ledger.entries.isEmpty)
    }

    func testPersistenceFailureReturnsNilAndDoesNotAppend() throws {
        let fileBase = tempDir.appendingPathComponent("not-a-directory")
        try Data("not a dir".utf8).write(to: fileBase)

        let ledger = FleetSignoffLedger(baseDir: fileBase)
        let entry = ledger.record(goalID: "G", agentID: UUID(), branch: "a",
                                  grounded: greenVerdict(buildID: "b0"),
                                  evidence: evidence(buildID: "b0"), atEpoch: 1)

        XCTAssertNil(entry, "if the JSONL write fails, no signoff is returned")
        XCTAssertTrue(ledger.all().isEmpty, "memory stays aligned with disk on persist failure")
        XCTAssertTrue(ledger.entries.isEmpty)
    }

    // MARK: (4) A FORGED row (hand-written bad seal) is rejected at LOAD

    func testForgedRowRejectedAtLoad() throws {
        let agent = UUID()
        let fileURL = tempDir.appendingPathComponent("signoff.jsonl")

        // Write ONE legit sealed entry through the real path.
        do {
            let ledger = FleetSignoffLedger(baseDir: tempDir)
            ledger.record(goalID: "G", agentID: agent, branch: "a",
                          grounded: greenVerdict(buildID: "b0"),
                          evidence: evidence(buildID: "b0"), atEpoch: 1)
        }

        // Append a hand-crafted second row claiming a green signoff for a NEW agent, with a bogus seal
        // (the attacker has no install HMAC key). Its prevHash is even set to the prior entry's hash so
        // the LINK looks valid — only the seal (and the recomputed entryHash) betrays it.
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        let firstLine = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)[0]
        let prevEntry = try JSONDecoder.iso8601.decode(FleetSignoffEntry.self, from: Data(firstLine.utf8))
        let forgedAgent = UUID()
        let forged = FleetSignoffEntry(
            seq: 1, prevHash: prevEntry.entryHash, goalID: "G", agentID: forgedAgent,
            branch: "evil", buildID: "forged", verdict: .green, testExitCode: 0,
            changedLines: 1, maxFileLines: 1, outOfScopeCount: 0, summary: "I promise it's done",
            recordedAt: Date(timeIntervalSince1970: 2),
            entryHash: FleetSignoffEntry.computeHash(prevHash: prevEntry.entryHash,
                                                     canonical: "doesnt-matter"),
            seal: "deadbeefdeadbeefdeadbeef")  // not a valid HMAC over canonical
        let forgedData = try JSONEncoder.iso8601Sorted.encode(forged)
        let forgedLine = String(data: forgedData, encoding: .utf8)!
        try (raw + forgedLine + "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        // Reload + audit: the forged row's bad seal breaks the chain at its seq, so the WHOLE ledger
        // collapses to zero trustworthy signoffs (fail-safe).
        let reloaded = FleetSignoffLedger(baseDir: tempDir)
        XCTAssertEqual(reloaded.all().count, 2, "both rows are physically present on disk")
        XCTAssertEqual(reloaded.verifyChain(), 1, "the forged row is detected at its seq")
        XCTAssertFalse(reloaded.signedOff(agentID: forgedAgent),
                       "a hand-written green with a bogus seal can NEVER sign off")
        XCTAssertFalse(reloaded.signedOff(agentID: agent),
                       "a broken chain collapses evidence to zero — even the legit row is untrusted")
        XCTAssertTrue(reloaded.entries.isEmpty, "no trustworthy entries while the chain is broken")
    }

    // MARK: (5) TAMPERED chain → verifyChain() returns the FIRST broken seq

    func testOnDiskTamperDetectedAtFirstBrokenSeq() throws {
        let fileURL = tempDir.appendingPathComponent("signoff.jsonl")

        // Three real entries through the legit path.
        do {
            let ledger = FleetSignoffLedger(baseDir: tempDir)
            ledger.record(goalID: "G", agentID: UUID(), branch: "a",
                          grounded: greenVerdict(buildID: "b0"),
                          evidence: evidence(buildID: "b0"), atEpoch: 1)
            ledger.record(goalID: "G", agentID: UUID(), branch: "b",
                          grounded: greenVerdict(buildID: "b1"),
                          evidence: evidence(buildID: "b1"), atEpoch: 2)
            ledger.record(goalID: "G", agentID: UUID(), branch: "c",
                          grounded: greenVerdict(buildID: "b2"),
                          evidence: evidence(buildID: "b2"), atEpoch: 3)
        }

        // Edit seq==1's PAYLOAD on disk (re-credit the branch) while leaving its stored entryHash + seal.
        // On reload, the recomputed canonical changes, so the SEAL check (then the hash check) fails
        // first at seq 1.
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, 3, "precondition: three persisted lines")
        lines[1] = lines[1].replacingOccurrences(of: "\"branch\":\"b\"",
                                                 with: "\"branch\":\"b-FORGED\"")
        XCTAssertTrue(lines[1].contains("b-FORGED"), "tamper must actually land in the bytes")
        try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        let reloaded = FleetSignoffLedger(baseDir: tempDir)
        XCTAssertEqual(reloaded.verifyChain(), 1,
                       "tamper-evidence: the first broken entry is the edited seq==1")
        XCTAssertTrue(reloaded.entries.isEmpty,
                      "a broken chain yields ZERO trustworthy entries — stricter, never looser")
    }

    // MARK: (6) Replay / duplicate agent rows → ONE signoff signal

    func testDuplicateAgentRowsDedupedToOneSignal() {
        let agent = UUID()
        let ledger = FleetSignoffLedger(baseDir: tempDir)

        // The same agent legitimately re-signed (e.g. a retry that also passed).
        let e0 = ledger.record(goalID: "G", agentID: agent, branch: "a",
                               grounded: greenVerdict(buildID: "b0"),
                               evidence: evidence(buildID: "b0"), atEpoch: 1)!
        let e1 = ledger.record(goalID: "G", agentID: agent, branch: "a",
                               grounded: greenVerdict(buildID: "b0"),
                               evidence: evidence(buildID: "b0"), atEpoch: 2)!

        XCTAssertEqual(ledger.all().count, 2, "two physical rows exist (append-only chain)")
        XCTAssertNotEqual(e0.entryHash, e1.entryHash, "even a re-sign chains to a fresh distinct hash")
        XCTAssertNil(ledger.verifyChain(), "both rows are chain-valid")

        // signedOff() is a single boolean signal regardless of duplicate rows.
        XCTAssertTrue(ledger.signedOff(agentID: agent), "the agent IS signed off")
        let distinctSignedAgents = Set(ledger.entries.map(\.agentID))
        XCTAssertEqual(distinctSignedAgents, [agent],
                       "duplicate rows collapse to exactly ONE signed-off agent identity")
    }

    // MARK: (7) Persistence — append, reload from same baseDir, entries survive

    func testPersistenceSurvivesReload() {
        let a0 = UUID(); let a1 = UUID()
        do {
            let ledger = FleetSignoffLedger(baseDir: tempDir)
            ledger.record(goalID: "G", agentID: a0, branch: "a",
                          grounded: greenVerdict(buildID: "b0"),
                          evidence: evidence(buildID: "b0"), atEpoch: 11)
            ledger.record(goalID: "G", agentID: a1, branch: "b",
                          grounded: greenVerdict(buildID: "b1"),
                          evidence: evidence(buildID: "b1"), atEpoch: 22)
        }

        let reloaded = FleetSignoffLedger(baseDir: tempDir)
        let all = reloaded.all()
        XCTAssertEqual(all.count, 2, "both appended entries must persist across reload")
        XCTAssertEqual(all.map(\.seq), [0, 1])
        XCTAssertEqual(all.map(\.agentID), [a0, a1], "agent identities persist verbatim")
        XCTAssertNil(reloaded.verifyChain(), "reloaded intact chain verifies clean")
        XCTAssertTrue(reloaded.signedOff(agentID: a0))
        XCTAssertTrue(reloaded.signedOff(agentID: a1))
    }

    // MARK: (8) Concurrent record() keeps the chain valid (Codex MED — replaces @MainActor serialization)

    func testConcurrentRecordsMaintainValidChain() {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let n = 64
        DispatchQueue.concurrentPerform(iterations: n) { i in
            ledger.record(goalID: "G", agentID: UUID(), branch: "b\(i)",
                          grounded: greenVerdict(buildID: "b\(i)"),
                          evidence: evidence(buildID: "b\(i)"), atEpoch: Double(i + 1))
        }
        XCTAssertEqual(ledger.all().count, n, "every concurrent record landed (no lost update)")
        XCTAssertNil(ledger.verifyChain(), "the chain is valid despite concurrent writers (lock serializes)")
        XCTAssertEqual(ledger.entries.count, n, "all entries trustworthy")
        XCTAssertEqual(Set(ledger.all().map(\.seq)), Set(0..<n),
                       "seqs are a contiguous 0..<n with no duplicates — chain.count never raced")
    }

    // MARK: (9) Load fail-closed on mid-file garbage; tolerate a single torn final line (Codex MED)

    func testMidFileGarbageFailsClosed() throws {
        let fileURL = tempDir.appendingPathComponent("signoff.jsonl")
        let a0 = UUID(); let a1 = UUID()
        do {
            let ledger = FleetSignoffLedger(baseDir: tempDir)
            ledger.record(goalID: "G", agentID: a0, branch: "a",
                          grounded: greenVerdict(buildID: "b0"), evidence: evidence(buildID: "b0"), atEpoch: 1)
            ledger.record(goalID: "G", agentID: a1, branch: "b",
                          grounded: greenVerdict(buildID: "b1"), evidence: evidence(buildID: "b1"), atEpoch: 2)
        }
        let lines = try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, 2)
        // Inject garbage BETWEEN the two valid rows → structural corruption, not a torn tail.
        let corrupted = lines[0] + "\n" + "}{ NOT JSON {{" + "\n" + lines[1] + "\n"
        try corrupted.write(to: fileURL, atomically: true, encoding: .utf8)

        let reloaded = FleetSignoffLedger(baseDir: tempDir)
        XCTAssertTrue(reloaded.all().isEmpty, "mid-file garbage rejects the WHOLE file — fail closed")
        XCTAssertFalse(reloaded.signedOff(agentID: a0), "no signoff survives a structurally-corrupt file")
        XCTAssertFalse(reloaded.signedOff(agentID: a1))
        XCTAssertTrue(reloaded.entries.isEmpty)
    }

    func testTornFinalLineIsTolerated() throws {
        let fileURL = tempDir.appendingPathComponent("signoff.jsonl")
        let a0 = UUID(); let a1 = UUID()
        do {
            let ledger = FleetSignoffLedger(baseDir: tempDir)
            ledger.record(goalID: "G", agentID: a0, branch: "a",
                          grounded: greenVerdict(buildID: "b0"), evidence: evidence(buildID: "b0"), atEpoch: 1)
            ledger.record(goalID: "G", agentID: a1, branch: "b",
                          grounded: greenVerdict(buildID: "b1"), evidence: evidence(buildID: "b1"), atEpoch: 2)
        }
        // Simulate a crash mid-persist: a half-written final line appended after two valid rows.
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        try (raw + "{\"seq\":2,\"prevHa").write(to: fileURL, atomically: true, encoding: .utf8)

        let reloaded = FleetSignoffLedger(baseDir: tempDir)
        XCTAssertEqual(reloaded.all().count, 2, "a single torn FINAL line is dropped; prior rows survive")
        XCTAssertNil(reloaded.verifyChain(), "the surviving prefix is an intact chain")
        XCTAssertTrue(reloaded.signedOff(agentID: a0))
        XCTAssertTrue(reloaded.signedOff(agentID: a1))
    }
}

// MARK: - Local JSON coder helpers (match the ledger's persistence shape)

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}

private extension JSONEncoder {
    static var iso8601Sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
