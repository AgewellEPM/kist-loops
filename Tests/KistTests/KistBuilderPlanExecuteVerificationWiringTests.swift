import Foundation
import XCTest
@testable import AgentCore
@testable import Kist

private final class PlanExecuteCommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTimeouts: [Int?] = []

    func record(_ arguments: [String: Any]) {
        lock.lock()
        recordedTimeouts.append(arguments["timeout"] as? Int)
        lock.unlock()
    }

    var timeouts: [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTimeouts
    }
}

private struct PlanExecuteCommandStub: AgentTool {
    let name = "run_command"
    let description = "record an authorized verifier"
    let parameters: [ToolParameter] = []
    let capture: PlanExecuteCommandCapture

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        capture.record(arguments)
        return ToolResult(success: true, output: "verified")
    }
}

final class KistBuilderPlanExecuteVerificationWiringTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPlanExecuteUsesFrozenVerificationOnlyRegistry() throws {
        let source = try ["KistRunner+BuilderRouting.swift", "KistRunner+BuilderAdapters.swift"].map {
            try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/Kist/" + $0), encoding: .utf8)
        }.joined(separator: "\n")

        XCTAssertTrue(source.contains("static func builderScopedPlanExecuteTools("))
        XCTAssertTrue(source.contains("guard tool.name == \"run_command\" else { return tool }"))
        XCTAssertTrue(source.contains("verificationCommands: sealedPlan.verificationCommands"))
        XCTAssertTrue(source.contains("let planExecuteTools = builderScopedPlanExecuteTools("))
        XCTAssertTrue(source.contains("root: adapterRoot, tools: planExecuteTools, context: adapterContext"))
    }

    func testOmittedTimeoutIsBoundToUniqueFrozenVerifierBeforeExecution() async throws {
        let capture = PlanExecuteCommandCapture()
        let tool = BuilderContractScopedMutationTool(
            base: PlanExecuteCommandStub(capture: capture), authority: [:],
            verificationCommands: [.init(
                executable: "python3", arguments: ["test_plan.py"], timeoutSeconds: 60)])

        let result = await ToolRegistry([tool]).execute(
            name: "run_command", arguments: try verifierArguments(),
            context: ToolContext(projectRoot: NSTemporaryDirectory()))

        XCTAssertTrue(result.success)
        XCTAssertEqual(capture.timeouts.map { $0 ?? -1 }, [60])
    }

    func testExplicitTimeoutMismatchIsDeniedWithoutExecution() async throws {
        let capture = PlanExecuteCommandCapture()
        let tool = BuilderContractScopedMutationTool(
            base: PlanExecuteCommandStub(capture: capture), authority: [:],
            verificationCommands: [.init(
                executable: "python3", arguments: ["test_plan.py"], timeoutSeconds: 60)])
        var arguments = try verifierArguments()
        arguments["timeout"] = 61

        let result = try await tool.execute(
            arguments: arguments,
            context: ToolContext(projectRoot: NSTemporaryDirectory()))

        XCTAssertFalse(result.success)
        XCTAssertTrue(capture.timeouts.isEmpty)
    }

    /// 0.17.63: a same-executable near miss runs the sealed verifier instead of failing the step
    /// (the mismatch used to cost a full replan on every build); the note is visible in the output.
    func testSameExecutableNearMissRunsTheSealedVerifierWithANote() async throws {
        let capture = PlanExecuteCommandCapture()
        let tool = BuilderContractScopedMutationTool(
            base: PlanExecuteCommandStub(capture: capture), authority: [:],
            verificationCommands: [.init(
                executable: "python3", arguments: ["-m", "unittest"], timeoutSeconds: 60)],
            substitutesNearMisses: true)
        // Through the registry the near miss is canonicalized BEFORE the wrapper runs, so the
        // sealed command executes with no note (the recorded arguments are the sealed ones).
        let result = await ToolRegistry([tool]).execute(
            name: "run_command",
            arguments: ["executable": "python3", "args": ["-m", "unittest", "discover", "-v"], "cwd": "."],
            context: ToolContext(projectRoot: NSTemporaryDirectory()))
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(capture.timeouts.map { $0 ?? -1 }, [60], "the sealed timeout ran, once")
        // A direct raw call (no registry canonicalization) still substitutes and says so.
        let direct = try await tool.execute(
            arguments: ["executable": "python3", "args": ["-m", "unittest", "discover", "-v"]],
            context: ToolContext(projectRoot: NSTemporaryDirectory()))
        XCTAssertTrue(direct.success, direct.error ?? "")
        XCTAssertTrue(direct.output.hasPrefix("[sealed verifier substituted for the requested arguments: python3 -m unittest]"), direct.output)
        XCTAssertEqual(capture.timeouts.map { $0 ?? -1 }, [60, 60])
    }

    func testNearMissSubstitutionRefusesAmbiguityDifferentExecutableAndEscapes() async throws {
        let capture = PlanExecuteCommandCapture()
        let ambiguous = BuilderContractScopedMutationTool(
            base: PlanExecuteCommandStub(capture: capture), authority: [:],
            verificationCommands: [
                .init(executable: "python3", arguments: ["-m", "unittest"], timeoutSeconds: 60),
                .init(executable: "python3", arguments: ["-m", "pytest"], timeoutSeconds: 60),
            ], substitutesNearMisses: true)
        let context = ToolContext(projectRoot: NSTemporaryDirectory())
        let twoSeals = try await ambiguous.execute(
            arguments: ["executable": "python3", "args": ["-m", "unittest", "-v"]], context: context)
        XCTAssertFalse(twoSeals.success, "two sealed commands for one executable: no unambiguous substitute")

        let single = BuilderContractScopedMutationTool(
            base: PlanExecuteCommandStub(capture: capture), authority: [:],
            verificationCommands: [.init(executable: "python3", arguments: ["-m", "unittest"], timeoutSeconds: 60)],
            substitutesNearMisses: true)
        let otherExecutable = try await single.execute(
            arguments: ["executable": "pytest", "args": ["-q"]], context: context)
        XCTAssertFalse(otherExecutable.success, "a different executable is not a near miss")
        let escapedCwd = try await single.execute(
            arguments: ["executable": "python3", "args": ["-m", "unittest", "-v"], "cwd": "../elsewhere"], context: context)
        XCTAssertFalse(escapedCwd.success, "a cwd escape is never repaired into the sealed command")
        let shell = try await single.execute(
            arguments: ["executable": "python3", "args": ["-m", "unittest"], "shell": true], context: context)
        XCTAssertFalse(shell.success)
        let explicitOtherTimeout = try await single.execute(
            arguments: ["executable": "python3", "args": ["-m", "unittest", "-v"], "timeout": 61], context: context)
        XCTAssertFalse(explicitOtherTimeout.success, "explicit timeouts are never repaired, even with substituted args")
        XCTAssertTrue(capture.timeouts.isEmpty, "nothing executed")
        let explicitSealedTimeout = try await single.execute(
            arguments: ["executable": "python3", "args": ["-m", "unittest", "-v"], "timeout": 60], context: context)
        XCTAssertTrue(explicitSealedTimeout.success, "the sealed timeout may accompany substituted args")
        XCTAssertEqual(capture.timeouts.map { $0 ?? -1 }, [60])
    }

    /// The substitution is part of CANONICALIZATION, so executors record the sealed invocation.
    func testCanonicalizationReturnsTheSealedCommandForANearMiss() {
        let tool = BuilderContractScopedMutationTool(
            base: PlanExecuteCommandStub(capture: PlanExecuteCommandCapture()), authority: [:],
            verificationCommands: [.init(executable: "python3", arguments: ["-m", "unittest"], timeoutSeconds: 60)],
            substitutesNearMisses: true)
        let canonical = tool.canonicalizeToolArguments(
            ["executable": "python3", "args": ["-m", "unittest", "discover", "-v"], "cwd": "."])
        XCTAssertEqual(canonical["executable"] as? String, "python3")
        XCTAssertEqual(canonical["args"] as? [String], ["-m", "unittest"])
        XCTAssertEqual(canonical["timeout"] as? Int, 60)
        XCTAssertNil(canonical["cwd"])
        let exact = tool.canonicalizeToolArguments(["executable": "python3", "args": ["-m", "unittest"]])
        XCTAssertEqual(exact["args"] as? [String], ["-m", "unittest"])
        XCTAssertEqual(exact["timeout"] as? Int, 60, "an omitted timeout is still bound to the sealed one")
        let registry = ToolRegistry([tool])
        XCTAssertEqual(registry.canonicalArguments(name: "run_command",
                                                   arguments: ["executable": "python3", "args": ["-m", "unittest", "-v"]])["args"] as? [String],
                       ["-m", "unittest"], "the registry exposes the same view to executors")
    }

    func testPlanExecutorRecordsCanonicalArgumentsAtBothResolutionSites() throws {
        let src = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AgentCore/PlanExecutor.swift"), encoding: .utf8)
        let sites = src.components(separatedBy: "tools.canonicalArguments(").count - 1
        XCTAssertEqual(sites, 2, "launch and repair resolution must both canonicalize (multi-site fix)")
    }

    func testAmbiguousOmittedTimeoutIsDeniedWithoutExecution() async throws {
        let capture = PlanExecuteCommandCapture()
        let tool = BuilderContractScopedMutationTool(
            base: PlanExecuteCommandStub(capture: capture), authority: [:],
            verificationCommands: [
                .init(executable: "python3", arguments: ["test_plan.py"], timeoutSeconds: 60),
                .init(executable: "python3", arguments: ["test_plan.py"], timeoutSeconds: 90),
            ])

        let result = try await tool.execute(
            arguments: try verifierArguments(),
            context: ToolContext(projectRoot: NSTemporaryDirectory()))

        XCTAssertFalse(result.success)
        XCTAssertTrue(capture.timeouts.isEmpty)
    }

    func testGovernedNodeUsesHostReceiptInsteadOfWorkerSelfVerdict() {
        let worker = BuilderWorkerReceipt(
            nodeID: "fleet-alpha", provider: "claude-cli", model: "sonnet",
            checks: [.init(name: "worker self verdict", passed: false,
                           details: "unverified — worker did not run the global oracle")])
        let host = BuilderVerifierReceipt(
            scope: .node("fleet-alpha"), provider: "host", model: "deterministic",
            deterministic: true, passed: true,
            checks: [.init(name: "partition path", passed: true,
                           details: "sealed child path exists")])

        let disposition = KistRunner.builderGovernedNodeVerificationDisposition(
            worker: worker, commandReceipt: host)

        XCTAssertTrue(disposition.passed)
        XCTAssertEqual(disposition.checks, host.checks)
        XCTAssertFalse(disposition.checks.contains { $0.name == "worker self verdict" })
    }

    func testGovernedFinalSourceVerdictIsAdvisoryButLegacyStillFailsClosed() {
        let worker = BuilderWorkerReceipt(
            nodeID: "fleet-alpha", provider: "claude-cli", model: "sonnet",
            checks: [.init(name: "worker self verdict", passed: false,
                           details: "unverified")])

        let governed = KistRunner.builderAdapterSourceEvidence(
            workers: [worker], governedByPreflight: true)
        let legacy = KistRunner.builderAdapterSourceEvidence(
            workers: [worker], governedByPreflight: false)

        XCTAssertTrue(governed.passed)
        XCTAssertTrue(governed.check.passed)
        XCTAssertTrue(governed.check.details.contains("sealed host verification"))
        XCTAssertFalse(legacy.passed)
        XCTAssertFalse(legacy.check.passed)
    }

    func testPlanExecuteReplayUsesRealFullStreamDigestAndBuildRetainsTypedReceipt() throws {
        ForgeSeal.forceEphemeralKeyForTesting()
        defer { ForgeSeal.resetCacheForTesting() }
        let reference = try BuilderTrustedCommandReference(
            observationID: "plan-final-observation", invocationID: "plan-final-invocation",
            gateArgumentsDigest: String(repeating: "1", count: 64),
            requestedArgumentsDigest: String(repeating: "2", count: 64),
            effectiveLauncherDigest: String(repeating: "3", count: 64),
            effectiveEnvironmentDigest: String(repeating: "4", count: 64),
            sandboxProfileDigest: String(repeating: "5", count: 64),
            stdoutDigest: BuilderEvidenceDigest.sha256("stdout"),
            stderrDigest: BuilderEvidenceDigest.sha256("stderr"),
            stdoutByteCount: 6, stderrByteCount: 6, exitCode: 0,
            timedOut: false, wasSignalled: false, wallTimeMilliseconds: 1)
        XCTAssertNotEqual(reference.fullStreamDigest, reference.stdoutDigest)
        let mission = String(repeating: "a", count: 64)
        let contract = "kist-builder-fixture"
        let subject = String(repeating: "c", count: 64)
        let receipt = PlanFinalVerificationReceipt(
            missionInstanceID: mission, contractID: contract, stepID: "final",
            tool: "run_command",
            invocation: .init(executable: "/usr/bin/true", argv: [],
                              hasStandardInput: false),
            commandFingerprint: String(repeating: "6", count: 64),
            expectedExitCode: 0, actualExitCode: 0,
            outputDigest: reference.fullStreamDigest,
            boundedRedactedOutputExcerpt: "verified",
            governedWorkspaceDigest: subject,
            completionContractFingerprint: String(repeating: "7", count: 64),
            executionPolicyFingerprint: String(repeating: "8", count: 64),
            verifiedAt: Date(), freshAfterMutationFrontier: true,
            captureOrdinal: 2, mutationFrontierOrdinal: 1,
            trustedCommandReference: reference)

        let evidence = try XCTUnwrap(KistRunner.builderFinalReplayEvidence(
            receipt: receipt, missionInstanceID: mission, contractID: contract,
            contractFingerprint: String(repeating: "9", count: 64),
            subjectDigest: subject))
        XCTAssertEqual(evidence.outputDigest, reference.fullStreamDigest)
        XCTAssertTrue(evidence.isBound(
            contractFingerprint: String(repeating: "9", count: 64),
            subjectDigest: subject))
        XCTAssertTrue(KistRunner.builderPlanExecuteCompletionGatePassed(
            adapterPassed: true, observedMissionID: mission,
            expectedMissionID: mission, finalReplay: evidence))

        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Kist/KistRunner+BuilderAdapters.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("planFinalVerificationReceipt = replay != nil"))
        XCTAssertTrue(source.contains("? outcome?.finalVerificationReceipt : nil"))
    }

    func testPlanExecuteBuildCannotPassCompletionGateWithNilTypedReplay() {
        let mission = String(repeating: "a", count: 64)
        XCTAssertFalse(KistRunner.builderPlanExecuteCompletionGatePassed(
            adapterPassed: true, observedMissionID: mission,
            expectedMissionID: mission, finalReplay: nil))
        XCTAssertFalse(KistRunner.builderPlanExecuteCompletionGatePassed(
            adapterPassed: true, observedMissionID: String(repeating: "b", count: 64),
            expectedMissionID: mission, finalReplay: nil))
    }

    func testAcceptedPersistenceIsPlanExecuteOnlyInsideBuilderPreReleaseHook() throws {
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Kist/KistRunner+Builder.swift"),
            encoding: .utf8)
        let hook = try XCTUnwrap(source.range(of: "if launch.adapter == .planExecute"))
        let persistence = try XCTUnwrap(
            source.range(of: "persistAcceptedPlanExecuteRun("))
        let runConstruction = try XCTUnwrap(source.range(of: "let run = try BuilderRun("))
        let execution = try XCTUnwrap(source.range(of: "let final = try await run.run()"))

        XCTAssertLessThan(hook.lowerBound, persistence.lowerBound)
        XCTAssertLessThan(persistence.lowerBound, runConstruction.lowerBound,
                          "persistence must be supplied as a BuilderRun hook, not called post-run")
        XCTAssertLessThan(runConstruction.lowerBound, execution.lowerBound)
        XCTAssertEqual(source.components(separatedBy: "persistAcceptedPlanExecuteRun(").count - 1,
                       1)
        XCTAssertTrue(source.contains("finalAcceptanceCommit: finalAcceptanceCommit"))
        XCTAssertTrue(source.contains("finalAcceptanceCommit = nil"),
                      "non-PlanExecute Builder adapters must not receive the trust hook")
        XCTAssertTrue(source.contains("case .acceptancePersistencePending"))
        XCTAssertTrue(source.contains("outcome: \"acceptance-persistence-pending\""))
    }

    private func verifierArguments() throws -> [String: Any] {
        let data = Data(
            #"{"executable":"python3","args":["test_plan.py"],"cwd":".","allowed_exit_codes":[0]}"#.utf8)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
