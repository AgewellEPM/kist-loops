import XCTest
import Crypto   // swift-crypto's cross-platform CryptoKit API (Linux has no system CryptoKit); `import Darwin` was dead — removed
@testable import AgentCore

final class BuilderIsolatedWorkspaceTransactionTests: XCTestCase {
    private struct TestAttestor: BuilderSandboxAttestor {
        func attest(_ request: BuilderSandboxAttestationRequest) async throws -> BuilderSandboxAttestation {
            try .init(
                request: request, mechanism: "hostile-test-sandbox", enforced: true,
                evidenceDigest: String(repeating: "a", count: 64))
        }
    }

    private enum InjectedFailure: Error { case crash }

    private final class OneShotFault: BuilderWorkspaceTransactionFaultInjector, @unchecked Sendable {
        private let lock = NSLock()
        private let target: BuilderWorkspaceTransactionFaultPoint
        private var fired = false

        init(_ target: BuilderWorkspaceTransactionFaultPoint) { self.target = target }

        func hit(_ point: BuilderWorkspaceTransactionFaultPoint) throws {
            lock.lock(); defer { lock.unlock() }
            if point == target, !fired { fired = true; throw InjectedFailure.crash }
        }
    }

    private struct Fixture {
        let base: URL
        let project: URL
        let staging: URL
        let node: BuilderNode
    }

