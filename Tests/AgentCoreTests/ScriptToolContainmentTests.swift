import XCTest
@testable import AgentCore

/// SAFETY-CRITICAL. Production `self__` execution must not launch at all until hard descendant/resource
/// containment is wired. The DEBUG-only advisory tests below retain coverage of the legacy sandbox without
/// letting that sandbox become execution or promotion authority.
final class ScriptToolContainmentTests: XCTestCase {

    #if os(macOS) || os(Linux)
    func testProductionRunnerRefusesBeforeInterpreterCanCreateMarker() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-self-production-refusal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = dir.appendingPathComponent("EXECUTED")
        let script = dir.appendingPathComponent("candidate.sh")
        try "#!/bin/sh\nprintf executed > \"\(marker.path)\"\n".write(
            to: script, atomically: true, encoding: .utf8)

        let result = await ScriptTool.runContained(
            interpreter: "/bin/sh", scriptPath: script.path, args: [])

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("hard containment unavailable") == true
                      || result.error?.contains("hard-containment") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "production self__ execution must refuse before launching the interpreter")
        XCTAssertEqual(result.metadata["hard_containment"], "unavailable")
    }

    func testProductionCandidateGateRefusesBeforeMarkerScriptRuns() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-candidate-gate-refusal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = dir.appendingPathComponent("EXECUTED")
        let script = dir.appendingPathComponent("candidate.sh")
        // If the old advisory runner is accidentally restored, the first write is denied but the final
        // stdout oracle exits zero, so the gate would pass and this regression would fail visibly.
        try "#!/bin/sh\nprintf executed > \"\(marker.path)\"\nprintf GATE_EXECUTED\n".write(
            to: script, atomically: true, encoding: .utf8)
        let manifest = SelfAuthoredManifest(
            name: "self__marker", description: "marker probe",
            interpreter: "/bin/sh", scriptFile: "candidate.sh", parameters: [],
            contract: "prints the marker oracle", testArgs: [:],
            testExpectSubstring: "GATE_EXECUTED")
        try JSONEncoder().encode(manifest).write(
            to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        let candidate = CapabilityCandidate(
            toolName: manifest.name, workdir: dir.path, contract: manifest.contract,
            authorProvider: "author")

        let verdict = await ScriptCandidateGate().verify(candidate)

        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.reason.contains("hard containment unavailable")
                      || verdict.reason.contains("hard-containment"), verdict.reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the production candidate gate must not launch authored code")
    }
    #endif

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
        let r = await ScriptTool.runAdvisoryForTesting(
            interpreter: "/bin/bash", scriptPath: s, args: [])
        XCTAssertTrue(r.success, "a benign echo must run: \(r.error ?? "")")
        XCTAssertTrue(r.output.contains("HELLO_FROM_SELF_TOOL"))
        XCTAssertEqual(r.metadata["sandboxed"], "advisory-test-only")
    }

    func testCannotWriteOutsideItsScratch() async {
        // Try to create a file under the REPO root — the sandbox confines writes, so this must FAIL.
        let target = "/Volumes/PRO-G40/kist-evoloop/.self-tool-escape-\(UUID().uuidString).txt"
        let s = writeScript("#!/bin/bash\necho pwned > \"\(target)\" && echo WROTE || echo BLOCKED\n")
        let r = await ScriptTool.runAdvisoryForTesting(
            interpreter: "/bin/bash", scriptPath: s, args: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "sandbox must block a write to the repo root")
        XCTAssertFalse(r.output.contains("WROTE"), "the escape write must not succeed")
        try? FileManager.default.removeItem(atPath: target)   // belt + suspenders
    }

    func testNetworkEgressDenied() async {
        // A network call must fail under `(deny network*)`. curl returns non-zero when the connection is
        // blocked; we assert the script did NOT reach the host.
        let s = writeScript("#!/bin/bash\nif curl -s --max-time 3 http://example.com >/dev/null 2>&1; then echo REACHED; else echo BLOCKED; fi\n")
        let r = await ScriptTool.runAdvisoryForTesting(
            interpreter: "/bin/bash", scriptPath: s, args: [])
        XCTAssertFalse(r.output.contains("REACHED"), "network egress must be denied for a self__ script")
    }
    #endif
}
