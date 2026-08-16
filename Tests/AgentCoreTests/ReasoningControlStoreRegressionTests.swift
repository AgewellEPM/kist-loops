import XCTest
@testable import AgentCore

final class ReasoningControlStoreRegressionTests: XCTestCase {
    func testAtomicStoreRoundTripsLatestMonotonicState() async throws {
        let root = temporaryDirectory("reasoning-store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AtomicReasoningControlStore(directory: root, clock: { 42 })
        var state = ReasoningControlState(id: "run/one", route: .planned,
                                          goalFingerprint: "goal", updatedAt: 0)
        state.cycle = 1
        state.tokensSpent = 100
        state.childCheckpointIDs["node"] = "child-1"
        state.addEvidence([.init(id: "e1", kind: .artifact, summary: "artifact", at: 1)])
        let first = try await store.save(state)

        var next = first
        next.cycle = 2
        next.tokensSpent = 175
        next.recordNudge()
        let second = try await store.save(next)
        let loaded = try await store.load(runID: state.id)

        XCTAssertEqual(loaded, second)
        XCTAssertGreaterThan(second.revision, first.revision)
        XCTAssertEqual(second.updatedAt, 42)
        XCTAssertEqual(second.childCheckpointIDs["node"], "child-1")
    }

    func testStoreDecodesLegacyStateWithoutNewOptionalCollections() async throws {
        let root = temporaryDirectory("reasoning-legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runID = "legacy/run"
        let state = ReasoningControlState(id: runID, route: .direct, updatedAt: 10)
        let encoded = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "providerEffortRecords")
        object.removeValue(forKey: "executablePlanSnapshots")
        object.removeValue(forKey: "approvedExecutablePlanIDs")
        object.removeValue(forKey: "verificationControl")
        object.removeValue(forKey: "rejectedPlanAttemptReceipts")
        object["schemaVersion"] = 1
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try legacy.write(to: controlFileURL(directory: root, runID: runID), options: .atomic)

        let store = AtomicReasoningControlStore(directory: root)
        let legacyLoaded = try await store.load(runID: runID)
        let decoded = try XCTUnwrap(legacyLoaded)
        XCTAssertNil(decoded.providerEffortRecords)
        XCTAssertNil(decoded.executablePlanSnapshots)
        XCTAssertNil(decoded.approvedExecutablePlanIDs)
        XCTAssertNil(decoded.verificationControl)
        XCTAssertNil(decoded.rejectedPlanAttemptReceipts)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.id, runID)
    }

    func testVerificationRecipeAppendIsIdempotentAndRejectsIdentityCollision() throws {
        var state = ReasoningControlState(id: "recipe", route: .planned)
        try configureVerification(&state, limit: 2)
        let original = verificationRecipe(id: "recipe-1")

        try state.appendVerificationRecipe(original)
        try state.appendVerificationRecipe(original)
        XCTAssertEqual(state.verificationControl?.recipes, [original])

        let collision = verificationRecipe(id: "recipe-1", stepID: "different-step")
        XCTAssertThrowsError(try state.appendVerificationRecipe(collision)) { error in
            guard case ReasoningControlError.invalidState = error else {
                return XCTFail("expected invalidState, got \(error)")
            }
        }
    }

    func testAtomicStoreRejectsVerificationRecipeDeletionAndMutation() async throws {
        let root = temporaryDirectory("reasoning-verification-monotonic")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AtomicReasoningControlStore(directory: root)
        var state = ReasoningControlState(id: "verification-monotonic", route: .planned)
        try configureVerification(&state, limit: 2)
        try state.appendVerificationRecipe(verificationRecipe(id: "recipe-1"))
        let saved = try await store.save(state)

        var deleted = saved
        var deletedControl = try XCTUnwrap(deleted.verificationControl)
        deletedControl.recipes.removeAll()
        deleted.verificationControl = deletedControl
        await assertMonotonicRejection(store: store, state: deleted)

        var mutated = saved
        var mutatedControl = try XCTUnwrap(mutated.verificationControl)
        mutatedControl.recipes[0] = verificationRecipe(id: "recipe-1", stepID: "changed")
        mutated.verificationControl = mutatedControl
        await assertMonotonicRejection(store: store, state: mutated)

        let persisted = try await store.load(runID: saved.id)
        XCTAssertEqual(persisted, saved)
    }

