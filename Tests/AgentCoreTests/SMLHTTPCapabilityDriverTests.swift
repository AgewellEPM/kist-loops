import XCTest
@testable import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class SMLHTTPCapabilityDriverTests: XCTestCase {
    func testDriverBuildsOnlyThePinnedRequestAndEvidenceOmitsInputsAndSecrets() async throws {
        let endpoint = SMLHTTPEndpointSpec(
            capability: "pets.update",
            method: .post,
            pathTemplate: "/pets/{pet-id}",
            servers: [.init(
                scheme: "https", host: "api.example.com", port: 8_443, basePath: "/v1")],
            parameters: [
                .init(
                    name: "pet-id", location: .path, required: true,
                    stateField: "pet_id", valueType: .string),
                .init(
                    name: "tag", location: .query, required: false,
                    stateField: "tags", valueType: .array, explode: true),
                .init(
                    name: "X-Tenant", location: .header, required: true,
                    stateField: "tenant", valueType: .string),
            ],
            requestBody: .init(
                required: true, stateField: "request_body", valueType: .object,
                maximumBytes: 1_024),
            authentication: [.init(schemes: [.init(
                credentialID: "pets.key", kind: .apiKeyHeader, headerName: "X-API-Key")])],
            timeoutSeconds: 4,
            maximumResponseBytes: 1_024
        )
        let registry = try registry(endpoint)
        let secret = "TEST-SECRET-MUST-NOT-LEAK"
        let authentication = SMLHTTPAuthenticationStore(credentials: [
            "pets.key": .init(value: secret, username: nil, password: nil, scopes: []),
        ])
        let responseBody = Data(#"{"ok":true}"#.utf8)
        let transport = RecordingHTTPTransport(response: .init(
            statusCode: 200, body: responseBody))
        let driver = try SMLHTTPCapabilityDriver(
            registry: registry,
            authentication: authentication,
            transport: transport,
            clock: { 2_000 }
        )
        let request = capabilityRequest(
            reference: endpoint.capability,
            arguments: ["output_field": .string("response_body")],
            state: [
                "pet_id": .string("a/b"),
                "tags": .array([.string("one two"), .string("x&y")]),
                "tenant": .string("tenant-7"),
                "request_body": .object(["name": .string("Milo")]),
            ]
        )

        let outcome = try await driver.execute(invocation(request, driverID: driver.id))

        XCTAssertEqual(outcome.status, .passed)
        XCTAssertEqual(outcome.statePatch, ["response_body": .string(#"{"ok":true}"#)])
        let capturedRequest = await transport.lastRequest()
        let sent = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            sent.url?.absoluteString,
            "https://api.example.com:8443/v1/pets/a%2Fb?tag=one%20two&tag=x%26y"
        )
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-API-Key"), secret)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Tenant"), "tenant-7")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(sent.httpBody, Data(#"{"name":"Milo"}"#.utf8))

        let responseDigest = MythosCrypto.sha256(responseBody)
            .map { String(format: "%02x", $0) }.joined()
        let expectedEvidence: SMLObject = [
            "capability": .string(endpoint.capability),
            "method": .string("POST"),
            "origin": .string("https://api.example.com:8443"),
            "category": .string("success"),
            "response_bytes": .number(11),
            "response_digest": .string(responseDigest),
            "status_code": .number(200),
        ]
        XCTAssertEqual(
            outcome.evidence.digest,
            SMLCapabilityDriverSupport.evidenceDigest(expectedEvidence),
            "evidence must be exactly the fixed metadata contract, without secret/request values"
        )
        XCTAssertFalse(outcome.evidence.receiptID.contains(secret))
    }

    func testUnknownArgumentFailsBeforeTransportAndCannotOverrideURL() async throws {
        let endpoint = simpleEndpoint(serverPort: 8_443, scheme: "https", host: "example.com")
        let transport = RecordingHTTPTransport(response: .init(statusCode: 200, body: Data()))
        let driver = try SMLHTTPCapabilityDriver(
            registry: try registry(endpoint),
            authentication: .init(),
            transport: transport
        )
        let request = capabilityRequest(
            reference: endpoint.capability,
            arguments: ["url": .string("http://127.0.0.1/admin")]
        )

        let outcome = try await driver.execute(invocation(request, driverID: driver.id))

        XCTAssertEqual(outcome.status, .failed)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testMissingCredentialFailsAtDriverLaunchBeforeAnyRequestCanRun() throws {
        let endpoint = SMLHTTPEndpointSpec(
            capability: "secure.get",
            method: .get,
            pathTemplate: "/secure",
            servers: [.init(scheme: "https", host: "example.com")],
            authentication: [.init(schemes: [.init(
                credentialID: "secure.token", kind: .bearer)])]
        )

        XCTAssertThrowsError(try SMLHTTPCapabilityDriver(
            registry: try registry(endpoint), authentication: .init()
        )) { error in
            XCTAssertEqual(
                error as? SMLHTTPExecutionError,
                .missingCredentials("secure.get")
            )
        }
    }

    func testNonSuccessStatusCompletesAsFailedWithoutPersistingRemoteBody() async throws {
        let endpoint = simpleEndpoint(serverPort: 8_443, scheme: "https", host: "example.com")
        let remoteBody = Data("REMOTE-SENSITIVE-ERROR".utf8)
        let transport = RecordingHTTPTransport(response: .init(
            statusCode: 401, body: remoteBody))
        let driver = try SMLHTTPCapabilityDriver(
            registry: try registry(endpoint),
            authentication: .init(),
            transport: transport,
            clock: { 2_000 }
        )

        let outcome = try await driver.execute(invocation(
            capabilityRequest(reference: endpoint.capability), driverID: driver.id))

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.statePatch.isEmpty)
        XCTAssertFalse(outcome.evidence.receiptID.contains("REMOTE-SENSITIVE-ERROR"))
    }

    func testWriteResponseFailuresRemainUncertainAndNonReplayable() async throws {
        let endpoint = SMLHTTPEndpointSpec(
            capability: "simple.post",
            method: .post,
            pathTemplate: "/value",
            servers: [.init(scheme: "https", host: "example.com")],
            maximumResponseBytes: 1_024
        )
        let cases: [(SMLHTTPTransportResponse, String)] = [
            (.init(statusCode: 500, body: Data()), "http_status_after_write"),
            (.init(statusCode: 302, body: Data()), "redirect_after_write"),
            (.init(statusCode: 200, body: Data([0xff])), "invalid_response_after_write"),
        ]

        for (response, category) in cases {
            let driver = try SMLHTTPCapabilityDriver(
                registry: try registry(endpoint),
                authentication: .init(),
                transport: RecordingHTTPTransport(response: response)
            )
            do {
                _ = try await driver.execute(invocation(
                    capabilityRequest(reference: endpoint.capability), driverID: driver.id))
                XCTFail("a write with an unprovable result must remain an uncertain dispatch")
            } catch let error as SMLHTTPExecutionError {
                XCTAssertEqual(error, .uncertain(
                    capability: endpoint.capability, category: category))
            }
        }
    }

    func testTransportUncertaintyThrowsFixedCategory() async throws {
        let endpoint = simpleEndpoint(serverPort: 8_443, scheme: "https", host: "example.com")
        let transport = RecordingHTTPTransport(error: .responseTooLarge)
        let driver = try SMLHTTPCapabilityDriver(
            registry: try registry(endpoint), authentication: .init(), transport: transport)

        do {
            _ = try await driver.execute(invocation(
                capabilityRequest(reference: endpoint.capability), driverID: driver.id))
            XCTFail("an incomplete response is an uncertain, non-replayable dispatch")
        } catch let error as SMLHTTPExecutionError {
            XCTAssertEqual(error, .uncertain(
                capability: endpoint.capability, category: "response_too_large"))
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testTransportContractCannotReturnAnOversizedSuccessfulBody() async throws {
        let endpoint = SMLHTTPEndpointSpec(
            capability: "bounded.mock",
            method: .get,
            pathTemplate: "/bounded",
            servers: [.init(scheme: "https", host: "example.com")],
            maximumResponseBytes: 8)
        let transport = RecordingHTTPTransport(response: .init(
            statusCode: 200, body: Data(repeating: 0x61, count: 9)))
        let driver = try SMLHTTPCapabilityDriver(
            registry: try registry(endpoint), authentication: .init(), transport: transport)

        do {
            _ = try await driver.execute(invocation(
                capabilityRequest(reference: endpoint.capability), driverID: driver.id))
            XCTFail("an oversized body must remain an uncertain dispatch")
        } catch let error as SMLHTTPExecutionError {
            XCTAssertEqual(error, .uncertain(
                capability: endpoint.capability, category: "response_too_large"))
        }
    }

    func testTransportContractBoundsFailureBodiesAndStatusCodes() async throws {
        let endpoint = SMLHTTPEndpointSpec(
            capability: "bounded.failure",
            method: .get,
            pathTemplate: "/bounded",
            servers: [.init(scheme: "https", host: "example.com")],
            maximumResponseBytes: 8)
        for response in [
            SMLHTTPTransportResponse(statusCode: 500, body: Data(repeating: 0x61, count: 9)),
            SMLHTTPTransportResponse(statusCode: 999, body: Data()),
        ] {
            let driver = try SMLHTTPCapabilityDriver(
                registry: try registry(endpoint),
                authentication: .init(),
                transport: RecordingHTTPTransport(response: response))
            do {
                _ = try await driver.execute(invocation(
                    capabilityRequest(reference: endpoint.capability), driverID: driver.id))
                XCTFail("invalid transport response must remain uncertain")
            } catch {
                guard case .uncertain = error as? SMLHTTPExecutionError else {
                    return XCTFail("invalid transport response must remain uncertain: \(error)")
                }
            }
        }
    }

    func testOversizedDynamicURLFailsBeforeTransport() async throws {
        let endpoint = SMLHTTPEndpointSpec(
            capability: "bounded.query",
            method: .get,
            pathTemplate: "/bounded",
            servers: [.init(scheme: "https", host: "example.com")],
            parameters: [.init(
                name: "query", location: .query, required: true,
                stateField: "query", valueType: .string)],
            maximumResponseBytes: 1_024)
        let transport = RecordingHTTPTransport(response: .init(statusCode: 200, body: Data()))
        let driver = try SMLHTTPCapabilityDriver(
            registry: try registry(endpoint), authentication: .init(), transport: transport)

        let outcome = try await driver.execute(invocation(
            capabilityRequest(
                reference: endpoint.capability,
                state: ["query": .string(String(repeating: "/", count: 30_000))]),
            driverID: driver.id))

        XCTAssertEqual(outcome.status, .failed)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testC1ControlInDynamicHeaderFailsBeforeTransport() async throws {
        let endpoint = SMLHTTPEndpointSpec(
            capability: "bounded.header",
            method: .get,
            pathTemplate: "/bounded",
            servers: [.init(scheme: "https", host: "example.com")],
            parameters: [.init(
                name: "X-Value", location: .header, required: true,
                stateField: "header_value", valueType: .string)]
        )
        let transport = RecordingHTTPTransport(response: .init(statusCode: 200, body: Data()))
        let driver = try SMLHTTPCapabilityDriver(
            registry: try registry(endpoint), authentication: .init(), transport: transport)

        let outcome = try await driver.execute(invocation(
            capabilityRequest(
                reference: endpoint.capability,
                state: ["header_value": .string("unsafe\u{0085}value")]),
            driverID: driver.id))

        XCTAssertEqual(outcome.status, .failed)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testEndpointConfigurationRejectsStateAndAuthorizationCollisions() {
        let stateCollision = SMLHTTPEndpointSpec(
            capability: "collision.state",
            method: .get,
            pathTemplate: "/value",
            servers: [.init(scheme: "https", host: "example.com")],
            parameters: [.init(
                name: "value", location: .query, required: false,
                stateField: "response_body")],
            responseStateField: "response_body")
        XCTAssertThrowsError(try registry(stateCollision))

        let authorizationCollision = SMLHTTPEndpointSpec(
            capability: "collision.auth",
            method: .get,
            pathTemplate: "/value",
            servers: [.init(scheme: "https", host: "example.com")],
            authentication: [.init(schemes: [
                .init(credentialID: "one", kind: .bearer),
                .init(credentialID: "two", kind: .oauth2Bearer),
            ])])
        XCTAssertThrowsError(try registry(authorizationCollision))

        let headerCaseCollision = SMLHTTPEndpointSpec(
            capability: "collision.headers",
            method: .get,
            pathTemplate: "/value",
            servers: [.init(scheme: "https", host: "example.com")],
            parameters: [
                .init(name: "X-Tenant", location: .header, required: false,
                      stateField: "tenant_one"),
                .init(name: "x-tenant", location: .header, required: false,
                      stateField: "tenant_two"),
            ])
        XCTAssertThrowsError(try registry(headerCaseCollision))

        let noncanonicalBase = SMLHTTPEndpointSpec(
            capability: "collision.base",
            method: .get,
            pathTemplate: "/value",
            servers: [.init(scheme: "https", host: "example.com", basePath: "/v1/")])
        XCTAssertThrowsError(try registry(noncanonicalBase))

        let wildcardServer = SMLHTTPEndpointSpec(
            capability: "collision.wildcard",
            method: .get,
            pathTemplate: "/value",
            servers: [.init(scheme: "https", host: "*.example.com")])
        XCTAssertThrowsError(try registry(wildcardServer))
    }

    func testRegistryRequiresOwnerOnlyEndpointBundles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-http-endpoints-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent(
            SMLHTTPEndpointRegistry.relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = SMLHTTPEndpointBundle(
            apiID: "test.api",
            sourceDigest: String(repeating: "a", count: 64),
            endpoints: [simpleEndpoint(
                serverPort: 8_443, scheme: "https", host: "example.com")]
        )
        let path = directory.appendingPathComponent("test.json")
        try JSONEncoder().encode(bundle).write(to: path)
        XCTAssertEqual(chmod(path.path, 0o644), 0)

        XCTAssertThrowsError(try SMLHTTPEndpointRegistry.load(projectRoot: root.path))
        XCTAssertEqual(chmod(path.path, 0o600), 0)
        XCTAssertEqual(
            Set(try SMLHTTPEndpointRegistry.load(projectRoot: root.path).endpoints.keys),
            ["simple.get"]
        )
    }

    func testProductionTransportRefusesRedirectWithoutContactingTarget() async throws {
        let target = try makeSMLHTTPTestListener()
        defer { close(target.fd) }
        let redirect = try makeSMLHTTPTestListener()
        defer { close(redirect.fd) }
        let redirectResponse = "HTTP/1.1 302 Found\r\n"
            + "Location: http://127.0.0.1:\(target.port)/stolen\r\n"
            + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        let redirectTask = serveOneSMLHTTPRequest(
            listener: redirect.fd, response: Data(redirectResponse.utf8))
        let secret = "REDIRECT-SECRET-MUST-STAY-AT-SOURCE"
        let endpoint = SMLHTTPEndpointSpec(
            capability: "redirect.get",
            method: .get,
            pathTemplate: "/start",
            servers: [.init(
                scheme: "http", host: "127.0.0.1", port: Int(redirect.port))],
            authentication: [.init(schemes: [.init(
                credentialID: "redirect.key", kind: .apiKeyHeader,
                headerName: "X-Test-Key")])],
            maximumResponseBytes: 1_024
        )
        let authentication = SMLHTTPAuthenticationStore(credentials: [
            "redirect.key": .init(value: secret, username: nil, password: nil, scopes: []),
        ])
        let driver = try SMLHTTPCapabilityDriver(
            registry: try registry(endpoint), authentication: authentication)

        let outcome = try await driver.execute(invocation(
            capabilityRequest(reference: endpoint.capability), driverID: driver.id))
        let sourceRequest = try await redirectTask.value

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(sourceRequest.contains("X-Test-Key: \(secret)"))
        XCTAssertFalse(
            smlHTTPListenerHasPendingConnection(target.fd, timeoutMilliseconds: 250),
            "a refused redirect must send zero bytes to its target"
        )
    }

    func testProductionTransportRejectsOversizedContentLength() async throws {
        let server = try makeSMLHTTPTestListener()
        defer { close(server.fd) }
        let response = Data(
            ("HTTP/1.1 200 OK\r\nContent-Length: 16\r\nConnection: close\r\n\r\n"
                + "0123456789ABCDEF").utf8)
        let serverTask = serveOneSMLHTTPRequest(listener: server.fd, response: response)
        let endpoint = SMLHTTPEndpointSpec(
            capability: "bounded.get",
            method: .get,
            pathTemplate: "/large",
            servers: [.init(scheme: "http", host: "127.0.0.1", port: Int(server.port))],
            maximumResponseBytes: 8
        )
        let driver = try SMLHTTPCapabilityDriver(
            registry: try registry(endpoint), authentication: .init())

        do {
            _ = try await driver.execute(invocation(
                capabilityRequest(reference: endpoint.capability), driverID: driver.id))
            XCTFail("oversized response must remain uncertain")
        } catch let error as SMLHTTPExecutionError {
            XCTAssertEqual(error, .uncertain(
                capability: endpoint.capability, category: "response_too_large"))
        }
        _ = try await serverTask.value
    }

    func testProductionTransportRejectsOversizedStreamingBodyWithoutLength() async throws {
        let server = try makeSMLHTTPTestListener()
        defer { close(server.fd) }
        let response = Data(
            ("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n" + "0123456789ABCDEF").utf8)
        let serverTask = serveOneSMLHTTPRequest(listener: server.fd, response: response)
        let endpoint = SMLHTTPEndpointSpec(
            capability: "bounded.stream",
            method: .get,
            pathTemplate: "/large",
            servers: [.init(scheme: "http", host: "127.0.0.1", port: Int(server.port))],
            maximumResponseBytes: 8
        )
        let driver = try SMLHTTPCapabilityDriver(
            registry: try registry(endpoint), authentication: .init())

        do {
            _ = try await driver.execute(invocation(
                capabilityRequest(reference: endpoint.capability), driverID: driver.id))
            XCTFail("an oversized streaming response must remain uncertain")
        } catch let error as SMLHTTPExecutionError {
            XCTAssertEqual(error, .uncertain(
                capability: endpoint.capability, category: "response_too_large"))
        }
        _ = try await serverTask.value
    }

    private func registry(_ endpoint: SMLHTTPEndpointSpec) throws -> SMLHTTPEndpointRegistry {
        try SMLHTTPEndpointRegistry(bundles: [.init(
            apiID: "test.api",
            sourceDigest: String(repeating: "a", count: 64),
            endpoints: [endpoint]
        )])
    }

    private func simpleEndpoint(
        serverPort: Int,
        scheme: String,
        host: String
    ) -> SMLHTTPEndpointSpec {
        SMLHTTPEndpointSpec(
            capability: "simple.get",
            method: .get,
            pathTemplate: "/value",
            servers: [.init(scheme: scheme, host: host, port: serverPort)],
            maximumResponseBytes: 1_024
        )
    }

    private func capabilityRequest(
        reference: String,
        arguments: SMLObject = [:],
        state: SMLObject = [:]
    ) -> SMLCapabilityRequest {
        SMLCapabilityRequest(
            taskID: "TASK-HTTP",
            role: "operator",
            workflowID: "http.test",
            workflowVersion: "1.0.0",
            taskRevision: 2,
            instructionID: "request",
            operation: .callTool,
            reference: reference,
            arguments: arguments,
            scope: [:],
            expectedState: [:],
            state: state,
            stateDigest: String(repeating: "d", count: 64)
        )
    }

    private func invocation(
        _ request: SMLCapabilityRequest,
        driverID: String
    ) -> SMLCapabilityInvocation {
        SMLCapabilityInvocation(claimed: SMLClaimedCapability(
            request: request,
            record: SMLCapabilityClaimRecord(
                dispatchID: "dispatch-http",
                driverID: driverID,
                instructionID: request.instructionID,
                stateDigest: request.stateDigest,
                commandID: "claim-http",
                actor: "operator",
                leaseID: "lease-http",
                claimedAtEpoch: 1_000
            )
        ))
    }
}

private actor RecordingHTTPTransport: SMLHTTPTransport {
    private let response: SMLHTTPTransportResponse?
    private let error: SMLHTTPTransportError?
    private var requests: [URLRequest] = []

    init(response: SMLHTTPTransportResponse) {
        self.response = response
        error = nil
    }

    init(error: SMLHTTPTransportError) {
        response = nil
        self.error = error
    }

    func send(
        _ request: URLRequest,
        timeoutSeconds: Double,
        maximumResponseBytes: Int
    ) async throws -> SMLHTTPTransportResponse {
        requests.append(request)
        if let error { throw error }
        return response!
    }

    func lastRequest() -> URLRequest? { requests.last }
    func requestCount() -> Int { requests.count }
}

private var smlHTTPTestSocketType: Int32 {
    #if canImport(Darwin)
    return SOCK_STREAM
    #else
    return Int32(SOCK_STREAM.rawValue)
    #endif
}

private func makeSMLHTTPTestListener() throws -> (fd: Int32, port: UInt16) {
    let descriptor = socket(AF_INET, smlHTTPTestSocketType, 0)
    guard descriptor >= 0 else { throw SMLHTTPTestFailure.socket }
    var address = sockaddr_in()
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(descriptor, 1) == 0 else {
        close(descriptor)
        throw SMLHTTPTestFailure.bind
    }
    var result = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &result) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard named == 0 else {
        close(descriptor)
        throw SMLHTTPTestFailure.bind
    }
    return (descriptor, UInt16(bigEndian: result.sin_port))
}

private func serveOneSMLHTTPRequest(
    listener: Int32,
    response: Data
) -> Task<String, Error> {
    Task.detached {
        guard smlHTTPListenerHasPendingConnection(listener, timeoutMilliseconds: 5_000) else {
            throw SMLHTTPTestFailure.timeout
        }
        let peer = accept(listener, nil, nil)
        guard peer >= 0 else { throw SMLHTTPTestFailure.accept }
        defer { close(peer) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(
            peer, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size))
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 128 * 1_024 {
            let count = recv(peer, &byte, 1, 0)
            guard count == 1 else { throw SMLHTTPTestFailure.read }
            bytes.append(byte)
            if bytes.count >= 4, bytes.suffix(4).elementsEqual([13, 10, 13, 10]) { break }
        }
        guard bytes.suffix(4).elementsEqual([13, 10, 13, 10]),
              let request = String(bytes: bytes, encoding: .utf8) else {
            throw SMLHTTPTestFailure.read
        }
        let wrote = response.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let count = write(peer, base.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
        guard wrote else { throw SMLHTTPTestFailure.write }
        return request
    }
}

private func smlHTTPListenerHasPendingConnection(
    _ descriptor: Int32,
    timeoutMilliseconds: Int32
) -> Bool {
    var value = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    return poll(&value, 1, timeoutMilliseconds) > 0 && value.revents & Int16(POLLIN) != 0
}

private enum SMLHTTPTestFailure: Error {
    case socket
    case bind
    case timeout
    case accept
    case read
    case write
}
