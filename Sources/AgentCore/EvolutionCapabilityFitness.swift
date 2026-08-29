import Foundation

/// The two independently executed arms of a parent-relative capability evaluation.
public enum EvolutionCapabilityArm: String, Codable, Sendable, Equatable {
    case parent
    case child
}

/// Fail-closed validation errors for the pure-data capability fitness contract.
public enum EvolutionCapabilityFitnessError: Error, LocalizedError, Sendable, Equatable {
    case invalidObjectID(field: String)
    case mixedObjectIDFormats
    case invalidDigest(field: String)
    case parentBaseIdentityMismatch
    case childIdentityNotDistinct
    case invalidCaseID(reason: String)
    case emptyCases(arm: EvolutionCapabilityArm)
    case tooManyCases(arm: EvolutionCapabilityArm, limit: Int)
    case duplicateCaseID(arm: EvolutionCapabilityArm, caseID: String)
    case armIdentityMismatch(arm: EvolutionCapabilityArm)
    case frozenInputsMismatch(arm: EvolutionCapabilityArm)
    case infrastructureFailed(arm: EvolutionCapabilityArm)
    case caseSetMismatch(parentOnly: [String], childOnly: [String])
    case regressedCases([String])
    case noNewlySolvedCases
    case nonPositiveSolvedCountDelta(parent: Int, child: Int)
    case invalidReceipt(reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidObjectID(let field):
            return "invalid lowercase Git object ID for \(field)"
        case .mixedObjectIDFormats:
            return "parent, base, and child Git object IDs do not use one hash width"
        case .invalidDigest(let field):
            return "invalid lowercase SHA-256 digest for \(field)"
        case .parentBaseIdentityMismatch:
            return "the child's exact base identity is not the evaluated parent identity"
        case .childIdentityNotDistinct:
            return "the child commit and tree must be distinct from the parent"
        case .invalidCaseID(let reason):
            return "invalid held-out case ID: \(reason)"
        case .emptyCases(let arm):
            return "the \(arm.rawValue) arm contains no held-out cases"
        case .tooManyCases(let arm, let limit):
            return "the \(arm.rawValue) arm exceeds the \(limit)-case bound"
        case .duplicateCaseID(let arm, let caseID):
            return "duplicate \(arm.rawValue) held-out case ID: \(caseID)"
        case .armIdentityMismatch(let arm):
            return "the \(arm.rawValue) result is not bound to its planned exact identity"
        case .frozenInputsMismatch(let arm):
            return "the \(arm.rawValue) result is not bound to the frozen evaluation inputs"
        case .infrastructureFailed(let arm):
            return "the \(arm.rawValue) evaluation infrastructure did not succeed"
        case .caseSetMismatch(let parentOnly, let childOnly):
            return "the held-out case sets differ (parent-only: \(parentOnly), child-only: \(childOnly))"
        case .regressedCases(let caseIDs):
            return "the child regressed held-out cases: \(caseIDs)"
        case .noNewlySolvedCases:
            return "the child did not newly solve a held-out case"
        case .nonPositiveSolvedCountDelta(let parent, let child):
            return "the solved-count delta is not positive (parent: \(parent), child: \(child))"
        case .invalidReceipt(let reason):
            return "invalid capability fitness receipt input: \(reason)"
        }
    }
}

private enum EvolutionCapabilityFitnessValidation {
    static let maximumCases = 4_096
    static let maximumCaseIDUTF8Bytes = 256

    static func requireObjectID(_ value: String, field: String) throws {
        guard (value.utf8.count == 40 || value.utf8.count == 64), isLowercaseHex(value) else {
            throw EvolutionCapabilityFitnessError.invalidObjectID(field: field)
        }
    }

    static func requireDigest(_ value: String, field: String) throws {
        guard value.utf8.count == 64, isLowercaseHex(value) else {
            throw EvolutionCapabilityFitnessError.invalidDigest(field: field)
        }
    }

