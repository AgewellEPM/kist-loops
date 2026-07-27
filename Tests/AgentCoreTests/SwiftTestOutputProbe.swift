import XCTest
@testable import AgentCore

/// Definitive: a deliberately-broken swift package's `swift test` compile error MUST reach the tool
/// (through the scrubbed env + process-group teardown) — the exact dogfood scenario.
final class SwiftTestOutputProbe: XCTestCase {
    func testSwiftTestCompileErrorReachesTheTool() async throws {
        guard let swift = RunCommandTool.resolveExecutable("swift", env: RunCommandTool.scrubbedEnvironment()) else {
            throw XCTSkip("swift not on PATH")
        }
        let dir = NSTemporaryDirectory() + "calc-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/Sources/Calc", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dir + "/Tests/CalcTests", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name:\"Calc\", targets:[.target(name:\"Calc\"), .testTarget(name:\"CalcTests\", dependencies:[\"Calc\"])])".write(toFile: dir+"/Package.swift", atomically:true, encoding:.utf8)
        try "public func add(_ a: Int, _ b: Int) -> Int { a + b }".write(toFile: dir+"/Sources/Calc/Calc.swift", atomically:true, encoding:.utf8)
        try "import XCTest\n@testable import Calc\nfinal class CalcTests: XCTestCase { func testAdd() { XCTAssertEqual(add(2,3), 5) } }".write(toFile: dir+"/Tests/CalcTests/CalcTests.swift", atomically:true, encoding:.utf8)
        let r = await RunCommandTool.spawnAndCollect(launchPath: swift, launchArgs: ["test"], cwd: dir, timeout: 180)
        XCTAssertFalse(r.success, "the broken test must fail")
        XCTAssertTrue(r.output.contains("instance method") || r.output.contains("use of 'add'"),
                      "swift test's compile error MUST reach the tool now. Got: >>>\(r.output.prefix(400))<<<")
    }
}
