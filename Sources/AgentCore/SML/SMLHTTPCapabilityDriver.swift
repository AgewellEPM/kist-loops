import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fixed, non-sensitive failure categories for the HTTP boundary. Remote text, request values,
/// URLs, and credentials must never be reflected into errors or durable evidence.
public enum SMLHTTPExecutionError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingCredentials(String)
    case invalidRequest(capability: String, category: String)
    case uncertain(capability: String, category: String)

    public var description: String {
        switch self {
        case .missingCredentials(let capability):
            return "SML HTTP capability '\(capability)' has no complete host credential set"
        case .invalidRequest(let capability, let category):
            return "SML HTTP capability '\(capability)' refused its request (\(category))"
        case .uncertain(let capability, let category):
            return "SML HTTP capability '\(capability)' has an uncertain dispatch (\(category))"
        }
    }
}

struct SMLHTTPTransportResponse: Sendable {
    let statusCode: Int
    let body: Data
}

enum SMLHTTPTransportError: Error, Sendable, Equatable {
    case responseTooLarge
    case timedOut
    case cancelled
    case connectionFailed

    var category: String {
        switch self {
        case .responseTooLarge: return "response_too_large"
        case .timedOut: return "timeout"
        case .cancelled: return "cancelled"
        case .connectionFailed: return "transport_failure"
        }
    }
}

protocol SMLHTTPTransport: Sendable {
    func send(
        _ request: URLRequest,
        timeoutSeconds: Double,
        maximumResponseBytes: Int
    ) async throws -> SMLHTTPTransportResponse
}

/// Production HTTP driver for reviewed OpenAPI operations. Endpoint bundles contain no secrets;
/// credentials are resolved once at launch from the owner-only host store. Redirects, cookies,
/// caching, unbounded bodies, and workflow-selected URLs are all unavailable by construction.
public struct SMLHTTPCapabilityDriver: SMLInstructionDriver {
    public let id = "sml-http-driver"

    private let endpoints: [String: SMLHTTPEndpointSpec]
    private let authenticationHeaders: [String: [String: String]]
    private let transport: any SMLHTTPTransport
    private let clock: @Sendable () -> Double

    public init(
        registry: SMLHTTPEndpointRegistry,
        authentication: SMLHTTPAuthenticationStore,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) throws {
        try self.init(
            registry: registry,
            authentication: authentication,
            transport: SMLHTTPURLSessionTransport(),
            clock: clock
        )
    }

    init(
        registry: SMLHTTPEndpointRegistry,
        authentication: SMLHTTPAuthenticationStore,
        transport: any SMLHTTPTransport,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) throws {
        var headers: [String: [String: String]] = [:]
        for capability in registry.endpoints.keys.sorted() {
            guard let endpoint = registry.endpoints[capability] else { continue }
            headers[capability] = try authentication.headers(for: endpoint)
        }
        endpoints = registry.endpoints
        authenticationHeaders = headers
        self.transport = transport
        self.clock = clock
    }

    public func supports(_ request: SMLCapabilityRequest) -> Bool {
        request.operation == .callTool && endpoints[request.reference] != nil
    }