    static func requireCaseID(_ value: String) throws {
        guard !value.isEmpty else {
            throw EvolutionCapabilityFitnessError.invalidCaseID(reason: "empty")
        }
        guard value.utf8.count <= maximumCaseIDUTF8Bytes else {
            throw EvolutionCapabilityFitnessError.invalidCaseID(
                reason: "longer than \(maximumCaseIDUTF8Bytes) UTF-8 bytes")
        }
        guard value == value.precomposedStringWithCanonicalMapping else {
            throw EvolutionCapabilityFitnessError.invalidCaseID(reason: "not NFC-normalized")
        }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw EvolutionCapabilityFitnessError.invalidCaseID(
                reason: "leading or trailing whitespace")
        }
        guard value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw EvolutionCapabilityFitnessError.invalidCaseID(reason: "contains a control character")
        }
    }

    static func isLowercaseHex(_ value: String) -> Bool {
        value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in MythosCrypto.sha256(data) {
            bytes.append(alphabet[Int(byte >> 4)])
            bytes.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Exact durable Git identity for one evaluation subject.
///
/// `gitControlDigest` binds the hardened Git control state used by the evaluator in addition to the
/// commit and tree object IDs. This value is data only; it is not an attestation or signature.
public struct EvolutionCapabilitySubjectIdentity: Codable, Sendable, Equatable {
    public let commitSHA: String
    public let treeSHA: String
    public let gitControlDigest: String

    public init(commitSHA: String, treeSHA: String, gitControlDigest: String) throws {
        try EvolutionCapabilityFitnessValidation.requireObjectID(
            commitSHA, field: "subject.commitSHA")
        try EvolutionCapabilityFitnessValidation.requireObjectID(
            treeSHA, field: "subject.treeSHA")
        guard commitSHA.utf8.count == treeSHA.utf8.count else {
            throw EvolutionCapabilityFitnessError.mixedObjectIDFormats
        }
        try EvolutionCapabilityFitnessValidation.requireDigest(
            gitControlDigest, field: "subject.gitControlDigest")
        self.commitSHA = commitSHA
        self.treeSHA = treeSHA
        self.gitControlDigest = gitControlDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            commitSHA: container.decode(String.self, forKey: .commitSHA),
            treeSHA: container.decode(String.self, forKey: .treeSHA),
            gitControlDigest: container.decode(String.self, forKey: .gitControlDigest))
    }
}

/// Frozen, content-addressed inputs that both arms must use exactly.
public struct EvolutionCapabilityFrozenInputs: Codable, Sendable, Equatable {
    public let corpusDigest: String
    public let harnessDigest: String
    public let evaluatorDigest: String
    public let providerDigest: String
    public let modelDigest: String
    public let toolsetDigest: String

    public init(corpusDigest: String,
                harnessDigest: String,
                evaluatorDigest: String,
                providerDigest: String,
                modelDigest: String,
                toolsetDigest: String) throws {
        let fields = [
            ("frozen.corpusDigest", corpusDigest),
            ("frozen.harnessDigest", harnessDigest),
            ("frozen.evaluatorDigest", evaluatorDigest),
            ("frozen.providerDigest", providerDigest),
            ("frozen.modelDigest", modelDigest),
            ("frozen.toolsetDigest", toolsetDigest),
        ]
        for (field, digest) in fields {
            try EvolutionCapabilityFitnessValidation.requireDigest(digest, field: field)
        }
        self.corpusDigest = corpusDigest
        self.harnessDigest = harnessDigest
        self.evaluatorDigest = evaluatorDigest
        self.providerDigest = providerDigest
        self.modelDigest = modelDigest
        self.toolsetDigest = toolsetDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            corpusDigest: container.decode(String.self, forKey: .corpusDigest),
            harnessDigest: container.decode(String.self, forKey: .harnessDigest),
            evaluatorDigest: container.decode(String.self, forKey: .evaluatorDigest),
            providerDigest: container.decode(String.self, forKey: .providerDigest),
            modelDigest: container.decode(String.self, forKey: .modelDigest),
            toolsetDigest: container.decode(String.self, forKey: .toolsetDigest))
    }
}

/// Immutable comparison plan. The child base must be the exact parent identity, not merely a label.
public struct EvolutionCapabilityEvaluationPlan: Codable, Sendable, Equatable {
    public let parentIdentity: EvolutionCapabilitySubjectIdentity
    public let childBaseIdentity: EvolutionCapabilitySubjectIdentity
    public let childIdentity: EvolutionCapabilitySubjectIdentity
    public let frozenInputs: EvolutionCapabilityFrozenInputs

