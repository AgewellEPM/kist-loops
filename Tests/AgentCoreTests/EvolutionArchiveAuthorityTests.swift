import Foundation
import XCTest
@testable import AgentCore

final class EvolutionArchiveAuthorityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evolution-authority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testPayloadTamperZerosAllAuthorityAndRefusesAppend() throws {
        let store = EvolutionArchiveStore(root: root.path)
        _ = try store.append(record("candidate", score: 100))
        let original = try String(contentsOf: store.archiveURL, encoding: .utf8)
        XCTAssertTrue(original.contains(#""score":100"#))
        try overwrite(store.archiveURL, Data(original.replacingOccurrences(
            of: #""score":100"#, with: #""score":999"#).utf8))

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.records.count, 1, "strictly readable tamper remains displayable")
        XCTAssertTrue(snapshot.authoritativeRecords.isEmpty)
        XCTAssertTrue(snapshot.state.isInvalid)
        XCTAssertTrue(store.topCandidates().isEmpty)
        XCTAssertThrowsError(try store.append(record("after-tamper")))
    }

    func testTornFinalLineFailsClosed() throws {
        let store = EvolutionArchiveStore(root: root.path)
        _ = try store.append(record("candidate"))
        var bytes = try Data(contentsOf: store.archiveURL)
        bytes.removeLast()
        try overwrite(store.archiveURL, bytes)
        XCTAssertTrue(store.snapshot().state.isInvalid)
        if case .refused = store.selectParentDecisionForTesting(seed: 1) {} else {
            XCTFail("torn archive must be refusal, never root seed")
        }
    }

    func testDeletingWholeValidTailRowIsDetectedBySealedHead() throws {
        let store = EvolutionArchiveStore(root: root.path)
        _ = try store.append(record("one"))
        _ = try store.append(record("two"))
        let bytes = try Data(contentsOf: store.archiveURL)
        let firstLF = try XCTUnwrap(bytes.firstIndex(of: 0x0a))
        try overwrite(store.archiveURL, bytes.subdata(in: 0..<bytes.index(after: firstLF)))
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.records.map(\.candidateID), ["one"])
        XCTAssertTrue(snapshot.authoritativeRecords.isEmpty)
        XCTAssertTrue(snapshot.state.isInvalid)
    }

    func testMalformedRowFailsStrictReadInsteadOfCompactMapSkipping() throws {
        let store = EvolutionArchiveStore(root: root.path)
        try writeRawArchive(Data("{}\n".utf8), store: store)
        let snapshot = store.snapshot()
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertTrue(snapshot.state.isInvalid)
    }

    func testExactRowReplayBricksAuthorityBeforeHeadValidation() throws {
        let store = EvolutionArchiveStore(root: root.path)
        _ = try store.append(record("replayed"))
        let row = try Data(contentsOf: store.archiveURL)
        var replay = row
        replay.append(row)
        try overwrite(store.archiveURL, replay)
        let snapshot = store.snapshot()
        XCTAssertTrue(snapshot.authoritativeRecords.isEmpty)
        guard case .invalid(let reason) = snapshot.state else { return XCTFail("expected invalid") }
        XCTAssertTrue(reason.contains("duplicate") || reason.contains("replay"), reason)
    }

    func testAlreadySealedRecordCannotBeAppendedAgain() throws {
        let store = EvolutionArchiveStore(root: root.path)
        let sealed = try store.append(record("once"))
        XCTAssertThrowsError(try store.append(sealed)) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate") || error.localizedDescription.contains("replay"))
        }
    }

    func testOneUseEvaluationReceiptCannotAuthorizeASecondAppend() throws {
        let firstStore = EvolutionArchiveStore(root: root.path)
        let sealed = try firstStore.append(record("one-use"))
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("evolution-one-use-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let replay = EvolutionArchiveAuthorityCodec.withoutAuthority(sealed)
        XCTAssertThrowsError(try EvolutionArchiveStore(root: other.path).append(replay)) { error in
            XCTAssertTrue(error.localizedDescription.contains("one-use")
                          || error.localizedDescription.contains("receipt"),
                          error.localizedDescription)
        }
    }

    func testNilBenchmarkEvidenceCannotReachArchiveSeal() throws {
        let valid = record("nil-evidence")
        let forged = EvolutionCandidateRecord(
            runID: valid.runID, candidateID: valid.candidateID, parentID: valid.parentID,
            objective: valid.objective, branch: valid.branch, worktreePath: valid.worktreePath,
            baseSHA: valid.baseSHA, commitSHA: valid.commitSHA,
            status: .passed, score: valid.score,
            changedFiles: valid.changedFiles, protectedFiles: valid.protectedFiles,
            benchmarks: [], summary: valid.summary, createdAtEpoch: valid.createdAtEpoch,
            requiredBenchmarkCommands: valid.requiredBenchmarkCommands,
            treeSHA: valid.treeSHA, gitControlDigest: valid.gitControlDigest,
            hostStateDigest: valid.hostStateDigest,
            committedDiffDigest: valid.committedDiffDigest,
            integrityDigest: valid.integrityDigest,
            evaluationReceiptID: valid.evaluationReceiptID,
            evaluationReceiptDigest: valid.evaluationReceiptDigest,
            evaluationReceiptSeal: valid.evaluationReceiptSeal,
            evaluationContainmentExecutionDigest: valid.evaluationContainmentExecutionDigest)
        XCTAssertThrowsError(try EvolutionArchiveStore(root: root.path).append(forged))
        let archive = EvolutionArchiveStore(root: root.path).archiveURL
        XCTAssertEqual((try? Data(contentsOf: archive)) ?? Data(), Data())
    }

    func testConcurrentAppendsSerializeIntoOneValidContiguousChain() throws {
        let store = EvolutionArchiveStore(root: root.path)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "evolution.archive.concurrent", attributes: .concurrent)
        let errorLock = NSLock()
        var errors: [String] = []
        for index in 0..<16 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do { _ = try store.append(self.record("candidate-\(index)")) }
                catch { errorLock.lock(); errors.append(String(describing: error)); errorLock.unlock() }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.authoritativeRecords.count, 16)
        XCTAssertEqual(snapshot.authoritativeRecords.map(\.archiveSequence), Array(0..<16).map(Optional.some))
        XCTAssertEqual(Set(snapshot.authoritativeRecords.map(\.candidateID)).count, 16)
        guard case .trusted(let count, let legacy) = snapshot.state else { return XCTFail("expected trusted") }
        XCTAssertEqual(count, 16); XCTAssertEqual(legacy, 0)
    }

