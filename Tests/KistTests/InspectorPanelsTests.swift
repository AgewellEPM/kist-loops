import XCTest
@testable import AgentCore
@testable import Kist

/// Pins the read-only inspector panels: /skills, /mcp, /hooks, /permissions rendering.
final class InspectorPanelsTests: XCTestCase {

    func testSkillsListsNamesTokensAndDescription() {
        let skills = [Skill(name: "git-hygiene", description: "branch before editing", instructions: String(repeating: "x", count: 400))]
        let out = InspectorPanels.skills(skills, theme: .mono)
        XCTAssertTrue(out.contains("git-hygiene"))
        XCTAssertTrue(out.contains("branch before editing"))
        XCTAssertTrue(out.contains("~100 tok"), "token estimate ~ chars/4")
    }

    func testSkillsEmpty() {
        XCTAssertTrue(InspectorPanels.skills([], theme: .mono).contains("none"))
    }

    func testMcpListsServersAndIssues() {
        let servers = [MCPServerConfig(name: "github", command: "/usr/bin/node", args: ["srv.js"], env: [:])]
        let issues = [MCPConfigIssue(server: "bad", reason: "relative command")]
        let out = InspectorPanels.mcp(servers: servers, issues: issues, theme: .mono)
        XCTAssertTrue(out.contains("github"))
        XCTAssertTrue(out.contains("/usr/bin/node srv.js"))
        XCTAssertTrue(out.contains("1 rejected"))
        XCTAssertTrue(out.contains("bad") && out.contains("relative command"))
    }

    func testHooksListsEventMatcherCommand() {
        let specs = [HookSpec(event: .preToolUse, matcher: "Bash", command: "echo before")]
        let out = InspectorPanels.hooks(specs, theme: .mono)
        XCTAssertTrue(out.contains("PreToolUse"))
        XCTAssertTrue(out.contains("[Bash]"))
        XCTAssertTrue(out.contains("echo before"))
    }

    func testHooksEmpty() {
        XCTAssertTrue(InspectorPanels.hooks([], theme: .mono).contains("none"))
    }

    func testPermissionsShowsTierAndApprovalSet() {
        let sensitive: Set<String> = ["run_command", "write_file"]
        let normal = InspectorPanels.permissions(mode: .normal, sensitive: sensitive, editTools: ["write_file"], theme: .mono)
        XCTAssertTrue(normal.contains("normal"))
        XCTAssertTrue(normal.contains("run_command") && normal.contains("write_file"), "normal prompts for all sensitive")

        let bypass = InspectorPanels.permissions(mode: .bypass, sensitive: sensitive, editTools: ["write_file"], theme: .mono)
        XCTAssertTrue(bypass.contains("GUARDS OFF"))
        XCTAssertTrue(bypass.contains("nothing"), "bypass approval set is empty")
    }

    func testPanelsHonorMonoNoAnsi() {
        // a11y: every inspector under mono must be escape-free (screen-reader safe).
        let skills = InspectorPanels.skills([Skill(name: "a", description: "b", instructions: "c")], theme: .mono)
        let perms = InspectorPanels.permissions(mode: .acceptEdits, sensitive: ["run_command"], editTools: [], theme: .mono)
        XCTAssertFalse(skills.contains("\u{001B}"))
        XCTAssertFalse(perms.contains("\u{001B}"))
        // non-mono actually colors
        XCTAssertTrue(InspectorPanels.skills([], theme: .standard).contains("\u{001B}["))
    }
}
