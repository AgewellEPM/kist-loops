import Foundation

/// Self-evolution phase 2 — the ROUTER. Turns a classifier `Verdict` into a concrete `RecoveryPlan`: what
/// kind of recovery to run, and the brief that drives it. This is the fork that stops "I cannot complete the
/// task" — every category gets an ACTION instead of a give-up.
public enum RecoveryKind: String, Sendable, Codable, Equatable, CaseIterable {
    /// knowledgeGap → the tool CAN do it; discover its real usage and retry. NO code edit.
    case discoverAndRetry
    /// taskBug → repair OUR source (hand to the existing SelfHealHandoff builder).
    case repairCode
    /// toolLimit → extend the capability. kist tool ⇒ auto-evolve (write+build+test+adversarial verify);
    /// foreign tool ⇒ write a spec and hand it to that repo's owner (never blend repos).
    case extendTool
    /// blocked → not a code/tool bug; surface the exact authority the run needs.
    case surfaceBlocked
}

public struct RecoveryPlan: Sendable, Equatable {
    public let kind: RecoveryKind
    public let category: FailureCategory
    public let culpritTool: String?
    public let discoveryHint: String?
    /// The instruction that drives this recovery — injected into the self-heal researcher/builder brief.
    public let brief: String
}

public enum FailureRouter {

    public static func plan(for v: FailureClassifier.Verdict) -> RecoveryPlan {
        switch v.category {
        case .knowledgeGap:
            let tool = v.culpritTool ?? "the tool"
            let hint = v.discoveryHint.map { " The tool told you how: “\($0)”." } ?? ""
            return RecoveryPlan(
                kind: .discoverAndRetry, category: v.category, culpritTool: v.culpritTool,
                discoveryHint: v.discoveryHint,
                brief: """
                RECOVER — knowledge gap, do NOT edit code. `\(tool)` refused the request, but it CAN do this; \
                you used the wrong form.\(hint) First DISCOVER its real capabilities (call its list/search \
                sibling if one exists, or re-read its tool contract), then RETRY with a valid form. Only if \
                discovery proves it truly can't should this become a tool-limit.
                """)
        case .toolLimit:
            let tool = v.culpritTool ?? "the tool"
            return RecoveryPlan(
                kind: .extendTool, category: v.category, culpritTool: v.culpritTool, discoveryHint: nil,
                brief: """
                RECOVER — capability gap. `\(tool)` genuinely cannot do what the task needs (\(v.evidence)). \
                The fix is to EXTEND the capability, not flail on the task. If `\(tool)` is one of OUR (kist) \
                tools, propose the smallest safe extension, implement it with tests, and let it ship only \
                after an INDEPENDENT adversarial check. If it belongs to another system (an MCP tool), write \
                a precise capability spec for its owner — never edit another repo.
                """)
        case .blocked:
            return RecoveryPlan(
                kind: .surfaceBlocked, category: v.category, culpritTool: v.culpritTool, discoveryHint: nil,
                brief: """
                STOP — this is an AUTHORITY block, not a bug (\(v.evidence)). Do not retry or edit anything. \
                Surface exactly what permission/scope/approval the run needs so the operator can grant it.
                """)
        case .taskBug:
            return RecoveryPlan(
                kind: .repairCode, category: v.category, culpritTool: v.culpritTool, discoveryHint: nil,
                brief: """
                REPAIR — a real code/build error (\(v.evidence)). Read the actual error, fix OUR source, and \
                re-verify with the same build/test that failed.
                """)
        }
    }
}