    public init(parentIdentity: EvolutionCapabilitySubjectIdentity,
                childBaseIdentity: EvolutionCapabilitySubjectIdentity,
                childIdentity: EvolutionCapabilitySubjectIdentity,
                frozenInputs: EvolutionCapabilityFrozenInputs) throws {
        guard childBaseIdentity == parentIdentity else {
            throw EvolutionCapabilityFitnessError.parentBaseIdentityMismatch
        }
        let objectIDWidths = [
            parentIdentity.commitSHA.utf8.count,
            parentIdentity.treeSHA.utf8.count,
            childIdentity.commitSHA.utf8.count,
            childIdentity.treeSHA.utf8.count,
        ]
        guard Set(objectIDWidths).count == 1 else {
            throw EvolutionCapabilityFitnessError.mixedObjectIDFormats
        }
        guard childIdentity.commitSHA != parentIdentity.commitSHA,
              childIdentity.treeSHA != parentIdentity.treeSHA else {
            throw EvolutionCapabilityFitnessError.childIdentityNotDistinct
        }
        self.parentIdentity = parentIdentity
        self.childBaseIdentity = childBaseIdentity
        self.childIdentity = childIdentity
        self.frozenInputs = frozenInputs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            parentIdentity: container.decode(
                EvolutionCapabilitySubjectIdentity.self, forKey: .parentIdentity),
            childBaseIdentity: container.decode(
                EvolutionCapabilitySubjectIdentity.self, forKey: .childBaseIdentity),
            childIdentity: container.decode(
                EvolutionCapabilitySubjectIdentity.self, forKey: .childIdentity),
            frozenInputs: container.decode(
                EvolutionCapabilityFrozenInputs.self, forKey: .frozenInputs))
    }
}

/// One assertion outcome from a held-out corpus.
public struct EvolutionCapabilityCaseResult: Codable, Sendable, Equatable {
    public let caseID: String
    public let passed: Bool
    public let evidenceDigest: String

    public init(caseID: String, passed: Bool, evidenceDigest: String) throws {
        try EvolutionCapabilityFitnessValidation.requireCaseID(caseID)
        try EvolutionCapabilityFitnessValidation.requireDigest(
            evidenceDigest, field: "case[\(caseID)].evidenceDigest")
        self.caseID = caseID
        self.passed = passed
        self.evidenceDigest = evidenceDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            caseID: container.decode(String.self, forKey: .caseID),
            passed: container.decode(Bool.self, forKey: .passed),
            evidenceDigest: container.decode(String.self, forKey: .evidenceDigest))
    }
}

/// Complete data returned by one independently run evaluation arm.
public struct EvolutionCapabilityArmResult: Codable, Sendable, Equatable {
    public let arm: EvolutionCapabilityArm
    public let identity: EvolutionCapabilitySubjectIdentity
    public let frozenInputs: EvolutionCapabilityFrozenInputs
    public let infrastructureSucceeded: Bool
    public let infrastructureEvidenceDigest: String
    public let cases: [EvolutionCapabilityCaseResult]

    public init(arm: EvolutionCapabilityArm,
                identity: EvolutionCapabilitySubjectIdentity,
                frozenInputs: EvolutionCapabilityFrozenInputs,
                infrastructureSucceeded: Bool,
                infrastructureEvidenceDigest: String,
                cases: [EvolutionCapabilityCaseResult]) throws {
        try EvolutionCapabilityFitnessValidation.requireDigest(
            infrastructureEvidenceDigest,
            field: "\(arm.rawValue).infrastructureEvidenceDigest")
        guard !cases.isEmpty else {
            throw EvolutionCapabilityFitnessError.emptyCases(arm: arm)
        }
        guard cases.count <= EvolutionCapabilityFitnessValidation.maximumCases else {
            throw EvolutionCapabilityFitnessError.tooManyCases(
                arm: arm, limit: EvolutionCapabilityFitnessValidation.maximumCases)
        }
        var seen = Set<String>()
        for result in cases where !seen.insert(result.caseID).inserted {
            throw EvolutionCapabilityFitnessError.duplicateCaseID(
                arm: arm, caseID: result.caseID)
        }
        self.arm = arm
        self.identity = identity
        self.frozenInputs = frozenInputs
        self.infrastructureSucceeded = infrastructureSucceeded
        self.infrastructureEvidenceDigest = infrastructureEvidenceDigest
        self.cases = cases.sorted { $0.caseID < $1.caseID }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let arm = try container.decode(EvolutionCapabilityArm.self, forKey: .arm)
        try self.init(
            arm: arm,
            identity: container.decode(
                EvolutionCapabilitySubjectIdentity.self, forKey: .identity),
            frozenInputs: container.decode(
                EvolutionCapabilityFrozenInputs.self, forKey: .frozenInputs),
            infrastructureSucceeded: container.decode(
                Bool.self, forKey: .infrastructureSucceeded),
            infrastructureEvidenceDigest: container.decode(
                String.self, forKey: .infrastructureEvidenceDigest),
            cases: container.decode([EvolutionCapabilityCaseResult].self, forKey: .cases))
    }

