import XCTest
@testable import AgentCore

/// Activation (store save/load → callable ScriptTool) and the P2 script gate (acceptance test under the
/// contained runner). Uses a real bash tool so the round-trip is end-to-end.
final class SelfAuthoredStoreGateTests: XCTestCase {

    #if os(macOS)
    private func tmpRoot() -> String {
        let d = (NSTemporaryDirectory() as NSString).appendingPathComponent("kist-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    // A self__ tool that upper-cases its --text arg (a real, verifiable capability).
    private func upperManifest() -> SelfAuthoredManifest {
        SelfAuthoredManifest(
            name: "self__upper", description: "upper-case the --text argument",
            interpreter: "/bin/bash", scriptFile: "upper.sh",
            parameters: [.init(name: "text", description: "text to upper-case")],
            contract: "given --text T, prints T upper-cased",
            testArgs: ["text": "hello"], testExpectSubstring: "HELLO")
    }
    private let upperScript = """
    #!/bin/bash
    text=""
    while [[ $# -gt 0 ]]; do case "$1" in --text) text="$2"; shift 2;; *) shift;; esac; done
    echo "$text" | tr '[:lower:]' '[:upper:]'
    """

    func testStoreRoundTripAndCallable() async throws {
        let store = SelfAuthoredToolStore(projectRoot: tmpRoot())
        _ = try store.save(manifest: upperManifest(), scriptBody: upperScript)
        let tools = store.load()
        XCTAssertEqual(tools.count, 1)
        let tool = tools[0]
        XCTAssertEqual(tool.name, "self__upper")
        let r = try await tool.execute(arguments: ["text": "world"], context: ToolContext(projectRoot: "/tmp"))
        XCTAssertTrue(r.output.contains("WORLD"), "the loaded self__ tool actually runs: \(r.output)")
        XCTAssertEqual(r.metadata["sandboxed"], "true")
    }

    func testSaveRefusesNonSelfNamespace() {
        let store = SelfAuthoredToolStore(projectRoot: tmpRoot())
        var m = upperManifest()
        m = SelfAuthoredManifest(name: "sneaky_tool", description: m.description, interpreter: m.interpreter,
                                 scriptFile: m.scriptFile, parameters: m.parameters, contract: m.contract,
                                 testArgs: m.testArgs, testExpectSubstring: m.testExpectSubstring)
        XCTAssertThrowsError(try store.save(manifest: m, scriptBody: upperScript), "only self__ may be saved")
    }

    func testGatePassesAWorkingTool() async throws {
        let root = tmpRoot()
        let store = SelfAuthoredToolStore(projectRoot: root)
        let home = try store.save(manifest: upperManifest(), scriptBody: upperScript)
        let gate = ScriptCandidateGate()
        let cand = CapabilityCandidate(toolName: "self__upper", workdir: home, contract: "x", authorProvider: "deepseek")
        let v = await gate.verify(cand)
        XCTAssertTrue(v.passed, v.reason)
    }

    func testGateRejectsAToolThatFailsItsOwnTest() async throws {
        let root = tmpRoot()
        let store = SelfAuthoredToolStore(projectRoot: root)
        // A script that does the WRONG thing (lower-cases) → acceptance test (expects HELLO) fails.
        let badScript = "#!/bin/bash\necho hello\n"
        let m = upperManifest()
        let home = try store.save(manifest: m, scriptBody: badScript)
        let gate = ScriptCandidateGate()
        let cand = CapabilityCandidate(toolName: "self__upper", workdir: home, contract: "x", authorProvider: "deepseek")
        let v = await gate.verify(cand)
        XCTAssertFalse(v.passed, "a tool that fails its own acceptance test must not pass the gate")
    }
    #endif
}
