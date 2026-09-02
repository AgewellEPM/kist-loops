import XCTest
@testable import AgentCore

/// Pins for the 2026-08-03 "brew-flail" regressions:
/// - run_command executable resolution gains an APPEND-ONLY well-known-dirs fallback
///   (/opt/homebrew/bin, /usr/local/bin) — env PATH keeps precedence.
/// - The plan-execute planner routes registered legacy/DOS/Win9x VM lifecycle through
///   GhostBridge's catalog/session broker (the owner-safe `legacy open` CLI fallback when absent),
///   then uses Perslis only for guest operations after HOT. This is pinned on BOTH prompt branches,
///   the full tool contract, CapabilityRegistry, and the PlanLint backstop.
final class LegacyRoutingAndResolutionTests: XCTestCase {

    // MARK: - run_command resolution order

    private func makeTempBin(named name: String) throws -> (dir: String, path: String) {
        let dir = NSTemporaryDirectory() + "resolve_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/" + name
        try "#!/bin/sh\nexit 0\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (dir, path)
    }

    func testEnvPathBeatsWellKnownDirs() throws {
        // A fake `brew` on the env PATH must win over the real /opt/homebrew/bin/brew:
        // the fallback tier may never shadow what PATH explicitly provides.
        let fake = try makeTempBin(named: "brew")
        defer { try? FileManager.default.removeItem(atPath: fake.dir) }
        let resolved = RunCommandTool.resolveExecutable("brew", env: ["PATH": fake.dir + ":/usr/bin:/bin"])
        // Compare both sides through the same symlink canonicalization (/var vs /private/var).
        let canon = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        XCTAssertEqual(resolved.map(canon), canon(fake.path), "env PATH tier must have precedence over well-known dirs")
    }

    func testWellKnownDirsResolveWhenPathIsScrubbed() throws {
        // The exact 2026-08-03 failure: scrubbed PATH without Homebrew → brew must STILL resolve
        // via the well-known fallback tier.
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") else {
            throw XCTSkip("host has no /opt/homebrew/bin/brew — fallback tier not exercisable here")
        }
        let resolved = RunCommandTool.resolveExecutable("brew", env: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        XCTAssertEqual(resolved, "/opt/homebrew/bin/brew",
                       "a scrubbed PATH must no longer hide installed Homebrew tools")
    }

    func testUnknownExecutableStaysFailClosed() {
        XCTAssertNil(RunCommandTool.resolveExecutable("definitely-not-a-real-tool-xyz",
                                                      env: ["PATH": "/usr/bin:/bin"]),
                     "the fallback tier must not weaken fail-closed resolution")
    }

    func testFallbackDirListIsAppendOnlyAndCurated() {
        // The tier is a fixed, ordered, curated list — ~/bin is deliberately NOT here (the
        // launcher grants it via PATH; unattended runs don't get private bridges by default).
        XCTAssertEqual(RunCommandTool.wellKnownFallbackDirs, ["/opt/homebrew/bin", "/usr/local/bin"])
    }

    // MARK: - planner legacy routing (per-surface pins)