    private enum CodingKeys: String, CodingKey {
        case arm
        case identity
        case frozenInputs
        case infrastructureSucceeded
        case infrastructureEvidenceDigest
        case cases
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(arm, forKey: .arm)
        try container.encode(identity, forKey: .identity)
        try container.encode(frozenInputs, forKey: .frozenInputs)
        try container.encode(infrastructureSucceeded, forKey: .infrastructureSucceeded)
        try container.encode(infrastructureEvidenceDigest, forKey: .infrastructureEvidenceDigest)
        try container.encode(cases, forKey: .cases)
    }
}

/// Canonically ordered parent/child outcome for one held-out case.
public struct EvolutionCapabilityCaseComparison: Codable, Sendable, Equatable {
    public let caseID: String
    public let parentPassed: Bool
    public let childPassed: Bool
    public let parentEvidenceDigest: String
    public let childEvidenceDigest: String

    fileprivate init(parent: EvolutionCapabilityCaseResult,
                     child: EvolutionCapabilityCaseResult) {
        self.caseID = parent.caseID
        self.parentPassed = parent.passed
        self.childPassed = child.passed
        self.parentEvidenceDigest = parent.evidenceDigest
        self.childEvidenceDigest = child.evidenceDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let caseID = try container.decode(String.self, forKey: .caseID)
        let parentEvidence = try container.decode(String.self, forKey: .parentEvidenceDigest)
        let childEvidence = try container.decode(String.self, forKey: .childEvidenceDigest)
        try EvolutionCapabilityFitnessValidation.requireCaseID(caseID)
        try EvolutionCapabilityFitnessValidation.requireDigest(
            parentEvidence, field: "comparison[\(caseID)].parentEvidenceDigest")
        try EvolutionCapabilityFitnessValidation.requireDigest(
            childEvidence, field: "comparison[\(caseID)].childEvidenceDigest")
        self.caseID = caseID
        self.parentPassed = try container.decode(Bool.self, forKey: .parentPassed)
        self.childPassed = try container.decode(Bool.self, forKey: .childPassed)
        self.parentEvidenceDigest = parentEvidence
        self.childEvidenceDigest = childEvidence
    }
}

/// Deterministic, unsigned input for a future externally witnessed fitness receipt.
///
/// This type deliberately contains no signature, seal, timestamp, persistence, or promotion action. Its
/// digest binds pure evaluation data; it does not turn that data into an authority claim.
public struct EvolutionCapabilityFitnessReceiptInput: Codable, Sendable, Equatable {
    public static let currentSchema = "kist.evolution.capability-fitness.v1"

    public let schema: String
    public let plan: EvolutionCapabilityEvaluationPlan
    public let parentInfrastructureSucceeded: Bool
    public let childInfrastructureSucceeded: Bool
    public let parentInfrastructureEvidenceDigest: String
    public let childInfrastructureEvidenceDigest: String
    public let comparisons: [EvolutionCapabilityCaseComparison]
    public let parentSolvedCount: Int
    public let childSolvedCount: Int
    public let solvedCountDelta: Int
    public let newlySolvedCaseIDs: [String]
    public let regressedCaseIDs: [String]

