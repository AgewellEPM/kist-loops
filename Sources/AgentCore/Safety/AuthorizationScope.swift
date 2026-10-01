import Foundation

public enum AuthorizedWorkKind: String, Sendable, Codable, Equatable {
    case normal
    case bugBounty
    case visualReconstruction
    case serverDiagnostics
    case desktopControl
}

public enum ScopeGate: String, Sendable, Codable, Equatable {
    case allow
    case planOnly
    case needsApproval
    case needsScope
}

public struct ScopeDecision: Sendable, Codable, Equatable {
    public let kind: AuthorizedWorkKind
    public let gate: ScopeGate
    public let reason: String
    public let allowedActions: [String]
    public let blockedActions: [String]
    public let requiredEvidence: [String]

    public init(kind: AuthorizedWorkKind, gate: ScopeGate, reason: String,
                allowedActions: [String], blockedActions: [String], requiredEvidence: [String]) {
        self.kind = kind
        self.gate = gate
        self.reason = reason
        self.allowedActions = allowedActions
        self.blockedActions = blockedActions
        self.requiredEvidence = requiredEvidence
    }

    public var promptLines: [String] {
        guard kind != .normal else { return [] }
        var lines = [
            "Authorization/scope gate: \(gate.rawValue) (\(kind.rawValue)) — \(reason)",
            "Allowed now: \(allowedActions.joined(separator: ", "))",
        ]
        if !blockedActions.isEmpty { lines.append("Blocked until scope/approval: \(blockedActions.joined(separator: ", "))") }
        if !requiredEvidence.isEmpty { lines.append("Required evidence before execution: \(requiredEvidence.joined(separator: "; "))") }
        return lines
    }

    /// Runtime enforcement for this scope. This is the hard backstop under prompt guidance:
    /// if a model ignores the scope instructions and asks for an active tool anyway, the
    /// registry refuses before the tool sees the request.
    public func toolBlockReason(tool: String, arguments: [String: Any] = [:], scopeApproved: Bool = false) -> String? {
        switch gate {
        case .allow:
            return nil
        case .needsScope:
            guard Self.isPassiveToolCall(tool: tool, arguments: arguments) else {
                return "authorization/scope required for \(kind.rawValue): \(reason). Allowed now: \(allowedActions.joined(separator: ", "))"
            }
            return nil
        case .planOnly:
            guard !Self.stateChangingOrControlTools.contains(tool) || Self.isPassiveToolCall(tool: tool, arguments: arguments) else {
                return "plan-only scope for \(kind.rawValue): \(reason). Run read-only investigation and present a plan before active work."
            }
            return nil
        case .needsApproval:
            guard Self.approvalSensitiveTools.contains(tool), !scopeApproved else { return nil }
            return "explicit approval required for \(kind.rawValue): \(reason)"
        }
    }

    /// Used by hosts to prompt before running active tools in `.needsApproval` scopes.
    public func requiresExplicitApproval(tool: String, arguments: [String: Any] = [:]) -> String? {
        guard gate == .needsApproval, Self.approvalSensitiveTools.contains(tool) else { return nil }
        return "active \(kind.rawValue) work needs explicit approval: \(reason)"
    }

    private static let passiveTools: Set<String> = [
        "list_files", "glob_files", "read_file", "search_code", "web_search",
        "context_brain",
        "view_image",
        "read_spreadsheet", "query_data", "security_audit", "governance_report",
        "business_workflow", "ask_user", "generate"
    ]

    private static func isPassiveToolCall(tool: String, arguments: [String: Any]) -> Bool {
        if passiveTools.contains(tool) { return true }
        if tool == "custom_tool", (arguments["action"] as? String)?.lowercased() == "list" { return true }
        if tool == "tasks" {
            let action = (arguments["action"] as? String ?? "list")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["list", "map", "validate", "check"].contains(action)
        }
        return false
    }

    private static let stateChangingOrControlTools: Set<String> = [
        "write_file", "edit_file", "apply_patch", "move_file", "make_dir",
        "run_command", "computer_control", "browse", "fetch_url",
        "analyze_media", "media_clip", "extract_clip", "watch_video",
        "live_screen_watch", "generate_image", "visual_verify",
        "custom_tool", "tasks",
        "spawn_agent"
    ]

    private static let approvalSensitiveTools: Set<String> = stateChangingOrControlTools.union([
        "security_audit"
    ])
}

