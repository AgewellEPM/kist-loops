import Foundation
import CryptoKit

public enum BuilderGraphGovernanceAdmissionError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedSchema(Int)
    case bindingMismatch(String)
    case missingMutationGovernance

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "unsupported graph-governance admission schema \(version)"
        case .bindingMismatch(let field):
            return "graph-governance admission mismatch: \(field)"
        case .missingMutationGovernance:
            return "mutation graph has no sealed graph-governance admission"
        }
    }
}

/// Durable admission binding for graph governance. The graph digest covers full
/// topology and node resource claims; the policy and provider are bound
/// separately so resume diagnostics identify which authority changed.
public struct BuilderGraphGovernanceAdmission: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let governanceRequired: Bool
    public let policyFingerprint: String
    public let graphFingerprint: String
    public let providerFingerprint: String?
    public let governedNodeIDs: [String]

    public init(
        schemaVersion: Int = BuilderGraphGovernanceAdmission.currentSchemaVersion,
        governanceRequired: Bool,
        policyFingerprint: String,
        graphFingerprint: String,
        providerFingerprint: String?,
        governedNodeIDs: [String]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw BuilderGraphGovernanceAdmissionError.unsupportedSchema(schemaVersion)
        }
        let nodes = governedNodeIDs.sorted()
        guard Set(nodes).count == nodes.count,
              policyFingerprint.isBuilderSHA256,
              graphFingerprint.isBuilderSHA256,
              providerFingerprint == nil || providerFingerprint!.isBuilderSHA256 else {
            throw BuilderGraphGovernanceAdmissionError.bindingMismatch("malformed fingerprint or node set")
        }
        guard governanceRequired == !nodes.isEmpty else {
            throw BuilderGraphGovernanceAdmissionError.bindingMismatch("governanceRequired")
        }
        self.schemaVersion = schemaVersion
        self.governanceRequired = governanceRequired
        self.policyFingerprint = policyFingerprint
        self.graphFingerprint = graphFingerprint
        self.providerFingerprint = providerFingerprint
        self.governedNodeIDs = nodes
    }

    public static func make(
        graph: BuilderGraph,
        policy: BuilderGraphExecutionPolicy,
        providerIdentity: BuilderNodeContractProviderIdentity?
    ) throws -> Self {
        try policy.validate(graph: graph)
        let governed = graph.nodes
            .filter { policy.executionClass(for: $0.id) == .mutation }
            .map(\.id).sorted()
        return try .init(
            governanceRequired: !governed.isEmpty,
            policyFingerprint: try digest(policy),
            graphFingerprint: try digest(GraphBinding(graph: graph, policy: policy)),
            providerFingerprint: try providerIdentity.map(digest),
            governedNodeIDs: governed)
    }

    public func validate(matches expected: Self) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw BuilderGraphGovernanceAdmissionError.unsupportedSchema(schemaVersion)
        }
        guard governanceRequired == expected.governanceRequired else {
            throw BuilderGraphGovernanceAdmissionError.bindingMismatch("governanceRequired")
        }
        guard policyFingerprint == expected.policyFingerprint else {
            throw BuilderGraphGovernanceAdmissionError.bindingMismatch("policy fingerprint")
        }
        guard graphFingerprint == expected.graphFingerprint else {
            throw BuilderGraphGovernanceAdmissionError.bindingMismatch("graph fingerprint")
        }
        guard providerFingerprint == expected.providerFingerprint else {
            throw BuilderGraphGovernanceAdmissionError.bindingMismatch("provider fingerprint")
        }
        guard governedNodeIDs == expected.governedNodeIDs else {
            throw BuilderGraphGovernanceAdmissionError.bindingMismatch("governed node set")
        }
    }

    private struct GraphBinding: Codable {
        let graph: BuilderGraph
        let policy: BuilderGraphExecutionPolicy
    }

    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let data = try BuilderDurableIO.canonicalData(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var isBuilderSHA256: Bool {
        count == 64 && allSatisfy { "0123456789abcdef".contains($0) }
    }
}
