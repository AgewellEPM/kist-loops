import XCTest
@testable import AgentCore

final class SpanExporterTests: XCTestCase {

    /// Controllable clock so span timing is exact, not wall-clock-flaky.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: TimeInterval
        init(_ start: TimeInterval) { t = start }
        func advance(_ dt: TimeInterval) { lock.lock(); t += dt; lock.unlock() }
        var now: @Sendable () -> Date { { [self] in lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: t) } }
    }

    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock(); private var _lines: [String] = []
        func add(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    }

    func testActionPairBecomesASpanWithMeasuredDuration() {
        let clock = Clock(100)
        let out = LineCollector()
        let exp = SpanExporter(traceId: "trc", now: clock.now) { out.add($0) }

        exp.emit(.actionStarted(index: 0, tool: "read_file", description: "read x"))
        clock.advance(0.25)
        exp.emit(.actionFinished(index: 0, success: true, output: "ok", error: nil))

        XCTAssertEqual(exp.spans.count, 1)
        let s = exp.spans[0]
        XCTAssertEqual(s.name, "tool.read_file")
        XCTAssertEqual(s.attributes["tool"], "read_file")
        XCTAssertEqual(s.attributes["success"], "true")
        XCTAssertEqual(s.status, "ok")
        XCTAssertEqual(s.durationMs, 250, accuracy: 1e-6)
        XCTAssertEqual(s.traceId, "trc")
        XCTAssertEqual(out.lines.count, 1, "each span is written as one JSONL line")
    }

    func testFailedActionRecordsErrorStatusAndAttribute() {
        let exp = SpanExporter(traceId: "t") { _ in }
        exp.emit(.actionStarted(index: 1, tool: "run_command", description: "swift build"))
        exp.emit(.actionFinished(index: 1, success: false, output: "", error: "compile error: X"))
        let s = exp.spans[0]
        XCTAssertEqual(s.status, "error")
        XCTAssertEqual(s.attributes["error"], "compile error: X")
        XCTAssertEqual(s.attributes["success"], "false")
    }

    func testFinishWithoutStartIsIgnored() {
        let exp = SpanExporter { _ in }
        exp.emit(.actionFinished(index: 9, success: true, output: "", error: nil))
        XCTAssertTrue(exp.spans.isEmpty, "an unmatched finish must not fabricate a span")
    }

    func testRunLifecycleEmitsARootSpan() {
        let clock = Clock(0)
        let exp = SpanExporter(traceId: "run", now: clock.now) { _ in }
        clock.advance(2.0)
        exp.emit(.completed(summary: "done"))
        let root = exp.spans.first { $0.name == "agent.run" }
        XCTAssertNotNil(root)
        XCTAssertEqual(root?.kind, "server")
        XCTAssertEqual(root?.status, "ok")
        XCTAssertEqual(root?.durationMs ?? 0, 2000, accuracy: 1e-6)
    }

    func testCancelledRunHasADistinctStatusNotError() {
        let exp = SpanExporter(traceId: "c") { _ in }
        exp.emit(.cancelled)
        let root = try? XCTUnwrap(exp.spans.first { $0.name == "agent.run" })
        XCTAssertEqual(root?.status, "cancelled", "cancellation must not read as error (would page on-call)")
        XCTAssertEqual(root?.attributes["cancelled"], "true")
    }

    func testEmittedLineIsValidOTelShapedJSON() throws {
        let out = LineCollector()
        let exp = SpanExporter(traceId: "t") { out.add($0) }
        exp.emit(.actionStarted(index: 0, tool: "search_code", description: "find"))
        exp.emit(.actionFinished(index: 0, success: true, output: "", error: nil))
        let line = try XCTUnwrap(out.lines.first)
        let decoded = try JSONDecoder().decode(SpanExporter.Span.self, from: Data(line.utf8))
        XCTAssertEqual(decoded.name, "tool.search_code")
        XCTAssertGreaterThan(decoded.startTimeUnixNano, 0)
        XCTAssertGreaterThanOrEqual(decoded.endTimeUnixNano, decoded.startTimeUnixNano)
    }

    func testMultiEventSinkFansOutToEverySink() {
        let a = RecordingEventSink(), b = RecordingEventSink()
        let multi = MultiEventSink([a, b])
        multi.emit(.completed(summary: "x"))
        XCTAssertEqual(a.events.count, 1)
        XCTAssertEqual(b.events.count, 1)
    }

    func testFromEnvironmentIsNilWithoutTheVarAndWritesAFileWithIt() throws {
        XCTAssertNil(SpanExporter.fromEnvironment([:]), "no KIST_TRACE_SPANS → no exporter (zero overhead)")

        let path = NSTemporaryDirectory() + "kist-spans-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let exp = try XCTUnwrap(SpanExporter.fromEnvironment(["KIST_TRACE_SPANS": path]))
        exp.emit(.actionStarted(index: 0, tool: "read_file", description: "x"))
        exp.emit(.actionFinished(index: 0, success: true, output: "", error: nil))
        exp.close()   // flush + release the fd (no leak, no unflushed tail)

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.contains("tool.read_file"), "span must be flushed to the file on close")
        let decoded = try JSONDecoder().decode(SpanExporter.Span.self,
                                               from: Data(contents.split(separator: "\n").first!.utf8))
        XCTAssertEqual(decoded.attributes["tool"], "read_file")
    }
}
