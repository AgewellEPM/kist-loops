import Foundation

/// Evidence-first research primitive. It gives agents one resumable place to plan, gather,
/// heartbeat, and synthesize research before a council/planner turns it into work.
public struct ResearchRunTool: AgentTool {
    public typealias Runner = @Sendable (_ arguments: [String: Any], _ context: ToolContext) async throws -> ToolResult

    public let name = "research_run"
    public let description = """
    Manage a durable research run under .kist/research-runs/<id>. Use this before deep planning: \
    start a run, gather web/search/browser/repo evidence, record visual artifacts, heartbeat progress, \
    synthesize a dossier, then feed that dossier into council/plan-execute.
    """
    public let parameters = [
        ToolParameter(name: "action", type: "string", description: "start | status | heartbeat | search | fetch | browse | visual | context | add_evidence | synthesize", required: true),
        ToolParameter(name: "goal", type: "string", description: "Research goal for action=start, or fallback goal when creating a run.", required: false),
        ToolParameter(name: "run_id", type: "string", description: "Research run id. Omit for action=start.", required: false),
        ToolParameter(name: "query", type: "string", description: "Search or context query.", required: false),
        ToolParameter(name: "url", type: "string", description: "URL for action=fetch or browse.", required: false),
        ToolParameter(name: "reference", type: "string", description: "Reference image path for action=visual.", required: false),
        ToolParameter(name: "candidate", type: "string", description: "Candidate image path for action=visual.", required: false),
        ToolParameter(name: "actions", type: "array", description: "Browser actions for action=browse.", required: false),
        ToolParameter(name: "kind", type: "string", description: "Evidence kind for action=add_evidence.", required: false),
        ToolParameter(name: "title", type: "string", description: "Evidence title.", required: false),
        ToolParameter(name: "text", type: "string", description: "Evidence text for action=add_evidence.", required: false),
        ToolParameter(name: "path", type: "string", description: "Optional local artifact path for visual/file evidence.", required: false),
        ToolParameter(name: "message", type: "string", description: "Heartbeat message.", required: false),
    ]

    public var supportedActions: [String] {
        ["start", "status", "heartbeat", "search", "fetch", "browse", "visual", "context", "add_evidence", "synthesize"]
    }
    public var unsupportedActions: [String] {
        ["crawl_unbounded", "bypass_allowlist", "claim_without_evidence", "write_code"]
    }
    public var capabilityNote: String? {
        "Research is resumable by run_id. Gather evidence first, then call synthesize and hand the dossier to council/plan-execute."
    }
    public var usageExamples: [String] {
        [
            "research_run(action=\"start\", goal=\"compare browser automation options\")",
            "research_run(action=\"search\", run_id=\"...\", query=\"Playwright screenshots trace viewer\")",
            "research_run(action=\"synthesize\", run_id=\"...\")",
        ]
    }

    private let search: Runner
    private let fetch: Runner
    private let browse: Runner
    private let visual: Runner
    private let contextBrain: Runner

    public init(allowedHosts: [String] = [], visual: Runner? = nil) {
        let searchTool = WebSearchTool()
        let fetchTool = WebFetchTool(allowedHosts: allowedHosts)
        let browserTool = BrowserTool(allowedHosts: allowedHosts)
        let contextTool = ContextBrainTool()
        // Each sub-action re-enters the SHARED ToolGate under its REAL tool name, so a composite call
        // is scope-checked + audited exactly like a top-level call (council #1 / Codex composite-bypass).
        self.init(
            search: { args, ctx in await ToolGate.run(name: searchTool.name, arguments: args, context: ctx) {
                try await searchTool.execute(arguments: args, context: ctx) } },
            fetch: { args, ctx in await ToolGate.run(name: fetchTool.name, arguments: args, context: ctx) {
                try await fetchTool.execute(arguments: args, context: ctx) } },
            browse: { args, ctx in await ToolGate.run(name: browserTool.name, arguments: args, context: ctx) {
                try await browserTool.execute(arguments: args, context: ctx) } },
            // The visual runner is INJECTED (KistRunner passes visual_verify's execute). It MUST re-enter
            // the gate under the real `visual_verify` name like the other four sub-actions — otherwise
            // visual verification through research_run skips skill-scope + authorization-scope + audit
            // (Codex HIGH). Wrap whichever runner is active (injected, or the unavailable-fallback).
            visual: { args, ctx in
                let runner = visual ?? { _, _ in ToolResult.failure("visual research gatherer unavailable: configure a vision-capable provider, or run visual_verify separately and record its report with research_run add_evidence") }
                return await ToolGate.run(name: "visual_verify", arguments: args, context: ctx) {
                    try await runner(args, ctx)
                }
            },
            contextBrain: { args, ctx in await ToolGate.run(name: contextTool.name, arguments: args, context: ctx) {
                try await contextTool.execute(arguments: args, context: ctx) } }
        )
    }