    private struct StubTool: AgentTool {
        let name: String
        var description: String { "stub" }
        var parameters: [ToolParameter] { [] }
        func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
            ToolResult(success: true, output: "ok")
        }
    }

    func testPlannerPromptRoutesRegisteredVMLifecycleThroughGhostBridge() {
        let registry = ToolRegistry([
            StubTool(name: "run_command"),
            StubTool(name: "ghostbridge-legacy__legacy_system_catalog"),
            StubTool(name: "ghostbridge-legacy__legacy_session_open"),
            StubTool(name: "perslis__vm_launch"),
            StubTool(name: "perslis__legacy_launch"),
            StubTool(name: "perslis__win98_run_command"),
        ])
        let prompt = PlanExecuteLoop.plannerSystemPrompt(tools: registry, projectRoot: "/tmp")
        XCTAssertTrue(prompt.contains("LEGACY SOFTWARE"), "planner prompt must carry the legacy routing rule")
        XCTAssertTrue(prompt.contains("FORBIDDEN"), "emulator host-installs must be named forbidden")
        XCTAssertTrue(prompt.contains("ghostbridge-legacy__legacy_system_catalog") &&
                      prompt.contains("ghostbridge-legacy__legacy_session_open"),
                      "registered VM lifecycle must use the GhostBridge broker")
        XCTAssertTrue(prompt.contains("NEVER call perslis__vm_launch or perslis__legacy_launch directly"),
                      "raw Perslis launch tools must be an explicit non-route")
        XCTAssertTrue(prompt.contains("untrusted data"),
                      "trust is scoped to INVOCATION only — VM outputs (downloaded era software) stay data, never instructions")
    }

    // 2026-08-04 dogfood: "assemble hello.com with nasm" was routed to the win98 VM and face-planted
    // on VM contract bugs. Building/assembling legacy code is a NATIVE task — the VM is only for
    // RUNNING actual legacy-OS software.
    func testPlannerPromptIsNativeFirstForBuildAssemble() {
        let prompt = PlanExecuteLoop.plannerSystemPrompt(
            tools: ToolRegistry([StubTool(name: "run_command"),
                                 StubTool(name: "ghostbridge-legacy__legacy_system_catalog"),
                                 StubTool(name: "ghostbridge-legacy__legacy_session_open")]),
            projectRoot: "/tmp")
        XCTAssertTrue(prompt.contains("NATIVE-FIRST"), "the legacy rule must be native-first")
        XCTAssertTrue(prompt.contains("nasm -f bin"), "assembling a .COM is a native run_command, not a VM step")
        XCTAssertTrue(prompt.contains("NO VM for a build"), "a build must not be routed into the VM")
    }

    // The planner must never guess an image or QMP socket. The broker resolves those from the registered
    // target and admits the launch through the authenticated one-VM lease.
    func testPlannerPromptTeachesGhostBridgeCallingConvention() {
        let prompt = PlanExecuteLoop.plannerSystemPrompt(
            tools: ToolRegistry([StubTool(name: "run_command"),
                                 StubTool(name: "ghostbridge-legacy__legacy_system_catalog"),
                                 StubTool(name: "ghostbridge-legacy__legacy_session_open"),
                                 StubTool(name: "perslis__win98_run_command")]),
            projectRoot: "/tmp")
        XCTAssertTrue(prompt.contains("follow its launchDirection"),
                      "the catalog's authoritative launch direction must drive session opening")
        for argument in ["targetId", "mode", "idempotencyKey", "purpose"] {
            XCTAssertTrue(prompt.contains(argument), "session_open must teach required broker argument \(argument)")
        }
        XCTAssertTrue(prompt.contains("Never provide a qcow2 image or QMP socket"),
                      "the model must not invent broker-owned disk/QMP inputs")
        XCTAssertTrue(prompt.contains("AFTER legacy_session_open reports the session HOT") &&
                      prompt.contains("win98_run_command") && prompt.contains("over blind vm_key"),
                      "prefer high-level guest commands over fragile keystroke driving")
    }

    func testGoldenImageDiscoveryPrefersReadyThenNewest() throws {
        let root = NSTemporaryDirectory() + "golden_\(UUID().uuidString)"
        let dir = root + "/.kist/vm/golden"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        for name in ["win98-v1.qcow2", "win98-v2.ready.qcow2", "win98-v3.qcow2"] {
            try Data().write(to: URL(fileURLWithPath: dir + "/" + name))
        }
        // Isolate HOME so discovery reads our fixture, not the real machine.
        let saved = getenv("HOME").map { String(cString: $0) }
        setenv("HOME", root, 1); defer { if let saved { setenv("HOME", saved, 1) } }
        let picked = PlanExecuteLoop.newestGoldenImagePath(fileManager: fm)
        XCTAssertEqual(picked, dir + "/win98-v2.ready.qcow2", "a validated .ready image wins over newer non-ready ones")
    }

    func testPlannerPromptFallsBackToCLIBridgesWithoutPerslis() {
        let prompt = PlanExecuteLoop.plannerSystemPrompt(tools: ToolRegistry([StubTool(name: "run_command")]),
                                                         projectRoot: "/tmp")
        XCTAssertTrue(prompt.contains("LEGACY SOFTWARE"), "the rule must exist even without the MCP gateway")
        XCTAssertTrue(prompt.contains("legacy open <registered-system>"),
                      "gateway down → use the owner-safe CLI that acquires the GhostBridge lease")
        XCTAssertTrue(prompt.contains("perslis-play"), "gateway down → route through the ~/bin CLI bridges")
        XCTAssertFalse(prompt.contains("perslis__vm_launch"),
                       "must not promise MCP tools that are not in the registry")
    }

    func testCapabilityRegistryPrioritizesGhostBridgeAndDeprioritizesRawPerslisLaunch() {
        let registry = ToolRegistry([
            StubTool(name: "ghostbridge-legacy__legacy_system_catalog"),
            StubTool(name: "ghostbridge-legacy__legacy_session_open"),
            StubTool(name: "perslis__vm_launch"),
            StubTool(name: "perslis__legacy_launch"),
            StubTool(name: "perslis__vm_ocr"),
        ])
        let rendered = CapabilityRegistry.render(tools: registry)
        let lifecycleLine = rendered.split(separator: "\n").first {
            $0.contains("Registered Legacy VM Lifecycle (GhostBridge)")
        }.map(String.init) ?? ""
        XCTAssertTrue(lifecycleLine.contains("ghostbridge-legacy__legacy_system_catalog") &&
                      lifecycleLine.contains("ghostbridge-legacy__legacy_session_open"), rendered)
        XCTAssertFalse(lifecycleLine.contains("perslis__vm_launch") || lifecycleLine.contains("perslis__legacy_launch"),
                       "raw Perslis launches cannot appear in the recommended lifecycle route")
        XCTAssertTrue(rendered.contains("Direct Perslis registered-VM launch (broker-internal; DO NOT call)"), rendered)
        XCTAssertTrue(rendered.contains("Legacy Guest Operations (Perslis): perslis__vm_ocr"), rendered)
        XCTAssertFalse(rendered.contains("MCP/Other: perslis__vm_launch") ||
                       rendered.contains("MCP/Other: perslis__legacy_launch"),
                       "broker-internal launch tools must not fall through as usable MCP/Other tools")
    }

    func testFullToolContractMarksRawPerslisLaunchUnavailableWhenBrokerIsPresent() {
        let registry = ToolRegistry([
            StubTool(name: "ghostbridge-legacy__legacy_system_catalog"),
            StubTool(name: "ghostbridge-legacy__legacy_session_open"),
            StubTool(name: "perslis__vm_launch"),
            StubTool(name: "perslis__legacy_launch"),
        ])
        let rendered = ToolContractBook.render(tools: registry)
        for rawTool in ["perslis__vm_launch", "perslis__legacy_launch"] {
            XCTAssertTrue(rendered.contains("## \(rawTool)  ⚠ UNAVAILABLE this session"), rendered)
        }
        XCTAssertTrue(rendered.contains("first call ghostbridge-legacy__legacy_system_catalog") &&
                      rendered.contains("then call ghostbridge-legacy__legacy_session_open") &&
                      rendered.contains("Do NOT call it"), rendered)
    }

    // MARK: - PlanLint backstop

    func testPlanLintFlagsEmulatorInstallSteps() {
        for cmd in ["brew install nasm", "brew install dosbox-x", "apt-get -y install qemu",
                    "sudo port install wine", "brew reinstall nasm", "brew upgrade dosbox-x"] {
            XCTAssertTrue(PlanLint.installsLegacyEmulator(cmd), "should flag: \(cmd)")
        }
        let plan = ExecutablePlan(goal: "dos clock", steps: [
            PlanStep(id: "E1", intent: "install assembler", tool: "run_command",
                     argumentsJSON: #"{"command":"brew install nasm"}"#, dependsOn: []),
        ])
        let finding = PlanLint.findings(for: plan).first { $0.contains("legacy emulator/toolchain") } ?? ""
        XCTAssertTrue(finding.contains("ghostbridge-legacy__legacy_system_catalog") &&
                      finding.contains("ghostbridge-legacy__legacy_session_open"),
                      "the lint must route lifecycle through GhostBridge, not merely reject the install")
        XCTAssertFalse(finding.contains("perslis__vm_launch"),
                       "the lint must not recommend the raw Perslis launch route")
    }

    func testPlanLintDoesNotFlagLegitimateCommands() {
        for cmd in ["brew install jq", "qemu-img convert disk.qcow2 out.raw",
                    "dosbox-x -c 'mount c .'", "nasm clock.asm -o clock.com",
                    "git log --oneline nasm-notes.md",
                    // An ALLOWED two-command chain: the install verb and the emulator token live in
                    // DIFFERENT segments — the match may not span `;`/`&&`.
                    "brew install jq && nasm clock.asm -o clock.com",
                    "brew install jq; dosbox-x -c 'mount c .'"] {
            XCTAssertFalse(PlanLint.installsLegacyEmulator(cmd), "false positive on: \(cmd)")
        }
    }
}
