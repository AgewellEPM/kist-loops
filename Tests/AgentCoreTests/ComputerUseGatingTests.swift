import XCTest
@testable import AgentCore

/// Council-mandated (2026-07-03) desktop-control safety: the real input-injection tools must be classified
/// `.dangerous` — ALWAYS prompt, even past "allow all", and never auto-run on a `.mutating` pass (which is
/// what let them fire unattended in the one-shot path). This pins the classification so a refactor can't
/// silently drop them back to the default `.mutating`.
final class ComputerUseGatingTests: XCTestCase {
    func testInputInjectionToolsAreDangerous() {
        for tool in ["desktop_control", "ax_press", "tap", "point_click"] {
            XCTAssertEqual(ReversibilityClassifier.assess(tool: tool, args: [:], projectRoot: "/tmp"),
                           .dangerous, "\(tool) injects real mouse/keyboard input — must be .dangerous")
        }
    }

    func testShellHostControlBinariesAreDangerous() {
        // The shell route to UI automation / screen capture must be .dangerous so unattended (NonDestructive)
        // and interactive surfaces refuse it — the same capability --enable-computer-use gates for tools.
        for cmd in ["osascript -e 'tell application \"System Events\"'", "cliclick c:100,200",
                    "screencapture /tmp/x.png", "shortcuts run 'Do Thing'"] {
            XCTAssertEqual(ReversibilityClassifier.assess(tool: "run_command", args: ["command": cmd], projectRoot: "/tmp"),
                           .dangerous, "host-control shell must be .dangerous: \(cmd)")
        }
        // A normal build/test command is still recoverable → .mutating (no over-broadening).
        XCTAssertEqual(ReversibilityClassifier.assess(tool: "run_command", args: ["command": "swift build"], projectRoot: "/tmp"),
                       .mutating)
    }

    func testOrdinaryMutatingToolStaysMutating() {
        // Guard against over-broadening: a normal in-project edit is still recoverable → .mutating.
        XCTAssertEqual(ReversibilityClassifier.assess(tool: "make_dir", args: [:], projectRoot: "/tmp"),
                       .mutating)
    }

    /// Unarmed shell HARD-refuses host-control via the un-bypassable structured gate (binaryRefusalReason),
    /// independent of autoApprove — even the full path / `env` wrapper is caught. Armed ⇒ not deny-listed.
    func testShellHostControlHardDeniedWhenUnarmedButAllowedWhenArmed() async {
        // defaultDeny now INCLUDES hostControlDeny (deny-by-default at every site); this is what evolve/fleet
        // workers get automatically.
        let unarmed = ShellPolicy(enabled: true, autoApprove: true, deny: ShellPolicy.defaultDeny)
        for (path, args) in [("/usr/bin/osascript", ["-e", "tell app \"System Events\""]),
                             ("/usr/bin/env", ["osascript", "-e", "x"]),
                             ("/usr/sbin/screencapture", ["/tmp/x.png"]),
                             ("/opt/homebrew/bin/cliclick", ["c:10,10"])] {
            let reason = await unarmed.binaryRefusalReason(resolvedPath: path, args: args)
            XCTAssertNotNil(reason, "unarmed shell must HARD-refuse host-control: \(path) \(args)")
        }
        // Armed: the top-level path opts out to baseDeny (no host-control), so osascript passes the deny gate.
        let armed = ShellPolicy(enabled: true, autoApprove: true, deny: ShellPolicy.baseDeny)
        let ok = await armed.binaryRefusalReason(resolvedPath: "/usr/bin/osascript", args: ["-e", "x"])
        XCTAssertNil(ok, "armed shell does not deny-list host-control (subject to normal approval)")
        // A normal build command is never host-control-denied, armed or not.
        let build = await unarmed.binaryRefusalReason(resolvedPath: "/usr/bin/swift", args: ["build"])
        XCTAssertNil(build, "a normal build command is not host-control")
    }

    /// Multi-site invariant (Codex catch): a DEFAULT ShellPolicy — what evolve/fleet workers and every
    /// non-opt-out site construct — denies host-control. Only the top-level armed path opts out via baseDeny.
    func testDefaultShellPolicyDeniesHostControlEverywhere() async {
        let workerDefault = ShellPolicy(enabled: true, autoApprove: true)   // no explicit deny → defaultDeny
        let reason = await workerDefault.binaryRefusalReason(resolvedPath: "/usr/bin/osascript", args: ["-e", "x"])
        XCTAssertNotNil(reason, "an evolve/fleet worker's default shell must deny host-control")
        XCTAssertTrue(ShellPolicy.defaultDeny.contains("osascript"), "defaultDeny must include host-control")
        XCTAssertFalse(ShellPolicy.baseDeny.contains("osascript"), "baseDeny is the armed opt-out (no host-control)")
    }

    /// Host-control MCP tools (desktop actuation / screen capture verbs) are detected for arming-gating;
    /// non-desktop MCP servers (github, db, filesystem) are NOT flagged, so they keep working unarmed.
    func testHostControlMCPDetection() {
        for hc in ["desktopmcp__click", "ui__doubleClick", "screen__screenshot", "robot__keyPress", "auto__type_text"] {
            XCTAssertTrue(ReversibilityClassifier.isHostControlMCPTool(hc), "\(hc) should be flagged host-control")
        }
        for ok in ["github__create_issue", "postgres__query", "fs__write_file", "notion__get_page"] {
            XCTAssertFalse(ReversibilityClassifier.isHostControlMCPTool(ok), "\(ok) is not host-control")
        }
        XCTAssertFalse(ReversibilityClassifier.isHostControlMCPTool("run_command"), "a non-MCP tool is never MCP-host-control")
    }
}
