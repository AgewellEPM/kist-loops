import XCTest
@testable import AgentCore

final class BuilderToolchainEnvironmentTests: XCTestCase {
    func testTrustedCompilerAliasDoesNotBypassActualOrRequestedDenials() async {
        let allowed = ShellPolicy(enabled: true, autoApprove: true, allow: ["python3"], deny: [])
        let normal = await allowed.binaryRefusalReason(resolvedPath: "/installed/python3.9", args: ["check.py"])
        XCTAssertNotNil(normal)
        let bound = await allowed.binaryRefusalReason(resolvedPath: "/installed/python3.9", args: ["check.py"], trustedToolchainAlias: "python3")
        XCTAssertNil(bound)
        for deny in [["python3.9"], ["python3 check.py"]] {
            let policy = ShellPolicy(enabled: true, autoApprove: true, allow: ["python3"], deny: deny)
            let result = await policy.binaryRefusalReason(resolvedPath: "/installed/python3.9", args: ["check.py"], trustedToolchainAlias: "python3")
            XCTAssertNotNil(result)
        }
    }

    func testConfiguredCompilerRootIsSpecificAndForbiddenRootsStayForbidden() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toolchains-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let compiler = root.appendingPathComponent("typescript")
        try FileManager.default.createDirectory(at: compiler.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: compiler.appendingPathComponent("lib"), withIntermediateDirectories: true)
        let executable = compiler.appendingPathComponent("bin/tsc")
        try Data("#!/usr/bin/env node\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("// fixture compiler".utf8).write(to: compiler.appendingPathComponent("lib/typescript.js"))
        let configuration = String(decoding: try JSONEncoder().encode([compiler.path]), as: UTF8.self)
        let environment = try BuilderToolchainEnvironment.discover(
            parent: ["PATH": "/attacker", "SECRET": "must-not-leak", "KIST_BUILDER_TOOLCHAIN_ROOTS": configuration],
            home: root.path)
        let canonical = try XCTUnwrap(ToolContext.canonicalize(compiler.path))
        XCTAssertTrue(environment.readOnlyRoots.contains(canonical))
        XCTAssertFalse(environment.readOnlyRoots.contains(ToolContext.canonicalize(root.path)!))
        XCTAssertTrue(environment.values["PATH"]!.contains(canonical + "/bin"))
        XCTAssertFalse(environment.values["PATH"]!.contains("/attacker"))
        XCTAssertNil(environment.values["SECRET"])
        XCTAssertNil(environment.values["HOME"])
        XCTAssertThrowsError(try BuilderToolchainEnvironment.discover(
            parent: ["KIST_BUILDER_TOOLCHAIN_ROOTS": configuration], home: root.path,
            forbiddenReadPaths: [compiler.path]))
        XCTAssertThrowsError(try BuilderToolchainEnvironment.discover(
            parent: ["KIST_BUILDER_TOOLCHAIN_ROOTS": "not JSON"], home: root.path))
    }
}
