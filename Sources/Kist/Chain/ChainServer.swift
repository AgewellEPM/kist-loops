import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A tiny local HTTP server that backs the `/chain` visual builder. Binds to 127.0.0.1 ONLY (never a
/// network interface — it's a single-user local tool), serves the canvas page + a small JSON API to
/// list / load / save / run / delete chains. One request at a time on a background thread; that's plenty
/// for a local builder and keeps the socket code simple and correct.
final class ChainServer: @unchecked Sendable {
    let store: ChainStore
    /// Runs a chain end-to-end (wired by the REPL to the real agent loop). Async → bridged synchronously
    /// per request via a semaphore (fine: local, one connection at a time).
    let runChain: @Sendable (Chain) async -> ChainRunner.RunResult
    private(set) var port: UInt16 = 0
    private var listenFD: Int32 = -1
    private var running = false

    init(store: ChainStore, runChain: @escaping @Sendable (Chain) async -> ChainRunner.RunResult) {
        self.store = store
        self.runChain = runChain
    }

    /// Bind + listen on the first free port from 8760. Returns the browser URL, or nil on failure.
    func start() -> URL? {
        for candidate in UInt16(8760)...UInt16(8790) {
            if let url = bind(port: candidate) { return url }
        }
        return nil
    }

    private func bind(port candidate: UInt16) -> URL? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = candidate.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")   // loopback only
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return nil }
        listenFD = fd
        port = candidate
        running = true
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        return URL(string: "http://127.0.0.1:\(candidate)/")
    }

    func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    private func acceptLoop() {
        while running {
            let conn = accept(listenFD, nil, nil)
            if conn < 0 { if running { continue } else { break } }
            handle(conn)
            close(conn)
        }
    }

    // MARK: - One request

    private func handle(_ conn: Int32) {
        guard let (method, path, body) = readRequest(conn) else { return }
        let (status, contentType, payload) = route(method: method, path: path, body: body)
        write(conn, status: status, contentType: contentType, body: payload)
    }

    private func route(method: String, path: String, body: Data) -> (Int, String, Data) {
        // Static page
        if method == "GET", path == "/" || path == "/index.html" {
            return (200, "text/html; charset=utf-8", Data(ChainCanvasHTML.page.utf8))
        }
        // API
        if path == "/api/chains", method == "GET" {
            let list = store.all().map { ["id": $0.id, "name": $0.name, "enabled": $0.enabled, "schedule": $0.schedule ?? ""] as [String: Any] }
            return json(list)
        }
        if method == "POST", path == "/api/chain" {
            guard var chain = try? JSONDecoder().decode(Chain.self, from: body) else { return (400, "application/json", Data("{\"error\":\"bad chain json\"}".utf8)) }
            let problems = chain.validate()
            if chain.id.isEmpty { chain.id = "chain-" + UUID().uuidString.prefix(8).lowercased() }
            chain.updatedAt = Date().timeIntervalSince1970
            if chain.createdAt == 0 { chain.createdAt = chain.updatedAt }
            _ = store.save(chain)
            return json(["ok": true, "id": chain.id, "problems": problems])
        }
        if method == "GET", path.hasPrefix("/api/chain/") {
            let id = String(path.dropFirst("/api/chain/".count))
            guard let c = store.load(id: id), let data = try? JSONEncoder().encode(c) else { return (404, "application/json", Data("{\"error\":\"not found\"}".utf8)) }
            return (200, "application/json", data)
        }
        if method == "DELETE", path.hasPrefix("/api/chain/") {
            let id = String(path.dropFirst("/api/chain/".count))
            return json(["ok": store.delete(id: id)])
        }
        if method == "POST", path.hasPrefix("/api/chain/"), path.hasSuffix("/run") {
            let id = String(path.dropFirst("/api/chain/".count).dropLast("/run".count))
            guard let c = store.load(id: id) else { return (404, "application/json", Data("{\"error\":\"not found\"}".utf8)) }
            var result: ChainRunner.RunResult?
            let sem = DispatchSemaphore(value: 0)
            Task { result = await self.runChain(c); sem.signal() }
            sem.wait()
            let steps = (result?.steps ?? []).map { ["title": $0.title, "kind": $0.kind.rawValue, "input": $0.input, "output": $0.output] as [String: Any] }
            return json(["ok": true, "steps": steps, "final": result?.finalText ?? ""])
        }
        return (404, "text/plain", Data("not found".utf8))
    }

    private func json(_ obj: Any) -> (Int, String, Data) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("null".utf8)
        return (200, "application/json", data)
    }

    // MARK: - Minimal HTTP I/O

    private func readRequest(_ conn: Int32) -> (method: String, path: String, body: Data)? {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        // Read headers (until CRLFCRLF), then Content-Length bytes of body.
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = read(conn, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
            headerEnd = buf.range(of: Data("\r\n\r\n".utf8))
            if buf.count > 8 * 1024 * 1024 { return nil }   // sanity cap
        }
        guard let he = headerEnd else { return nil }
        let headerData = buf[..<he.lowerBound]
        let header = String(decoding: headerData, as: UTF8.self)
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]); let path = String(parts[1])
        let contentLength = lines.compactMap { line -> Int? in
            let l = line.lowercased()
            guard l.hasPrefix("content-length:") else { return nil }
            return Int(line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        var body = Data(buf[he.upperBound...])
        while body.count < contentLength {
            let n = read(conn, &chunk, chunk.count)
            if n <= 0 { break }
            body.append(contentsOf: chunk[0..<n])
        }
        return (method, path, body)
    }

    private func write(_ conn: Int32, status: Int, contentType: String, body: Data) {
        let head = "HTTP/1.1 \(status) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        out.withUnsafeBytes { raw in
            var sent = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while sent < out.count {
                let n = Foundation.write(conn, base + sent, out.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
