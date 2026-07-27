import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A one-shot loopback HTTP listener that catches the OAuth redirect (`GET /cb?code=…&state=…`). Binds
/// 127.0.0.1 on an OS-assigned port (so the redirect_uri is `http://127.0.0.1:<port>/cb`), accepts ONE
/// connection, parses the query, replies with a "you can close this tab" page, and returns (code, state).
/// Loopback-only + single-shot + short timeout — it never exposes anything to the network.
enum OAuthCallbackServer {

    struct Callback: Equatable { let code: String?; let state: String?; let error: String? }

    /// Parse the query of an HTTP request line ("GET /cb?code=X&state=Y HTTP/1.1"). Pure + testable.
    static func parseRequestLine(_ line: String) -> Callback {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let comps = URLComponents(string: "http://x" + parts[1]) else {
            return Callback(code: nil, state: nil, error: "malformed request")
        }
        func q(_ n: String) -> String? { comps.queryItems?.first { $0.name == n }?.value }
        return Callback(code: q("code"), state: q("state"), error: q("error"))
    }

    #if canImport(Darwin) || canImport(Glibc)
    /// Bind a loopback port; returns (port, listeningSocketFD). Caller uses the port in redirect_uri, then
    /// calls `waitForCallback`. Throws on any socket error.
    static func bind() throws -> (port: Int, fd: Int32) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPConnectionError.badResponse("socket() failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                                   // OS assigns a free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")       // loopback ONLY
        let bindRes = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { DarwinBind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindRes == 0, listen(fd, 1) == 0 else { close(fd); throw MCPConnectionError.badResponse("bind/listen failed") }
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return (Int(UInt16(bigEndian: bound.sin_port)), fd)
    }

    /// Accept one connection, read the request line, reply, and return the parsed callback. Blocks up to
    /// `timeoutSeconds`. Runs the blocking accept()/read() off the main actor via a detached task. Does
    /// NOT close the listening `fd` — the CALLER owns it (so it's closed once, on every path, via a
    /// single defer, including the error paths before this is even reached).
    static func waitForCallback(fd: Int32, timeoutSeconds: Int = 300) async -> Callback {
        await withCheckedContinuation { cont in
            let box = ContinuationBox(cont)
            Task.detached {
                // accept() with a poll timeout so we don't hang forever.
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, Int32(timeoutSeconds * 1000))
                guard ready > 0 else { box.resume(Callback(code: nil, state: nil, error: "timeout")); return }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { box.resume(Callback(code: nil, state: nil, error: "accept failed")); return }
                defer { close(client) }
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = read(client, &buf, buf.count)
                let request = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
                let firstLine = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? ""
                let cb = parseRequestLine(firstLine)
                let bodyText = cb.error != nil ? "Authorization failed: \(cb.error!). You can close this tab."
                                               : "Authorization complete. You can close this tab and return to kist."
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(bodyText.utf8.count)\r\nConnection: close\r\n\r\n\(bodyText)"
                _ = response.withCString { write(client, $0, strlen($0)) }
                box.resume(cb)
            }
        }
    }
    #endif
}

/// One-shot continuation wrapper so the detached socket task can resume exactly once.
private final class ContinuationBox: @unchecked Sendable {
    private let cont: CheckedContinuation<OAuthCallbackServer.Callback, Never>
    private var done = false
    private let lock = NSLock()
    init(_ c: CheckedContinuation<OAuthCallbackServer.Callback, Never>) { cont = c }
    func resume(_ cb: OAuthCallbackServer.Callback) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }; done = true
        cont.resume(returning: cb)
    }
}

#if canImport(Darwin) || canImport(Glibc)
// `bind` collides with Swift; alias the C symbol.
private func DarwinBind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.bind(fd, addr, len)
    #else
    return Glibc.bind(fd, addr, len)
    #endif
}
#endif