/// Deterministic scope policy for workflows where "just do it" is unsafe: bug bounty / recon,
/// visual reconstruction of apps, server remediation, and user-visible computer control.
///
/// This is both a prompt/routing primitive and a runtime enforcement primitive. Tools still enforce
/// their own local safety boundaries; the scope gate also keeps active tools from running when
/// authority is missing or approval has not been granted.
public enum AuthorizationScopeEngine {
    public static func evaluate(_ request: String) -> ScopeDecision {
        let lower = request.lowercased()

        if matchesAny(lower, ["reconstruct", "clone this app", "rebuild this app", "copy this website", "visual clone", "pixel match"]) {
            let owned = matchesAny(lower, ["my app", "my site", "our app", "owned", "authorized", "client-approved", "i own"])
            return ScopeDecision(kind: .visualReconstruction, gate: owned ? .needsApproval : .needsScope,
                                 reason: owned ? "visual reconstruction is allowed only for owned/authorized properties and still needs confirmation before capture/build loops"
                                               : "visual reconstruction may implicate copyright/trade dress unless ownership or authorization is clear",
                                 allowedActions: ["ask ownership/scope questions", "analyze provided screenshots", "draft reconstruction plan"],
                                 blockedActions: ["crawl third-party app flows", "copy brand assets", "publish lookalike output"],
                                 requiredEvidence: ["ownership/authorization", "screens or URL allowed for analysis", "acceptable similarity target"])
        }

        if matchesAny(lower, ["bug bounty", "pentest", "penetration test", "exploit", "exploits", "exploitation",
                              "recon", "reconnaissance", "hackerone", "bugcrowd"]) {
            let claimsScope = matchesAny(lower, ["authorized", "my app", "my site", "owned", "i own", "program scope", "scope:", "safe harbor"])
            if claimsScope {
                return ScopeDecision(kind: .bugBounty, gate: .needsApproval,
                                     reason: "the request claims authorization, but active security work still needs explicit target scope and approval before testing",
                                     allowedActions: ["read policy/scope", "passive research", "static analysis", "draft test plan"],
                                     blockedActions: ["active probing", "exploit attempts", "credential attacks", "destructive payloads"],
                                     requiredEvidence: ["target host/app is in scope", "safe-harbor/program rules",
                                                        "authorization evidence beyond the prompt text", "human approval for active test"])
            }
            return ScopeDecision(kind: .bugBounty, gate: .needsScope,
                                 reason: "security testing request lacks explicit authorization or program scope",
                                 allowedActions: ["ask clarifying questions", "draft read-only plan", "explain legal/safety boundaries"],
                                 blockedActions: ["network probing", "exploit attempts", "automation against third-party targets"],
                                 requiredEvidence: ["written authorization or owned target", "allowed target list", "testing limits"])
        }

        if matchesAny(lower, ["server", "ssh", "production", "restart service", "nginx", "dns", "latency", "outage"]) {
            let remediation = matchesAny(lower, ["restart", "fix it", "change config", "apply", "deploy", "remediate"])
            return ScopeDecision(kind: .serverDiagnostics, gate: remediation ? .needsApproval : .planOnly,
                                 reason: remediation ? "server remediation can change availability and needs approval after read-only diagnosis"
                                                     : "server diagnosis should begin read-only and cite metrics/log lines before any change",
                                 allowedActions: ["read-only health checks", "log/metric correlation", "ranked diagnosis", "remediation plan"],
                                 blockedActions: remediation ? ["service restart", "config writes", "deploys", "firewall changes"] : [],
                                 requiredEvidence: ["target host is owned/authorized", "commands to run", "rollback/re-check plan"])
        }

        if matchesAny(lower, ["open safari", "launch safari", "start safari",
                              "open chrome", "launch chrome", "start chrome",
                              "open firefox", "launch firefox", "start firefox",
                              "open app", "open browser", "open the browser", "launch browser", "start browser",
                              "clean desktop", "play me", "open youtube", "search youtube", "youtube search", "play youtube"]) {
            return ScopeDecision(kind: .desktopControl, gate: .needsApproval,
                                 reason: "computer control is user-visible and must use typed actions with approval",
                                 allowedActions: ["open_app", "open_url", "youtube_search", "clean_desktop dry-run"],
                                 blockedActions: ["delete files", "arbitrary shell GUI automation", "credential entry"],
                                 requiredEvidence: ["typed computer_control action", "user approval when prompted"])
        }

        return ScopeDecision(kind: .normal, gate: .allow, reason: "normal task",
                             allowedActions: [], blockedActions: [], requiredEvidence: [])
    }

    /// Match phrases as adjacent token sequences, and single words as full tokens. This prevents scope
    /// gates from firing on accidental substrings: `reconstruct` must not match security `recon`,
    /// `product` must not match production server work, and `youtube-dl` must not match "open YouTube".
    static func matchesAny(_ text: String, _ needles: [String]) -> Bool {
        let tokenList = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let tokens = Set(tokenList)
        return needles.contains { needle in
            let parts = needle.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            guard !parts.isEmpty else { return false }
            if parts.count == 1 {
                return tokens.contains(parts[0])
            }
            guard tokenList.count >= parts.count else { return false }
            for start in 0...(tokenList.count - parts.count) {
                if Array(tokenList[start..<(start + parts.count)]) == parts { return true }
            }
            return false
        }
    }
}
