import XCTest
import Foundation
@testable import AgentCore

/// Tests the opt-in OS-level sandbox tier. Profile-generation + fail-closed behavior are
/// cross-platform; the live kernel-confinement assertions are macOS-only (Seatbelt) and use
/// deterministic filesystem-write checks (not flaky live-network calls).
final class SeatbeltSandboxTests: XCTestCase {

    private var root: String!
    private var external: String?

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "sbx-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
        #if os(macOS)
        if Self.liveSeatbeltRequested {
            // "external" must be a NON-temp location (the profile allows the project root + temp
            // + /dev), so use a dir under HOME to prove writes to real files are blocked.
            let ext = NSHomeDirectory() + "/.agentcore-sbxtest-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: ext, withIntermediateDirectories: true)
            external = ToolContext.canonicalize(ext)
        }
        #endif
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
        if let external { try? FileManager.default.removeItem(atPath: external) }
    }

    private func enabledShell() -> ShellPolicy { ShellPolicy(enabled: true, autoApprove: true) }
    private func ctx(sandbox: SandboxPolicy) -> ToolContext {
        ToolContext(projectRoot: root, shell: enabledShell(), sandbox: sandbox)
    }
    private func run(_ script: String, sandbox: SandboxPolicy) async -> ToolResult {
        await ToolRegistry.headless().execute(
            name: "run_command",
            arguments: ["executable": "/bin/sh", "args": ["-c", script]],
            context: ctx(sandbox: sandbox))
    }

    #if os(macOS)
    private static var liveSeatbeltRequested: Bool {
        ProcessInfo.processInfo.environment["KIST_LIVE_SEATBELT"] == "1"
    }

    private static let probeLock = NSLock()
    private static var cachedSeatbeltCanApply: Bool?
    private static var cachedSeatbeltProbeReason = ""

    private struct SeatbeltProbeFailure: Error, CustomStringConvertible {
        let reason: String
        var description: String {
            "KIST_LIVE_SEATBELT=1 requested live Seatbelt checks, but sandbox-exec probe failed (\(reason)). Run this gate outside the harness."
        }
    }

    private func guardLiveSeatbeltRequested() -> Bool {
        // Default suite runs should not probe sandbox-exec from inside Codex's harness; nested
        // Seatbelt failures create false-positive verification noise. Use
        // `KIST_LIVE_SEATBELT=1 swift test --disable-sandbox --filter SeatbeltSandboxTests`
        // for the explicit kernel-sandbox gate.
        Self.liveSeatbeltRequested
    }

    private func requireSeatbeltCanApply() throws {
        guard Self.seatbeltCanApply() else {
            throw SeatbeltProbeFailure(reason: Self.seatbeltProbeReason())
        }
    }

    private static func seatbeltCanApply() -> Bool {
        probeLock.lock()
        defer { probeLock.unlock() }
        if let cached = cachedSeatbeltCanApply {
            return cached
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", "(version 1)\n(allow default)", "/usr/bin/true"]
        process.standardOutput = Pipe()
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            cachedSeatbeltCanApply = false
            cachedSeatbeltProbeReason = error.localizedDescription
            return false
        }

        let ok = process.terminationStatus == 0
        cachedSeatbeltCanApply = ok
        if !ok {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            cachedSeatbeltProbeReason = "status \(process.terminationStatus)" + (message.isEmpty ? "" : ": \(message)")
        } else {
            cachedSeatbeltProbeReason = ""
        }
        return ok
    }

    private static func seatbeltProbeReason() -> String {
        probeLock.lock()
        defer { probeLock.unlock() }
        return cachedSeatbeltProbeReason.isEmpty ? "unknown reason" : cachedSeatbeltProbeReason
    }
    #endif

    // MARK: - Profile generation + injection safety (cross-platform)

    func testProfileContainsExpectedRules() {
        let p = SeatbeltSandbox.seatbeltProfile(root: "/private/var/x", policy: .confined())
        XCTAssertTrue(p.contains("(deny network*)"))
        XCTAssertTrue(p.contains("(deny file-write*)"))
        XCTAssertTrue(p.contains("(allow file-write* (subpath \"/private/var/x\"))"))
    }

    func testProfileRespectsRelaxedFlags() {
        let noNet = SeatbeltSandbox.seatbeltProfile(root: "/r", policy: .confined(denyNetwork: false))
        XCTAssertFalse(noNet.contains("(deny network*)"))
        let noWrite = SeatbeltSandbox.seatbeltProfile(root: "/r", policy: .confined(confineWrites: false))
        XCTAssertFalse(noWrite.contains("(deny file-write*)"))
    }

    func testQuoteEscapesInjectionChars() {
        // The whole anti-injection guarantee is in quote(): every " and \ is escaped, so a
        // malicious root cannot terminate the subpath string early. Pin it directly.
        XCTAssertEqual(SeatbeltSandbox.quote("/a/b"), "\"/a/b\"")
        XCTAssertEqual(SeatbeltSandbox.quote("a\"b"), "\"a\\\"b\"")     // " → \"
        XCTAssertEqual(SeatbeltSandbox.quote("a\\b"), "\"a\\\\b\"")     // \ → \\
        // A breakout payload: the closing quote is escaped, so it stays inside the literal.
        let q = SeatbeltSandbox.quote("x\")(allow network*)")
        XCTAssertTrue(q.hasPrefix("\"") && q.hasSuffix("\""))
        XCTAssertTrue(q.contains("\\\")(allow network*)"), "the injected quote must be escaped")
    }

    func testWrapPassthroughWhenDisabled() {
        let w = SeatbeltSandbox.wrap(launchPath: "/bin/echo", args: ["hi"], root: root, policy: .disabled)
        XCTAssertEqual(w, .passthrough)
    }

    func testWrapFailsClosedOnUncanonicalizableRoot() {
        // A non-existent root can't be canonicalized → wrap returns .unavailable, so
        // RunCommandTool refuses rather than running unsandboxed. (On Linux, wrap is always
        // .unavailable when enabled — same fail-closed contract.)
        let w = SeatbeltSandbox.wrap(launchPath: "/bin/echo", args: ["hi"],
                                     root: "/nonexistent-\(UUID().uuidString)", policy: .confined())
        guard case .unavailable = w else { return XCTFail("expected .unavailable, got \(w)") }
    }

    // MARK: - Live kernel confinement (macOS / Seatbelt)

    #if os(macOS)
    func testSandboxDeniesWriteOutsideRoot() async throws {
        guard guardLiveSeatbeltRequested() else { return }
        try requireSeatbeltCanApply()
        let external = try XCTUnwrap(external)
        let target = external + "/bad.txt"
        let r = await run("echo hi > '\(target)'", sandbox: .confined())
        XCTAssertFalse(FileManager.default.fileExists(atPath: target),
                       "kernel sandbox must block writes outside the root")
        XCTAssertFalse(r.success, "the denied write should make the command fail")
    }

    func testSandboxAllowsWriteInsideRoot() async throws {
        guard guardLiveSeatbeltRequested() else { return }
        try requireSeatbeltCanApply()
        let target = root! + "/ok.txt"
        let r = await run("echo hi > '\(target)'", sandbox: .confined())
        XCTAssertTrue(r.success, r.error ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target),
                      "writes inside the root must still be allowed")
    }

    func testInheritedFdDoesNotBypassSandbox() async throws {
        guard guardLiveSeatbeltRequested() else { return }
        try requireSeatbeltCanApply()
        let external = try XCTUnwrap(external)
        // Codex HIGH: Seatbelt's write-deny is checked at OPEN time, so a fd opened in the
        // parent BEFORE the sandbox would let a child write outside the root via `>&N` (no
        // re-open). The fd lockdown (CLOEXEC_DEFAULT) must close that inherited fd.
        let outside = external + "/pwned.txt"
        let fd = open(outside, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 3, "need a fd >= 3 for a meaningful test")
        defer { close(fd) }
        _ = await run("echo PWNED >&\(fd)", sandbox: .confined())
        let contents = (try? String(contentsOfFile: outside, encoding: .utf8)) ?? ""
        XCTAssertFalse(contents.contains("PWNED"),
                       "inherited fd \(fd) must be closed in the sandboxed child (got: \(contents))")
    }

    func testDisabledSandboxAllowsWriteOutsideRoot_control() async throws {
        guard guardLiveSeatbeltRequested() else { return }
        let external = try XCTUnwrap(external)
        // Control: without the sandbox, run_command does NOT confine raw shell writes, so the
        // outside write succeeds — proving the sandbox (not something else) is the gate above.
        let target = external + "/control.txt"
        _ = await run("echo hi > '\(target)'", sandbox: .disabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target),
                      "without the sandbox the outside write is NOT blocked (control)")
    }
    #endif
}
