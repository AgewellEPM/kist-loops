import XCTest
@testable import AgentCore

final class CustomToolTests: XCTestCase {
    private func makeRoot() throws -> String {
        let raw = NSTemporaryDirectory() + "custom-tool-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return ToolContext.canonicalize(raw)!
    }

    private func context(root: String, shell: ShellPolicy = .denied,
                         sandbox: SandboxPolicy = .disabled) -> ToolContext {
        ToolContext(projectRoot: root, shell: shell, sandbox: sandbox)
    }

    func testHeadlessRegistryIncludesCustomTool() {
        XCTAssertTrue(ToolRegistry.headless().names.contains("custom_tool"))
    }

    func testCreateAndListCustomTool() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let registry = ToolRegistry([CustomTool()])

        let created = await registry.execute(name: "custom_tool", arguments: [
            "action": "create",
            "name": "csv_stats",
            "description": "summarize a csv file",
            "code": "print('ready')\n",
        ], context: context(root: root))

        XCTAssertTrue(created.success, created.error ?? created.output)
        XCTAssertEqual(created.metadata["code_sha256"]?.count, 64)
        XCTAssertEqual(created.metadata["code_bytes"], "15")
        XCTAssertTrue(created.output.contains("sha256"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/generated-tools/csv_stats/tool.py"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/generated-tools/csv_stats/manifest.json"))
        let manifest = try String(contentsOfFile: root + "/.kist/generated-tools/csv_stats/manifest.json")
        XCTAssertTrue(manifest.contains("codeSHA256"))
        XCTAssertTrue(manifest.contains("codeBytes"))