    fileprivate init(
        schema: String = EvolutionCapabilityFitnessReceiptInput.currentSchema,
        plan: EvolutionCapabilityEvaluationPlan,
        parentInfrastructureSucceeded: Bool,
        childInfrastructureSucceeded: Bool,
        parentInfrastructureEvidenceDigest: String,
        childInfrastructureEvidenceDigest: String,
        comparisons: [EvolutionCapabilityCaseComparison],
        parentSolvedCount: Int,
        childSolvedCount: Int,
        solvedCountDelta: Int,
        newlySolvedCaseIDs: [String],
        regressedCaseIDs: [String]
    ) throws {
        guard schema == Self.currentSchema else {
            throw EvolutionCapabilityFitnessError.invalidReceipt(reason: "unknown schema")
        }
        guard parentInfrastructureSucceeded else {
            throw EvolutionCapabilityFitnessError.infrastructureFailed(arm: .parent)
        }
        guard childInfrastructureSucceeded else {
            throw EvolutionCapabilityFitnessError.infrastructureFailed(arm: .child)
        }
        try EvolutionCapabilityFitnessValidation.requireDigest(
            parentInfrastructureEvidenceDigest,
            field: "receipt.parentInfrastructureEvidenceDigest")
        try EvolutionCapabilityFitnessValidation.requireDigest(
            childInfrastructureEvidenceDigest,
            field: "receipt.childInfrastructureEvidenceDigest")
        guard !comparisons.isEmpty,
              comparisons.count <= EvolutionCapabilityFitnessValidation.maximumCases else {
            throw EvolutionCapabilityFitnessError.invalidReceipt(
                reason: "comparison count is outside the bounded nonempty range")
        }
        guard comparisons == comparisons.sorted(by: { $0.caseID < $1.caseID }),
              Set(comparisons.map(\.caseID)).count == comparisons.count else {
            throw EvolutionCapabilityFitnessError.invalidReceipt(
                reason: "case comparisons are not sorted and unique")
        }

        let expectedParentSolved = comparisons.filter(\.parentPassed).count
        let expectedChildSolved = comparisons.filter(\.childPassed).count
        let expectedDelta = expectedChildSolved - expectedParentSolved
        let expectedNew = comparisons
            .filter { !$0.parentPassed && $0.childPassed }
            .map(\.caseID)
        let expectedRegressions = comparisons
            .filter { $0.parentPassed && !$0.childPassed }
            .map(\.caseID)
        guard parentSolvedCount == expectedParentSolved,
              childSolvedCount == expectedChildSolved,
              solvedCountDelta == expectedDelta,
              newlySolvedCaseIDs == expectedNew,
              regressedCaseIDs == expectedRegressions else {
            throw EvolutionCapabilityFitnessError.invalidReceipt(
                reason: "derived fitness fields do not recompute")
        }
        guard expectedRegressions.isEmpty else {
            throw EvolutionCapabilityFitnessError.regressedCases(expectedRegressions)
        }
        guard !expectedNew.isEmpty else {
            throw EvolutionCapabilityFitnessError.noNewlySolvedCases
        }
        guard expectedDelta > 0 else {
            throw EvolutionCapabilityFitnessError.nonPositiveSolvedCountDelta(
                parent: expectedParentSolved, child: expectedChildSolved)
        }

        self.schema = schema
        self.plan = plan
        self.parentInfrastructureSucceeded = parentInfrastructureSucceeded
        self.childInfrastructureSucceeded = childInfrastructureSucceeded
        self.parentInfrastructureEvidenceDigest = parentInfrastructureEvidenceDigest
        self.childInfrastructureEvidenceDigest = childInfrastructureEvidenceDigest
        self.comparisons = comparisons
        self.parentSolvedCount = parentSolvedCount
        self.childSolvedCount = childSolvedCount
        self.solvedCountDelta = solvedCountDelta
        self.newlySolvedCaseIDs = newlySolvedCaseIDs
        self.regressedCaseIDs = regressedCaseIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(String.self, forKey: .schema),
            plan: container.decode(EvolutionCapabilityEvaluationPlan.self, forKey: .plan),
            parentInfrastructureSucceeded: container.decode(
                Bool.self, forKey: .parentInfrastructureSucceeded),
            childInfrastructureSucceeded: container.decode(
                Bool.self, forKey: .childInfrastructureSucceeded),
            parentInfrastructureEvidenceDigest: container.decode(
                String.self, forKey: .parentInfrastructureEvidenceDigest),
            childInfrastructureEvidenceDigest: container.decode(
                String.self, forKey: .childInfrastructureEvidenceDigest),
            comparisons: container.decode(
                [EvolutionCapabilityCaseComparison].self, forKey: .comparisons),
            parentSolvedCount: container.decode(Int.self, forKey: .parentSolvedCount),
            childSolvedCount: container.decode(Int.self, forKey: .childSolvedCount),
            solvedCountDelta: container.decode(Int.self, forKey: .solvedCountDelta),
            newlySolvedCaseIDs: container.decode([String].self, forKey: .newlySolvedCaseIDs),
            regressedCaseIDs: container.decode([String].self, forKey: .regressedCaseIDs))
    }

    /// Stable JSON bytes suitable for content addressing. They remain unsigned and unwitnessed.
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// SHA-256 of `canonicalData()`. This is a data-binding digest, not an approval or trust seal.
    public func bindingDigest() throws -> String {
        EvolutionCapabilityFitnessValidation.sha256Hex(try canonicalData())
    }
}

