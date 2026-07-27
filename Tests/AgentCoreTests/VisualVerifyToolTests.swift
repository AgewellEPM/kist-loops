import XCTest
@testable import AgentCore

final class VisualVerifyToolTests: XCTestCase {
    private final class CaptureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var attachments: [MediaAttachment] = []
        private var prompt = ""
        private var capturedURL = ""
        private var capturedActions: [BrowserAction] = []
        private var capturedPath = ""

        func recordAnalysis(_ attachments: [MediaAttachment], _ prompt: String) {
            lock.lock(); defer { lock.unlock() }
            self.attachments = attachments
            self.prompt = prompt
        }

        func recordCapture(url: String, actions: [BrowserAction], path: String) {
            lock.lock(); defer { lock.unlock() }
            capturedURL = url
            capturedActions = actions
            capturedPath = path
        }

        func analysisSnapshot() -> (attachments: [MediaAttachment], prompt: String) {
            lock.lock(); defer { lock.unlock() }
            return (attachments, prompt)
        }

        func captureSnapshot() -> (url: String, actions: [BrowserAction], path: String) {
            lock.lock(); defer { lock.unlock() }
            return (capturedURL, capturedActions, capturedPath)
        }
    }

    private func makeRoot() throws -> String {
        let raw = NSTemporaryDirectory() + "visual-verify-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return ToolContext.canonicalize(raw)!
    }

    private func writePNG(_ path: String) throws {
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: path))
    }

    func testCandidateComparisonPersistsPassingArtifacts() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writePNG(root + "/reference.png")
        try writePNG(root + "/candidate.png")
        let capture = CaptureBox()
        let tool = VisualVerifyTool(analyze: { attachments, prompt in
            capture.recordAnalysis(attachments, prompt)
            return """
            Verdict: PASS
            Score: 96
            Matches:
            - layout matches
            Mismatches:
            - none
            Patch guidance:
            - no patch
            Retest:
            - keep same viewport
            """
        })

        let result = try await tool.execute(arguments: [
            "goal": "match the reference screen",
            "reference": "reference.png",
            "candidate": "candidate.png",
            "run_id": "home_screen",
            "threshold": 90,
        ], context: ToolContext(projectRoot: root))

        XCTAssertTrue(result.success, result.error ?? result.output)
        XCTAssertTrue(result.output.contains("Visual verify PASS"))
        XCTAssertEqual(result.metadata["run_id"], "home_screen")
        XCTAssertEqual(result.metadata["attempt"], "1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/visual-runs/home_screen/reference.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/visual-runs/home_screen/attempt-01.png"))
        let report = try String(contentsOfFile: root + "/.kist/visual-runs/home_screen/attempt-01-report.md")
        XCTAssertTrue(report.contains("Verdict: PASS"))
        let latest = try String(contentsOfFile: root + "/.kist/visual-runs/home_screen/latest.json")
        XCTAssertTrue(latest.contains("\"passed\" : true"))
        XCTAssertTrue(latest.contains("\"score\" : 96"))

        let seen = capture.analysisSnapshot()
        XCTAssertEqual(seen.attachments.count, 2)
        XCTAssertEqual(seen.attachments[0].sourcePath, ".kist/visual-runs/home_screen/reference.png")
        XCTAssertEqual(seen.attachments[1].sourcePath, ".kist/visual-runs/home_screen/attempt-01.png")
        XCTAssertTrue(seen.prompt.contains("first image is the reference"))
    }

    func testFailingReportWritesEvidenceAndIncrementsRetestAttempt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writePNG(root + "/candidate.png")
        let responses = LockedResponses([
            """
            Verdict: FAIL
            Score: 62
            Matches:
            - header present
            Mismatches:
            - primary action is missing
            Patch guidance:
            - add the button
            Retest:
            - capture home route
            """,
            """
            Verdict: PASS
            Score: 93
            Matches:
            - target met
            Mismatches:
            - none
            Patch guidance:
            - none
            Retest:
            - keep screenshot
            """,
        ])
        let tool = VisualVerifyTool(analyze: { _, _ in responses.next() })

        let first = try await tool.execute(arguments: [
            "goal": "show the primary action",
            "candidate": "candidate.png",
            "run_id": "retest",
        ], context: ToolContext(projectRoot: root))
        let second = try await tool.execute(arguments: [
            "goal": "show the primary action",
            "candidate": "candidate.png",
            "run_id": "retest",
        ], context: ToolContext(projectRoot: root))

        XCTAssertFalse(first.success)
        XCTAssertEqual(first.metadata["attempt"], "1")
        XCTAssertTrue(first.output.contains("Patch the mismatches"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/visual-runs/retest/attempt-01-report.md"))
        XCTAssertTrue(second.success, second.error ?? second.output)
        XCTAssertEqual(second.metadata["attempt"], "2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/visual-runs/retest/attempt-02-report.md"))
    }

    func testBrowserCapturePathFeedsCandidateIntoVisionJudge() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let capture = CaptureBox()
        let tool = VisualVerifyTool(analyze: { attachments, prompt in
            capture.recordAnalysis(attachments, prompt)
            return "Verdict: PASS\nScore: 91\nMatches:\n- loaded\nMismatches:\n- none\nPatch guidance:\n- none\nRetest:\n- same route"
        }, captureBrowser: { url, actions, screenshotPath, context in
            capture.recordCapture(url: url, actions: actions, path: screenshotPath)
            let resolved = try context.resolvedPath(screenshotPath, mustExist: false)
            try FileManager.default.createDirectory(atPath: (resolved as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: resolved))
            return ToolResult(success: true, output: "Captured browser text")
        })

        let result = try await tool.execute(arguments: [
            "goal": "settings route should load",
            "url": "http://127.0.0.1:5173/settings",
            "actions": [["do": "wait", "selector": "#ready"]],
            "run_id": "settings",
        ], context: ToolContext(projectRoot: root))

        XCTAssertTrue(result.success, result.error ?? result.output)
        let captured = capture.captureSnapshot()
        XCTAssertEqual(captured.url, "http://127.0.0.1:5173/settings")
        XCTAssertEqual(captured.actions, [.waitFor(selector: "#ready")])
        XCTAssertEqual(captured.path, ".kist/visual-runs/settings/attempt-01.png")
        let seen = capture.analysisSnapshot()
        XCTAssertEqual(seen.attachments.count, 1)
        XCTAssertEqual(seen.attachments[0].sourcePath, ".kist/visual-runs/settings/attempt-01.png")
        XCTAssertTrue(seen.prompt.contains("Browser text summary from capture"))
    }

    func testInvalidRunIDAndNonImageCandidateAreRejected() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "not image".write(toFile: root + "/candidate.txt", atomically: true, encoding: .utf8)
        let registry = ToolRegistry([VisualVerifyTool(analyze: { _, _ in "should not run" })])

        let badID = await registry.execute(name: "visual_verify", arguments: [
            "goal": "x",
            "candidate": "candidate.txt",
            "run_id": "../escape",
        ], context: ToolContext(projectRoot: root))
        XCTAssertFalse(badID.success)
        XCTAssertTrue((badID.error ?? "").contains("run_id may contain only"), badID.error ?? "")

        let badImage = await registry.execute(name: "visual_verify", arguments: [
            "goal": "x",
            "candidate": "candidate.txt",
            "run_id": "safe",
        ], context: ToolContext(projectRoot: root))
        XCTAssertFalse(badImage.success)
        XCTAssertTrue((badImage.error ?? "").contains("candidate must be an image"), badImage.error ?? "")
    }

    func testVisualArtifactIORejectsSymlinkEscapes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let outside = NSTemporaryDirectory() + "visual-outside-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try writePNG(outside)
        try FileManager.default.createSymbolicLink(atPath: root + "/candidate-link.png",
                                                   withDestinationPath: outside)
        let registry = ToolRegistry([VisualVerifyTool(analyze: { _, _ in "should not run" })])

        let result = await registry.execute(name: "visual_verify", arguments: [
            "goal": "x",
            "candidate": "candidate-link.png",
            "run_id": "symlink_candidate",
        ], context: ToolContext(projectRoot: root))

        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("escapes the project root"), result.error ?? "")
    }

    func testVisualRunDirectorySymlinkCannotRedirectArtifacts() async throws {
        let root = try makeRoot()
        let outside = NSTemporaryDirectory() + "visual-runs-outside-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outside)
        }
        try writePNG(root + "/candidate.png")
        try FileManager.default.createDirectory(atPath: root + "/.kist", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/.kist/visual-runs",
                                                   withDestinationPath: outside)
        let registry = ToolRegistry([VisualVerifyTool(analyze: { _, _ in "should not run" })])

        let result = await registry.execute(name: "visual_verify", arguments: [
            "goal": "x",
            "candidate": "candidate.png",
            "run_id": "symlinked",
        ], context: ToolContext(projectRoot: root))

        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("escapes the project root"), result.error ?? "")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: outside)) ?? [], [])
    }

    func testAttemptParsingHandlesTripleDigitsAndCapsRunGrowth() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writePNG(root + "/candidate.png")
        let runDir = root + "/.kist/visual-runs/retest"
        try FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
        try writePNG(runDir + "/attempt-99.png")
        let registry = ToolRegistry([VisualVerifyTool(analyze: { _, _ in
            "Verdict: PASS\nScore: 99\nMatches:\n- ok\nMismatches:\n- none\nPatch guidance:\n- none\nRetest:\n- same"
        })])

        let hundred = await registry.execute(name: "visual_verify", arguments: [
            "goal": "x",
            "candidate": "candidate.png",
            "run_id": "retest",
        ], context: ToolContext(projectRoot: root))
        XCTAssertTrue(hundred.success, hundred.error ?? hundred.output)
        XCTAssertEqual(hundred.metadata["attempt"], "100")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runDir + "/attempt-100-report.md"))

        let capped = await registry.execute(name: "visual_verify", arguments: [
            "goal": "x",
            "candidate": "candidate.png",
            "run_id": "retest",
        ], context: ToolContext(projectRoot: root))
        XCTAssertFalse(capped.success)
        XCTAssertTrue((capped.error ?? "").contains("max attempt count"), capped.error ?? "")
    }

    func testScopeGateBlocksVisualVerifyDuringPlanOnlyWork() async {
        let decision = AuthorizationScopeEngine.evaluate("diagnose why my server has high latency")
        XCTAssertEqual(decision.gate, .planOnly)
        let registry = ToolRegistry([VisualVerifyTool(analyze: { _, _ in "should not run" })])

        let result = await registry.execute(name: "visual_verify", arguments: [
            "goal": "capture admin dashboard",
            "candidate": "shot.png",
        ], context: ToolContext(projectRoot: NSTemporaryDirectory(), authorizationScope: decision))

        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("plan-only scope"), result.error ?? "")
    }

    func testContractAdvertisesVisualVerificationLoop() {
        let contract = ToolContractBook.render(tools: ToolRegistry([
            VisualVerifyTool(analyze: { _, _ in "ok" }),
            ViewImageTool { _, _ in "ok" },
            ReadFileTool(),
        ]))

        XCTAssertTrue(contract.contains("Visual Verification"))
        XCTAssertTrue(contract.contains("visual_verify"))
        XCTAssertTrue(contract.contains("visual diff"))
        XCTAssertTrue(contract.contains("retest"))
    }

    func testScoreAndVerdictParsing() {
        XCTAssertEqual(VisualVerifyTool.parseScore("Score: 101"), 100)
        XCTAssertEqual(VisualVerifyTool.parseScore("score = 87/100"), 87)
        XCTAssertTrue(VisualVerifyTool.isPassing(report: "Verdict: PASS", score: nil, threshold: 90))
        XCTAssertFalse(VisualVerifyTool.isPassing(report: "Verdict: FAIL\nScore: 99", score: 99, threshold: 90))
        XCTAssertFalse(VisualVerifyTool.isPassing(report: "Score: 89", score: 89, threshold: 90))
    }
}

private final class LockedResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        if values.isEmpty { return "Verdict: FAIL\nScore: 0" }
        return values.removeFirst()
    }
}
