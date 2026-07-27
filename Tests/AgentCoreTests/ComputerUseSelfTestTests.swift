import XCTest
@testable import AgentCore

final class ComputerUseSelfTestTests: XCTestCase {

    private func step(_ name: String, _ passed: Bool, _ detail: String = "") -> ComputerUseSelfTest.Step {
        { ComputerUseSelfTest.StepResult(name: name, passed: passed, detail: detail) }
    }

    func testAllPassAggregatesTrue() async {
        let (results, all) = await ComputerUseSelfTest.run([step("capture", true), step("input", true)])
        XCTAssertTrue(all)
        XCTAssertEqual(results.count, 2)
    }

    func testAnyFailAggregatesFalse() async {
        let (_, all) = await ComputerUseSelfTest.run([step("capture", true), step("input", false, "no move")])
        XCTAssertFalse(all)
    }

    func testReportMarksEachStep() {
        let results = [
            ComputerUseSelfTest.StepResult(name: "capture", passed: true, detail: "1920x1080"),
            ComputerUseSelfTest.StepResult(name: "input", passed: false, detail: "cursor did not move"),
        ]
        let r = ComputerUseSelfTest.report(results, allPassed: false)
        XCTAssertTrue(r.contains("FAILED"))
        XCTAssertTrue(r.contains("✓ capture"))
        XCTAssertTrue(r.contains("✗ input"))
        XCTAssertTrue(r.contains("cursor did not move"))
    }

    func testReportHeaderOnAllPassed() {
        let r = ComputerUseSelfTest.report([ComputerUseSelfTest.StepResult(name: "x", passed: true, detail: "ok")], allPassed: true)
        XCTAssertTrue(r.contains("PASSED"))
    }

    func testStepsRunInOrder() async {
        let order = Order()
        let (_, _) = await ComputerUseSelfTest.run([
            { order.add("a"); return .init(name: "a", passed: true, detail: "") },
            { order.add("b"); return .init(name: "b", passed: true, detail: "") },
        ])
        XCTAssertEqual(order.value, ["a", "b"])
    }

    func testToolReportsMetadata() async throws {
        let tool = ComputerUseSelfTestTool(steps: [step("capture", true, "ok"), step("input", false, "no move")])
        let r = try await tool.execute(arguments: [:], context: ToolContext(projectRoot: NSTemporaryDirectory()))
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["all_passed"], "false")
        XCTAssertEqual(r.metadata["steps"], "2")
        XCTAssertEqual(r.metadata["failed"], "1")
        XCTAssertTrue(r.output.contains("FAILED"))
    }

    func testWithTimeoutReturnsCompletedOperation() async throws {
        let value = try await ComputerUseSelfTestTool.withTimeout(seconds: 1) { "ok" }
        XCTAssertEqual(value, "ok")
    }

    func testWithTimeoutThrowsTimeout() async {
        do {
            _ = try await ComputerUseSelfTestTool.withTimeout(seconds: 0.01) {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return "late"
            }
            XCTFail("expected timeout")
        } catch is SelfTestTimeout {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private final class Order: @unchecked Sendable {
    private var items: [String] = []; private let lock = NSLock()
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var value: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
