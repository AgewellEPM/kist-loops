import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport errors from the external rollback-witness service.
public enum EvolutionRollbackHTTPClientError: Error, LocalizedError, Sendable, Equatable {
    case invalidEndpoint(String)
    case requestEncoding
    case responseTooLarge
    case invalidResponse
    case httpStatus(Int)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let detail): return "rollback witness endpoint refused: \(detail)"
        case .requestEncoding: return "rollback witness request could not be encoded"
        case .responseTooLarge: return "rollback witness response exceeds the bounded response limit"
        case .invalidResponse: return "rollback witness returned an invalid signed witness response"
        case .httpStatus(let status): return "rollback witness returned HTTP \(status)"
        case .transport(let detail): return "rollback witness transport failed: \(detail)"
        }
    }
}

/// A production transport for an operator-owned external compare-and-advance register.
///
/// The service remains the authority: this client cannot sign, synthesize, persist, or advance a
/// witness locally. The caller must still verify the returned signature, namespace, challenge,
/// continuity, and freshness through `EvolutionRollbackWitnessVerifier`.
public struct EvolutionRollbackHTTPSCASClient: EvolutionRollbackExternalCASClient, Sendable {
    public struct Configuration: Sendable, Equatable {
        public let baseURL: URL
        public let bearerToken: String?
        public let timeoutSeconds: TimeInterval
        public let maximumResponseBytes: Int
        public let allowInsecureLoopback: Bool

        public init(baseURL: URL, bearerToken: String? = nil,
                    timeoutSeconds: TimeInterval = 10,
                    maximumResponseBytes: Int = 256 * 1_024,
                    allowInsecureLoopback: Bool = false) throws {
            guard baseURL.scheme?.lowercased() == "https"
                    || (allowInsecureLoopback && Self.isLoopback(baseURL)) else {
                throw EvolutionRollbackHTTPClientError.invalidEndpoint(
                    "HTTPS is required (plain HTTP is allowed only for an explicitly enabled loopback test endpoint)")
            }
            guard baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
                  baseURL.query == nil, baseURL.fragment == nil else {
                throw EvolutionRollbackHTTPClientError.invalidEndpoint(
                    "endpoint must have a host and no embedded credentials, query, or fragment")
            }
            guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 60 else {
                throw EvolutionRollbackHTTPClientError.invalidEndpoint("timeout must be in 0...60 seconds")
            }
            guard (1...4 * 1_024 * 1_024).contains(maximumResponseBytes) else {
                throw EvolutionRollbackHTTPClientError.invalidEndpoint("response limit is out of range")
            }
            if let bearerToken {
                guard !bearerToken.isEmpty, bearerToken.utf8.count <= 4_096,
                      bearerToken.rangeOfCharacter(from: .newlines) == nil else {
                    throw EvolutionRollbackHTTPClientError.invalidEndpoint("bearer token is malformed")
                }
            }
            self.baseURL = baseURL
            self.bearerToken = bearerToken
            self.timeoutSeconds = timeoutSeconds
            self.maximumResponseBytes = maximumResponseBytes
            self.allowInsecureLoopback = allowInsecureLoopback
        }

        private static func isLoopback(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }
    }

    private struct ReadPayload: Encodable {
        let anchorNamespaceDigest: String
        let projectIdentityDigest: String
        let challenge: String
    }

    private struct AdvancePayload: Encodable {
        let anchorNamespaceDigest: String
        let expectedRevision: UInt64
        let expectedWitnessDigest: String
        let checkpoint: EvolutionRollbackCheckpoint
        let challenge: String
    }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func readCurrent(
        _ request: EvolutionRollbackCASReadRequest
    ) async throws -> EvolutionSignedRollbackWitness {
        try await send(path: "read", payload: ReadPayload(
            anchorNamespaceDigest: request.anchorNamespaceDigest,
            projectIdentityDigest: request.projectIdentityDigest,
            challenge: request.challenge))
    }

    public func compareAndSwap(
        _ request: EvolutionRollbackCASAdvanceRequest
    ) async throws -> EvolutionSignedRollbackWitness {
        try await send(path: "compare-and-swap", payload: AdvancePayload(
            anchorNamespaceDigest: request.anchorNamespaceDigest,
            expectedRevision: request.expectedRevision,
            expectedWitnessDigest: request.expectedWitnessDigest,
            checkpoint: request.checkpoint,
            challenge: request.challenge))
    }

    private func send<Payload: Encodable>(path: String, payload: Payload) async throws
        -> EvolutionSignedRollbackWitness {
        let endpoint = configuration.baseURL.appendingPathComponent(path)
        guard endpoint.scheme?.lowercased() == "https"
                || (configuration.allowInsecureLoopback && endpoint.host.map({
                    ["localhost", "127.0.0.1", "::1"].contains($0.lowercased())
                }) == true) else {
            throw EvolutionRollbackHTTPClientError.invalidEndpoint("redirected or derived endpoint is not HTTPS")
        }
        var request = URLRequest(url: endpoint, timeoutInterval: configuration.timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken = configuration.bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw EvolutionRollbackHTTPClientError.requestEncoding
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= configuration.maximumResponseBytes else {
                throw EvolutionRollbackHTTPClientError.responseTooLarge
            }
            guard let http = response as? HTTPURLResponse else {
                throw EvolutionRollbackHTTPClientError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw EvolutionRollbackHTTPClientError.httpStatus(http.statusCode)
            }
            do {
                return try JSONDecoder().decode(EvolutionSignedRollbackWitness.self, from: data)
            } catch {
                throw EvolutionRollbackHTTPClientError.invalidResponse
            }
        } catch let error as EvolutionRollbackHTTPClientError {
            throw error
        } catch {
            throw EvolutionRollbackHTTPClientError.transport(String(describing: error))
        }
    }
}
