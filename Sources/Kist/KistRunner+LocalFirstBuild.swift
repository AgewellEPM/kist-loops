import Foundation
import AgentCore

extension KistRunner {
    /// Only a known model-output failure can escalate. Scope/authority validation, resource
    /// budgets and cancellation are terminal; no tools have executed at this planning boundary.
    static func localPlanningCanEscalate(_ error: Error) -> Bool {
        if let providerError = error as? AIProviderError, case .configuration(let reason) = providerError {
            return reason.hasPrefix("local context capacity estimate exceeded:")
        }
        guard let preflight = error as? BuilderPreflightError, case .invalid(let reason) = preflight else { return false }
        let lower = reason.lowercased()
        guard !["authorization", "permission", "protected", "escapes", "unsafe", "refused",
                 "invented", "requires explicit", "budget"].contains(where: lower.contains) else { return false }
        return [
            "planner-quality: duplicate or conflicting operation for ",
            "planner-quality: verification command has no script, module or subcommand;",
            "single schema-repair pass failed: builder preflight rejected: duplicate or conflicting operation for ",
            "single schema-repair pass failed: builder preflight rejected: planner must return one json object and no prose",
            "single schema-repair pass failed: builder preflight rejected: planner output is not an object",
            "single schema-repair pass failed: builder preflight rejected: schema or adapter does not match the selected route"
        ].contains(where: lower.hasPrefix)
    }

    /// Heavy build routes bypass the interactive chat router. Apply the same difficulty rule
    /// before any plan is sealed. Explicit CLI/provider/role pins remain authoritative.
    static func localFirstBuildRoles(_ roles: RoleBindings, opts: KistOptions, goal: String,
                                     config: KistConfig, router: AutoModelRouter,
                                     avoid: (String) -> Bool) -> (roles: RoleBindings, reason: String?) {
        guard opts.providerId == nil, opts.model == nil, opts.roleProfile == nil,
              opts.plannerSpec == nil, opts.workerSpec == nil, opts.coderSpec == nil,
              let local = config.localFirstBinding,
              [AgentRole.planner, .worker, .coder].allSatisfy({ roles.binding(for: $0) == local })
        else { return (roles, nil) }
        let decision = router.localFirstDecision(goal, hasMedia: false, local: local, avoid: avoid)
        guard decision.binding != local else { return (roles, nil) }
        // Difficulty escalates the architect only. Keep bounded generation and research on
        // the user's small local model; a benched local runtime is the exception.
        let escalatedRoles: [AgentRole] = avoid(local.providerId)
            ? [.planner, .worker, .coder] : [.planner]
        let next = escalatedRoles.reduce(roles) { $0.binding($1, to: decision.binding) }
        return (next, decision.reason + (escalatedRoles.count == 1
            ? " · planner only; local workers retained" : " · local runtime unavailable"))
    }
}