    func testReplayBeginIsSingleUseCappedAndPersistedMonotonically() async throws {
        let root = temporaryDirectory("reasoning-replay-cap")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AtomicReasoningControlStore(directory: root)
        var state = ReasoningControlState(id: "replay-cap", route: .planned)
        try configureVerification(&state, limit: 2)
        state = try await store.save(state)

        state = try await store.update(runID: state.id, create: nil) {
            try $0.beginVerificationReplay(stateKey: "state-a")
        }
        XCTAssertEqual(state.verificationControl?.attemptsStarted, 1)
        XCTAssertEqual(state.verificationControl?.seenReplayStateKeys, ["state-a"])

        do {
            _ = try await store.update(runID: state.id, create: nil) {
                try $0.beginVerificationReplay(stateKey: "state-a")
            }
            XCTFail("a replay state key must be single-use")
        } catch let error as ReasoningControlError {
            guard case .invalidState = error else {
                return XCTFail("expected invalidState, got \(error)")
            }
        }

        state = try await store.update(runID: state.id, create: nil) {
            try $0.beginVerificationReplay(stateKey: "state-b")
        }
        do {
            _ = try await store.update(runID: state.id, create: nil) {
                try $0.beginVerificationReplay(stateKey: "state-c")
            }
            XCTFail("the replay attempt cap must be enforced before launch")
        } catch let error as ReasoningControlError {
            guard case .invalidState = error else {
                return XCTFail("expected invalidState, got \(error)")
            }
        }

        let loadedOptional = try await store.load(runID: state.id)
        let loaded = try XCTUnwrap(loadedOptional)
        XCTAssertEqual(loaded.verificationControl?.attemptsStarted, 2)
        XCTAssertEqual(loaded.verificationControl?.seenReplayStateKeys, ["state-a", "state-b"])
    }

    func testAtomicStoreRejectsReplayLedgerRegressionAndInconsistency() async throws {
        let root = temporaryDirectory("reasoning-replay-regression")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AtomicReasoningControlStore(directory: root)
        var state = ReasoningControlState(id: "replay-regression", route: .planned)
        try configureVerification(&state, limit: 2)
        try state.beginVerificationReplay(stateKey: "state-a")
        let saved = try await store.save(state)

        var regressed = saved
        var control = try XCTUnwrap(regressed.verificationControl)
        control.seenReplayStateKeys.removeAll()
        control.attemptsStarted = 0
        regressed.verificationControl = control
        await assertMonotonicRejection(store: store, state: regressed)

        var inconsistent = saved
        control = try XCTUnwrap(inconsistent.verificationControl)
        control.attemptsStarted = 2
        inconsistent.verificationControl = control
        await assertMonotonicRejection(store: store, state: inconsistent)
    }

    func testStoreRejectsCounterAndAcceptedWorkRegression() async throws {
        let root = temporaryDirectory("reasoning-regression")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AtomicReasoningControlStore(directory: root)
        var state = ReasoningControlState(id: "monotonic", route: .planned)
        let node = ReasoningPlanNode(id: "accepted", title: "accepted")
        try state.installPlanNodes([node], acceptedIDs: [node.id])
        state.cycle = 3
        state.tokensSpent = 300
        let saved = try await store.save(state)

        var regressed = saved
        regressed.cycle = 2
        regressed.tokensSpent = 200
        regressed.acceptedPlanNodeIDs.removeAll()
        do {
            _ = try await store.save(regressed)
            XCTFail("durable counters and accepted work must be monotonic")
        } catch let error as ReasoningControlError {
            guard case .nonMonotonicUpdate = error else {
                return XCTFail("expected nonMonotonicUpdate, got \(error)")
            }
        }
        let persisted = try await store.load(runID: state.id)
        XCTAssertEqual(persisted, saved)
    }

