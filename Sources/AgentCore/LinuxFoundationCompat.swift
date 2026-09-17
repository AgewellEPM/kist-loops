#if !canImport(Darwin)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Linux/swift-corelibs-foundation compatibility shims for a handful of Darwin-Foundation APIs AgentCore
// relies on. These exist ONLY off Darwin (`#if !canImport(Darwin)`), so the macOS build is untouched and
// always uses the real system implementations. Each shim matches the exact member surface AgentCore uses
// — nothing broader — so the Linux build compiles without silently changing macOS behaviour.

/// `autoreleasepool(invoking:)` is an Objective-C runtime construct absent on Linux. AgentCore uses it
/// only as a scoping hint around tight loops; on Linux there is no autorelease pool, so it is a direct
/// pass-through with the identical signature and rethrows behaviour.
@discardableResult
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}

/// Linux compatibility for the async streaming `URLSession.bytes(for:)`, which swift-corelibs-foundation
/// (Swift 6.1) does not provide. It buffers the full response via the available `data(for:)` and vends it
/// as an async byte sequence exposing the two members AgentCore consumes: byte iteration and `.lines`.
///
/// This intentionally loses INCREMENTAL streaming on Linux (the whole body is fetched before iteration).
/// That is acceptable and honestly labelled: the Linux host is the evolution EVALUATION lane, where the
/// LLM providers are not on the hot path — candidate benchmarks run under containment, not chat streaming.
extension URLSession {
    func bytes(for request: URLRequest) async throws -> (LinuxBufferedAsyncBytes, URLResponse) {
        let (data, response) = try await self.data(for: request)
        return (LinuxBufferedAsyncBytes(data: data), response)
    }
}

/// A buffered async byte sequence matching the members AgentCore reads off `URLSession.bytes`.
struct LinuxBufferedAsyncBytes: AsyncSequence {
    typealias Element = UInt8
    let data: Data

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: Data.Iterator
        mutating func next() async -> UInt8? { iterator.next() }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(iterator: data.makeIterator()) }

    /// Matches `URLSession.AsyncBytes.lines`: newline-delimited strings with no trailing empty element.
    var lines: LinuxBufferedAsyncLines { LinuxBufferedAsyncLines(data: data) }

    /// `URLSession.AsyncBytes.task` on Darwin exposes the underlying task so callers can cancel a live
    /// stream. In the buffered Linux shim the response has already been fully received before iteration,
    /// so cancellation is a no-op handle with the same `.cancel()` surface the call sites use.
    var task: LinuxBufferedTaskHandle { LinuxBufferedTaskHandle() }
}

struct LinuxBufferedTaskHandle {
    func cancel() {}
}

struct LinuxBufferedAsyncLines: AsyncSequence {
    typealias Element = String
    let data: Data

    struct AsyncIterator: AsyncIteratorProtocol {
        var lines: [String]
        var index = 0
        mutating func next() async -> String? {
            guard index < lines.count else { return nil }
            defer { index += 1 }
            return lines[index]
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        var parts = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return AsyncIterator(lines: parts)
    }
}
#endif
