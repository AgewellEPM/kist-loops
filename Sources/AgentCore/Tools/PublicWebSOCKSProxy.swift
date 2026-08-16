import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Short-lived authenticated loopback HTTP proxy for BrowserTool.
///
/// Chromium sends the original authority to this proxy. The proxy applies host policy, resolves
/// exactly once through the shared public-address classifier, rejects the whole DNS set if any
/// answer is non-public, and connects only to a selected numeric address. HTTPS remains end-to-end
/// through CONNECT, preserving Host, SNI, and certificate verification.
///
/// The historical type name is retained to avoid a source-breaking API rename. Its advertised
/// endpoint is HTTP because Playwright supports username/password authentication for HTTP proxies.
final class PublicWebSOCKSProxy: @unchecked Sendable {
    typealias Resolver = @Sendable (_ host: String, _ timeoutSeconds: Int) ->
        (addresses: [String], reason: String?)

    struct Limits: Sendable {
        let maxConnections: Int
        let maxTotalConnections: Int
        let maxDNSResolutions: Int
        let maxResolvedAddresses: Int
        let maxAggregateBytes: Int
        let maxHeaderBytes: Int
        let maxRequestBodyBytes: Int
        let handshakeTimeoutNanoseconds: UInt64
        let connectTimeoutNanoseconds: UInt64
        let idleTimeoutNanoseconds: UInt64
        let maxLifetimeNanoseconds: UInt64

        init(
            maxConnections: Int = 64,
            maxTotalConnections: Int = 256,
            maxDNSResolutions: Int = 256,
            maxResolvedAddresses: Int = 64,
            maxAggregateBytes: Int = 256 * 1_024 * 1_024,
            maxHeaderBytes: Int = 64 * 1_024,
            maxRequestBodyBytes: Int = 16 * 1_024 * 1_024,
            handshakeTimeoutNanoseconds: UInt64 = 5_000_000_000,
            connectTimeoutNanoseconds: UInt64 = 10_000_000_000,
            idleTimeoutNanoseconds: UInt64 = 30_000_000_000,
            maxLifetimeNanoseconds: UInt64 = 65_000_000_000
        ) {
            self.maxConnections = maxConnections
            self.maxTotalConnections = maxTotalConnections
            self.maxDNSResolutions = maxDNSResolutions
            self.maxResolvedAddresses = maxResolvedAddresses
            self.maxAggregateBytes = maxAggregateBytes
            self.maxHeaderBytes = maxHeaderBytes
            self.maxRequestBodyBytes = maxRequestBodyBytes
            self.handshakeTimeoutNanoseconds = handshakeTimeoutNanoseconds
            self.connectTimeoutNanoseconds = connectTimeoutNanoseconds
            self.idleTimeoutNanoseconds = idleTimeoutNanoseconds
            self.maxLifetimeNanoseconds = maxLifetimeNanoseconds
        }

        var isValid: Bool {
            maxConnections > 0 && maxConnections <= Int(Int32.max)
                && maxTotalConnections >= maxConnections
                && maxDNSResolutions > 0
                && maxResolvedAddresses > 0
                && maxAggregateBytes > 0
                && maxHeaderBytes >= 1_024 && maxHeaderBytes <= 1_024 * 1_024
                && maxRequestBodyBytes >= 0 && maxRequestBodyBytes <= maxAggregateBytes
                && handshakeTimeoutNanoseconds > 0 && connectTimeoutNanoseconds > 0
                && idleTimeoutNanoseconds > 0
                && maxLifetimeNanoseconds > 0 && maxLifetimeNanoseconds <= 86_400_000_000_000
        }
    }

    let port: UInt16
    var endpoint: String { "http://127.0.0.1:\(port)" }
    let proxyUsername: String
    let proxyPassword: String

    private let listenerFD: Int32
    private let configuredAllowedHosts: Set<String>
    private let perCallAllowedHosts: Set<String>
    private let localCaptureScheme: String?
    private let localCaptureHost: String?
    private let localCapturePort: UInt16?
    private let resolver: Resolver
    private let limits: Limits
    private let lock = NSCondition()
    private let acceptWorkerState = AcceptWorkerState()
    private var stopped = false
    private var stopComplete = false
    private var clientFDs = Set<Int32>()
    private var ownedFDs = Set<Int32>()
    private var activeHandlers = 0
    private var totalConnections = 0
    private var dnsResolutions = 0
    private var aggregateBytes = 0
    private let startedNanoseconds = DispatchTime.now().uptimeNanoseconds

