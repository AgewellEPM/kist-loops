import XCTest
import Foundation
@testable import AgentCore

final class DurableStandardInputSourceTests: XCTestCase {
    private func recipe(source: DurablePlanStandardInputSource?) -> DurablePlanVerificationRecipe {
        DurablePlanVerificationRecipe(
            id: "recipe", sourcePlanID: "plan", stepID: "E1", tool: "run_command",
            resolvedExecutable: "/bin/cat", argv: [], workingDirectory: "/tmp/project",
            standardInputSource: source, allowedExitCodes: [0],
            canonicalArgumentsJSON: "{\"args\":[],\"executable\":\"/bin/cat\"}",
            argsFingerprint: "args", commandFingerprint: "command",
            completionContractFingerprint: "completion", obligationsFingerprint: "obligations",
            executionPolicyFingerprint: "policy", workspaceManifestDigest: "manifest",
            proofWorkspaceDigest: "workspace", proofOutputDigest: "output", proofAt: Date(timeIntervalSince1970: 1),
            capabilityFingerprint: "capability", authorizationFingerprint: "authorization",
            toolSchemaFingerprint: "schema", executableIdentity: "executable")
    }

    func testInlineRecipeJSONContainsOnlyDigestAndCountNeverBytes() throws {
        let secret = "TOP-SECRET-NDJSON-{\"token\":\"abc\"}"
        let data = Data(secret.utf8)
        let value = recipe(source: DurablePlanStandardInputSource(
            kind: .inline, sha256: RunCommandTool.sha256(data), byteCount: data.count))

        let encoded = try JSONEncoder().encode(value)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains("TOP-SECRET"))
        XCTAssertTrue(json.contains(RunCommandTool.sha256(data)))
    }

    func testLegacyRawStandardInputIsDroppedAndScrubbedOnRewrite() throws {
        let secret = "LEGACY-RAW-SECRET"
        let encoded = try JSONEncoder().encode(recipe(source: .none))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "standardInputSource")
        object["standardInput"] = secret
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let decoded = try JSONDecoder().decode(DurablePlanVerificationRecipe.self, from: legacy)
        XCTAssertNil(decoded.standardInputSource, "legacy raw stdin must not enter the typed model")
        let rewritten = try JSONEncoder().encode(decoded)
        XCTAssertFalse(String(decoding: rewritten, as: UTF8.self).contains(secret))
    }

    func testPlanCheckpointEncodingRedactsInlineBytesAndForcesResumeReplan() throws {
        let secret = "CHECKPOINT-ONLY-SECRET-valid-true"
        let step = PlanStep(
            id: "E5", intent: "stdin", tool: "run_command",
            argumentsJSON: "{\"executable\":\"/bin/cat\",\"args\":[],\"stdin\":\"\(secret)\"}")
        let encoded = try JSONEncoder().encode(step)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains(secret))
        XCTAssertTrue(json.contains(RunCommandTool.sha256(Data(secret.utf8))))

        let restored = try JSONDecoder().decode(PlanStep.self, from: encoded)
        let arguments = ExecutablePlan.resolveArguments(restored.argumentsJSON, outputs: [:])
        XCTAssertNil(arguments["stdin"])
        XCTAssertNotNil(arguments["_inline_stdin_unavailable_after_resume"])
        XCTAssertNotNil(RunCommandTool.argumentValidationIssue(arguments, planPreflight: true))
        XCTAssertFalse(PlanExecuteLoop.durablePlanPersistencePreflight(
            ExecutablePlan(goal: "resume", steps: [restored])).isEmpty)
    }

    func testLegacyCheckpointLoadAtomicallyScrubsRawInlineStdin() async throws {
        let secret = "LEGACY-CHECKPOINT-RAW-STDIN-SECRET"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-inline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runID = "legacy-inline-run"
        let step = PlanStep(
            id: "E1", intent: "legacy", tool: "run_command",
            argumentsJSON: "{\"executable\":\"/bin/cat\",\"args\":[],\"stdin\":\"placeholder\"}")
        let plan = ExecutablePlan(goal: "resume", steps: [step])
        var state = ReasoningControlState(id: runID, route: .planned)
        state.executablePlanSnapshots = [DurableExecutablePlanSnapshot(
            id: "legacy-plan", generation: 0, plan: plan)]
        state.approvedExecutablePlanIDs = ["legacy-plan"]

        let safe = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: safe) as? [String: Any])
        var snapshots = try XCTUnwrap(object["executablePlanSnapshots"] as? [[String: Any]])
        var snapshot = snapshots[0]
        var planObject = try XCTUnwrap(snapshot["plan"] as? [String: Any])
        var steps = try XCTUnwrap(planObject["steps"] as? [[String: Any]])
        steps[0]["argumentsJSON"] =
            "{\"executable\":\"/bin/cat\",\"args\":[],\"stdin\":\"\(secret)\"}"
        planObject["steps"] = steps
        snapshot["plan"] = planObject
        snapshots[0] = snapshot
        object["executablePlanSnapshots"] = snapshots
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let fileName = Data(runID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "") + ".json"
        let file = directory.appendingPathComponent(fileName)
        try legacy.write(to: file, options: .atomic)

        let store = AtomicReasoningControlStore(directory: directory)
        let loadedOptional = try await store.load(runID: runID)
        let loaded = try XCTUnwrap(loadedOptional)
        let loadedPlan = try XCTUnwrap(loaded.executablePlanSnapshots?.last?.plan)
        XCTAssertFalse(PlanExecuteLoop.durablePlanPersistencePreflight(loadedPlan).isEmpty)
        XCTAssertFalse(loadedPlan.steps[0].argumentsJSON.contains(secret))
        XCTAssertTrue(loadedPlan.steps[0].argumentsJSON.contains(
            PlanStep.unavailableInlineStdinKey))
        let rewritten = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: rewritten, as: UTF8.self).contains(secret))
    }
}