    func testRejectedPlanAttemptReceiptsAreBoundedRedactedAndMonotonic() async throws {
        let root = temporaryDirectory("reasoning-rejected-plans")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AtomicReasoningControlStore(directory: root)
        var state = ReasoningControlState(id: "rejected-plans", route: .planned)
        let first = rejectedPlanReceipt(ordinal: 1, fingerprint: "sha256-plan-1")
        try state.appendRejectedPlanAttempt(first, attemptLimit: 2)
        let savedFirst = try await store.save(state)

        var next = savedFirst
        let second = rejectedPlanReceipt(ordinal: 2, fingerprint: "sha256-plan-2")
        try next.appendRejectedPlanAttempt(second, attemptLimit: 2)
        let savedSecond = try await store.save(next)
        let loadedOptional = try await store.load(runID: state.id)
        let loaded = try XCTUnwrap(loadedOptional)
        XCTAssertEqual(loaded.rejectedPlanAttemptReceipts, [first, second])

        var deleted = savedSecond
        deleted.rejectedPlanAttemptReceipts = [first]
        await assertMonotonicRejection(store: store, state: deleted)

        var mutated = savedSecond
        mutated.rejectedPlanAttemptReceipts = [
            rejectedPlanReceipt(ordinal: 1, fingerprint: "changed"), second,
        ]
        await assertMonotonicRejection(store: store, state: mutated)

        var capped = savedSecond
        XCTAssertThrowsError(try capped.appendRejectedPlanAttempt(
            rejectedPlanReceipt(ordinal: 3, fingerprint: "sha256-plan-3"), attemptLimit: 2))
        let encoded = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-stdin-payload"), encoded)
        XCTAssertTrue(encoded.contains("sha256-stdin"), encoded)
    }

    private func temporaryDirectory(_ prefix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func configureVerification(_ state: inout ReasoningControlState, limit: Int) throws {
        try state.configureVerificationControl(
            completionContractFingerprint: "contract",
            obligationsFingerprint: "obligations",
            executionPolicyFingerprint: "policy",
            workspaceManifestDigest: "manifest",
            attemptLimit: limit)
    }

    private func verificationRecipe(id: String, stepID: String = "E2") -> DurablePlanVerificationRecipe {
        DurablePlanVerificationRecipe(
            id: id, sourcePlanID: "plan-1", stepID: stepID, tool: "run_command",
            resolvedExecutable: "/usr/bin/swift", argv: ["test"], workingDirectory: ".",
            standardInput: nil, allowedExitCodes: [0],
            canonicalArgumentsJSON: #"{"args":["test"],"executable":"swift"}"#,
            argsFingerprint: "args-fingerprint", commandFingerprint: "sha256-command",
            completionContractFingerprint: "contract", obligationsFingerprint: "obligations",
            executionPolicyFingerprint: "policy", workspaceManifestDigest: "manifest",
            proofWorkspaceDigest: "workspace", proofOutputDigest: "output", proofAt: Date(timeIntervalSince1970: 1),
            capabilityFingerprint: "capability", authorizationFingerprint: "authorization",
            toolSchemaFingerprint: "schema", executableIdentity: "executable")
    }

    private func rejectedPlanReceipt(ordinal: Int, fingerprint: String) -> RejectedPlanAttemptReceipt {
        RejectedPlanAttemptReceipt(
            planFingerprint: fingerprint, providerID: "provider", modelID: "model",
            stepSummaries: [RejectedPlanStepSummary(
                stepID: "E5", tool: "run_command",
                argumentTypes: ["executable": "string", "stdin": "string"],
                stdinPresent: true, stdinByteCount: 21, stdinSHA256: "sha256-stdin")],
            validationErrors: ["valid stdin obligation missing"], at: 1,
            ordinal: ordinal)
    }

    private func assertMonotonicRejection(store: AtomicReasoningControlStore,
                                          state: ReasoningControlState) async {
        do {
            _ = try await store.save(state)
            XCTFail("expected monotonic verification-control rejection")
        } catch let error as ReasoningControlError {
            guard case .nonMonotonicUpdate = error else {
                return XCTFail("expected nonMonotonicUpdate, got \(error)")
            }
        } catch {
            XCTFail("expected ReasoningControlError, got \(error)")
        }
    }

    private func controlFileURL(directory: URL, runID: String) -> URL {
        let name = Data(runID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(name + ".json")
    }
}
