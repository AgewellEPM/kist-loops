import Foundation

/// The evidentiary grade of the neural review used by the closed evolution loop.
///
/// `.independent` remains the default and requires a provider distinct from the author. The explicit
/// same-model grade is weaker evidence: it permits only the exact same canonical provider/model identity,
/// and only when the critic starts a fresh conversation in a separate provider invocation.
public enum EvolutionReviewGrade: String, Sendable, Equatable, Codable {
    case independent
    case freshContextSameModel = "fresh_context_same_model"

    public var claimsIndependence: Bool { self == .independent }

    public var evidenceLabel: String {
        switch self {
        case .independent:
            return "independent adversarial review"
        case .freshContextSameModel:
            return "fresh-context same-model adversarial review (independent=false)"
        }
    }
}

/// Invocation-level facts supplied by the critic organ and checked by `ClosedEvolutionLoop` before review.
/// `canonicalIdentity` is resolved at the provider-selection edge, where provider model aliases/defaults are
/// known. `freshConversation` means the invocation receives only its review prompt, with no author transcript.
public struct EvolutionReviewContext: Sendable, Equatable {
    public let grade: EvolutionReviewGrade
    public let provider: String
    public let model: String?
    public let canonicalIdentity: String
    public let invocationID: String
    public let freshConversation: Bool

    public init(
        grade: EvolutionReviewGrade,
        provider: String,
        model: String?,
        canonicalIdentity: String,
        invocationID: String,
        freshConversation: Bool
    ) {
        self.grade = grade
        self.provider = provider
        self.model = model
        self.canonicalIdentity = canonicalIdentity
        self.invocationID = invocationID
        self.freshConversation = freshConversation
    }
}

/// Durable/output-safe evidence describing exactly what kind of review occurred. A same-model fresh-context
/// review always records `independent == false`; callers must never infer independence from two invocations.
public struct EvolutionReviewReceipt: Sendable, Equatable, Codable {
    public let grade: EvolutionReviewGrade
    public let independent: Bool
    public let authorIdentity: String
    public let criticIdentity: String
    public let authorInvocationID: String
    public let criticInvocationID: String
    public let freshConversation: Bool
    public let separateInvocation: Bool

    public init(
        grade: EvolutionReviewGrade,
        independent: Bool,
        authorIdentity: String,
        criticIdentity: String,
        authorInvocationID: String,
        criticInvocationID: String,
        freshConversation: Bool,
        separateInvocation: Bool
    ) {
        self.grade = grade
        self.independent = independent
        self.authorIdentity = authorIdentity
        self.criticIdentity = criticIdentity
        self.authorInvocationID = authorInvocationID
        self.criticInvocationID = criticInvocationID
        self.freshConversation = freshConversation
        self.separateInvocation = separateInvocation
    }
}
