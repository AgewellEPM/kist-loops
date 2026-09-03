import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Loopback-only HTTP host for a launched SML workflow runtime — the transport half of "runs in
/// its own harness". Adapted from the proven single-user ChainServer pattern: 127.0.0.1 ONLY,
/// one request at a time on a background thread, minimal HTTP/1.1 parsing with hard size caps.
/// Lives in AgentCore (not Kist) so the generated standalone runtime binary links the exact same
/// serving core the kist CLI uses.
///
/// Auth: every request must carry `Authorization: Bearer <session token>`, a per-session random
/// token the host writes to an owner-only file. There is no unauthenticated route — including
/// `GET /approvals` — because task IDs and workflow state are operator-private.
///
/// Routes:
/// - `GET /approvals` → the shared pending-work projection (`SMLRuntimePendingView`)
/// - everything else → the generated runtime router (`SMLWorkflowRuntimeAPI.handleRuntime`),
///   which already serves per-workflow describe/start/watch/approve/refuse/rollback/receipts
///   plus the runtime metadata endpoints. Approvals therefore happen through the SAME generated
///   route the offline CLI proves (`POST {base}/{workflow}/tasks/{id}/approve`).
///
/// After every successful POST the host triggers the capability pump, so an approval is followed
/// immediately by its (single-flight) dispatch without polling.
public final class SMLRuntimeHTTPCore: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let portRange: ClosedRange<UInt16>
        public let maximumHeaderBytes: Int
        public let maximumBodyBytes: Int
        public let maximumResponseBytes: Int
        public let socketTimeoutMilliseconds: Int
        public let shutdownGraceMilliseconds: Int

        public init(
            portRange: ClosedRange<UInt16> = 8850...8880,
            maximumHeaderBytes: Int = 16_384,
            maximumBodyBytes: Int = 1_048_576,
            maximumResponseBytes: Int = 4_194_304,
            socketTimeoutMilliseconds: Int = 5_000,
            shutdownGraceMilliseconds: Int = 30_000
        ) {
            self.portRange = portRange
            self.maximumHeaderBytes = max(1_024, maximumHeaderBytes)
            self.maximumBodyBytes = max(0, maximumBodyBytes)
            self.maximumResponseBytes = max(1_024, maximumResponseBytes)
            self.socketTimeoutMilliseconds = max(1, socketTimeoutMilliseconds)
            self.shutdownGraceMilliseconds = max(1, shutdownGraceMilliseconds)
        }
    }

    private let api: SMLWorkflowRuntimeAPI
    private let store: SMLRuntimeStore
    private let pump: SMLRuntimeCapabilityPump?
    private let sessionToken: String
    private let configuration: Configuration
    private let lifecycleLock = NSLock()
    private let workerGroup = DispatchGroup()
    private var storedPort: UInt16 = 0
    private var listenFD: Int32 = -1
    private var activeConnectionFD: Int32 = -1
    private var running = false
    private var started = false

    public var port: UInt16 {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return storedPort
    }

    public init(
        api: SMLWorkflowRuntimeAPI,
        store: SMLRuntimeStore,
        pump: SMLRuntimeCapabilityPump?,
        sessionToken: String,
        configuration: Configuration = Configuration()
    ) {
        self.api = api
        self.store = store
        self.pump = pump
        self.sessionToken = sessionToken
        self.configuration = configuration
    }

    /// Mints a 256-bit session token and publishes it through an owner-only directory descriptor.
    /// The temporary inode is born 0600, never follows a symlink, is fsync'd before rename, and is
    /// identity-checked after publication. There is no chmod-after-write disclosure window.
    public static func mintSessionToken(writingTo url: URL) throws -> String {
        let basename = try validatedTokenBasename(url)
        let token = MythosCrypto.randomKey().map { String(format: "%02x", $0) }.joined()
        let data = Data(token.utf8)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )

        let directoryFD = open(
            directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryFD >= 0 else {
            throw SMLRuntimeHTTPCoreError.secureTokenDirectoryUnavailable
        }
        defer { _ = close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid(),
              fchmod(directoryFD, mode_t(0o700)) == 0,
              fstat(directoryFD, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(0o7777)) == mode_t(0o700) else {
            throw SMLRuntimeHTTPCoreError.insecureTokenDirectory
        }

        let temporaryName = ".\(basename).\(UUID().uuidString).tmp"
        let tokenFD = openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard tokenFD >= 0 else { throw SMLRuntimeHTTPCoreError.tokenWriteFailed }
        var published = false
        var verified = false
        defer {
            _ = close(tokenFD)
            if !published {
                _ = unlinkat(directoryFD, temporaryName, 0)
            } else if !verified {
                _ = unlinkat(directoryFD, basename, 0)
                _ = fsync(directoryFD)
            }
        }
        try writeAll(data, to: tokenFD)
        guard fchmod(tokenFD, mode_t(0o600)) == 0, fsync(tokenFD) == 0 else {
            throw SMLRuntimeHTTPCoreError.tokenWriteFailed
        }
        guard renameat(directoryFD, temporaryName, directoryFD, basename) == 0 else {
            throw SMLRuntimeHTTPCoreError.tokenPublishFailed
        }
        published = true
        guard fsync(directoryFD) == 0 else {
            throw SMLRuntimeHTTPCoreError.tokenPublishFailed
        }

        let publishedFD = openat(directoryFD, basename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard publishedFD >= 0 else { throw SMLRuntimeHTTPCoreError.tokenVerificationFailed }
        defer { _ = close(publishedFD) }
        var tokenInfo = stat()
        guard fstat(publishedFD, &tokenInfo) == 0,
              (tokenInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              tokenInfo.st_uid == geteuid(),
              tokenInfo.st_nlink == 1,
              (tokenInfo.st_mode & mode_t(0o7777)) == mode_t(0o600),
              tokenInfo.st_size == off_t(data.count) else {
            throw SMLRuntimeHTTPCoreError.tokenVerificationFailed
        }
        verified = true
        return token
    }

    /// Removes the published session secret through the same no-follow directory boundary used
    /// to create it. Missing is already-clean success; every other failure is surfaced so hosts
    /// can warn instead of silently leaving a reusable credential behind.
    public static func removeSessionToken(at url: URL) throws {
        let basename = try validatedTokenBasename(url)
        let directory = url.deletingLastPathComponent()
        let directoryFD = open(
            directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryFD >= 0 else {
            if errno == ENOENT { return }
            throw SMLRuntimeHTTPCoreError.secureTokenDirectoryUnavailable
        }
        defer { _ = close(directoryFD) }

        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid(),
              (directoryInfo.st_mode & mode_t(0o077)) == 0 else {
            throw SMLRuntimeHTTPCoreError.insecureTokenDirectory
        }
        guard unlinkat(directoryFD, basename, 0) == 0 else {
            if errno == ENOENT { return }
            throw SMLRuntimeHTTPCoreError.tokenRemovalFailed
        }
        guard fsync(directoryFD) == 0 else {
            throw SMLRuntimeHTTPCoreError.tokenRemovalFailed
        }
    }

    private static func validatedTokenBasename(_ url: URL) throws -> String {
        let basename = url.lastPathComponent
        guard !basename.isEmpty, basename != ".", basename != "..", !basename.contains("/") else {
            throw SMLRuntimeHTTPCoreError.invalidTokenPath
        }
        return basename
    }

    /// Binds the first free loopback port in the configured range and starts serving.
    public func start() -> URL? {
        lifecycleLock.lock()
        let alreadyRunningOrConsumed = started || running || listenFD >= 0
        lifecycleLock.unlock()
        guard !alreadyRunningOrConsumed else { return nil }
        for candidate in configuration.portRange {
            if let url = bind(port: candidate) { return url }
        }
        return nil
    }

    public func stop() {
        lifecycleLock.lock()
        running = false
        listenFD = -1
        storedPort = 0
        lifecycleLock.unlock()
        let deadline = DispatchTime.now() + .milliseconds(configuration.shutdownGraceMilliseconds)
        if workerGroup.wait(timeout: deadline) == .timedOut {
            lifecycleLock.lock()
            let active = activeConnectionFD
            lifecycleLock.unlock()
            if active >= 0 { _ = shutdown(active, SHUT_RDWR) }
            // Give a socket unblocked above one bounded opportunity to unwind its handler. A
            // capability implementation may ignore cancellation, so stop never waits forever.
            _ = workerGroup.wait(
                timeout: .now() + .milliseconds(min(configuration.socketTimeoutMilliseconds, 5_000))
            )
        }
    }

    private func bind(port candidate: UInt16) -> URL? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = candidate.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")   // loopback only — never an interface
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        guard Self.setCloseOnExec(fd), Self.setNonBlocking(fd) else {
            close(fd)
            return nil
        }
        lifecycleLock.lock()
        guard !started, !running, listenFD < 0 else {
            lifecycleLock.unlock()
            close(fd)
            return nil
        }
        listenFD = fd
        storedPort = candidate
        running = true
        started = true
        lifecycleLock.unlock()
        workerGroup.enter()
        Thread.detachNewThread { self.acceptLoop(listenerFD: fd) }
        return URL(string: "http://127.0.0.1:\(candidate)/")
    }

    private func acceptLoop(listenerFD: Int32) {
        defer {
            _ = close(listenerFD)
            workerGroup.leave()
        }
        while isRunning {
            var listener = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&listener, 1, 100)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            guard isRunning else { break }
            guard listener.revents & Int16(POLLIN) != 0 else { break }
            let conn = accept(listenerFD, nil, nil)
            if conn < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                if isRunning { continue } else { break }
            }
            guard Self.setBlocking(conn), configureConnection(conn) else {
                close(conn)
                continue
            }
            lifecycleLock.lock()
            activeConnectionFD = conn
            lifecycleLock.unlock()
            handle(conn)
            lifecycleLock.lock()
            if activeConnectionFD == conn { activeConnectionFD = -1 }
            lifecycleLock.unlock()
            close(conn)
        }
    }

    private var isRunning: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return running
    }

    // MARK: - One request

    private func handle(_ conn: Int32) {
        let request: ParsedRequest
        switch readRequest(conn) {
        case .request(let parsed):
            request = parsed
        case .rejected(let status, let message):
            writeResponse(conn, status: status, body: errorJSON(message))
            return
        case .closed:
            return
        }
        guard let bearer = request.bearerToken,
              HostSnapshotAuth.constantTimeEquals(sessionToken, bearer) else {
            writeResponse(conn, status: 401,
                          body: errorJSON("missing or invalid session token"))
            return
        }
        let (status, payload) = routeSynchronously(
            method: request.method, path: request.path, body: request.body
        )
        writeResponse(conn, status: status, body: payload)
    }

    /// Bridges the async runtime router onto the single-connection thread. Fine at this scale:
    /// local, one request in flight, and the pump keeps dispatch single-flight anyway.
    private func routeSynchronously(
        method: String, path: String, body: Data
    ) -> (Int, Data) {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task { [weak self] in
            defer { semaphore.signal() }
            guard let self else { return }
            box.set(await self.route(method: method, path: path, body: body))
        }
        semaphore.wait()
        return box.get() ?? (500, errorJSON("request handling failed"))
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (Int, Data)?
        func set(_ new: (Int, Data)) {
            lock.lock(); defer { lock.unlock() }
            value = new
        }
        func get() -> (Int, Data)? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private func route(method: String, path: String, body: Data) async -> (Int, Data) {
        if method == "GET", path == "/approvals" {
            do {
                let snapshot = try await store.load()
                let view = SMLRuntimePendingView.build(from: snapshot)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                return (200, try encoder.encode(view))
            } catch {
                return (500, errorJSON("internal server error"))
            }
        }

        guard let apiMethod = SMLWorkflowAPIMethod(rawValue: method) else {
            return (405, errorJSON("method not allowed"))
        }
        let requestBody: SMLObject
        if body.isEmpty {
            requestBody = [:]
        } else {
            do {
                requestBody = try SMLWireCodec.decodeOpenObject(from: body)
            } catch {
                return (400, errorJSON("request body must be a JSON object"))
            }
        }
        // The generated approve/refuse/rollback routes read expected_state.task_revision from the
        // request body's expected_state envelope; the runtime router splits body vs expected
        // internally via the route's bodyKind. Pass the body straight through.
        let request = SMLWorkflowAPIRequest(
            method: apiMethod,
            path: path,
            body: requestBody
        )
        do {
            let response = try await api.handleRuntime(request)
            if apiMethod == .post, let pump {
                await pump.drain()
            }
            return try encodeRuntimeResponse(response)
        } catch let error as SMLWorkflowRuntimeRegistryError {
            if case .routeNotFound = error {
                return (404, errorJSON("route not found"))
            }
            return (422, errorJSON("request rejected"))
        } catch let error as SMLWorkflowAPIError {
            if case .routeNotFound = error {
                return (404, errorJSON("route not found"))
            }
            return (422, errorJSON("request rejected"))
        } catch let error as SMLRuntimeError {
            // Optimistic-concurrency conflicts surface as 409 so an operator retries with the
            // fresh revision instead of reading a generic failure.
            if case .expectedStateMismatch = error {
                return (409, errorJSON("request conflicts with current task state"))
            }
            return (422, errorJSON("request rejected"))
        } catch {
            return (422, errorJSON("request rejected"))
        }
    }

    private func encodeRuntimeResponse(
        _ response: SMLWorkflowRuntimeAPIResponse
    ) throws -> (Int, Data) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = try encoder.encode(ResponseEnvelope(
            statusCode: response.statusCode,
            kind: response.kind.rawValue,
            path: response.path,
            body: response.body,
            command: response.command,
            result: response.result
        ))
        return (response.statusCode, payload)
    }

    private struct ResponseEnvelope: Encodable {
        let statusCode: Int
        let kind: String
        let path: String
        let body: SMLValue
        let command: SMLCommandEnvelope?
        let result: SMLCommandResult?

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case kind, path, body, command, result
        }
    }

    private func errorJSON(_ message: String) -> Data {
        let payload = ["error": message]
        return (try? JSONEncoder().encode(payload)) ?? Data("{\"error\":\"unknown\"}".utf8)
    }

    // MARK: - Minimal HTTP I/O (ChainServer pattern + auth header + body cap)

    private struct ParsedRequest {
        let method: String
        let path: String
        let body: Data
        let bearerToken: String?
    }

    private enum RequestReadResult {
        case request(ParsedRequest)
        case rejected(status: Int, message: String)
        case closed
    }

    /// Strict request framing is part of the auth boundary. Ambiguous Content-Length,
    /// Transfer-Encoding, folded headers, bytes after the declared body, and non-origin request
    /// targets are all rejected before they can reach the runtime router.
    private func readRequest(_ conn: Int32) -> RequestReadResult {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        var headerEnd: Range<Data.Index>?
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(configuration.socketTimeoutMilliseconds) * 1_000_000
        while headerEnd == nil {
            let count = readBeforeDeadline(
                conn, into: &chunk, count: chunk.count, deadline: deadline
            )
            if count == 0 {
                return buffer.isEmpty
                    ? .closed
                    : .rejected(status: 400, message: "incomplete HTTP request")
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return .rejected(status: 408, message: "request timeout")
                }
                return .closed
            }
            buffer.append(contentsOf: chunk[0..<count])
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if headerEnd == nil,
               buffer.count > configuration.maximumHeaderBytes + 3 {
                return .rejected(status: 431, message: "request headers too large")
            }
        }
        guard let headerRange = headerEnd,
              headerRange.lowerBound <= configuration.maximumHeaderBytes else {
            return .rejected(status: 431, message: "request headers too large")
        }
        let headerData = Data(buffer[..<headerRange.lowerBound])
        guard headerData.allSatisfy({
                  $0 == 9 || $0 == 13 || $0 == 10 || ($0 >= 32 && $0 <= 126)
              }),
              let header = String(data: headerData, encoding: .utf8) else {
            return .rejected(status: 400, message: "invalid HTTP headers")
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .rejected(status: 400, message: "missing request line")
        }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count == 3,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts[2] == "HTTP/1.1",
              parts[1].hasPrefix("/"),
              !parts[1].contains("?"),
              !parts[1].contains("#") else {
            return .rejected(status: 400, message: "invalid HTTP request line")
        }

        var contentLength: Int?
        var bearer: String?
        var hostCount = 0
        var authorizationCount = 0
        var sawTransferEncoding = false
        var sawExpect = false
        for line in lines.dropFirst() {
            guard !line.isEmpty,
                  line.first != " ",
                  line.first != "\t",
                  let colon = line.firstIndex(of: ":") else {
                return .rejected(status: 400, message: "invalid HTTP header")
            }
            let name = String(line[..<colon])
            guard isValidHeaderName(name) else {
                return .rejected(status: 400, message: "invalid HTTP header")
            }
            let valueStart = line.index(after: colon)
            let value = line[valueStart...].trimmingCharacters(in: .whitespaces)
            guard value.unicodeScalars.allSatisfy({
                let byte = $0.value
                return byte == 9 || (byte >= 32 && byte <= 126)
            }) else {
                return .rejected(status: 400, message: "invalid HTTP header")
            }
            switch name.lowercased() {
            case "host":
                hostCount += 1
                guard hostCount == 1, !value.isEmpty else {
                    return .rejected(status: 400, message: "invalid Host header")
                }
            case "content-length":
                guard contentLength == nil,
                      !value.isEmpty,
                      value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                      let parsed = Int(value) else {
                    return .rejected(status: 400, message: "invalid Content-Length")
                }
                guard parsed <= configuration.maximumBodyBytes else {
                    return .rejected(status: 413, message: "request body too large")
                }
                contentLength = parsed
            case "authorization":
                authorizationCount += 1
                guard authorizationCount == 1 else {
                    return .rejected(status: 400, message: "duplicate Authorization header")
                }
                if value.lowercased().hasPrefix("bearer ") {
                    bearer = String(value.dropFirst("bearer ".count))
                        .trimmingCharacters(in: .whitespaces)
                }
            case "transfer-encoding":
                sawTransferEncoding = true
            case "expect":
                sawExpect = true
            default:
                continue
            }
        }
        guard hostCount == 1 else {
            return .rejected(status: 400, message: "missing Host header")
        }
        guard !sawTransferEncoding else {
            return .rejected(status: 400, message: "Transfer-Encoding is not supported")
        }
        guard !sawExpect else {
            return .rejected(status: 417, message: "Expect is not supported")
        }

        var body = Data(buffer[headerRange.upperBound...])
        let declaredLength = contentLength ?? 0
        guard body.count <= declaredLength else {
            return .rejected(status: 400, message: "bytes follow the declared request body")
        }
        if parts[0] == SMLWorkflowAPIMethod.get.rawValue, declaredLength != 0 {
            return .rejected(status: 400, message: "GET request bodies are not supported")
        }
        while body.count < declaredLength {
            let remaining = declaredLength - body.count
            let count = readBeforeDeadline(
                conn,
                into: &chunk,
                count: min(chunk.count, remaining),
                deadline: deadline
            )
            if count == 0 {
                return .rejected(status: 400, message: "incomplete request body")
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return .rejected(status: 408, message: "request timeout")
                }
                return .closed
            }
            body.append(contentsOf: chunk[0..<count])
        }
        return .request(ParsedRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            body: body,
            bearerToken: bearer
        ))
    }

    /// Reads against one absolute request deadline, rather than resetting an idle timeout after
    /// each byte. A local slowloris therefore cannot monopolize the single-flight server by
    /// trickling data just before SO_RCVTIMEO expires.
    private func readBeforeDeadline(
        _ descriptor: Int32,
        into buffer: inout [UInt8],
        count: Int,
        deadline: UInt64
    ) -> Int {
        while true {
            guard let timeout = Self.remainingPollMilliseconds(until: deadline) else {
                errno = EAGAIN
                return -1
            }
            var candidate = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let ready = poll(&candidate, 1, timeout)
            if ready == 0 {
                errno = EAGAIN
                return -1
            }
            if ready < 0 {
                if errno == EINTR { continue }
                return -1
            }
            if candidate.revents & Int16(POLLERR | POLLNVAL) != 0 {
                errno = ECONNRESET
                return -1
            }
            let result = read(descriptor, &buffer, count)
            if result < 0, errno == EINTR { continue }
            return result
        }
    }

    private static func remainingPollMilliseconds(until deadline: UInt64) -> Int32? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return nil }
        let remainingNanoseconds = deadline - now
        let roundedMilliseconds = (remainingNanoseconds + 999_999) / 1_000_000
        return Int32(min(roundedMilliseconds, UInt64(Int32.max)))
    }

    private func isValidHeaderName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let punctuation = Set("!#$%&'*+-.^_|~".utf8)
        return name.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || punctuation.contains($0)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        let succeeded = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = write(
                    descriptor, base.advanced(by: offset), bytes.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
        guard succeeded else { throw SMLRuntimeHTTPCoreError.tokenWriteFailed }
    }

    private static func setCloseOnExec(_ descriptor: Int32) -> Bool {
        let current = fcntl(descriptor, F_GETFD)
        guard current >= 0 else { return false }
        return fcntl(descriptor, F_SETFD, current | FD_CLOEXEC) == 0
    }

    private static func setNonBlocking(_ descriptor: Int32) -> Bool {
        let current = fcntl(descriptor, F_GETFL)
        guard current >= 0 else { return false }
        return fcntl(descriptor, F_SETFL, current | O_NONBLOCK) == 0
    }

    private static func setBlocking(_ descriptor: Int32) -> Bool {
        let current = fcntl(descriptor, F_GETFL)
        guard current >= 0 else { return false }
        return fcntl(descriptor, F_SETFL, current & ~O_NONBLOCK) == 0
    }

    private func configureConnection(_ descriptor: Int32) -> Bool {
        guard Self.setCloseOnExec(descriptor) else { return false }
        var timeout = timeval()
        timeout.tv_sec = numericCast(configuration.socketTimeoutMilliseconds / 1_000)
        timeout.tv_usec = numericCast(
            (configuration.socketTimeoutMilliseconds % 1_000) * 1_000
        )
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO,
            &timeout, socklen_t(MemoryLayout<timeval>.size)
        ) == 0,
        setsockopt(
            descriptor, SOL_SOCKET, SO_SNDTIMEO,
            &timeout, socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            return false
        }
        #if canImport(Darwin)
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE,
            &noSignal, socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            return false
        }
        #endif
        return true
    }

    private func writeResponse(_ conn: Int32, status requestedStatus: Int, body requestedBody: Data) {
        let status: Int
        let body: Data
        if requestedBody.count <= configuration.maximumResponseBytes {
            status = requestedStatus
            body = requestedBody
        } else {
            status = 500
            body = errorJSON("response exceeds configured limit")
        }
        let head = "HTTP/1.1 \(status) \(Self.statusText(status))\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Pragma: no-cache\r\n"
            + "Content-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\n"
            + "Referrer-Policy: no-referrer\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(configuration.socketTimeoutMilliseconds) * 1_000_000
        out.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < out.count {
                guard let timeout = Self.remainingPollMilliseconds(until: deadline) else { break }
                var candidate = pollfd(fd: conn, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&candidate, 1, timeout)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0,
                      candidate.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else {
                    break
                }
                #if canImport(Glibc)
                let wrote = send(conn, base + sent, out.count - sent, Int32(MSG_NOSIGNAL))
                #else
                let wrote = send(conn, base + sent, out.count - sent, 0)
                #endif
                if wrote < 0, errno == EINTR { continue }
                if wrote <= 0 { break }
                sent += wrote
            }
        }
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 408: return "Request Timeout"
        case 413: return "Content Too Large"
        case 417: return "Expectation Failed"
        case 431: return "Request Header Fields Too Large"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 422: return "Unprocessable Entity"
        case 500: return "Internal Server Error"
        default: return "Error"
        }
    }
}

public enum SMLRuntimeHTTPCoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidTokenPath
    case secureTokenDirectoryUnavailable
    case insecureTokenDirectory
    case tokenWriteFailed
    case tokenPublishFailed
    case tokenVerificationFailed
    case tokenRemovalFailed

    public var description: String {
        switch self {
        case .invalidTokenPath:
            return "invalid SML runtime session-token path"
        case .secureTokenDirectoryUnavailable:
            return "cannot open the SML runtime session-token directory without following links"
        case .insecureTokenDirectory:
            return "SML runtime session-token directory is not an owner-only directory"
        case .tokenWriteFailed:
            return "cannot securely write the SML runtime session token"
        case .tokenPublishFailed:
            return "cannot durably publish the SML runtime session token"
        case .tokenVerificationFailed:
            return "published SML runtime session token failed identity or permission checks"
        case .tokenRemovalFailed:
            return "cannot durably remove the SML runtime session token"
        }
    }
}