    func testLegacyRowsAreDisplayOnlyAndCannotBecomeParentsOrFitness() throws {
        let store = EvolutionArchiveStore(root: root.path)
        let legacy = record("legacy", score: 999)
        var legacyLine = try EvolutionArchiveAuthorityCodec.canonicalRecordData(legacy)
        legacyLine.append(0x0a)
        try writeRawArchive(legacyLine, store: store)

        var snapshot = store.snapshot()
        XCTAssertEqual(snapshot.records.map(\.candidateID), ["legacy"])
        XCTAssertTrue(snapshot.authoritativeRecords.isEmpty)
        XCTAssertTrue(EvolutionParentSelector.eligibleParents(snapshot.records).isEmpty)
        XCTAssertNil(EvolutionRunProgress.bestPassingScore(snapshot.records))
        XCTAssertTrue(store.topCandidates().isEmpty)

        let signed = try store.append(record("signed"))
        snapshot = store.snapshot()
        XCTAssertEqual(snapshot.records.count, 2)
        XCTAssertEqual(snapshot.authoritativeRecords, [signed])
        guard case .trusted(let authority, let legacyCount) = snapshot.state else {
            return XCTFail("expected signed suffix anchored to legacy prefix")
        }
        XCTAssertEqual(authority, 1); XCTAssertEqual(legacyCount, 1)
        XCTAssertThrowsError(try store.append(record("child", parent: "legacy")))
    }

