import XCTest
@testable import Kist

/// Custom slash-command loading + `$ARGUMENTS` expansion (project overrides user).
final class KistCommandsTests: XCTestCase {

    func testExpandReplacesArguments() {
        let c = KistCommands(templates: ["review": "Review the file $ARGUMENTS for bugs."])
        XCTAssertEqual(c.expand("review", args: "auth.swift"), "Review the file auth.swift for bugs.")
    }

    func testExpandUnknownCommandReturnsNil() {
        let c = KistCommands(templates: [:])
        XCTAssertNil(c.expand("nope", args: ""))
    }

    func testExpandTrimsWhitespace() {
        let c = KistCommands(templates: ["t": "\n  hello $ARGUMENTS  \n"])
        XCTAssertEqual(c.expand("t", args: "world"), "hello world")
    }

    func testNamesSorted() {
        let c = KistCommands(templates: ["zed": "z", "alpha": "a", "mid": "m"])
        XCTAssertEqual(c.names, ["alpha", "mid", "zed"])
    }

    func testLoadFromProjectDirectory() throws {
        let proj = NSTemporaryDirectory() + "kc-\(UUID().uuidString)"
        let dir = proj + "/.kist/commands"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: proj) }
        try "Summarize $ARGUMENTS".write(toFile: dir + "/summarize.md", atomically: true, encoding: .utf8)

        let c = KistCommands.load(projectRoot: proj)
        XCTAssertTrue(c.names.contains("summarize"))
        XCTAssertEqual(c.expand("summarize", args: "README"), "Summarize README")
    }

    func testProjectOverridesUserDefinition() throws {
        // Point XDG_CONFIG_HOME at a temp "user" dir, then a project dir with the SAME command name.
        let userCfg = NSTemporaryDirectory() + "kc-user-\(UUID().uuidString)"
        let proj = NSTemporaryDirectory() + "kc-proj-\(UUID().uuidString)"
        let userDir = userCfg + "/kist/commands"
        let projDir = proj + "/.kist/commands"
        try FileManager.default.createDirectory(atPath: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: projDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: userCfg); try? FileManager.default.removeItem(atPath: proj) }
        try "USER version".write(toFile: userDir + "/x.md", atomically: true, encoding: .utf8)
        try "PROJECT version".write(toFile: projDir + "/x.md", atomically: true, encoding: .utf8)

        setenv("XDG_CONFIG_HOME", userCfg, 1)
        defer { unsetenv("XDG_CONFIG_HOME") }
        let c = KistCommands.load(projectRoot: proj)
        XCTAssertEqual(c.expand("x", args: ""), "PROJECT version")   // project wins
    }
}