    public init(search: @escaping Runner,
                fetch: @escaping Runner,
                browse: @escaping Runner,
                visual: @escaping Runner = { _, _ in .failure("visual research gatherer unavailable") },
                contextBrain: @escaping Runner) {
        self.search = search
        self.fetch = fetch
        self.browse = browse
        self.visual = visual
        self.contextBrain = contextBrain
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let action = try requireString("action", from: arguments).lowercased()
        switch action {
        case "start", "plan":
            let goal = try requireString("goal", from: arguments)
            let store = try ResearchRunStore(projectRoot: context.projectRoot, goal: goal,
                                             runID: arguments["run_id"] as? String)
            try store.heartbeat(status: "planning", message: "research run started")
            let plan = Self.defaultPlan(goal: goal, runID: store.currentManifest().runID)
            try store.appendEvidence(kind: "research_plan", title: "Research plan", text: plan)
            return ToolResult(success: true, output: plan,
                              metadata: ["run_id": store.currentManifest().runID,
                                         "path": ".kist/research-runs/\(store.currentManifest().runID)"])
        case "status":
            let id = try runID(arguments)
            return ToolResult(success: true,
                              output: try ResearchRunStore.renderStatus(projectRoot: context.projectRoot, runID: id),
                              metadata: ["run_id": id])
        case "heartbeat":
            let store = try openStore(arguments, context: context)
            let message = (arguments["message"] as? String) ?? "progress"
            let status = (arguments["status"] as? String) ?? "working"
            let beat = try store.heartbeat(status: status, message: message)
            return ToolResult(success: true, output: "Heartbeat \(beat.sequence): \(beat.status) · \(beat.message)",
                              metadata: ["run_id": store.currentManifest().runID])
        case "search":
            return try await gather(kind: "web_search", title: try requireString("query", from: arguments),
                                    runner: search, runnerArgs: searchArgs(arguments), arguments: arguments,
                                    context: context)
        case "fetch":
            let url = try requireString("url", from: arguments)
            return try await gather(kind: "fetch_url", title: url, runner: fetch,
                                    runnerArgs: ["url": url], arguments: arguments, context: context,
                                    url: url)
        case "browse":
            let url = try requireString("url", from: arguments)
            var args: [String: Any] = ["url": url]
            if let actions = arguments["actions"] { args["actions"] = actions }
            if let extract = arguments["extract"] { args["extract"] = extract }
            return try await gather(kind: "browse", title: url, runner: browse,
                                    runnerArgs: args, arguments: arguments, context: context, url: url)
        case "visual":
            let goal = try requireString("goal", from: arguments)
            var args: [String: Any] = ["goal": goal]
            if let reference = arguments["reference"] { args["reference"] = reference }
            if let candidate = arguments["candidate"] { args["candidate"] = candidate }
            if let url = arguments["url"] { args["url"] = url }
            if let actions = arguments["actions"] { args["actions"] = actions }
            if let threshold = arguments["threshold"] { args["threshold"] = threshold }
            if let runID = arguments["run_id"] { args["run_id"] = "research-\(runID)" }
            return try await gather(kind: "visual_verify", title: goal, runner: visual,
                                    runnerArgs: args, arguments: arguments, context: context,
                                    url: arguments["url"] as? String)
        case "context":
            var args: [String: Any] = ["action": "coverage"]
            var title = "Context coverage"
            if let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !query.isEmpty {
                args = ["action": "search", "query": query]
                title = "Context search: \(query)"
            }
            if let limit = arguments["limit"] { args["limit"] = limit }
            return try await gather(kind: "context_brain", title: title, runner: contextBrain,
                                    runnerArgs: args, arguments: arguments, context: context)
        case "add_evidence":
            let store = try openStore(arguments, context: context)
            let kind = (arguments["kind"] as? String) ?? "note"
            let title = (arguments["title"] as? String) ?? kind
            let text = try requireString("text", from: arguments)
            let ev = try store.appendEvidence(kind: kind, title: title, text: text,
                                              url: arguments["url"] as? String,
                                              path: arguments["path"] as? String)
            try store.heartbeat(status: "gathering", message: "added \(ev.id): \(title)")
            return ToolResult(success: true, output: "Recorded \(ev.id) · \(kind): \(title)",
                              metadata: ["run_id": store.currentManifest().runID, "evidence_id": ev.id])
        case "synthesize":
            let store = try openStore(arguments, context: context)
            try store.heartbeat(status: "synthesizing", message: "writing research dossier")
            let report = try store.synthesize()
            return ToolResult(success: true, output: report,
                              metadata: ["run_id": store.currentManifest().runID,
                                         "report": ".kist/research-runs/\(store.currentManifest().runID)/report.md"])
        default:
            return .failure("unknown research_run action '\(action)'; use \(supportedActions.joined(separator: ", "))")
        }
    }

