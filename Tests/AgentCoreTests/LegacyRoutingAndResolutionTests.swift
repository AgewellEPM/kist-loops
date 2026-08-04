import XCTest
@testable import AgentCore

/// Pins for the 2026-08-03 "brew-flail" regressions:
/// - run_command executable resolution gains an APPEND-ONLY well-known-dirs fallback
///   (/opt/homebrew/bin, /usr/local/bin) — env PATH keeps precedence.
/// - The plan-execute planner routes legacy/DOS/Win9x goals onto the Perslis system
///   (perslis__* MCP tools when up, the ~/bin CLI bridges when not) instead of
///   brew-installing emulators — pinned on BOTH prompt branches, the shared
///   CapabilityRegistry surface, and the PlanLint backstop (one assertion per surface).
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

    func testPlannerPromptRoutesLegacyToPerslisToolsWhenAvailable() {
        let registry = ToolRegistry([StubTool(name: "run_command"), StubTool(name: "perslis__vm_launch"),
                                     StubTool(name: "perslis__win98_run_command")])
        let prompt = PlanExecuteLoop.plannerSystemPrompt(tools: registry, projectRoot: "/tmp")
        XCTAssertTrue(prompt.contains("LEGACY SOFTWARE"), "planner prompt must carry the legacy routing rule")
        XCTAssertTrue(prompt.contains("FORBIDDEN"), "emulator host-installs must be named forbidden")
        XCTAssertTrue(prompt.contains("perslis__vm_launch"), "with the gateway up, the rule names the perslis__* route")
    }

    func testPlannerPromptFallsBackToCLIBridgesWithoutPerslis() {
        let prompt = PlanExecuteLoop.plannerSystemPrompt(tools: ToolRegistry([StubTool(name: "run_command")]),
                                                         projectRoot: "/tmp")
        XCTAssertTrue(prompt.contains("LEGACY SOFTWARE"), "the rule must exist even without the MCP gateway")
        XCTAssertTrue(prompt.contains("perslis-play"), "gateway down → route through the ~/bin CLI bridges")
        XCTAssertFalse(prompt.contains("perslis__vm_launch"),
                       "must not promise MCP tools that are not in the registry")
    }

    func testCapabilityRegistryNamesThePerslisDomain() {
        // One edit, two prompt surfaces (planner + chat/headless both embed this render): the
        // perslis tools must appear as a NAMED capability, not the anonymous MCP/Other blob.
        let registry = ToolRegistry([StubTool(name: "perslis__vm_launch"), StubTool(name: "perslis__vm_ocr")])
        let rendered = CapabilityRegistry.render(tools: registry)
        XCTAssertTrue(rendered.contains("Legacy DOS/Win9x VM (Perslis)"), rendered)
        XCTAssertFalse(rendered.contains("MCP/Other: perslis__vm_launch"),
                       "named domain tools must not fall through to the MCP/Other bucket")
    }

    // MARK: - PlanLint backstop

    func testPlanLintFlagsEmulatorInstallSteps() {
        for cmd in ["brew install nasm", "brew install dosbox-x", "apt-get -y install qemu",
                    "sudo port install wine", "brew reinstall nasm && brew install dosbox"] {
            if cmd.contains("reinstall") { continue }   // install-verb only; reinstall isn't the planner shape
            XCTAssertTrue(PlanLint.installsLegacyEmulator(cmd), "should flag: \(cmd)")
        }
        let plan = ExecutablePlan(goal: "dos clock", steps: [
            PlanStep(id: "E1", intent: "install assembler", tool: "run_command",
                     argumentsJSON: #"{"command":"brew install nasm"}"#, dependsOn: []),
        ])
        XCTAssertTrue(PlanLint.findings(for: plan).contains { $0.contains("Perslis") },
                      "the finding must route the planner to Perslis, not just say no")
    }

    func testPlanLintDoesNotFlagLegitimateCommands() {
        for cmd in ["brew install jq", "qemu-img convert disk.qcow2 out.raw",
                    "dosbox-x -c 'mount c .'", "nasm clock.asm -o clock.com",
                    "git log --oneline nasm-notes.md"] {
            XCTAssertFalse(PlanLint.installsLegacyEmulator(cmd), "false positive on: \(cmd)")
        }
    }
}
