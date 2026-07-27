import Foundation

/// Minimal structured logger. Writes human lines to stdout and, when a sink is
/// configured, mirrors machine-readable JSONL for later inspection.
public enum LogLevel: String, Sendable {
    case debug, info, warn, error, success
}

public struct Log: Sendable {
    public let component: String
    private let minLevel: LogLevel

    public init(_ component: String, minLevel: LogLevel = .info) {
        self.component = component
        self.minLevel = minLevel
    }

    public func debug(_ m: @autoclosure () -> String) { emit(.debug, m()) }
    public func info(_ m: @autoclosure () -> String) { emit(.info, m()) }
    public func warn(_ m: @autoclosure () -> String) { emit(.warn, m()) }
    public func error(_ m: @autoclosure () -> String) { emit(.error, m()) }
    public func success(_ m: @autoclosure () -> String) { emit(.success, m()) }

    private static let order: [LogLevel: Int] = [
        .debug: 0, .info: 1, .success: 1, .warn: 2, .error: 3,
    ]

    private func emit(_ level: LogLevel, _ message: String) {
        guard (Self.order[level] ?? 1) >= (Self.order[minLevel] ?? 1) else { return }
        let icon: String
        switch level {
        case .debug: icon = "·"
        case .info: icon = "→"
        case .warn: icon = "⚠"
        case .error: icon = "✗"
        case .success: icon = "✓"
        }
        FileHandle.standardOutput.write(Data("\(icon) [\(component)] \(message)\n".utf8))
    }
}
