import Foundation

public struct ReasoningRouteRequest: Sendable, Equatable {
    public let explicitRoute: ReasoningRoute?
    public let complexity: Int
    public let risk: ReasoningRiskLevel
    public let requiresMutation: Bool
    public let independentWorkstreams: Int
    public let expectedToolCalls: Int

    public init(explicitRoute: ReasoningRoute? = nil, complexity: Int,
                risk: ReasoningRiskLevel = .low, requiresMutation: Bool = false,
                independentWorkstreams: Int = 1, expectedToolCalls: Int = 0) {
        self.explicitRoute = explicitRoute
        self.complexity = max(0, min(100, complexity))
        self.risk = risk
        self.requiresMutation = requiresMutation
        self.independentWorkstreams = max(1, independentWorkstreams)
        self.expectedToolCalls = max(0, expectedToolCalls)
    }
}

public struct ReasoningRouteDecision: Codable, Sendable, Equatable {
    public let route: ReasoningRoute
    public let reason: String
}

public protocol ReasoningRoutePolicy: Sendable {
    func decide(_ request: ReasoningRouteRequest) -> ReasoningRouteDecision
}

/// Typed routing policy: no lexical keyword classifier and no prompt-only route label.
public struct SolReasoningRoutePolicy: ReasoningRoutePolicy, Sendable {
    public init() {}

    public func decide(_ request: ReasoningRouteRequest) -> ReasoningRouteDecision {
        if request.explicitRoute == .direct, request.risk >= .high {
            return ReasoningRouteDecision(
                route: .planned,
                reason: "unsafe direct override escalated because high-risk work requires an accepted plan"
            )
        }
        if let explicit = request.explicitRoute {
            return ReasoningRouteDecision(route: explicit, reason: "explicit route override")
        }
        if request.independentWorkstreams >= 2 && request.complexity >= 55 {
            return ReasoningRouteDecision(route: .fleet,
                                          reason: "multiple independent workstreams justify bounded delegation")
        }
        if request.complexity >= 75 {
            return ReasoningRouteDecision(route: .fleet,
                                          reason: "high complexity requires decomposition and independent review")
        }
        if request.requiresMutation || request.risk >= .high || request.complexity >= 30
            || request.expectedToolCalls >= 4 {
            return ReasoningRouteDecision(route: .planned,
                                          reason: "state-changing or multi-step work requires an accepted plan")
        }
        return ReasoningRouteDecision(route: .direct,
                                      reason: "bounded low-risk work fits the lean direct loop")
    }
}