    public func execute(
        _ invocation: SMLCapabilityInvocation
    ) async throws -> SMLCapabilityOutcome {
        let request = invocation.request
        guard let endpoint = endpoints[request.reference] else {
            throw SMLHTTPExecutionError.invalidRequest(
                capability: request.reference, category: "unknown_capability")
        }

        let prepared: URLRequest
        let origin: String
        do {
            let result = try prepare(
                request: request,
                endpoint: endpoint,
                authenticationHeaders: authenticationHeaders[endpoint.capability] ?? [:]
            )
            prepared = result.request
            origin = result.origin
        } catch let refusal as SMLHTTPRequestRefusal {
            return failedOutcome(
                invocation: invocation,
                endpoint: endpoint,
                origin: "pinned",
                statusCode: nil,
                body: Data(),
                category: refusal.rawValue
            )
        } catch {
            throw SMLHTTPExecutionError.invalidRequest(
                capability: endpoint.capability, category: "request_construction")
        }

        let response: SMLHTTPTransportResponse
        do {
            response = try await transport.send(
                prepared,
                timeoutSeconds: endpoint.timeoutSeconds,
                maximumResponseBytes: endpoint.maximumResponseBytes
            )
        } catch let transportError as SMLHTTPTransportError {
            throw SMLHTTPExecutionError.uncertain(
                capability: endpoint.capability, category: transportError.category)
        } catch is CancellationError {
            throw SMLHTTPExecutionError.uncertain(
                capability: endpoint.capability, category: "cancelled")
        } catch {
            throw SMLHTTPExecutionError.uncertain(
                capability: endpoint.capability, category: "transport_failure")
        }

        guard response.body.count <= endpoint.maximumResponseBytes else {
            throw SMLHTTPExecutionError.uncertain(
                capability: endpoint.capability, category: "response_too_large")
        }
        guard (100...599).contains(response.statusCode) else {
            throw SMLHTTPExecutionError.uncertain(
                capability: endpoint.capability, category: "invalid_http_status")
        }
        guard (200...299).contains(response.statusCode) else {
            if !endpoint.method.isReadOnly {
                throw SMLHTTPExecutionError.uncertain(
                    capability: endpoint.capability,
                    category: (300...399).contains(response.statusCode)
                        ? "redirect_after_write" : "http_status_after_write"
                )
            }
            return failedOutcome(
                invocation: invocation,
                endpoint: endpoint,
                origin: origin,
                statusCode: response.statusCode,
                body: response.body,
                category: (300...399).contains(response.statusCode)
                    ? "redirect_refused" : "http_status"
            )
        }
        guard let responseText = String(data: response.body, encoding: .utf8) else {
            if !endpoint.method.isReadOnly {
                throw SMLHTTPExecutionError.uncertain(
                    capability: endpoint.capability, category: "invalid_response_after_write")
            }
            return failedOutcome(
                invocation: invocation,
                endpoint: endpoint,
                origin: origin,
                statusCode: response.statusCode,
                body: response.body,
                category: "invalid_utf8"
            )
        }

        let evidence = evidencePayload(
            endpoint: endpoint,
            origin: origin,
            statusCode: response.statusCode,
            body: response.body,
            category: "success"
        )
        return SMLCapabilityDriverSupport.outcome(
            for: invocation,
            driverID: id,
            status: .passed,
            statePatch: [endpoint.responseStateField: .string(responseText)],
            evidencePayload: evidence,
            receiptID: "http.\(endpoint.capability).passed",
            observedAtEpoch: clock()
        )
    }

    private func failedOutcome(
        invocation: SMLCapabilityInvocation,
        endpoint: SMLHTTPEndpointSpec,
        origin: String,
        statusCode: Int?,
        body: Data,
        category: String
    ) -> SMLCapabilityOutcome {
        SMLCapabilityDriverSupport.outcome(
            for: invocation,
            driverID: id,
            status: .failed,
            statePatch: [:],
            evidencePayload: evidencePayload(
                endpoint: endpoint,
                origin: origin,
                statusCode: statusCode,
                body: body,
                category: category
            ),
            receiptID: "http.\(endpoint.capability).failed",
            observedAtEpoch: clock()
        )
    }

    private func evidencePayload(
        endpoint: SMLHTTPEndpointSpec,
        origin: String,
        statusCode: Int?,
        body: Data,
        category: String
    ) -> SMLObject {
        var payload: SMLObject = [
            "capability": .string(endpoint.capability),
            "method": .string(endpoint.method.rawValue),
            "origin": .string(origin),
            "category": .string(category),
            "response_bytes": .number(Decimal(body.count)),
            "response_digest": .string(Self.digest(body)),
        ]
        payload["status_code"] = statusCode.map { .number(Decimal($0)) } ?? .null
        return payload
    }