    private func gather(kind: String, title: String, runner: Runner, runnerArgs: [String: Any],
                        arguments: [String: Any], context: ToolContext, url: String? = nil) async throws -> ToolResult {
        let store = try openStore(arguments, context: context)
        try store.heartbeat(status: "gathering", message: "\(kind): \(title)")
        let result = try await runner(runnerArgs, context)
        guard result.success else {
            _ = try? store.heartbeat(status: "blocked", message: "\(kind) failed: \(result.error ?? result.output)")
            return result
        }
        let ev = try store.appendEvidence(kind: kind, title: title, text: result.output,
                                          url: url, metadata: result.metadata)
        var output = "Recorded \(ev.id) · \(kind): \(title)\n\n"
        output += result.output
        var metadata = result.metadata
        metadata["run_id"] = store.currentManifest().runID
        metadata["evidence_id"] = ev.id
        return ToolResult(success: true, output: output, metadata: metadata)
    }

    private func openStore(_ arguments: [String: Any], context: ToolContext) throws -> ResearchRunStore {
        if let id = (arguments["run_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            return try ResearchRunStore.open(projectRoot: context.projectRoot, runID: id)
        }
        let goal = (arguments["goal"] as? String) ?? "ad hoc research"
        return try ResearchRunStore(projectRoot: context.projectRoot, goal: goal)
    }

    private func runID(_ arguments: [String: Any]) throws -> String {
        try ResearchRunStore.validRunID(requireString("run_id", from: arguments))
    }

    private func searchArgs(_ arguments: [String: Any]) throws -> [String: Any] {
        var args: [String: Any] = ["query": try requireString("query", from: arguments)]
        if let limit = arguments["limit"] { args["limit"] = limit }
        if let site = arguments["site"] { args["site"] = site }
        return args
    }

    private static func defaultPlan(goal: String, runID: String) -> String {
        """
        Research run \(runID)
        Goal: \(goal)

        Evidence-first procedure:
        1. Use research_run(action="search", run_id="\(runID)", query="...") for source discovery.
        2. Use research_run(action="fetch", run_id="\(runID)", url="...") for primary sources.
        3. Use research_run(action="browse", run_id="\(runID)", url="...") when JavaScript or screenshots matter.
        4. Use research_run(action="context", run_id="\(runID)", query="...") for repo/RAG evidence.
        5. Use visual_verify separately for screenshot comparison, then record its report with add_evidence.
        6. Use research_run(action="synthesize", run_id="\(runID)") before council or plan-execute.
        """
    }
}