        let listed = await registry.execute(name: "custom_tool", arguments: ["action": "list"],
                                            context: context(root: root))
        XCTAssertTrue(listed.success, listed.error ?? listed.output)
        XCTAssertTrue(listed.output.contains("csv_stats"))
        XCTAssertTrue(listed.output.contains("summarize a csv file"))
        XCTAssertTrue(listed.output.contains("sha256"))
    }

    func testRejectsOversizedCustomToolSource() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let huge = String(repeating: "x", count: CustomTool.maxCodeBytes + 1)

        let result = await ToolRegistry([CustomTool()]).execute(name: "custom_tool", arguments: [
            "action": "create",
            "name": "too_big",
            "code": huge,
        ], context: context(root: root))

        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("max is \(CustomTool.maxCodeBytes)"), result.error ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.kist/generated-tools/too_big/tool.py"))
    }

    func testRejectsUnsafeToolName() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let result = await ToolRegistry([CustomTool()]).execute(name: "custom_tool", arguments: [
            "action": "create",
            "name": "../escape",
            "code": "print('no')\n",
        ], context: context(root: root))

        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("letters, numbers"), result.error ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/escape"))
    }

    func testRunUsesRequiredOSSandboxEvenWhenContextSandboxDisabled() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        guard SandboxedProcessRunner.canApplyRequiredSandbox(root: root) else {
            throw XCTSkip("required OS sandbox unavailable in this test environment")
        }
        let registry = ToolRegistry([CustomTool()])

        _ = await registry.execute(name: "custom_tool", arguments: [
            "action": "create",
            "name": "hello",
            "code": "print('hello')\n",
        ], context: context(root: root))

        let run = await registry.execute(name: "custom_tool", arguments: [
            "action": "run",
            "name": "hello",
        ], context: context(root: root))

        XCTAssertTrue(run.success, run.error ?? run.output)
        XCTAssertTrue(run.output.contains("hello"), run.output)
        XCTAssertEqual(run.metadata["sandboxed"], "true")
        XCTAssertEqual(run.metadata["sandbox"], "macOS Seatbelt")
    }

    func testRunCustomToolCannotWriteOutsideRootWithoutOuterSandboxFlag() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        guard SandboxedProcessRunner.canApplyRequiredSandbox(root: root) else {
            throw XCTSkip("required OS sandbox unavailable in this test environment")
        }
        let externalRoot = NSHomeDirectory() + "/.custom-tool-escape-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: externalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: externalRoot) }
        let externalTarget = externalRoot + "/escaped.txt"
        let registry = ToolRegistry([CustomTool()])

        let created = await registry.execute(name: "custom_tool", arguments: [
            "action": "create",
            "name": "escape_check",
            "code": """
            import pathlib
            target = pathlib.Path('\(externalTarget)')
            try:
                target.write_text('escaped')
                print('escaped')
                raise SystemExit(42)
            except OSError:
                print('sandbox-blocked')
            """,
        ], context: context(root: root))
        XCTAssertTrue(created.success, created.error ?? created.output)

        let run = await registry.execute(name: "custom_tool", arguments: [
            "action": "run",
            "name": "escape_check",
        ], context: context(root: root))

        XCTAssertTrue(run.success, run.error ?? run.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalTarget))
        XCTAssertTrue(run.output.contains("sandbox-blocked"), run.output)
        XCTAssertEqual(run.metadata["sandboxed"], "true")
    }

    #if os(macOS)
    func testRunCustomToolInsideSandbox() async throws {
        guard guardLiveSeatbeltRequested() else { return }
        try requireSeatbeltCanApply()
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let registry = ToolRegistry([CustomTool()])
        let autoContext = context(root: root,
                                  shell: ShellPolicy(enabled: true, autoApprove: true),
                                  sandbox: .confined())

        let created = await registry.execute(name: "custom_tool", arguments: [
            "action": "create",
            "name": "upper",
            "description": "uppercase argv",
            "code": "import sys\nprint(sys.argv[1].upper())\n",
        ], context: autoContext)
        XCTAssertTrue(created.success, created.error ?? created.output)

        let run = await registry.execute(name: "custom_tool", arguments: [
            "action": "run",
            "name": "upper",
            "args": ["mythos"],
        ], context: autoContext)

        XCTAssertTrue(run.success, run.error ?? run.output)
        XCTAssertTrue(run.output.contains("MYTHOS"))
    }
    #endif

    func testContractAdvertisesToolForgeWithoutFakeActions() {
        let contract = ToolContractBook.render(tools: ToolRegistry([CustomTool()]))

        XCTAssertTrue(contract.contains("Tool Forge"))
        XCTAssertTrue(contract.contains("custom_tool"))
        XCTAssertTrue(contract.contains("create"))
        XCTAssertTrue(contract.contains("list"))
        XCTAssertTrue(contract.contains("run"))
        XCTAssertTrue(contract.contains("run_unsandboxed"))
        XCTAssertTrue(contract.contains("pip_install_global"))
    }

    func testScopeGateAllowsListButBlocksCreateInPlanOnlyScope() async {
        let decision = AuthorizationScopeEngine.evaluate("diagnose why my server has high latency")
        XCTAssertEqual(decision.gate, .planOnly)
        let registry = ToolRegistry([CustomTool()])
        let context = ToolContext(projectRoot: NSTemporaryDirectory(), authorizationScope: decision)

        let list = await registry.execute(name: "custom_tool", arguments: ["action": "list"], context: context)
        XCTAssertTrue(list.success, list.error ?? "")

        let create = await registry.execute(name: "custom_tool", arguments: [
            "action": "create",
            "name": "diag",
            "code": "print('x')",
        ], context: context)
        XCTAssertFalse(create.success)
        XCTAssertTrue((create.error ?? "").contains("plan-only scope"), create.error ?? "")
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
            "KIST_LIVE_SEATBELT=1 requested live custom_tool sandbox checks, but sandbox-exec probe failed (\(reason)). Run this gate outside the harness."
        }
    }

    private func guardLiveSeatbeltRequested() -> Bool {
        // The default suite must not attempt nested sandbox-exec inside the Codex harness. The
        // explicit live gate is:
        // KIST_LIVE_SEATBELT=1 swift test --disable-sandbox --filter "SeatbeltSandboxTests|CustomToolTests"
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
}