    private static func digest(_ data: Data) -> String {
        MythosCrypto.sha256(data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum SMLHTTPRequestRefusal: String, Error {
    case invalidArguments = "invalid_arguments"
    case invalidOutputField = "invalid_output_field"
    case invalidServerIndex = "invalid_server_index"
    case missingParameter = "missing_parameter"
    case invalidParameter = "invalid_parameter"
    case invalidHeader = "invalid_header"
    case missingBody = "missing_body"
    case invalidBody = "invalid_body"
    case requestTooLarge = "request_too_large"
    case invalidURL = "invalid_url"
    case requestURLTooLarge = "request_url_too_large"
    case headerCollision = "header_collision"
    case headersTooLarge = "headers_too_large"
}

private extension SMLHTTPCapabilityDriver {
    static let serverIndexArgument = "server_index"
    static let maximumURLBytes = 64 * 1_024
    static let maximumHeaderBytes = 64 * 1_024

    func prepare(
        request: SMLCapabilityRequest,
        endpoint: SMLHTTPEndpointSpec,
        authenticationHeaders: [String: String]
    ) throws -> (request: URLRequest, origin: String) {
        var allowedArguments: Set<String> = [
            SMLCapabilityDriverSupport.outputFieldArgument,
            Self.serverIndexArgument,
        ]
        allowedArguments.formUnion(endpoint.parameters.map(\.stateField))
        if let body = endpoint.requestBody { allowedArguments.insert(body.stateField) }
        guard request.arguments.keys.allSatisfy(allowedArguments.contains) else {
            throw SMLHTTPRequestRefusal.invalidArguments
        }
        if let output = request.arguments[SMLCapabilityDriverSupport.outputFieldArgument] {
            guard output == .string(endpoint.responseStateField) else {
                throw SMLHTTPRequestRefusal.invalidOutputField
            }
        }

        let serverIndex: Int
        if let value = request.arguments[Self.serverIndexArgument] {
            guard case .number(let decimal) = value,
                  let exact = Self.exactInteger(decimal),
                  endpoint.servers.indices.contains(exact) else {
                throw SMLHTTPRequestRefusal.invalidServerIndex
            }
            serverIndex = exact
        } else {
            serverIndex = 0
        }
        let server = endpoint.servers[serverIndex]

        var expandedPath = endpoint.pathTemplate
        var queryPairs: [(String, String)] = []
        var parameterHeaders: [(String, String)] = []
        for parameter in endpoint.parameters {
            let value = request.arguments[parameter.stateField] ?? request.state[parameter.stateField]
            guard let value else {
                if parameter.required { throw SMLHTTPRequestRefusal.missingParameter }
                continue
            }
            let encodedValues = try Self.scalarStrings(value, expectedType: parameter.valueType)
            switch parameter.location {
            case .path:
                guard encodedValues.count == 1 else {
                    throw SMLHTTPRequestRefusal.invalidParameter
                }
                expandedPath = expandedPath.replacingOccurrences(
                    of: "{\(parameter.name)}",
                    with: Self.percentEncode(encodedValues[0])
                )
            case .query:
                if parameter.explode {
                    queryPairs.append(contentsOf: encodedValues.map { (parameter.name, $0) })
                } else {
                    queryPairs.append((parameter.name, encodedValues.joined(separator: ",")))
                }
            case .header:
                guard encodedValues.count == 1,
                      Self.safeHeaderValue(encodedValues[0]) else {
                    throw SMLHTTPRequestRefusal.invalidHeader
                }
                parameterHeaders.append((parameter.name, encodedValues[0]))
            }
        }
        guard !expandedPath.contains("{"), !expandedPath.contains("}") else {
            throw SMLHTTPRequestRefusal.missingParameter
        }

        var components = URLComponents()
        components.scheme = server.scheme
        components.host = server.host
        components.port = server.port
        components.percentEncodedPath = server.basePath + expandedPath
        if !queryPairs.isEmpty {
            components.percentEncodedQuery = queryPairs.map {
                "\(Self.percentEncode($0.0))=\(Self.percentEncode($0.1))"
            }.joined(separator: "&")
        }
        guard let url = components.url,
              url.scheme?.lowercased() == server.scheme,
              url.host?.lowercased() == server.host,
              url.port == server.port else {
            throw SMLHTTPRequestRefusal.invalidURL
        }
        guard url.absoluteString.utf8.count <= Self.maximumURLBytes else {
            throw SMLHTTPRequestRefusal.requestURLTooLarge
        }

        var bodyData: Data?
        if let body = endpoint.requestBody {
            let value = request.arguments[body.stateField] ?? request.state[body.stateField]
            guard let value else {
                if body.required { throw SMLHTTPRequestRefusal.missingBody }
                bodyData = nil
                return try makeURLRequest(
                    url: url,
                    endpoint: endpoint,
                    parameterHeaders: parameterHeaders,
                    authenticationHeaders: authenticationHeaders,
                    body: bodyData
                )
            }
            guard Self.matches(value, type: body.valueType) else {
                throw SMLHTTPRequestRefusal.invalidBody
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let encoded = try? encoder.encode(value) else {
                throw SMLHTTPRequestRefusal.invalidBody
            }
            guard encoded.count <= body.maximumBytes else {
                throw SMLHTTPRequestRefusal.requestTooLarge
            }
            bodyData = encoded
        }

        return try makeURLRequest(
            url: url,
            endpoint: endpoint,
            parameterHeaders: parameterHeaders,
            authenticationHeaders: authenticationHeaders,
            body: bodyData
        )
    }

    func makeURLRequest(
        url: URL,
        endpoint: SMLHTTPEndpointSpec,
        parameterHeaders: [(String, String)],
        authenticationHeaders: [String: String],
        body: Data?
    ) throws -> (request: URLRequest, origin: String) {
        var headers: [String: (name: String, value: String)] = [:]
        var headerBytes = 0
        func insert(_ name: String, _ value: String) throws {
            guard Self.safeHeaderValue(value) else {
                throw SMLHTTPRequestRefusal.invalidHeader
            }
            guard headers[name.lowercased()] == nil else {
                throw SMLHTTPRequestRefusal.headerCollision
            }
            let addedBytes = name.utf8.count + value.utf8.count + 4
            guard addedBytes <= Self.maximumHeaderBytes,
                  headerBytes <= Self.maximumHeaderBytes - addedBytes else {
                throw SMLHTTPRequestRefusal.headersTooLarge
            }
            headerBytes += addedBytes
            headers[name.lowercased()] = (name, value)
        }
        try insert("Accept", "application/json")
        try insert("User-Agent", "kist-sml-http/1")
        if body != nil { try insert("Content-Type", "application/json") }
        for (name, value) in authenticationHeaders.sorted(by: { $0.key < $1.key }) {
            try insert(name, value)
        }
        for (name, value) in parameterHeaders { try insert(name, value) }

        var result = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: endpoint.timeoutSeconds
        )
        result.httpMethod = endpoint.method.rawValue
        result.httpBody = body
        for header in headers.values.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            result.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return (result, endpoint.servers.first(where: {
            $0.scheme == url.scheme && $0.host == url.host && $0.port == url.port
        })?.origin ?? "pinned")
    }

    static func scalarStrings(
        _ value: SMLValue,
        expectedType: SMLStateType
    ) throws -> [String] {
        guard matches(value, type: expectedType) else {
            throw SMLHTTPRequestRefusal.invalidParameter
        }
        switch value {
        case .string(let string): return [string]
        case .number(let number): return [NSDecimalNumber(decimal: number).stringValue]
        case .bool(let bool): return [bool ? "true" : "false"]
        case .array(let values):
            guard values.count <= 1_024 else { throw SMLHTTPRequestRefusal.invalidParameter }
            return try values.map { item in
                switch item {
                case .string(let string): return string
                case .number(let number): return NSDecimalNumber(decimal: number).stringValue
                case .bool(let bool): return bool ? "true" : "false"
                default: throw SMLHTTPRequestRefusal.invalidParameter
                }
            }
        case .null, .object:
            throw SMLHTTPRequestRefusal.invalidParameter
        }
    }

    static func matches(_ value: SMLValue, type: SMLStateType) -> Bool {
        switch (value, type) {
        case (.string, .string), (.number, .number), (.bool, .boolean),
             (.object, .object), (.array, .array):
            return true
        case (.number(let value), .integer):
            return exactInteger(value) != nil
        default:
            return false
        }
    }

    static func exactInteger(_ decimal: Decimal) -> Int? {
        guard decimal.isFinite,
              decimal >= Decimal(Int.min), decimal <= Decimal(Int.max) else { return nil }
        var input = decimal
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        guard rounded == input else { return nil }
        return NSDecimalNumber(decimal: input).intValue
    }

    static func percentEncode(_ value: String) -> String {
        value.utf8.map { byte -> String in
            if (48...57).contains(byte) || (65...90).contains(byte)
                || (97...122).contains(byte) || [45, 46, 95, 126].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    static func safeHeaderValue(_ value: String) -> Bool {
        value.utf8.count <= 16_384 && value.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value <= 0x7e
        }
    }
}

/// A fresh ephemeral session per request gives the resource timeout the same exact bound as the
/// endpoint, while the delegate streams into a capped buffer and refuses every redirect.
struct SMLHTTPURLSessionTransport: SMLHTTPTransport {
    func send(
        _ request: URLRequest,
        timeoutSeconds: Double,
        maximumResponseBytes: Int
    ) async throws -> SMLHTTPTransportResponse {
        let delegate = SMLHTTPBoundedDelegate(maximumBytes: maximumResponseBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.connectionProxyDictionary = [:]
        configuration.urlCredentialStorage = nil
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        return try await delegate.perform(request, session: session)
    }
}

private final class SMLHTTPBoundedDelegate: NSObject, URLSessionDataDelegate,
    @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SMLHTTPTransportResponse, Error>?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var terminal = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func perform(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> SMLHTTPTransportResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !terminal else {
                    lock.unlock()
                    continuation.resume(throwing: SMLHTTPTransportError.cancelled)
                    return
                }
                self.continuation = continuation
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(SMLHTTPTransportError.connectionFailed))
            return
        }
        lock.lock()
        self.response = http
        let tooLarge = response.expectedContentLength > Int64(maximumBytes)
        lock.unlock()
        if tooLarge {
            completionHandler(.cancel)
            finish(.failure(SMLHTTPTransportError.responseTooLarge))
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        guard data.count <= maximumBytes,
              body.count <= maximumBytes - data.count else {
            lock.unlock()
            finish(.failure(SMLHTTPTransportError.responseTooLarge))
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            let urlError = error as? URLError
            let mapped: SMLHTTPTransportError
            if urlError?.code == .timedOut { mapped = .timedOut }
            else if urlError?.code == .cancelled { mapped = .cancelled }
            else { mapped = .connectionFailed }
            finish(.failure(mapped))
            return
        }
        lock.lock()
        let response = self.response
        let body = self.body
        lock.unlock()
        guard let response else {
            finish(.failure(SMLHTTPTransportError.connectionFailed))
            return
        }
        finish(.success(.init(statusCode: response.statusCode, body: body)))
    }

    private func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(SMLHTTPTransportError.cancelled))
    }

    private func finish(_ result: Result<SMLHTTPTransportResponse, Error>) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        terminal = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        self.task = nil
        lock.unlock()
        if case .failure = result { task?.cancel() }
        continuation?.resume(with: result)
    }
}
