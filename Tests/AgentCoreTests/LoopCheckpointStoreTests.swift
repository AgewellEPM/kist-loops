import XCTest
import Foundation
@testable import AgentCore

final class LoopCheckpointStoreTests: XCTestCase {
    private var dir: String!
    private var store: LoopCheckpointStore!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "ckpt-\(UUID().uuidString)"
        store = LoopCheckpointStore(directory: dir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func make(_ status: LoopCheckpoint.Status, iter: Int = 1) -> LoopCheckpoint {
        LoopCheckpoint(goal: "g", providerId: "openai", model: "gpt-4o", projectRoot: "/tmp",
                       messages: [ChatMessage(role: .user, content: "g")], iteration: iter, status: status)
    }

    func testSaveLoadRoundTrip() throws {
        var cp = make(.running)
        cp.rawRequest = "fix the parser"
        cp.intent = .build
        cp.expectedOutcome = .mutation
        cp.pendingAction = PendingAction(
            tool: "write_file", argsSummary: "path=Sources/Pending.swift", iteration: 2,
            predictedEffects: ToolEffectObservation(mutation: .source, mutationEvidence: .mayMutate))
        cp.trajectory = [
            ActionRecord(tool: "write_file", argsFingerprint: "path=Sources/App.swift", success: true,
                         effectObservation: ToolEffectObservation(mutation: .source)),
            ActionRecord(tool: "run_command", argsFingerprint: "command=swift test", success: true,
                         effectObservation: ToolEffectObservation(verification: .buildOrTest)),
        ]
        cp.nativeToolFallback = NativeToolFallbackState(
            providerId: "openai", model: "gpt-4o", toolSchemaFingerprint: "schema-a")
        cp.nativeToolCapability = NativeToolPositiveState(
            providerId: "openai", model: "gpt-4o", toolSchemaFingerprint: "schema-b")
        cp.nativeToolRoundTrips = 3
        cp.providerRequestsConsumed = 7
        try store.save(cp)
        let back = try store.load(id: cp.id)
        XCTAssertEqual(back.id, cp.id)
        XCTAssertEqual(back.goal, "g")
        XCTAssertEqual(back.providerId, "openai")
        XCTAssertEqual(back.iteration, 1)
        XCTAssertEqual(back.messages.count, 1)
        XCTAssertEqual(back.rawRequest, "fix the parser")
        XCTAssertEqual(back.intent, .build)
        XCTAssertEqual(back.expectedOutcome, .mutation)
        XCTAssertEqual(back.trajectory, cp.trajectory)
        XCTAssertEqual(back.pendingAction?.predictedEffects,
                       cp.pendingAction?.predictedEffects)
        XCTAssertEqual(back.nativeToolFallback, cp.nativeToolFallback)
        XCTAssertEqual(back.nativeToolCapability, cp.nativeToolCapability)
        XCTAssertEqual(back.nativeToolRoundTrips, 3)
        XCTAssertEqual(back.providerRequestsConsumed, 7)
    }

    func testLegacyCheckpointWithoutTurnContractStillDecodes() throws {
        let encoded = try JSONEncoder().encode(make(.running))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "rawRequest")
        object.removeValue(forKey: "intent")
        object.removeValue(forKey: "expectedOutcome")
        object.removeValue(forKey: "trajectory")
        object.removeValue(forKey: "providerRequestsConsumed")
        if var pending = object["pendingAction"] as? [String: Any] {
            pending.removeValue(forKey: "predictedEffects")
            object["pendingAction"] = pending
        }

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(LoopCheckpoint.self, from: legacy)

        XCTAssertNil(decoded.rawRequest)
        XCTAssertNil(decoded.intent)
        XCTAssertNil(decoded.expectedOutcome)
        XCTAssertNil(decoded.trajectory)
        XCTAssertNil(decoded.providerRequestsConsumed)
        XCTAssertNil(decoded.pendingAction?.predictedEffects)
    }

    func testResumableExcludesCompleted() throws {
        try store.save(make(.running))
        try store.save(make(.paused))
        try store.save(make(.failed))
        try store.save(make(.completed))
        let r = store.resumable()
        XCTAssertEqual(r.count, 3)   // running + paused + failed; not completed
        XCTAssertFalse(r.contains { $0.status == .completed })
    }

    func testDeleteRemoves() throws {
        let cp = make(.failed)
        try store.save(cp)
        XCTAssertNoThrow(try store.load(id: cp.id))
        store.delete(id: cp.id)
        XCTAssertThrowsError(try store.load(id: cp.id))
    }

    func testRejectsUnsafeIdOnLoadAndSave() {
        // Codex HIGH-2: a user-supplied --resume id must not traverse out of the checkpoint dir.
        XCTAssertThrowsError(try store.load(id: "../../etc/passwd"))
        XCTAssertThrowsError(try store.load(id: "a/b"))
        XCTAssertThrowsError(try store.load(id: ".."))
        let bad = LoopCheckpoint(id: "../evil", goal: "g", providerId: "x", model: nil,
                                 projectRoot: "/tmp", messages: [])
        XCTAssertThrowsError(try store.save(bad))
    }

    func testAllSortedNewestFirst() throws {
        var a = make(.running); a.updatedAt = Date(timeIntervalSince1970: 1000)
        var b = make(.running); b.updatedAt = Date(timeIntervalSince1970: 2000)
        try store.save(a); try store.save(b)
        XCTAssertEqual(store.all().first?.id, b.id)   // newest first
    }

    func testRunLeaseExcludesAnotherProcessAndRecoversAfterRelease() throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("python3 unavailable for cross-process flock probe")
        }
        let checkpoint = make(.running)
        try store.save(checkpoint)
        let lease = try store.acquireRunLease(id: checkpoint.id)
        let lockPath = dir + "/.\(checkpoint.id).run.lock"
        let script = """
        import fcntl, os, sys
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOFOLLOW)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit(73)
        sys.exit(0)
        """
        func probe() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-c", script, lockPath]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        XCTAssertEqual(try probe(), 73, "another process must not acquire the live run lease")
        lease.release()
        XCTAssertEqual(try probe(), 0, "kernel lease must recover immediately after release")
    }

    func testReconcileUsesDurableCheckpointInsteadOfStaleCallerSnapshot() throws {
        var stale = make(.failed, iter: 0)
        stale.providerRequestsConsumed = 0
        var durable = stale
        durable.iteration = 4
        durable.providerRequestsConsumed = 4
        durable.summary = "newer durable state"
        try store.save(durable)
        let lease = try store.acquireRunLease(id: stale.id)
        defer { lease.release() }

        let reconciled = try store.reconcileForResume(stale)
        XCTAssertEqual(reconciled.providerRequestsConsumed, 4)
        XCTAssertEqual(reconciled.iteration, 4)
        XCTAssertEqual(reconciled.summary, "newer durable state")
    }

    func testSymlinkedLockAndCheckpointAreRejectedWithoutTouchingVictim() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let checkpoint = make(.running)
        let victim = dir + "/victim"
        try Data("do-not-touch".utf8).write(to: URL(fileURLWithPath: victim))
        let lockPath = dir + "/.\(checkpoint.id).data.lock"
        try FileManager.default.createSymbolicLink(atPath: lockPath, withDestinationPath: victim)
        XCTAssertThrowsError(try store.save(checkpoint))
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "do-not-touch")
        try FileManager.default.removeItem(atPath: lockPath)

        try FileManager.default.createSymbolicLink(
            atPath: dir + "/\(checkpoint.id).json", withDestinationPath: victim)
        XCTAssertThrowsError(try store.load(id: checkpoint.id))
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "do-not-touch")
    }
}
