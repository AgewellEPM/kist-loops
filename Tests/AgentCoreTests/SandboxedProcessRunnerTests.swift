import XCTest
@testable import AgentCore

final class SandboxedProcessRunnerTests: XCTestCase {
    func testRequiredSandboxReportsThePlatformImplementation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = SandboxedProcessRunner.runRequired(
            launchPath: "/usr/bin/true", launchArgs: [], root: root.path, cwd: root.path,
            env: ["PATH": "/usr/bin:/bin"], timeoutSeconds: 5, capPerStream: 2_000)

        try XCTSkipUnless(outcome.sandboxed && outcome.exitCode == 0,
                          "required OS sandbox unavailable in this test environment: \(outcome.combined)")
        #if os(macOS)
        XCTAssertEqual(outcome.sandbox, "macOS Seatbelt")
        #else
        XCTAssertEqual(outcome.sandbox, "Linux bubblewrap")
        #endif
    }
}