    private func fixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-transaction-\(UUID().uuidString)", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return Fixture(base: base, project: project, staging: staging,
                       node: BuilderNode(id: "builder", objective: "mutate safely"))
    }

    private func rawDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func mode(_ url: URL) throws -> UInt16 {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(.ENOENT) }
        return UInt16(value.st_mode & 0o7777)
    }

    private func write(_ data: Data, to root: URL, path: String, mode: Int16 = 0o640) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, mode_t(mode)) == 0 else { throw POSIXError(.EPERM) }
    }

    private func contract(
        operations: [BuilderMutationOperation], nodeID: String = "builder"
    ) throws -> BuilderExecutionContract {
        let limit = try BuilderResourceBudget(
            maxToolCalls: 100, maxTokens: 100_000, maxWallTimeSeconds: 600)
        let stage = try BuilderResourceBudget(
            maxToolCalls: 20, maxTokens: 20_000, maxWallTimeSeconds: 120)
        return try BuilderExecutionContract(
            builderContractID: "parent", builderNodeID: nodeID,
            mutations: operations,
            criteria: [
                try .init(id: "clean", stage: .build, kind: .noNewWarnings,
                          statement: "no new warnings"),
                try .init(id: "verify", stage: .verification, kind: .deterministicCommand,
                          statement: "deterministic verification"),
                try .init(id: "review", stage: .review, kind: .modelJudgment,
                          statement: "independent review")
            ],
            budgets: try .init(total: limit, stages: [
                .init(stage: .build, limit: stage),
                .init(stage: .verification, limit: stage),
                .init(stage: .review, limit: stage)
            ]),
            identities: try .init(
                producers: [try .init(providerID: "worker", modelID: "builder-v1")],
                reviewers: [try .init(providerID: "verifier", modelID: "review-v1")]),
            lineage: try .init())
    }

    private func stageAndVerify(
        source: BuilderIsolatedWorkspaceTransactionSource,
        contract: BuilderExecutionContract,
        fixture: Fixture,
        node: BuilderNode? = nil,
        mutate: (URL) throws -> Void
    ) async throws -> (BuilderStageContext, BuilderStageBaseline, String) {
        let selectedNode = node ?? fixture.node
        let build = try BuilderStageContext(
            contract: contract, node: selectedNode, attempt: 1, stage: .build)
        let baseline = try await source.prepare(build)
        let workspace = try await source.executionWorkspace(for: build)
        let staged = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
        try mutate(staged)
        let worker = BuilderWorkerReceipt(
            nodeID: selectedNode.id, provider: "worker", model: "builder-v1",
            changedPaths: contract.mutations.map(\.path),
            checks: [.init(name: "build", passed: true)])
        let buildObservation = try await source.observe(.init(
            context: build, baseline: baseline, subject: .execution(worker)))
        let verification = try BuilderStageContext(
            contract: contract, node: selectedNode, attempt: 1, stage: .verification)
        let verificationBaseline = try await source.prepare(verification)
        let proof = BuilderVerifierReceipt(
            scope: .node(selectedNode.id), provider: "verifier", model: "review-v1",
            deterministic: true, passed: true,
            checks: [.init(name: "verify", passed: true)],
            verificationSubject: selectedNode.id,
            baselineDigest: buildObservation.workspaceDigestBefore,
            subjectDigest: buildObservation.workspaceDigestAfter,
            contractFingerprint: try contract.fingerprint())
        let observation = try await source.observe(.init(
            context: verification, baseline: verificationBaseline,
            subject: .verification(worker, proof)))
        return (build, baseline, observation.workspaceDigestAfter)
    }

    func testExactCreateModifyDeleteCommitAndFinalize() async throws {
        let f = try fixture()
        let old = Data([0xff, 0x00, 0x41]); let deleted = Data("delete".utf8)
        try write(old, to: f.project, path: "modify.bin")
        try write(deleted, to: f.project, path: "delete.txt")
        let c = try contract(operations: [
            try .init(kind: .create, path: "new/data.bin"),
            try .init(kind: .modify, path: "modify.bin", preimageSHA256: rawDigest(old)),
            try .init(kind: .delete, path: "delete.txt", preimageSHA256: rawDigest(deleted))
        ])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        let changed = Data([0x80, 0x81, 0x00]); let created = Data("created".utf8)
        let (context, _, digest) = try await stageAndVerify(
            source: source, contract: c, fixture: f
        ) { root in
            try self.write(changed, to: root, path: "modify.bin", mode: 0o600)
            try self.write(created, to: root, path: "new/data.bin", mode: 0o644)
            try FileManager.default.removeItem(at: root.appendingPathComponent("delete.txt"))
        }
        try await source.commit(context: context, verifiedWorkspaceDigest: digest)
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("modify.bin")), old)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.project.appendingPathComponent("new/data.bin").path))
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("delete.txt")), deleted)
        try await source.markReviewApproved(context: context)
        try await source.finalize(context: context)
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("modify.bin")), changed)
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("new/data.bin")), created)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.project.appendingPathComponent("delete.txt").path))
        XCTAssertEqual(try mode(f.project.appendingPathComponent("modify.bin")), 0o600)
        try await source.verifyFinalized(context: context)
    }

    func testFinalizeRetainsExactWorkspaceIdentityUntilExplicitRelease() async throws {
        let f = try fixture()
        let c = try contract(operations: [try .init(kind: .create, path: "created.txt")])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        let (context, _, digest) = try await stageAndVerify(
            source: source, contract: c, fixture: f
        ) { try self.write(Data("created".utf8), to: $0, path: "created.txt") }
        try await source.commit(context: context, verifiedWorkspaceDigest: digest)
        let before = try await source.executionWorkspace(for: context)

        try await source.markReviewApproved(context: context)
        try await source.finalize(context: context)
        let verification = try BuilderStageContext(
            contract: c, node: f.node, attempt: 1, stage: .verification)
        let retained = try await source.executionWorkspace(for: verification)
        XCTAssertEqual(retained.rootIdentity, before.rootIdentity)
        XCTAssertEqual(
            try BuilderWorkspaceRootIdentity.capture(rootPath: retained.rootPath),
            before.rootIdentity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.rootPath))

        try await source.releaseRetainedData(context: context)
        try await source.releaseRetainedData(context: context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.rootPath))
        try await source.verifyFinalized(context: context)
    }

    func testReplacedStagedRootFailsWithConcurrentDriftWithoutDeletingReplacement() async throws {
        let f = try fixture()
        let c = try contract(operations: [try .init(kind: .create, path: "created.txt")])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        let (context, _, digest) = try await stageAndVerify(
            source: source, contract: c, fixture: f
        ) { try self.write(Data("created".utf8), to: $0, path: "created.txt") }
        try await source.commit(context: context, verifiedWorkspaceDigest: digest)
        let workspace = try await source.executionWorkspace(for: context)
        let original = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
        let displaced = original.deletingLastPathComponent()
            .appendingPathComponent("displaced", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: displaced)
        try FileManager.default.copyItem(at: displaced, to: original)

        do {
            _ = try await source.executionWorkspace(for: context)
            XCTFail("replaced staged root must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("concurrent governed-root drift"))
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: original.appendingPathComponent("created.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.project.appendingPathComponent("created.txt").path))
    }

    func testFinalizedWorkspaceLeaseReopensAcrossRestartBeforeRelease() async throws {
        let f = try fixture()
        let c = try contract(operations: [try .init(kind: .create, path: "created.txt")])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        let (context, _, digest) = try await stageAndVerify(
            source: source, contract: c, fixture: f
        ) { try self.write(Data("created".utf8), to: $0, path: "created.txt") }
        try await source.commit(context: context, verifiedWorkspaceDigest: digest)
        let identity = try await source.executionWorkspace(for: context).rootIdentity
        try await source.markReviewApproved(context: context)
        try await source.finalize(context: context)

        let resumed = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        let verification = try BuilderStageContext(
            contract: c, node: f.node, attempt: 1, stage: .verification)
        let reopened = try await resumed.executionWorkspace(for: verification)
        XCTAssertEqual(reopened.rootIdentity, identity)
        try await resumed.releaseRetainedData(context: context)
        try await resumed.verifyFinalized(context: context)
    }

    func testFinalizedPublicationCanRollbackWhileBaselineIsRetained() async throws {
        let f = try fixture()
        let original = Data("original".utf8)
        try write(original, to: f.project, path: "target")
        let c = try contract(operations: [try .init(
            kind: .modify, path: "target", preimageSHA256: rawDigest(original))])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        let (context, _, digest) = try await stageAndVerify(
            source: source, contract: c, fixture: f
        ) { try self.write(Data("published".utf8), to: $0, path: "target") }
        try await source.commit(context: context, verifiedWorkspaceDigest: digest)
        try await source.markReviewApproved(context: context)
        try await source.finalize(context: context)
        XCTAssertEqual(
            try Data(contentsOf: f.project.appendingPathComponent("target")),
            Data("published".utf8))

        _ = try await source.rollbackCommitted(
            context: context, reason: "post-publication final verifier failed")
        XCTAssertEqual(
            try Data(contentsOf: f.project.appendingPathComponent("target")), original)
    }

    func testNoAttestorFailsBeforeWorkerWorkspace() async throws {
        let f = try fixture(); let c = try contract(operations: [])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: nil)
        let context = try BuilderStageContext(contract: c, node: f.node, attempt: 1, stage: .build)
        _ = try await source.prepare(context)
        await XCTAssertThrowsErrorAsync { try await source.executionWorkspace(for: context) }
    }

    func testStageContextRejectsNodeAndAttemptDrift() throws {
        let f = try fixture()
        let c = try contract(operations: [])
        XCTAssertThrowsError(try BuilderStageContext(
            contract: c, node: BuilderNode(id: "other", objective: "substitute"),
            attempt: 1, stage: .build))
        XCTAssertThrowsError(try BuilderStageContext(
            contract: c, node: f.node, attempt: 0, stage: .build))
    }

    func testExecutionWorkspaceRefreshesConsumedOSAttestationForResume() async throws {
        #if os(macOS)
        let f = try fixture()
        let c = try contract(operations: [])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging,
            attestor: BuilderOSProcessSandboxAttestor())
        let context = try BuilderStageContext(
            contract: c, node: f.node, attempt: 1, stage: .build)
        _ = try await source.prepare(context)
        let first = try await source.executionWorkspace(for: context)
        let pendingReuse = try await source.executionWorkspace(for: context)
        XCTAssertEqual(pendingReuse.attestation, first.attestation)
        _ = try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
            workspace: first, builderContractID: c.builderContractID) { true }

        let resumed = try await source.executionWorkspace(for: context)
        XCTAssertNotEqual(resumed.attestation.evidenceDigest,
                          first.attestation.evidenceDigest)
        let activated = try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
            workspace: resumed, builderContractID: c.builderContractID) { true }
        XCTAssertTrue(activated)
        #else
        throw XCTSkip("real OS sandbox reattestation test requires macOS")
        #endif
    }

    func testHiddenMutationIsRejected() async throws {
        let f = try fixture(); let original = Data("old".utf8)
        try write(original, to: f.project, path: "declared.txt")
        let c = try contract(operations: [try .init(
            kind: .modify, path: "declared.txt", preimageSHA256: rawDigest(original))])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        let context = try BuilderStageContext(contract: c, node: f.node, attempt: 1, stage: .build)
        let baseline = try await source.prepare(context)
        let workspace = try await source.executionWorkspace(for: context)
        let root = URL(fileURLWithPath: workspace.rootPath)
        try write(Data("new".utf8), to: root, path: "declared.txt")
        try write(Data("hidden".utf8), to: root, path: "hidden.txt")
        let worker = BuilderWorkerReceipt(
            nodeID: f.node.id, provider: "worker", model: "builder-v1",
            changedPaths: ["declared.txt"], checks: [.init(name: "build", passed: true)])
        await XCTAssertThrowsErrorAsync {
            try await source.observe(.init(
                context: context, baseline: baseline, subject: .execution(worker)))
        }
    }

    func testEscapingSymlinkAndFIFOAreRejectedWithoutFollowing() async throws {
        let f = try fixture()
        XCTAssertEqual(symlink("../../outside", f.project.appendingPathComponent("escape").path), 0)
        let c = try contract(operations: [])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        let context = try BuilderStageContext(contract: c, node: f.node, attempt: 1, stage: .build)
        await XCTAssertThrowsErrorAsync { try await source.prepare(context) }

        try FileManager.default.removeItem(at: f.project.appendingPathComponent("escape"))
        XCTAssertEqual(mkfifo(f.project.appendingPathComponent("pipe").path, 0o600), 0)
        let second = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.base.appendingPathComponent("staging2"),
            attestor: TestAttestor())
        await XCTAssertThrowsErrorAsync { try await second.prepare(context) }
    }

    func testCASRacePreservesExternalDirtyBytesAndMode() async throws {
        let f = try fixture(); let old = Data("old".utf8); let dirty = Data([0xde, 0xad, 0xbe, 0xef])
        try write(old, to: f.project, path: "target", mode: 0o640)
        let c = try contract(operations: [try .init(
            kind: .modify, path: "target", preimageSHA256: rawDigest(old))])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        let (context, _, digest) = try await stageAndVerify(
            source: source, contract: c, fixture: f
        ) { try self.write(Data("worker".utf8), to: $0, path: "target", mode: 0o600) }
        try write(dirty, to: f.project, path: "target", mode: 0o604)
        await XCTAssertThrowsErrorAsync {
            try await source.commit(context: context, verifiedWorkspaceDigest: digest)
        }
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("target")), dirty)
        XCTAssertEqual(try mode(f.project.appendingPathComponent("target")), 0o604)
    }

    func testPartialPromotionCrashRollsBackAndPreservesUnrelatedDirtyFile() async throws {
        let f = try fixture(); let a = Data("a0".utf8); let b = Data("b0".utf8)
        try write(a, to: f.project, path: "a"); try write(b, to: f.project, path: "b")
        try write(Data("base".utf8), to: f.project, path: "unrelated", mode: 0o640)
        let c = try contract(operations: [
            try .init(kind: .modify, path: "a", preimageSHA256: rawDigest(a)),
            try .init(kind: .modify, path: "b", preimageSHA256: rawDigest(b))
        ])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor(),
            faultInjector: OneShotFault(.afterPromotedPath))
        let (context, _, digest) = try await stageAndVerify(
            source: source, contract: c, fixture: f
        ) { root in
            try self.write(Data("a1".utf8), to: root, path: "a")
            try self.write(Data("b1".utf8), to: root, path: "b")
        }
        let dirty = Data([0x00, 0xff, 0x01]); try write(dirty, to: f.project, path: "unrelated", mode: 0o605)
        try await source.commit(context: context, verifiedWorkspaceDigest: digest)
        try await source.markReviewApproved(context: context)
        await XCTAssertThrowsErrorAsync { try await source.finalize(context: context) }
        _ = try await source.rollbackCommitted(context: context, reason: "injected crash")
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("a")), a)
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("b")), b)
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("unrelated")), dirty)
        XCTAssertEqual(try mode(f.project.appendingPathComponent("unrelated")), 0o605)
    }

    func testSuccessfulPromotionAndLaterRollbackPreserveUnrelatedDirtyFile() async throws {
        let f = try fixture(); let old = Data("old".utf8); let changed = Data("changed".utf8)
        try write(old, to: f.project, path: "target")
        try write(Data("base".utf8), to: f.project, path: "unrelated", mode: 0o640)
        let c = try contract(operations: [try .init(
            kind: .modify, path: "target", preimageSHA256: rawDigest(old))])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        let (context, _, digest) = try await stageAndVerify(
            source: source, contract: c, fixture: f
        ) { try self.write(changed, to: $0, path: "target") }
        let dirty = Data([0x90, 0x00, 0x91]); try write(dirty, to: f.project, path: "unrelated", mode: 0o607)
        try await source.commit(context: context, verifiedWorkspaceDigest: digest)
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("target")), old)
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("unrelated")), dirty)
        XCTAssertEqual(try mode(f.project.appendingPathComponent("unrelated")), 0o607)
        _ = try await source.rollbackCommitted(context: context, reason: "review rejected")
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("target")), old)
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("unrelated")), dirty)
        XCTAssertEqual(try mode(f.project.appendingPathComponent("unrelated")), 0o607)
    }

    func testPrepublicationReviewRollbackNeverOverwritesExternalTargetEdit() async throws {
        let f = try fixture()
        let old = Data("old".utf8)
        let external = Data("human edit".utf8)
        try write(old, to: f.project, path: "target", mode: 0o640)
        let c = try contract(operations: [try .init(
            kind: .modify, path: "target", preimageSHA256: rawDigest(old))])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        let (context, baseline, digest) = try await stageAndVerify(
            source: source, contract: c, fixture: f
        ) { try self.write(Data("worker".utf8), to: $0, path: "target") }
        try await source.commit(context: context, verifiedWorkspaceDigest: digest)
        try write(external, to: f.project, path: "target", mode: 0o604)

        let rollback = try await source.rollbackCommitted(
            context: context, reason: "review rejected after external edit")

        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("target")), external)
        XCTAssertEqual(try mode(f.project.appendingPathComponent("target")), 0o604)
        XCTAssertThrowsError(try BuilderContractVerifier().verifyRollback(
            contract: c, baseline: baseline, observation: rollback))
    }

    func testReviewApprovedAndFinalizedReplayAreIdempotent() async throws {
        let f = try fixture(); let old = Data("old".utf8)
        try write(old, to: f.project, path: "target")
        let c = try contract(operations: [try .init(
            kind: .modify, path: "target", preimageSHA256: rawDigest(old))])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor(),
            faultInjector: OneShotFault(.afterReviewApproved))
        let (context, _, digest) = try await stageAndVerify(
            source: source, contract: c, fixture: f
        ) { try self.write(Data("new".utf8), to: $0, path: "target") }
        try await source.commit(context: context, verifiedWorkspaceDigest: digest)
        await XCTAssertThrowsErrorAsync { try await source.markReviewApproved(context: context) }
        let resumed = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        try await resumed.markReviewApproved(context: context)
        try await resumed.finalize(context: context)
        try await resumed.finalize(context: context)
        try await resumed.verifyFinalized(context: context)
    }

    func testRealRootSymlinkDriftFailsClosedWithoutRewindingExternalEdit() async throws {
        let f = try fixture()
        try write(Data("target".utf8), to: f.project, path: "target")
        try write(Data("other".utf8), to: f.project, path: "other")
        XCTAssertEqual(symlink("target", f.project.appendingPathComponent("alias").path), 0)
        let c = try contract(operations: [])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        let context = try BuilderStageContext(
            contract: c, node: f.node, attempt: 1, stage: .build)
        let baseline = try await source.prepare(context)
        _ = try await source.executionWorkspace(for: context)
        try FileManager.default.removeItem(at: f.project.appendingPathComponent("alias"))
        XCTAssertEqual(symlink("other", f.project.appendingPathComponent("alias").path), 0)
        let worker = BuilderWorkerReceipt(
            nodeID: f.node.id, provider: "worker", model: "builder-v1",
            changedPaths: [], checks: [.init(name: "build", passed: true)])
        await XCTAssertThrowsErrorAsync {
            try await source.observe(.init(
                context: context, baseline: baseline, subject: .execution(worker)))
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: f.project.appendingPathComponent("alias").path),
            "other")
    }

    func testRealRootWrongTypeDriftFailsClosedWithoutDeletingExternalTree() async throws {
        let f = try fixture(); let original = Data([0x00, 0xff, 0x42])
        try write(original, to: f.project, path: "victim", mode: 0o604)
        let c = try contract(operations: [])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        let context = try BuilderStageContext(
            contract: c, node: f.node, attempt: 1, stage: .build)
        let baseline = try await source.prepare(context)
        _ = try await source.executionWorkspace(for: context)
        try FileManager.default.removeItem(at: f.project.appendingPathComponent("victim"))
        try FileManager.default.createDirectory(
            at: f.project.appendingPathComponent("victim"), withIntermediateDirectories: false)
        try write(Data("hostile".utf8), to: f.project, path: "victim/child")
        let worker = BuilderWorkerReceipt(
            nodeID: f.node.id, provider: "worker", model: "builder-v1",
            changedPaths: [], checks: [.init(name: "build", passed: true)])
        await XCTAssertThrowsErrorAsync {
            try await source.observe(.init(
                context: context, baseline: baseline, subject: .execution(worker)))
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.project.appendingPathComponent("victim").path,
            isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(
            try Data(contentsOf: f.project.appendingPathComponent("victim/child")),
            Data("hostile".utf8))
    }

    func testRealRootHardLinkAndSpecialFileDriftFailClosedWithoutDestructiveRewind() async throws {
        let f = try fixture(); let original = Data("baseline".utf8)
        try write(original, to: f.project, path: "source", mode: 0o640)
        let c = try contract(operations: [])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        let context = try BuilderStageContext(
            contract: c, node: f.node, attempt: 1, stage: .build)
        let baseline = try await source.prepare(context)
        _ = try await source.executionWorkspace(for: context)
        try FileManager.default.linkItem(
            at: f.project.appendingPathComponent("source"),
            to: f.project.appendingPathComponent("alias"))
        XCTAssertEqual(mkfifo(f.project.appendingPathComponent("pipe").path, 0o600), 0)
        let worker = BuilderWorkerReceipt(
            nodeID: f.node.id, provider: "worker", model: "builder-v1",
            changedPaths: [], checks: [.init(name: "build", passed: true)])
        await XCTAssertThrowsErrorAsync {
            try await source.observe(.init(
                context: context, baseline: baseline, subject: .execution(worker)))
        }
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("source")), original)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.project.appendingPathComponent("alias").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.project.appendingPathComponent("pipe").path))
        var sourceStatus = stat()
        XCTAssertEqual(lstat(f.project.appendingPathComponent("source").path, &sourceStatus), 0)
        XCTAssertEqual(sourceStatus.st_nlink, 2)
    }

    func testDurableIntentBeforeMutationLeavesOriginalUntouched() async throws {
        let f = try fixture(); let original = Data("original".utf8)
        try write(original, to: f.project, path: "target", mode: 0o604)
        let c = try contract(operations: [try .init(
            kind: .modify, path: "target", preimageSHA256: rawDigest(original))])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor(),
            faultInjector: OneShotFault(.afterMutationIntent))
        let (context, _, digest) = try await stageAndVerify(
            source: source, contract: c, fixture: f
        ) { try self.write(Data("changed".utf8), to: $0, path: "target", mode: 0o600) }
        try await source.commit(context: context, verifiedWorkspaceDigest: digest)
        try await source.markReviewApproved(context: context)
        await XCTAssertThrowsErrorAsync { try await source.finalize(context: context) }
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("target")), original)
        XCTAssertEqual(try mode(f.project.appendingPathComponent("target")), 0o604)
    }

    func testCrashAfterAtomicMutationRestoresCreateModifyAndDeleteOnResume() async throws {
        enum MutationCase: CaseIterable { case create, modify, delete }
        for mutationCase in MutationCase.allCases {
            let f = try fixture()
            let original = Data("original".utf8)
            let path = "target-\(mutationCase)"
            if mutationCase != .create {
                try write(original, to: f.project, path: path, mode: 0o604)
            }
            let operation: BuilderMutationOperation
            switch mutationCase {
            case .create:
                operation = try .init(kind: .create, path: path)
            case .modify:
                operation = try .init(
                    kind: .modify, path: path, preimageSHA256: rawDigest(original))
            case .delete:
                operation = try .init(
                    kind: .delete, path: path, preimageSHA256: rawDigest(original))
            }
            let c = try contract(operations: [operation])
            let source = try BuilderIsolatedWorkspaceTransactionSource(
                projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor(),
                faultInjector: OneShotFault(.afterMutationBeforeApplied))
            let (context, _, digest) = try await stageAndVerify(
                source: source, contract: c, fixture: f
            ) { staged in
                switch mutationCase {
                case .create, .modify:
                    try self.write(Data("changed".utf8), to: staged, path: path, mode: 0o600)
                case .delete:
                    try FileManager.default.removeItem(at: staged.appendingPathComponent(path))
                }
            }
            try await source.commit(context: context, verifiedWorkspaceDigest: digest)
            try await source.markReviewApproved(context: context)
            await XCTAssertThrowsErrorAsync { try await source.finalize(context: context) }
            let resumed = try BuilderIsolatedWorkspaceTransactionSource(
                projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
            try await resumed.finalize(context: context)
            try await resumed.verifyFinalized(context: context)
            switch mutationCase {
            case .create:
                XCTAssertEqual(
                    try Data(contentsOf: f.project.appendingPathComponent(path)),
                    Data("changed".utf8))
            case .modify:
                XCTAssertEqual(
                    try Data(contentsOf: f.project.appendingPathComponent(path)),
                    Data("changed".utf8))
                XCTAssertEqual(try mode(f.project.appendingPathComponent(path)), 0o600)
            case .delete:
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: f.project.appendingPathComponent(path).path))
            }
        }
    }

    private func aggregateDescriptor(_ nodes: [String]) throws
        -> BuilderAggregateTransactionDescriptor {
        try .init(
            aggregateID: String(repeating: "1", count: 64),
            parentContractFingerprint: String(repeating: "2", count: 64),
            graphFingerprint: String(repeating: "3", count: 64),
            expectedNodeIDs: nodes)
    }

    func testAggregateChildMergesSurviveRestartWithoutPublishingGovernedRoot() async throws {
        let f = try fixture()
        let a0 = Data("a0".utf8), b0 = Data("b0".utf8)
        try write(a0, to: f.project, path: "a")
        try write(b0, to: f.project, path: "b")
        let aNode = BuilderNode(id: "fleet-a", objective: "a")
        let bNode = BuilderNode(id: "fleet-b", objective: "b")
        let aContract = try contract(operations: [try .init(
            kind: .modify, path: "a", preimageSHA256: rawDigest(a0))], nodeID: aNode.id)
        let bContract = try contract(operations: [try .init(
            kind: .modify, path: "b", preimageSHA256: rawDigest(b0))], nodeID: bNode.id)
        let descriptor = try aggregateDescriptor([aNode.id, bNode.id])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        try await source.beginAggregate(descriptor)
        let aContext = try BuilderStageContext(
            contract: aContract, node: aNode, attempt: 1, stage: .build)
        let bContext = try BuilderStageContext(
            contract: bContract, node: bNode, attempt: 1, stage: .build)
        try await source.registerAggregateChild(descriptor, context: aContext)
        try await source.registerAggregateChild(descriptor, context: bContext)
        let (aBuild, _, aDigest) = try await stageAndVerify(
            source: source, contract: aContract, fixture: f, node: aNode
        ) { try self.write(Data("a1".utf8), to: $0, path: "a") }
        let (bBuild, _, bDigest) = try await stageAndVerify(
            source: source, contract: bContract, fixture: f, node: bNode
        ) { try self.write(Data("b1".utf8), to: $0, path: "b") }
        try await source.commit(context: aBuild, verifiedWorkspaceDigest: aDigest)
        try await source.commit(context: bBuild, verifiedWorkspaceDigest: bDigest)
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("a")), a0)
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("b")), b0)

        let resumed = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        let receipt = try await resumed.assertAggregateReady(descriptor)
        XCTAssertEqual(receipt.childNodeIDs, [aNode.id, bNode.id])
        let verifyContext = try BuilderStageContext(
            contract: aContract, node: aNode, attempt: 1, stage: .verification)
        let reviewContext = try BuilderStageContext(
            contract: aContract, node: aNode, attempt: 1, stage: .review)
        let verification = try await resumed.executionWorkspace(for: verifyContext)
        let review = try await resumed.executionWorkspace(for: reviewContext)
        XCTAssertEqual(verification.rootPath, review.rootPath)
        XCTAssertEqual(verification.workspaceDigest, receipt.workspaceDigest)
        XCTAssertEqual(verification.attestation.stage, .verification)
        XCTAssertEqual(review.attestation.stage, .review)
    }

    func testAggregateMissingChildFailsClosed() async throws {
        let f = try fixture(); let old = Data("old".utf8)
        try write(old, to: f.project, path: "a")
        let node = BuilderNode(id: "fleet-a", objective: "a")
        let c = try contract(operations: [try .init(
            kind: .modify, path: "a", preimageSHA256: rawDigest(old))], nodeID: node.id)
        let descriptor = try aggregateDescriptor([node.id, "fleet-b"])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        try await source.beginAggregate(descriptor)
        let context = try BuilderStageContext(contract: c, node: node, attempt: 1, stage: .build)
        try await source.registerAggregateChild(descriptor, context: context)
        let (build, _, digest) = try await stageAndVerify(
            source: source, contract: c, fixture: f, node: node
        ) { try self.write(Data("new".utf8), to: $0, path: "a") }
        try await source.commit(context: build, verifiedWorkspaceDigest: digest)
        await XCTAssertThrowsErrorAsync { try await source.assertAggregateReady(descriptor) }
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("a")), old)
    }

    func testAggregateFinalCommandFailureRollsBackAllStagedChildren() async throws {
        let f = try fixture(); let old = Data("old".utf8)
        try write(old, to: f.project, path: "a")
        let descriptor = try aggregateDescriptor(["fleet-a", "fleet-b"])
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor())
        try await source.beginAggregate(descriptor)
        try await source.rollbackAggregate(descriptor, reason: "final command failed")
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("a")), old)
        await XCTAssertThrowsErrorAsync { try await source.assertAggregateReady(descriptor) }
    }

    func testAggregatePartialGlobalPromotionRollsBackEveryPartition() async throws {
        let f = try fixture()
        let a0 = Data("a0".utf8), b0 = Data("b0".utf8)
        try write(a0, to: f.project, path: "a")
        try write(b0, to: f.project, path: "b")
        let nodes = [BuilderNode(id: "fleet-a", objective: "a"),
                     BuilderNode(id: "fleet-b", objective: "b")]
        let contracts = try [
            contract(operations: [try .init(
                kind: .modify, path: "a", preimageSHA256: rawDigest(a0))], nodeID: nodes[0].id),
            contract(operations: [try .init(
                kind: .modify, path: "b", preimageSHA256: rawDigest(b0))], nodeID: nodes[1].id)
        ]
        let descriptor = try aggregateDescriptor(nodes.map(\.id))
        let source = try BuilderIsolatedWorkspaceTransactionSource(
            projectRoot: f.project, stagingBase: f.staging, attestor: TestAttestor(),
            faultInjector: OneShotFault(.afterAggregatePromotedPath))
        try await source.beginAggregate(descriptor)
        for index in nodes.indices {
            let context = try BuilderStageContext(
                contract: contracts[index], node: nodes[index], attempt: 1, stage: .build)
            try await source.registerAggregateChild(descriptor, context: context)
            let (build, _, digest) = try await stageAndVerify(
                source: source, contract: contracts[index], fixture: f, node: nodes[index]
            ) { root in
                try self.write(Data("changed-\(index)".utf8), to: root,
                               path: index == 0 ? "a" : "b")
            }
            try await source.commit(context: build, verifiedWorkspaceDigest: digest)
        }
        try await source.markAggregateReviewApproved(
            descriptor, commitEpoch: String(repeating: "4", count: 64))
        await XCTAssertThrowsErrorAsync { try await source.finalizeAggregate(descriptor) }
        try await source.rollbackAggregate(descriptor, reason: "partial promotion")
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("a")), a0)
        XCTAssertEqual(try Data(contentsOf: f.project.appendingPathComponent("b")), b0)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