/// Pure parent-relative held-out fitness evaluator. It has no filesystem, process, archive, or autonomy
/// side effects and emits a receipt input only when every improvement invariant holds.
public enum EvolutionCapabilityFitnessEvaluator {
    public static func evaluate(
        plan: EvolutionCapabilityEvaluationPlan,
        parent: EvolutionCapabilityArmResult,
        child: EvolutionCapabilityArmResult
    ) throws -> EvolutionCapabilityFitnessReceiptInput {
        guard parent.arm == .parent else {
            throw EvolutionCapabilityFitnessError.armIdentityMismatch(arm: .parent)
        }
        guard child.arm == .child else {
            throw EvolutionCapabilityFitnessError.armIdentityMismatch(arm: .child)
        }
        guard parent.identity == plan.parentIdentity else {
            throw EvolutionCapabilityFitnessError.armIdentityMismatch(arm: .parent)
        }
        guard child.identity == plan.childIdentity else {
            throw EvolutionCapabilityFitnessError.armIdentityMismatch(arm: .child)
        }
        guard parent.frozenInputs == plan.frozenInputs else {
            throw EvolutionCapabilityFitnessError.frozenInputsMismatch(arm: .parent)
        }
        guard child.frozenInputs == plan.frozenInputs else {
            throw EvolutionCapabilityFitnessError.frozenInputsMismatch(arm: .child)
        }
        guard parent.infrastructureSucceeded else {
            throw EvolutionCapabilityFitnessError.infrastructureFailed(arm: .parent)
        }
        guard child.infrastructureSucceeded else {
            throw EvolutionCapabilityFitnessError.infrastructureFailed(arm: .child)
        }

        let parentByID = Dictionary(uniqueKeysWithValues: parent.cases.map { ($0.caseID, $0) })
        let childByID = Dictionary(uniqueKeysWithValues: child.cases.map { ($0.caseID, $0) })
        let parentIDs = Set(parentByID.keys)
        let childIDs = Set(childByID.keys)
        guard parentIDs == childIDs else {
            throw EvolutionCapabilityFitnessError.caseSetMismatch(
                parentOnly: parentIDs.subtracting(childIDs).sorted(),
                childOnly: childIDs.subtracting(parentIDs).sorted())
        }

        let comparisons = parentIDs.sorted().map { caseID in
            EvolutionCapabilityCaseComparison(
                parent: parentByID[caseID]!, child: childByID[caseID]!)
        }
        let parentSolved = comparisons.filter(\.parentPassed).count
        let childSolved = comparisons.filter(\.childPassed).count
        let newlySolved = comparisons
            .filter { !$0.parentPassed && $0.childPassed }
            .map(\.caseID)
        let regressions = comparisons
            .filter { $0.parentPassed && !$0.childPassed }
            .map(\.caseID)
        let delta = childSolved - parentSolved

        guard regressions.isEmpty else {
            throw EvolutionCapabilityFitnessError.regressedCases(regressions)
        }
        guard !newlySolved.isEmpty else {
            throw EvolutionCapabilityFitnessError.noNewlySolvedCases
        }
        guard delta > 0 else {
            throw EvolutionCapabilityFitnessError.nonPositiveSolvedCountDelta(
                parent: parentSolved, child: childSolved)
        }

        return try EvolutionCapabilityFitnessReceiptInput(
            plan: plan,
            parentInfrastructureSucceeded: parent.infrastructureSucceeded,
            childInfrastructureSucceeded: child.infrastructureSucceeded,
            parentInfrastructureEvidenceDigest: parent.infrastructureEvidenceDigest,
            childInfrastructureEvidenceDigest: child.infrastructureEvidenceDigest,
            comparisons: comparisons,
            parentSolvedCount: parentSolved,
            childSolvedCount: childSolved,
            solvedCountDelta: delta,
            newlySolvedCaseIDs: newlySolved,
            regressedCaseIDs: regressions)
    }
}
