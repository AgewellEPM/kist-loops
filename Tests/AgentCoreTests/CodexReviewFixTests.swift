import XCTest
@testable import AgentCore

/// Regression tests for the pre-merge Codex review findings. One assertion per fixed invariant.
final class CodexReviewFixTests: XCTestCase {

    // CRITICAL — a token in ANY finding's evidence is redacted, not just secret-scanner hits.
    func testEvidenceRedactionIsCentral() {
        XCTAssertFalse(SecretScanner.redactSecrets(in: "load AKIAIOSFODNN7EXAMPLE now").contains("AKIAIOSFODNN7EXAMPLE"))
        let dep = SecurityFinding(severity: .low, category: .dependency, rule: "npm-floating-version",
                                  title: "t", file: "package.json", line: 1,
                                  evidence: "\"x\": \"^1\" AKIAIOSFODNN7EXAMPLE", recommendation: "")
        XCTAssertFalse(dep.evidence.contains("AKIAIOSFODNN7EXAMPLE"))   // dep finding evidence redacted
        XCTAssertTrue(dep.evidence.contains("•"))
    }

    // HIGH — IPv4-mapped IPv6 is classified via the IPv4 rules (no SSRF bypass).
    func testIPv4MappedIPv6IsNonPublic() {
        XCTAssertTrue(WebFetchTool.isNonPublicIPv4(127, 0))
        XCTAssertTrue(WebFetchTool.isNonPublicIPv4(169, 254))
        XCTAssertTrue(WebFetchTool.isNonPublicIPv4(10, 0))
        XCTAssertFalse(WebFetchTool.isNonPublicIPv4(8, 8))
    }

    func testBrowserRefusesIPv4MappedIPv6() async throws {
        let ctx = ToolContext(projectRoot: NSTemporaryDirectory())
        for bad in ["http://[::ffff:127.0.0.1]/", "http://[::ffff:169.254.169.254]/"] {
            let r = try await BrowserTool().execute(arguments: ["url": bad], context: ctx)
            XCTAssertFalse(r.success, "should refuse \(bad): \(r.output)")
        }
    }

    // HIGH — a sourceless `.proven` lesson decoded from JSON is coerced to `.obstacle`.
    func testLessonDecodeEnforcesProvenInvariant() throws {
        let json = #"{"id":"x","kind":"proven","text":"it worked","keywords":["worked"],"source":null,"at":1.0}"#
        let lesson = try JSONDecoder().decode(Lesson.self, from: Data(json.utf8))
        XCTAssertEqual(lesson.kind, .obstacle)   // can't claim proven without a source, even via decode
        let sourced = #"{"id":"x","kind":"proven","text":"t","keywords":[],"source":"signoff#1","at":1.0}"#
        XCTAssertEqual(try JSONDecoder().decode(Lesson.self, from: Data(sourced.utf8)).kind, .proven)
    }

    // HIGH — the tasks tool refuses to write through a `.kist` symlink that escapes the project root.
    func testTasksToolRefusesSymlinkEscape() async throws {
        let root = NSTemporaryDirectory() + "proj_\(UUID().uuidString)"
        let outside = NSTemporaryDirectory() + "outside_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/.kist", withDestinationPath: outside)
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: outside) }

        let r = try await ManageTasksTool().execute(arguments: ["action": "add", "title": "x"],
                                                    context: ToolContext(projectRoot: root))
        XCTAssertFalse(r.success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside + "/plan.json"))   // nothing written outside
    }

    // MEDIUM — the audit walk never reads through a symlinked file.
    func testAuditSkipsSymlinkedFiles() throws {
        let root = NSTemporaryDirectory() + "audit_\(UUID().uuidString)"
        let ext = NSTemporaryDirectory() + "ext_\(UUID().uuidString).swift"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "let k = \"AKIAIOSFODNN7EXAMPLE\"".write(toFile: ext, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/link.swift", withDestinationPath: ext)
        try "let clean = 1".write(toFile: root + "/clean.swift", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: ext) }

        let report = SecurityAuditor.audit(root: root)
        XCTAssertTrue(report.findings.filter { $0.category == .secret }.isEmpty)   // symlink not read
    }

    // MEDIUM — a real secret isn't suppressed just because the line also contains "test"/"example".
    func testPlaceholderSkipUsesMatchNotWholeLine() {
        let f = SecretScanner.scan(text: "password = \"a8Fj20fkQ91ldkfjs0211\"  // test note", file: "x")
        XCTAssertEqual(f.count, 1)
    }

    // T0.2 live-verify fix — the driver requires playwright from argv[3] so a GLOBAL install resolves.
    func testDriverResolvesPlaywrightFromArgv3() {
        XCTAssertTrue(BrowserSpec.driverJS.contains("process.argv[3]"))
        let p = BrowserTool.playwrightModulePath()
        XCTAssertTrue(p == "playwright" || p.hasSuffix("/playwright"), "got \(p)")
    }

    // LOW — alternating cyclic loops are detected, not just consecutive repeats.
    func testCyclicLoopDetected() {
        let steps = (0..<3).flatMap { _ in
            [ActionRecord(tool: "read_file", argsFingerprint: "A", success: true),
             ActionRecord(tool: "run_command", argsFingerprint: "test", success: true)]
        }
        XCTAssertTrue(TrajectoryAnalyzer.analyze(steps).issues.contains { $0.kind == .runawayLoop })
    }
}
