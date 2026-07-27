import XCTest
import Foundation
@testable import AgentCore

/// Tests for user lifecycle hooks (PreToolUse/PostToolUse/Stop): config parsing, matcher logic,
/// the block contract (exit code OR JSON decision), payload shape, and a real-process smoke test.
final class AgentHooksTests: XCTestCase {

    // MARK: - Config parsing (both shapes)

    func testParseFlatArrayShape() {
        let json = #"[{"event":"PreToolUse","matcher":"write_file","command":"./guard.sh"}]"#.data(using: .utf8)!
        let specs = AgentHooks.parse(json)
        XCTAssertEqual(specs?.count, 1)
        XCTAssertEqual(specs?.first?.event, .preToolUse)
        XCTAssertEqual(specs?.first?.matcher, "write_file")
        XCTAssertEqual(specs?.first?.command, "./guard.sh")
    }

    func testParseGroupedObjectShape() {
        let json = #"""
        {"preToolUse":[{"matcher":"write_file","command":"a"}],
         "postToolUse":[{"command":"b"}],
         "stop":[{"command":"c"}]}
        """#.data(using: .utf8)!
        let specs = AgentHooks.parse(json) ?? []
        XCTAssertEqual(specs.count, 3)
        XCTAssertEqual(specs.filter { $0.event == .preToolUse }.count, 1)
        XCTAssertEqual(specs.filter { $0.event == .postToolUse }.count, 1)
        XCTAssertEqual(specs.filter { $0.event == .stop }.count, 1)
    }

    func testParseSkipsEntriesWithoutCommand() {
        let json = #"[{"event":"Stop"},{"event":"Stop","command":""},{"event":"Stop","command":"ok"}]"#.data(using: .utf8)!
        XCTAssertEqual(AgentHooks.parse(json)?.count, 1)   // only the one with a non-empty command
    }

    func testLoadReturnsNilWhenAbsent() {
        XCTAssertNil(AgentHooks.load(fromFile: "/no/such/hooks.json", projectRoot: "/tmp"))
    }

    // MARK: - Matcher

    func testMatcherWildcardAndNilMatchAll() {
        XCTAssertTrue(HookSpec(event: .preToolUse, matcher: nil, command: "x").matches(tool: "anything"))
        XCTAssertTrue(HookSpec(event: .preToolUse, matcher: "*", command: "x").matches(tool: "anything"))
        XCTAssertTrue(HookSpec(event: .preToolUse, matcher: "", command: "x").matches(tool: "anything"))
    }

    func testMatcherRegex() {
        let s = HookSpec(event: .preToolUse, matcher: "write_file|edit_file", command: "x")
        XCTAssertTrue(s.matches(tool: "write_file"))
        XCTAssertTrue(s.matches(tool: "edit_file"))
        XCTAssertFalse(s.matches(tool: "read_file"))
    }

    // MARK: - Pre-hook block contract

    func testPreHookBlocksOnNonZeroExit() async {
        let runner = StubHookRunner { _ in (2, "denied: writes are frozen") }
        let hooks = AgentHooks(specs: [HookSpec(event: .preToolUse, matcher: "write_file", command: "g")],
                               runner: runner, projectRoot: "/tmp")
        let d = await hooks.firePreToolUse(tool: "write_file", arguments: ["path": "x"])
        XCTAssertTrue(d.blocked)
        XCTAssertEqual(d.reason, "denied: writes are frozen")
    }

    func testPreHookBlocksOnJSONDecision() async {
        let runner = StubHookRunner { _ in (0, #"some log line\n{"block":true,"reason":"policy"}"#) }
        let hooks = AgentHooks(specs: [HookSpec(event: .preToolUse, matcher: nil, command: "g")],
                               runner: runner, projectRoot: "/tmp")
        let d = await hooks.firePreToolUse(tool: "run_command", arguments: [:])
        XCTAssertTrue(d.blocked)
        XCTAssertEqual(d.reason, "policy")
    }

    func testPreHookAllowsOnZeroExit() async {
        let runner = StubHookRunner { _ in (0, "ok") }
        let hooks = AgentHooks(specs: [HookSpec(event: .preToolUse, matcher: nil, command: "g")],
                               runner: runner, projectRoot: "/tmp")
        let d = await hooks.firePreToolUse(tool: "write_file", arguments: [:])
        XCTAssertFalse(d.blocked)
    }

    func testPreHookSkipsNonMatchingTool() async {
        let runner = StubHookRunner { _ in (2, "would block") }
        let hooks = AgentHooks(specs: [HookSpec(event: .preToolUse, matcher: "write_file", command: "g")],
                               runner: runner, projectRoot: "/tmp")
        // read_file doesn't match the write_file matcher → hook never runs → allowed.
        let d = await hooks.firePreToolUse(tool: "read_file", arguments: [:])
        XCTAssertFalse(d.blocked)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    // MARK: - Payload

    func testPayloadJSONCarriesEventToolAndArgs() {
        let json = AgentHooks.payloadJSON(event: .preToolUse, tool: "write_file",
                                          arguments: ["path": "a.txt"], projectRoot: "/proj", result: nil, summary: nil)
        let obj = try! JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["event"] as? String, "PreToolUse")
        XCTAssertEqual(obj["tool"] as? String, "write_file")
        XCTAssertEqual(obj["projectRoot"] as? String, "/proj")
        XCTAssertEqual((obj["arguments"] as? [String: Any])?["path"] as? String, "a.txt")
    }

    // MARK: - Real process (smoke)

    func testProcessRunnerExecutesAndReportsExit() async {
        let runner = ProcessHookRunner(timeoutSeconds: 5)
        let ok = await runner.run(command: "cat >/dev/null; exit 0", payloadJSON: "{}")
        XCTAssertEqual(ok.exitCode, 0)
        let bad = await runner.run(command: "echo nope; exit 3", payloadJSON: "{}")
        XCTAssertEqual(bad.exitCode, 3)
        XCTAssertTrue(bad.output.contains("nope"))
    }

    func testProcessRunnerReceivesPayloadOnStdin() async {
        let runner = ProcessHookRunner(timeoutSeconds: 5)
        let r = await runner.run(command: "cat", payloadJSON: #"{"event":"Stop"}"#)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.output.contains("\"event\":\"Stop\""))
    }

    // Lifecycle notification events (SessionStart / UserPromptSubmit / SubagentStop / PreCompact):
    // parse from a grouped config and fire only the matching event, passing the detail as summary.
    func testLifecycleNotificationEventsParseAndFire() async {
        let json = #"{"UserPromptSubmit":[{"command":"log-prompt"}],"SessionStart":[{"command":"log-start"}]}"#.data(using: .utf8)!
        let specs = AgentHooks.parse(json) ?? []
        XCTAssertTrue(specs.contains { $0.event == .userPromptSubmit && $0.command == "log-prompt" })
        XCTAssertTrue(specs.contains { $0.event == .sessionStart && $0.command == "log-start" })

        let stub = StubHookRunner { _ in (0, "") }
        let hooks = AgentHooks(specs: specs, runner: stub, projectRoot: "/tmp")
        await hooks.fireNotification(.userPromptSubmit, detail: "build me a clock")
        XCTAssertEqual(stub.calls.count, 1)                              // only the matching event fired
        XCTAssertEqual(stub.calls.first?.command, "log-prompt")
        XCTAssertTrue(stub.calls.first?.payload.contains("build me a clock") ?? false)
    }

    // MARK: - Untrusted-workspace RCE guard (loadTrusted)

    /// Write a project `.kist/hooks.json` carrying a uniquely-identifiable command, return the root.
    private func makeProjectWithHooks(marker: String) -> String {
        let root = NSTemporaryDirectory() + "kist-hooktest-\(UUID().uuidString)"
        let dir = root + "/.kist"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let json = #"[{"event":"PreToolUse","command":"\#(marker)"}]"#
        try? json.data(using: .utf8)!.write(to: URL(fileURLWithPath: dir + "/hooks.json"))
        return root
    }

    /// SECURITY: a workspace `.kist/hooks.json` must NOT auto-load (it would be RCE — hooks run as
    /// /bin/sh). Assert on the project MARKER so a real ~/.kist/hooks.json on the box can't affect it.
    func testProjectHooksRefusedWhenUntrusted() {
        let marker = "PROJECT_HOOK_\(UUID().uuidString)"
        let root = makeProjectWithHooks(marker: marker)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let (hooks, refused) = AgentHooks.loadTrusted(projectRoot: root, allowProjectHooks: false)
        XCTAssertTrue(refused, "a present-but-untrusted project hooks file must be reported refused")
        XCTAssertFalse(hooks?.specs.contains { $0.command == marker } ?? false,
                       "the untrusted project hook command must NOT be loaded")
    }

    /// When explicitly trusted (opt-in), the workspace hooks file loads and is not reported refused.
    func testProjectHooksLoadedWhenTrusted() {
        let marker = "PROJECT_HOOK_\(UUID().uuidString)"
        let root = makeProjectWithHooks(marker: marker)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let (hooks, refused) = AgentHooks.loadTrusted(projectRoot: root, allowProjectHooks: true)
        XCTAssertFalse(refused)
        XCTAssertTrue(hooks?.specs.contains { $0.command == marker } ?? false,
                      "an explicitly-trusted project hook must load")
    }

    /// When projectRoot IS the user's home, `<home>/.kist/hooks.json` is the USER hook file, not an
    /// untrusted workspace file — it must never be reported refused (and never double-loaded).
    func testProjectRootEqualsHomeIsNotRefused() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let (_, refused) = AgentHooks.loadTrusted(projectRoot: home, allowProjectHooks: false)
        XCTAssertFalse(refused, "the home .kist/hooks.json is user config, not an untrusted workspace file")
    }

    /// No project hooks file → nothing refused (no false-positive warning).
    func testNoProjectHooksMeansNoRefusal() {
        let root = NSTemporaryDirectory() + "kist-hooktest-empty-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (_, refused) = AgentHooks.loadTrusted(projectRoot: root, allowProjectHooks: false)
        XCTAssertFalse(refused)
    }
}

/// Records hook invocations and returns scripted (exit, output) — no real process.
final class StubHookRunner: HookRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(command: String, payload: String)] = []
    var calls: [(command: String, payload: String)] { lock.lock(); defer { lock.unlock() }; return _calls }
    private let responder: @Sendable (String) -> (Int32, String)
    init(_ responder: @escaping @Sendable (String) -> (Int32, String)) { self.responder = responder }
    func run(command: String, payloadJSON: String) async -> (exitCode: Int32, output: String) {
        lock.lock(); _calls.append((command, payloadJSON)); lock.unlock()
        return responder(command)
    }
}