    func testCrossProjectArchiveCopyHasDisplayButNoAuthorityAndRefusesSelection() throws {
        let source = EvolutionArchiveStore(root: root.path)
        _ = try source.append(record("source"))
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("evolution-cross-project-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.createDirectory(
            at: other.appendingPathComponent(".mythos"), withIntermediateDirectories: true)
        let destination = EvolutionArchiveStore(root: other.path)
        try FileManager.default.copyItem(at: source.directoryURL, to: destination.directoryURL)

        let snapshot = destination.snapshot()
        XCTAssertEqual(snapshot.records.map(\.candidateID), ["source"])
        XCTAssertTrue(snapshot.authoritativeRecords.isEmpty)
        XCTAssertTrue(snapshot.state.isInvalid)
        if case .refused = destination.selectParentDecisionForTesting(seed: 1) {} else {
            XCTFail("cross-project archive must not look like an empty root seed")
        }
    }

    func testOwnerReadableButGroupReadableArchiveIsNonAuthoritative() throws {
        let store = EvolutionArchiveStore(root: root.path)
        _ = try store.append(record("candidate"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.archiveURL.path)
        XCTAssertTrue(store.snapshot().state.isInvalid)
        XCTAssertThrowsError(try store.append(record("after-insecure-mode")))
    }

    func testIndividualEnvelopeReadDoesNotCreateMissingForgeSealKey() throws {
        let keyDirectory = root.appendingPathComponent("authority-key", isDirectory: true)
        ForgeSeal.resetCacheForTesting()
        ForgeSeal.keyDirectoryOverrideForTesting = keyDirectory.path
        defer { ForgeSeal.resetCacheForTesting() }

        let sealed = try EvolutionArchiveStore(root: root.path).append(record("sealed"))
        let keyURL = keyDirectory.appendingPathComponent("forgeseal-v1.key")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))
        try FileManager.default.removeItem(at: keyURL)
        ForgeSeal.resetCacheForTesting()
        ForgeSeal.keyDirectoryOverrideForTesting = keyDirectory.path

