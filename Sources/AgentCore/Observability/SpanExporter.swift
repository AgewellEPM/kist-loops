import Foundation

/// OTel-style trace export off the agent's runtime event stream.
///
/// kist already records a rich internal trajectory (`ActionRecord`) and emits lifecycle `RuntimeEvent`s,
/// but nothing left the process in a shape an observability backend could ingest. This sink closes that:
/// it pairs each `actionStarted`/`actionFinished` into a SPAN (OpenTelemetry semantics — one trace per
/// agent run, one span per tool action), stamping wall-clock start/end and carrying the tool, success,
/// and error as attributes. Output is newline-delimited JSON spans (JSONL) — the same shape an OTLP
/// file-exporter emits — so it drops into any OTel-aware pipeline or is greppable on its own.
///
/// The clock is injected, so span timing is deterministic under test. Thread-safe: `emit` may be called
/// from concurrent tool contexts.
public final class SpanExporter: RuntimeEventSink, @unchecked Sendable {

    /// One OTel span. Field names follow the OTLP JSON span shape (nanosecond epochs, string ids,
    /// attribute bag, status) so a downstream collector needs no translation.
    public struct Span: Codable, Equatable, Sendable {
        public let traceId: String
        public let spanId: String
        public let name: String
        public let kind: String                 // "internal" (tool action) | "server" (run root)
        public let startTimeUnixNano: Int64
        public let endTimeUnixNano: Int64
        public let durationMs: Double
        public let attributes: [String: String] // tool, success, error, …
        public let status: String               // "ok" | "error"
    }

    private let lock = NSLock()
    private let traceId: String
    private let now: @Sendable () -> Date
    private let sink: @Sendable (String) -> Void
    private let onClose: (@Sendable () -> Void)?
    private let runStart: Date
    private var open: [Int: (start: Date, tool: String?, description: String)] = [:]
    private var seq: Int = 0
    private var _spans: [Span] = []

    public init(traceId: String = UUID().uuidString,
                now: @escaping @Sendable () -> Date = { Date() },
                write: @escaping @Sendable (String) -> Void,
                onClose: (@Sendable () -> Void)? = nil) {
        self.traceId = traceId
        self.now = now
        self.sink = write
        self.onClose = onClose
        self.runStart = now()
    }

    /// Flush + release any resource the exporter owns (e.g. the file handle from `toFile`). Idempotent
    /// via the sink's own lock. Called automatically on dealloc; call explicitly for deterministic close.
    public func close() { onClose?() }
    deinit { onClose?() }

    /// Convenience: export spans to a JSONL file (appends; created if absent). Honors `KIST_TRACE_SPANS`
    /// callers by passing that path here. The file handle is CLOSED on `close()`/dealloc (no fd leak on a
    /// long-lived process), and its own lock serializes writes now that `emit` calls the sink OUTSIDE the
    /// exporter lock.
    public static func toFile(path: String,
                              traceId: String = UUID().uuidString,
                              now: @escaping @Sendable () -> Date = { Date() }) -> SpanExporter {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
        handle?.seekToEndOfFile()
        let writeLock = NSLock()
        return SpanExporter(
            traceId: traceId, now: now,
            write: { line in
                guard let data = (line + "\n").data(using: .utf8) else { return }
                writeLock.lock(); handle?.write(data); writeLock.unlock()
            },
            onClose: {
                writeLock.lock(); try? handle?.synchronize(); try? handle?.close(); writeLock.unlock()
            })
    }

    /// Construct an exporter from `KIST_TRACE_SPANS` (a JSONL path), or nil when the env var is unset —
    /// so a caller composes tracing in with one line: `sink = SpanExporter.fromEnvironment().map { MultiEventSink([base, $0]) } ?? base`.
    /// Off by default (no env var → no exporter → zero overhead), on-demand when the path is set.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment,
                                       traceId: String = UUID().uuidString) -> SpanExporter? {
        guard let path = env["KIST_TRACE_SPANS"], !path.isEmpty else { return nil }
        return toFile(path: (path as NSString).expandingTildeInPath, traceId: traceId)
    }

    /// Test/inspection access to the spans emitted so far.
    public var spans: [Span] { lock.lock(); defer { lock.unlock() }; return _spans }

    public func emit(_ event: RuntimeEvent) {
        // Build the span + its JSONL line UNDER the lock, then release the lock and call `sink` OUTSIDE
        // it: a slow disk write (full/NFS/`/Volumes`) must not serialize every other concurrent emit.
        var line: String?
        switch event {
        case let .actionStarted(index, tool, description):
            lock.lock(); open[index] = (now(), tool, description); lock.unlock()

        case let .actionFinished(index, success, _, error):
            lock.lock()
            guard let started = open.removeValue(forKey: index) else { lock.unlock(); return }
            let end = now()
            var attrs: [String: String] = ["success": success ? "true" : "false"]
            if let tool = started.tool { attrs["tool"] = tool }
            if !started.description.isEmpty { attrs["description"] = started.description }
            if let error, !error.isEmpty { attrs["error"] = String(error.prefix(500)) }
            let span = makeSpan(name: started.tool.map { "tool.\($0)" } ?? "action.\(index)",
                                kind: "internal", start: started.start, end: end,
                                attributes: attrs, status: success ? "ok" : "error")
            line = record(span)
            lock.unlock()

        case .completed, .failed, .cancelled:
            lock.lock()
            // Cancellation is NOT a fault — keep it distinct from "error" so a status-based alert doesn't
            // page a human for every user-cancelled run.
            let status: String
            var attrs: [String: String] = [:]
            switch event {
            case let .completed(summary): status = "ok"; attrs["summary"] = String(summary.prefix(500))
            case let .failed(reason): status = "error"; attrs["error"] = String(reason.prefix(500))
            default: status = "cancelled"; attrs["cancelled"] = "true"
            }
            let root = makeSpan(name: "agent.run", kind: "server", start: runStart, end: now(),
                                attributes: attrs, status: status)
            line = record(root)
            lock.unlock()

        default:
            break   // token/usage/plan events are not spans
        }
        if let line { sink(line) }
    }

    // MARK: - internals (caller holds the lock)

    private func makeSpan(name: String, kind: String, start: Date, end: Date,
                          attributes: [String: String], status: String) -> Span {
        seq += 1
        let startN = Int64((start.timeIntervalSince1970 * 1_000_000_000).rounded())
        let endN = Int64((end.timeIntervalSince1970 * 1_000_000_000).rounded())
        return Span(traceId: traceId, spanId: "\(traceId).\(seq)", name: name, kind: kind,
                    startTimeUnixNano: startN, endTimeUnixNano: endN,
                    durationMs: end.timeIntervalSince(start) * 1000,
                    attributes: attributes, status: status)
    }

    /// Append + encode a span (caller holds the lock). Returns the JSONL line for the caller to write
    /// OUTSIDE the lock, or nil on an encoding failure.
    private func record(_ span: Span) -> String? {
        _spans.append(span)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(span), let line = String(data: data, encoding: .utf8) else { return nil }
        return line
    }
}

/// Fan-out sink: forward every event to several sinks so span export composes WITH the existing UI/log
/// sink rather than replacing it.
public struct MultiEventSink: RuntimeEventSink {
    private let sinks: [any RuntimeEventSink]
    public init(_ sinks: [any RuntimeEventSink]) { self.sinks = sinks }
    public func emit(_ event: RuntimeEvent) { for s in sinks { s.emit(event) } }
}