    static func start(
        configuredAllowedHosts: Set<String>,
        perCallAllowedHosts: Set<String>,
        localCaptureScheme: String? = nil,
        localCaptureHost: String? = nil,
        localCapturePort: UInt16? = nil,
        limits: Limits = Limits(),
        resolver: @escaping Resolver = { host, timeout in
            PublicWebTransport.resolvePublicAddresses(host: host, timeoutSeconds: timeout)
        }
    ) throws -> PublicWebSOCKSProxy {
        guard limits.isValid else { throw ProxyError("invalid browser proxy resource limits") }
        let normalizedScheme = localCaptureScheme?.lowercased()
        guard (localCaptureHost == nil && localCapturePort == nil && normalizedScheme == nil)
                || (localCaptureHost != nil && localCapturePort != nil
                    && (normalizedScheme == "http" || normalizedScheme == "https"))
        else { throw ProxyError("local browser capture requires an exact http(s) origin") }

        let fd = socket(AF_INET, streamSocketType, 0)
        guard fd >= 0 else { throw ProxyError("could not create browser proxy socket") }
        var shouldClose = true
        defer { if shouldClose { close(fd) } }

        var one: Int32 = 1
        guard setsockopt(
            fd, SOL_SOCKET, SO_REUSEADDR, &one,
            socklen_t(MemoryLayout.size(ofValue: one))) == 0
        else { throw ProxyError("could not configure browser proxy socket") }

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard "127.0.0.1".withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw ProxyError("could not encode browser proxy loopback address")
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, Int32(limits.maxConnections)) == 0 else {
            throw ProxyError("could not bind browser proxy to loopback")
        }
        let listenerFlags = fcntl(fd, F_GETFL, 0)
        guard listenerFlags >= 0,
              fcntl(fd, F_SETFL, listenerFlags | O_NONBLOCK) == 0 else {
            throw ProxyError("could not make browser proxy listener nonblocking")
        }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundLength)
            }
        }
        guard nameResult == 0 else { throw ProxyError("could not read browser proxy port") }

        let proxy = PublicWebSOCKSProxy(
            listenerFD: fd,
            port: UInt16(bigEndian: bound.sin_port),
            configuredAllowedHosts: configuredAllowedHosts,
            perCallAllowedHosts: perCallAllowedHosts,
            localCaptureScheme: normalizedScheme,
            localCaptureHost: localCaptureHost,
            localCapturePort: localCapturePort,
            limits: limits,
            resolver: resolver)
        shouldClose = false
        proxy.beginAccepting()
        return proxy
    }

    private init(
        listenerFD: Int32,
        port: UInt16,
        configuredAllowedHosts: Set<String>,
        perCallAllowedHosts: Set<String>,
        localCaptureScheme: String?,
        localCaptureHost: String?,
        localCapturePort: UInt16?,
        limits: Limits,
        resolver: @escaping Resolver
    ) {
        self.listenerFD = listenerFD
        self.port = port
        self.configuredAllowedHosts = configuredAllowedHosts
        self.perCallAllowedHosts = perCallAllowedHosts
        self.localCaptureScheme = localCaptureScheme
        self.localCaptureHost = localCaptureHost.flatMap { WebFetchTool.normalizedHostPattern($0) }
        self.localCapturePort = localCapturePort
        self.limits = limits
        self.resolver = resolver
        self.proxyUsername = Self.makeCredential()
        self.proxyPassword = Self.makeCredential()
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        if stopped {
            while !stopComplete { lock.wait() }
            lock.unlock()
            return
        }
        stopped = true
        // releaseOwnedFD removes and closes only while holding this same lock first. Revoking while
        // locked prevents an integer from being closed/reused between the ownership check and shutdown.
        for fd in ownedFDs { _ = shutdown(fd, Self.shutdownBoth) }
        lock.unlock()
        _ = shutdown(listenerFD, Self.shutdownBoth)

        // The accept state is independent of self so deinit can wait even after weak self becomes
        // unavailable to the worker. Keep the listener descriptor open until that worker has joined.
        acceptWorkerState.waitUntilFinished()

        // Each handler joins both tunnel pumps before decrementing its counter.
        lock.lock()
        while activeHandlers > 0 { lock.wait() }
        lock.unlock()
        close(listenerFD)
        lock.lock()
        stopComplete = true
        lock.broadcast()
        lock.unlock()
    }

    private func beginAccepting() {
        let acceptingFD = listenerFD
        acceptWorkerState.begin()
        let workerState = acceptWorkerState
        Thread.detachNewThread { [weak self] in
            defer { workerState.finish() }
            while true {
                var descriptor = pollfd(fd: acceptingFD, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                guard let self else { return }
                if self.isStopped { return }
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if ready == 0 { continue }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return }
                guard descriptor.revents & Int16(POLLIN) != 0 else { continue }
                let client = accept(acceptingFD, nil, nil)
                if client < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    return
                }
                Self.setNoSIGPIPE(client)
                self.lock.lock()
                let accepted = !self.stopped
                    && !self.lifetimeExpiredLocked
                    && self.clientFDs.count < self.limits.maxConnections
                    && self.totalConnections < self.limits.maxTotalConnections
                if accepted {
                    self.clientFDs.insert(client)
                    self.ownedFDs.insert(client)
                    self.totalConnections += 1
                    self.activeHandlers += 1
                }
                self.lock.unlock()
                guard accepted else { close(client); continue }
                Thread.detachNewThread { [self] in self.handle(client) }
            }
        }
    }

    private func handle(_ client: Int32) {
        defer {
            releaseOwnedFD(client, isClient: true)
            lock.lock()
            activeHandlers -= 1
            lock.broadcast()
            lock.unlock()
        }
        let headerDeadline = boundedDeadline(after: limits.handshakeTimeoutNanoseconds)
        guard let block = readHeaderBlock(client, deadline: headerDeadline) else {
            diagnose("incomplete or invalid HTTP proxy header")
            sendHTTP(client, status: 400, reason: "Bad Request", deadline: headerDeadline)
            return
        }
        guard let request = Self.parseRequest(block, maxBodyBytes: limits.maxRequestBodyBytes) else {
            let firstLine = String(bytes: block.prefix { $0 != 13 && $0 != 10 }, encoding: .utf8)
                ?? "non-UTF8 request line"
            diagnose("rejected HTTP proxy request: \(firstLine.prefix(200))")
            sendHTTP(client, status: 400, reason: "Bad Request", deadline: headerDeadline)
            return
        }
        guard authenticated(request.headers) else {
            diagnose("HTTP proxy authentication required")
            sendProxyAuthenticationRequired(client, deadline: headerDeadline)
            return
        }
        guard !isStopped,
              let addresses = permittedAddresses(
                host: request.host, port: request.port, scheme: request.scheme)
        else {
            diagnose("destination policy rejected \(request.scheme)://\(request.host):\(request.port)")
            sendHTTP(client, status: 403, reason: "Forbidden", deadline: headerDeadline)
            return
        }

        let connectDeadline = boundedDeadline(after: limits.connectTimeoutNanoseconds)
        guard let upstream = connectPinned(
            addresses: addresses, port: request.port, deadline: connectDeadline)
        else {
            diagnose("pinned upstream connect failed for \(request.host):\(request.port)")
            sendHTTP(client, status: 502, reason: "Bad Gateway", deadline: connectDeadline)
            return
        }
        defer { releaseOwnedFD(upstream, isClient: false) }

        switch request.mode {
        case .connect:
            guard writeAll(
                client,
                bytes: Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                deadline: connectDeadline)
            else { return }
            tunnel(client, upstream)

        case .forward(let originTarget, let isUpgrade):
            guard let forwarded = Self.forwardedHeader(request, originTarget: originTarget),
                  charge(forwarded.count),
                  writeAll(upstream, bytes: forwarded, deadline: connectDeadline)
            else { return }
            if request.contentLength > 0 {
                let bodyDeadline = boundedDeadline(after: limits.handshakeTimeoutNanoseconds)
                guard let body = readExact(
                    client, count: request.contentLength, deadline: bodyDeadline),
                    charge(body.count),
                    writeAll(upstream, bytes: body, deadline: connectDeadline)
                else { return }
            }
            if isUpgrade {
                tunnel(client, upstream)
            } else {
                relayResponse(upstream, to: client)
            }
        }
    }

    func permittedAddresses(
        host rawHost: String,
        port: UInt16,
        scheme rawScheme: String? = nil
    ) -> [String]? {
        guard !isStopped, !lifetimeExpired else { return nil }
        guard let host = WebFetchTool.normalizedHostPattern(rawHost),
              !host.hasPrefix("*."),
              WebFetchTool.allowlistBlockReason(
                host: host,
                configured: configuredAllowedHosts,
                perCall: perCallAllowedHosts) == nil
        else { return nil }

        if let localCaptureScheme, let localCaptureHost, let localCapturePort,
           rawScheme?.lowercased() == localCaptureScheme,
           host == localCaptureHost,
           port == localCapturePort {
            if host == "localhost" { return ["127.0.0.1"] }
            guard let parsed = WebFetchTool.parsedIPAddress(host),
                  Self.isLoopback(parsed) else { return nil }
            return [parsed.literal]
        }

        if let literal = WebFetchTool.parsedIPAddress(host) {
            return WebFetchTool.isGlobalUnicastAddress(literal) ? [literal.literal] : nil
        }
        guard chargeDNSResolution() else { return nil }
        let resolution = resolver(host, PublicWebTransport.resolverTimeoutSeconds)
        guard !isStopped, !lifetimeExpired,
              resolution.reason == nil,
              !resolution.addresses.isEmpty,
              resolution.addresses.count <= limits.maxResolvedAddresses
        else { return nil }

        var addresses: [String] = []
        var seen = Set<String>()
        for raw in resolution.addresses {
            guard let parsed = WebFetchTool.parsedIPAddress(raw),
                  WebFetchTool.isGlobalUnicastAddress(parsed)
            else { return nil }
            if seen.insert(parsed.literal).inserted { addresses.append(parsed.literal) }
        }
        return !isStopped && !lifetimeExpired && !addresses.isEmpty ? addresses : nil
    }

    private func authenticated(_ headers: [HTTPHeader]) -> Bool {
        guard let supplied = headers.first(where: {
            $0.lowerName == "proxy-authorization"
        })?.value else { return false }
        let raw = "\(proxyUsername):\(proxyPassword)"
        let expected = "Basic " + Data(raw.utf8).base64EncodedString()
        return Self.constantTimeEqual(Array(supplied.utf8), Array(expected.utf8)) && !isStopped
    }

    private func connectPinned(addresses: [String], port: UInt16, deadline: UInt64) -> Int32? {
        for address in addresses {
            guard !isStopped, Self.remainingMilliseconds(until: deadline) > 0 else { return nil }
            var hints = addrinfo()
            hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = Self.streamSocketType
            hints.ai_protocol = Int32(IPPROTO_TCP)
            var result: UnsafeMutablePointer<addrinfo>?
            let service = String(port)
            let rc = address.withCString { hostPointer in
                service.withCString { servicePointer in
                    getaddrinfo(hostPointer, servicePointer, &hints, &result)
                }
            }
            guard rc == 0, let first = result, !isStopped else { continue }
            defer { freeaddrinfo(result) }

            let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            Self.setNoSIGPIPE(fd)
            guard registerOwnedFD(fd) else { close(fd); return nil }

            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                releaseOwnedFD(fd, isClient: false)
                continue
            }
            let connected = Self.systemConnect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen)
            if connected == 0 {
                guard !isStopped else {
                    releaseOwnedFD(fd, isClient: false)
                    return nil
                }
                _ = fcntl(fd, F_SETFL, flags)
                return fd
            }
            guard errno == EINPROGRESS else {
                releaseOwnedFD(fd, isClient: false)
                continue
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let polled = poll(&descriptor, 1, Self.remainingMilliseconds(until: deadline))
            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout.size(ofValue: socketError))
            let gotError = getsockopt(
                fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0
            guard polled > 0, gotError, socketError == 0, !isStopped else {
                releaseOwnedFD(fd, isClient: false)
                continue
            }
            _ = fcntl(fd, F_SETFL, flags)
            return fd
        }
        return nil
    }

    private func registerOwnedFD(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, !lifetimeExpiredLocked else { return false }
        ownedFDs.insert(fd)
        return true
    }

    private func releaseOwnedFD(_ fd: Int32, isClient: Bool) {
        lock.lock()
        let owned = ownedFDs.remove(fd) != nil
        if isClient { clientFDs.remove(fd) }
        lock.unlock()
        if owned { close(fd) }
    }

    private func tunnel(_ client: Int32, _ upstream: Int32) {
        let state = TunnelState()
        Thread.detachNewThread { [self] in
            pump(
                source: client, destination: upstream,
                client: client, upstream: upstream, state: state)
        }
        Thread.detachNewThread { [self] in
            pump(
                source: upstream, destination: client,
                client: client, upstream: upstream, state: state)
        }
        state.waitForBothPumps()
    }

    private func pump(
        source: Int32,
        destination: Int32,
        client: Int32,
        upstream: Int32,
        state: TunnelState
    ) {
        defer { state.finishPump() }
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while !isStopped && !lifetimeExpired {
            var descriptor = pollfd(fd: source, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 1_000)
            if ready < 0 {
                if errno == EINTR { continue }
                failTunnel(client: client, upstream: upstream)
                return
            }
            if ready == 0 {
                if state.isIdle(for: limits.idleTimeoutNanoseconds) {
                    failTunnel(client: client, upstream: upstream)
                    return
                }
                continue
            }
            let events = descriptor.revents
            if events & Int16(POLLNVAL | POLLERR) != 0 {
                failTunnel(client: client, upstream: upstream)
                return
            }
            if events & Int16(POLLIN) != 0 {
                let count = recv(source, &buffer, buffer.count, 0)
                if count == 0 {
                    _ = shutdown(destination, Self.shutdownWrite)
                    return
                }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    failTunnel(client: client, upstream: upstream)
                    return
                }
                guard charge(Int(count)),
                      writeAll(
                        destination,
                        bytes: Array(buffer.prefix(Int(count))),
                        deadline: boundedDeadline(after: limits.idleTimeoutNanoseconds))
                else {
                    failTunnel(client: client, upstream: upstream)
                    return
                }
                state.touch()
                continue
            }
            if events & Int16(POLLHUP) != 0 {
                _ = shutdown(destination, Self.shutdownWrite)
                return
            }
        }
    }

    private func relayResponse(_ upstream: Int32, to client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 32_768)
        var lastActivity = DispatchTime.now().uptimeNanoseconds
        while !isStopped && !lifetimeExpired {
            var descriptor = pollfd(fd: upstream, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 1_000)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 {
                if DispatchTime.now().uptimeNanoseconds - lastActivity
                    >= limits.idleTimeoutNanoseconds { return }
                continue
            }
            if descriptor.revents & Int16(POLLNVAL | POLLERR) != 0 { return }
            if descriptor.revents & Int16(POLLIN) != 0 {
                let count = recv(upstream, &buffer, buffer.count, 0)
                if count == 0 { return }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    return
                }
                guard charge(Int(count)),
                      writeAll(
                        client,
                        bytes: Array(buffer.prefix(Int(count))),
                        deadline: boundedDeadline(after: limits.idleTimeoutNanoseconds))
                else { return }
                lastActivity = DispatchTime.now().uptimeNanoseconds
                continue
            }
            if descriptor.revents & Int16(POLLHUP) != 0 { return }
        }
    }

    private func failTunnel(client: Int32, upstream: Int32) {
        _ = shutdown(client, Self.shutdownBoth)
        _ = shutdown(upstream, Self.shutdownBoth)
    }

    private func charge(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped,
              count >= 0,
              count <= limits.maxAggregateBytes,
              aggregateBytes <= limits.maxAggregateBytes - count
        else { return false }
        aggregateBytes += count
        return true
    }

    private func chargeDNSResolution() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, !lifetimeExpiredLocked,
              dnsResolutions < limits.maxDNSResolutions else { return false }
        dnsResolutions += 1
        return true
    }

    private func readHeaderBlock(_ fd: Int32, deadline: UInt64) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(limits.maxHeaderBytes, 4_096))
        var byte: UInt8 = 0
        while bytes.count < limits.maxHeaderBytes {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Self.remainingMilliseconds(until: deadline)) > 0,
                  descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0,
                  recv(fd, &byte, 1, 0) == 1
            else { return nil }
            let previous = bytes.last
            bytes.append(byte)
            if byte == 10 && previous != 13 { return nil }
            if previous == 13 && byte != 10 { return nil }
            if bytes.count >= 4 && bytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
                return bytes
            }
        }
        return nil
    }

    private func readExact(_ fd: Int32, count: Int, deadline: UInt64) -> [UInt8]? {
        guard count >= 0 else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: max(1, min(count, 4_096)))
        while output.count < count {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Self.remainingMilliseconds(until: deadline)) > 0,
                  descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0
            else { return nil }
            let wanted = min(buffer.count, count - output.count)
            let received = recv(fd, &buffer, wanted, 0)
            guard received > 0 else { return nil }
            output.append(contentsOf: buffer.prefix(Int(received)))
        }
        return output
    }

    @discardableResult
    private func writeAll(_ fd: Int32, bytes: [UInt8], deadline: UInt64) -> Bool {
        var offset = 0
        while offset < bytes.count {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, Self.remainingMilliseconds(until: deadline)) > 0,
                  descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0
            else { return false }
            let sent = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Self.sendNoSignal(
                    fd, base.advanced(by: offset), bytes.count - offset)
            }
            guard sent > 0 else { return false }
            offset += sent
        }
        return true
    }

    private func sendProxyAuthenticationRequired(_ fd: Int32, deadline: UInt64) {
        let response = "HTTP/1.1 407 Proxy Authentication Required\r\n"
            + "Proxy-Authenticate: Basic realm=\"kist-browser\"\r\n"
            + "Connection: close\r\nContent-Length: 0\r\n\r\n"
        _ = writeAll(fd, bytes: Array(response.utf8), deadline: deadline)
    }

    private func sendHTTP(_ fd: Int32, status: Int, reason: String, deadline: UInt64) {
        let response = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Connection: close\r\nContent-Length: 0\r\n\r\n"
        _ = writeAll(fd, bytes: Array(response.utf8), deadline: deadline)
    }

    private func diagnose(_ message: String) {
        guard ProcessInfo.processInfo.environment["KIST_BROWSER_PROXY_DEBUG"] == "1" else { return }
        let line = "kist browser proxy: \(message)\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private var lifetimeExpired: Bool {
        lock.lock(); defer { lock.unlock() }
        return lifetimeExpiredLocked
    }

    private var lifetimeExpiredLocked: Bool {
        DispatchTime.now().uptimeNanoseconds - startedNanoseconds
            >= limits.maxLifetimeNanoseconds
    }

    private func boundedDeadline(after interval: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let intervalDeadline = now.addingReportingOverflow(interval)
        let lifetimeDeadline = startedNanoseconds.addingReportingOverflow(
            limits.maxLifetimeNanoseconds)
        let first = intervalDeadline.overflow ? UInt64.max : intervalDeadline.partialValue
        let second = lifetimeDeadline.overflow ? UInt64.max : lifetimeDeadline.partialValue
        return min(first, second)
    }

    private struct HTTPHeader: Sendable {
        let name: String
        let lowerName: String
        let value: String
    }

    private struct HTTPRequest: Sendable {
        enum Mode: Sendable {
            case connect
            case forward(originTarget: String, isUpgrade: Bool)
        }

        let method: String
        let version: String
        let host: String
        let port: UInt16
        let scheme: String
        let headers: [HTTPHeader]
        let contentLength: Int
        let mode: Mode
    }

    private static func parseRequest(_ bytes: [UInt8], maxBodyBytes: Int) -> HTTPRequest? {
        guard bytes.count >= 4,
              bytes.suffix(4).elementsEqual([13, 10, 13, 10]),
              !bytes.contains(0),
              validCRLF(bytes),
              let text = String(bytes: bytes, encoding: .utf8)
        else { return nil }

        var lines = text.components(separatedBy: "\r\n")
        guard lines.count >= 3,
              lines.removeLast().isEmpty,
              lines.removeLast().isEmpty
        else { return nil }

        let requestParts = lines.removeFirst().split(
            separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3,
              requestParts.allSatisfy({ !$0.isEmpty }),
              validToken(String(requestParts[0])),
              requestParts[2] == "HTTP/1.1"
        else { return nil }

        var headers: [HTTPHeader] = []
        var sensitiveCounts: [String: Int] = [:]
        let duplicateSensitive = Set([
            "host", "proxy-authorization", "proxy-connection",
            "content-length", "transfer-encoding", "connection", "upgrade",
        ])
        for line in lines {
            guard !line.isEmpty,
                  line.first != " ", line.first != "\t",
                  let colon = line.firstIndex(of: ":")
            else { return nil }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            let lower = name.lowercased()
            guard validToken(name), validHeaderValue(value) else { return nil }
            sensitiveCounts[lower, default: 0] += 1
            if duplicateSensitive.contains(lower), sensitiveCounts[lower] != 1 { return nil }
            headers.append(HTTPHeader(name: name, lowerName: lower, value: value))
        }

        guard sensitiveCounts["host"] == 1,
              sensitiveCounts["transfer-encoding"] == nil
        else { return nil }

        let contentLength: Int
        if let raw = headers.first(where: { $0.lowerName == "content-length" })?.value {
            guard !raw.isEmpty,
                  raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let parsed = Int(raw),
                  parsed <= maxBodyBytes
            else { return nil }
            contentLength = parsed
        } else {
            contentLength = 0
        }

        let method = String(requestParts[0])
        let target = String(requestParts[1])
        let version = String(requestParts[2])
        let hostHeader = headers.first(where: { $0.lowerName == "host" })!.value
        let forwardMethods: Set<String> = [
            "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS",
        ]
        guard method == "CONNECT" || forwardMethods.contains(method) else { return nil }
        if method == "CONNECT" {
            guard contentLength == 0,
                  let authority = parseAuthority(target, defaultPort: nil),
                  authority.port > 0,
                  authorityMatches(hostHeader, host: authority.host, port: authority.port)
            else { return nil }
            return HTTPRequest(
                method: method,
                version: version,
                host: authority.host,
                port: authority.port,
                scheme: "https",
                headers: headers,
                contentLength: 0,
                mode: .connect)
        }

        guard let components = URLComponents(string: target),
              let absoluteScheme = components.scheme?.lowercased(),
              absoluteScheme == "http" || absoluteScheme == "ws",
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let host = components.host,
              let normalizedHost = WebFetchTool.normalizedHostPattern(host),
              !normalizedHost.hasPrefix("*.")
        else { return nil }
        let portValue = components.port ?? 80
        guard let port = UInt16(exactly: portValue), port > 0,
              authorityMatches(hostHeader, host: normalizedHost, port: port)
        else { return nil }

        var originTarget = components.percentEncodedPath
        if originTarget.isEmpty { originTarget = "/" }
        if let query = components.percentEncodedQuery { originTarget += "?" + query }
        let connection = headers.first(where: {
            $0.lowerName == "connection"
        })?.value.lowercased()
        let upgrade = headers.first(where: {
            $0.lowerName == "upgrade"
        })?.value.lowercased()
        let isUpgrade = connection?.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.contains("upgrade") == true && upgrade == "websocket"
        if absoluteScheme == "ws" && (method != "GET" || !isUpgrade) { return nil }

        return HTTPRequest(
            method: method,
            version: version,
            host: normalizedHost,
            port: port,
            scheme: "http",
            headers: headers,
            contentLength: contentLength,
            mode: .forward(originTarget: originTarget, isUpgrade: isUpgrade))
    }

    private static func forwardedHeader(
        _ request: HTTPRequest,
        originTarget: String
    ) -> [UInt8]? {
        guard case .forward(_, let isUpgrade) = request.mode else { return nil }
        var output = "\(request.method) \(originTarget) \(request.version)\r\n"
        for header in request.headers {
            if header.lowerName == "proxy-authorization"
                || header.lowerName == "proxy-connection"
                || header.lowerName == "connection" {
                continue
            }
            output += "\(header.name): \(header.value)\r\n"
        }
        output += isUpgrade ? "Connection: Upgrade\r\n" : "Connection: close\r\n"
        output += "\r\n"
        return Array(output.utf8)
    }

    private static func authorityMatches(
        _ raw: String,
        host expectedHost: String,
        port expectedPort: UInt16
    ) -> Bool {
        guard let parsed = parseAuthority(raw, defaultPort: expectedPort),
              let lhs = WebFetchTool.normalizedHostPattern(parsed.host),
              let rhs = WebFetchTool.normalizedHostPattern(expectedHost)
        else { return false }
        return lhs == rhs && parsed.port == expectedPort
    }

    private static func parseAuthority(
        _ raw: String,
        defaultPort: UInt16?
    ) -> (host: String, port: UInt16)? {
        guard !raw.isEmpty, !raw.contains("@"), !raw.contains("/") else { return nil }
        let host: String
        let portText: String?
        if raw.hasPrefix("[") {
            guard let close = raw.firstIndex(of: "]") else { return nil }
            host = String(raw[raw.index(after: raw.startIndex)..<close])
            let rest = raw[raw.index(after: close)...]
            if rest.isEmpty {
                portText = nil
            } else {
                guard rest.first == ":" else { return nil }
                portText = String(rest.dropFirst())
            }
        } else {
            let colons = raw.filter { $0 == ":" }.count
            if colons == 0 {
                host = raw
                portText = nil
            } else if colons == 1, let colon = raw.lastIndex(of: ":") {
                host = String(raw[..<colon])
                portText = String(raw[raw.index(after: colon)...])
            } else {
                return nil
            }
        }
        guard let normalized = WebFetchTool.normalizedHostPattern(host),
              !normalized.hasPrefix("*.")
        else { return nil }

        if let portText {
            guard !portText.isEmpty,
                  portText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let port = UInt16(portText),
                  port > 0
            else { return nil }
            return (normalized, port)
        }
        guard let defaultPort else { return nil }
        return (normalized, defaultPort)
    }

    private static func validCRLF(_ bytes: [UInt8]) -> Bool {
        for index in bytes.indices {
            if bytes[index] == 13 {
                guard index + 1 < bytes.count, bytes[index + 1] == 10 else { return false }
            }
            if bytes[index] == 10 {
                guard index > 0, bytes[index - 1] == 13 else { return false }
            }
        }
        return true
    }

    private static func validToken(_ value: String) -> Bool {
        let separators = Set("()<>@,;:\\\"/[]?={} \t".utf8)
        return !value.isEmpty && value.utf8.allSatisfy {
            $0 > 0x20 && $0 < 0x7f && !separators.contains($0)
        }
    }

    private static func validHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 == 9 || ($0 >= 0x20 && $0 != 0x7f) }
    }

    private static func makeCredential() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map {
            _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }

    private static func isLoopback(_ address: WebFetchTool.ParsedIPAddress) -> Bool {
        if address.family == AF_INET { return address.bytes.first == 127 }
        guard address.family == AF_INET6, address.bytes.count == 16 else { return false }
        return address.bytes.dropLast().allSatisfy { $0 == 0 } && address.bytes.last == 1
    }

    private static func remainingMilliseconds(until deadline: UInt64) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return 0 }
        return Int32(min(
            UInt64(Int32.max),
            max(1, (deadline - now) / 1_000_000)))
    }

    private struct ProxyError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static var streamSocketType: Int32 {
        #if canImport(Darwin)
        return SOCK_STREAM
        #else
        return Int32(SOCK_STREAM.rawValue)
        #endif
    }

    private static var shutdownBoth: Int32 {
        #if canImport(Darwin)
        return SHUT_RDWR
        #else
        return Int32(SHUT_RDWR)
        #endif
    }

    private static var shutdownWrite: Int32 {
        #if canImport(Darwin)
        return SHUT_WR
        #else
        return Int32(SHUT_WR)
        #endif
    }

    private final class TunnelState: @unchecked Sendable {
        private let condition = NSCondition()
        private var finishedPumps = 0
        private var lastActivity = DispatchTime.now().uptimeNanoseconds

        func touch() {
            condition.lock()
            lastActivity = DispatchTime.now().uptimeNanoseconds
            condition.unlock()
        }

        func isIdle(for timeout: UInt64) -> Bool {
            condition.lock(); defer { condition.unlock() }
            return DispatchTime.now().uptimeNanoseconds - lastActivity >= timeout
        }

        func finishPump() {
            condition.lock()
            finishedPumps += 1
            condition.broadcast()
            condition.unlock()
        }

        func waitForBothPumps() {
            condition.lock()
            while finishedPumps < 2 { condition.wait() }
            condition.unlock()
        }
    }

    private final class AcceptWorkerState: @unchecked Sendable {
        private let condition = NSCondition()
        private var active = false

        func begin() {
            condition.lock()
            active = true
            condition.unlock()
        }

        func finish() {
            condition.lock()
            active = false
            condition.broadcast()
            condition.unlock()
        }

        func waitUntilFinished() {
            condition.lock()
            while active { condition.wait() }
            condition.unlock()
        }
    }

    private static func setNoSIGPIPE(_ fd: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &one,
            socklen_t(MemoryLayout.size(ofValue: one)))
        #endif
    }

    private static func sendNoSignal(
        _ fd: Int32,
        _ bytes: UnsafeRawPointer,
        _ count: Int
    ) -> Int {
        #if canImport(Darwin)
        return send(fd, bytes, count, 0)
        #else
        return send(fd, bytes, count, Int32(MSG_NOSIGNAL))
        #endif
    }

    private static func systemConnect(
        _ fd: Int32,
        _ address: UnsafePointer<sockaddr>?,
        _ length: socklen_t
    ) -> Int32 {
        #if canImport(Darwin)
        return Darwin.connect(fd, address, length)
        #else
        return Glibc.connect(fd, address, length)
        #endif
    }
}