        XCTAssertFalse(sealed.hasValidArchiveAuthority)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path),
                       "read-only envelope verification must never mint authority")
    }

    func testDeletingForgeKeyAfterItWasCachedImmediatelyRevokesAuthority() throws {
        let keyDirectory = root.appendingPathComponent("cached-authority-key", isDirectory: true)
        ForgeSeal.resetCacheForTesting()
        ForgeSeal.keyDirectoryOverrideForTesting = keyDirectory.path
        defer { ForgeSeal.resetCacheForTesting() }

        let sealed = try EvolutionArchiveStore(root: root.path).append(record("cached-key"))
        let keyURL = keyDirectory.appendingPathComponent("forgeseal-v1.key")
        XCTAssertTrue(sealed.hasValidArchiveAuthority)
        try FileManager.default.removeItem(at: keyURL)

        XCTAssertFalse(sealed.hasValidArchiveAuthority,
                       "a cached key must not outlive deletion/replacement of its protected file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path),
                       "read-only validation must not recreate the deleted key")
    }

    func testArchiveInRenamedAncestorIsNotTrustedAtTheCanonicalPath() throws {
        let store = EvolutionArchiveStore(root: root.path)
        _ = try store.append(record("detached"))
        let detached = root.appendingPathComponent(".mythos-detached")
        try FileManager.default.moveItem(
            at: root.appendingPathComponent(".mythos"), to: detached)
        try FileManager.default.createDirectory(
            at: store.directoryURL, withIntermediateDirectories: true)

        let snapshot = store.snapshot()
        XCTAssertTrue(snapshot.records.isEmpty,
                      "a previously valid archive under a detached ancestor is not the canonical project archive")
        XCTAssertEqual(snapshot.state, .empty)
    }

    func testSameRunCannotChangeItsObjective() throws {
        let store = EvolutionArchiveStore(root: root.path)
        _ = try store.append(record("one", runID: "run", objective: "objective A"))
        XCTAssertThrowsError(try store.append(record("two", runID: "run", objective: "objective B")))
    }

    func testChildBaseMustEqualExactParentCommit() throws {
        let parentCommit = String(repeating: "a", count: 40)
        let store = EvolutionArchiveStore(root: root.path)
        _ = try store.append(record("parent", commitSHA: parentCommit))

        XCTAssertThrowsError(try store.append(
            record("wrong-base", parent: "parent",
                   baseSHA: String(repeating: "b", count: 40))
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("does not match parent"),
                          error.localizedDescription)
        }

        _ = try store.append(record("exact-child", parent: "parent", baseSHA: parentCommit))
        XCTAssertEqual(store.snapshot().authoritativeRecords.map(\.candidateID),
                       ["parent", "exact-child"])
    }

    func testSelectionRequiresLiveExactBranchAndRefusesWhenItAdvances() throws {
        guard git(["init"], cwd: root)?.0 == 0 else { throw XCTSkip("git unavailable") }
        _ = git(["config", "user.email", "archive@test.invalid"], cwd: root)
        _ = git(["config", "user.name", "Archive Test"], cwd: root)
        try "root\n".write(to: root.appendingPathComponent("ROOT.txt"), atomically: true, encoding: .utf8)
        _ = git(["add", "-A"], cwd: root); _ = git(["commit", "-m", "root"], cwd: root)
        let parent = try XCTUnwrap(GitIsolation.makeWorktree(
            repo: root.path, label: "evolve-parent", nowEpoch: 1_700_000_000))
        defer { _ = GitIsolation.discard(parent) }
        try "parent\n".write(to: URL(fileURLWithPath: parent.path).appendingPathComponent("PARENT.txt"),
                             atomically: true, encoding: .utf8)
        XCTAssertTrue(GitIsolation.commit(parent, message: "parent"))
        let parentSHA = EvolutionLab.headSHA(worktreePath: parent.path)
        let store = EvolutionArchiveStore(root: root.path)
        _ = try store.append(record("parent", branch: parent.branch, commitSHA: parentSHA))
        let decision = store.selectParentDecisionForTesting(seed: 1)
        guard case .selected(let selected) = decision else {
            if case .refused(let reason) = decision {
                return XCTFail("live exact parent should select: \(reason)")
            }
            return XCTFail("live exact parent should select; got root seed")
        }
        XCTAssertEqual(selected.commitSHA, parentSHA)

        try "advanced\n".write(to: URL(fileURLWithPath: parent.path).appendingPathComponent("ADVANCED.txt"),
                               atomically: true, encoding: .utf8)
        XCTAssertTrue(GitIsolation.commit(parent, message: "advance"))
        if case .refused = store.selectParentDecisionForTesting(seed: 1) {} else {
            XCTFail("stale archive ref must refuse, never root seed")
        }
    }

    func testProductionParentSelectionRefusesWithoutFitnessOracleAndExternalWitness() {
        let decision = EvolutionArchiveStore(root: root.path).selectParentDecision(seed: 1)
        guard case .refused(let reason) = decision else {
            return XCTFail("missing external authorities must refuse, never look like an empty root archive")
        }
        XCTAssertTrue(reason.contains("parentRelativeCapabilityFitness"), reason)
        XCTAssertTrue(reason.contains("externalRollbackWitness"), reason)
    }

    private func record(_ id: String, score: Int = 100, runID: String = "run",
                        objective: String = "objective", parent: String? = nil,
                        branch: String = "mythos/auto-evolve-test",
                        baseSHA: String = String(repeating: "0", count: 40),
                        commitSHA: String = String(repeating: "1", count: 40)) -> EvolutionCandidateRecord {
        EvolutionTestAuthority.authoritative(EvolutionCandidateRecord(
            runID: runID, candidateID: id, parentID: parent, objective: objective,
            branch: branch, worktreePath: "/worktree/\(id)",
            baseSHA: baseSHA, commitSHA: commitSHA,
            status: .passed, score: score, changedFiles: ["Sources/AgentCore/PromptCompiler.swift"],
            protectedFiles: [], benchmarks: [], summary: "candidate \(id)", createdAtEpoch: 1))
    }

    private func overwrite(_ url: URL, _ data: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func writeRawArchive(_ data: Data, store: EvolutionArchiveStore) throws {
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: store.archiveURL.path, contents: data,
            attributes: [.posixPermissions: 0o600]))
    }

    @discardableResult
    private func git(_ args: [String], cwd: URL) -> (Int32, String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = cwd
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return nil }
    }
}
