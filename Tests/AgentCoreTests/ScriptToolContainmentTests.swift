import XCTest
@testable import AgentCore

/// SAFETY-CRITICAL. The gates prove a self-authored tool WORKS; this proves a working-but-harmful one can't
/// do damage. Every `self__` run must be sandboxed: write-confined off projectRoot, network denied. If any
/// of these regress, an authored script could `rm -rf` or exfiltrate despite passing its own tests.
final class ScriptToolContainmentTests: XCTestCase {

    #if os(macOS)
    private func writeScript(_ body: String) -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("kist-scripttest-\(abs(body.hashValue))")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("s.sh")
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testBenignScriptRunsAndIsMarkedSandboxed() async {
        let s = writeScript("#!/bin/bash\necho HELLO_FROM_SELF_TOOL\n")
        let r = await ScriptTool.runContained(interpreter: "/bin/bash", scriptPath: s, args: [])
        XCTAssertTrue(r.success, "a benign echo must run: \(r.error ?? "")")
        XCTAssertTrue(r.output.contains("HELLO_FROM_SELF_TOOL"))
        XCTAssertEqual(r.metadata["sandboxed"], "true")
    }

    func testCannotWriteOutsideItsScratch() async {
        // Try to create a file under the REPO root — the sandbox confines writes, so this must FAIL.
        let target = "/Volumes/PRO-G40/kist-evoloop/.self-tool-escape-\(UUID().uuidString).txt"
        let s = writeScript("#!/bin/bash\necho pwned > \"\(target)\" && echo WROTE || echo BLOCKED\n")
        let r = await ScriptTool.runContained(interpreter: "/bin/bash", scriptPath: s, args: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "sandbox must block a write to the repo root")
        XCTAssertFalse(r.output.contains("WROTE"), "the escape write must not succeed")
        try? FileManager.default.removeItem(atPath: target)   // belt + suspenders
    }

    func testNetworkEgressDenied() async {
        // A network call must fail under `(deny network*)`. curl returns non-zero when the connection is
        // blocked; we assert the script did NOT reach the host.
        let s = writeScript("#!/bin/bash\nif curl -s --max-time 3 http://example.com >/dev/null 2>&1; then echo REACHED; else echo BLOCKED; fi\n")
        let r = await ScriptTool.runContained(interpreter: "/bin/bash", scriptPath: s, args: [])
        XCTAssertFalse(r.output.contains("REACHED"), "network egress must be denied for a self__ script")
    }
    #endif
}
