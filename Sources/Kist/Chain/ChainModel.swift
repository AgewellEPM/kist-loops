import Foundation

/// A "chain" — a small visual automation (Zapier × LangGraph for Kist): a TRIGGER flows into a graph of
/// STEPS that Kist executes. Authored in the `/chain` web canvas, saved as JSON in `.kist/chains/`, then
/// run on demand or on a schedule. Pure data (Codable) so the engine + UI + storage all share one truth.
struct Chain: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var nodes: [ChainNode]
    var edges: [ChainEdge]
    var enabled: Bool
    var schedule: String?          // cron-ish ("daily 09:00", "*/30m") when any node is a schedule trigger; nil = manual
    var createdAt: Double
    var updatedAt: Double

    init(id: String, name: String, nodes: [ChainNode] = [], edges: [ChainEdge] = [],
         enabled: Bool = true, schedule: String? = nil, createdAt: Double = 0, updatedAt: Double = 0) {
        self.id = id; self.name = name; self.nodes = nodes; self.edges = edges
        self.enabled = enabled; self.schedule = schedule; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// The single entry node (a trigger). A well-formed chain has exactly one.
    var triggerNode: ChainNode? { nodes.first { $0.kind.isTrigger } }

    /// Outgoing edges from a node, in stable order.
    func edges(from nodeID: String) -> [ChainEdge] {
        edges.filter { $0.from == nodeID }
    }

    func node(_ id: String) -> ChainNode? { nodes.first { $0.id == id } }

    /// Structural validation for save/run: one trigger, all edges reference real nodes, no obvious cycle
    /// back to the trigger. Returns the problems (empty = valid).
    func validate() -> [String] {
        var problems: [String] = []
        let triggers = nodes.filter { $0.kind.isTrigger }
        if triggers.isEmpty { problems.append("no trigger node — every chain needs one entry point") }
        if triggers.count > 1 { problems.append("more than one trigger node (\(triggers.count)) — keep exactly one entry point") }
        let ids = Set(nodes.map(\.id))
        for e in edges {
            if !ids.contains(e.from) { problems.append("edge from unknown node '\(e.from)'") }
            if !ids.contains(e.to) { problems.append("edge to unknown node '\(e.to)'") }
        }
        for n in nodes where n.kind == .prompt {
            if (n.config["prompt"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("step '\(n.title)' has no prompt text")
            }
        }
        return problems
    }
}

struct ChainNode: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case manualTrigger      // run on demand
        case scheduleTrigger    // run on a cron/daily schedule
        case prompt             // run a Kist agent turn; output = the answer, passed to the next node
        case condition          // branch: does the incoming text match? → edges labeled "true"/"false"
        case output             // terminal: collect/emit the final result

        var isTrigger: Bool { self == .manualTrigger || self == .scheduleTrigger }
    }
    var id: String
    var kind: Kind
    var title: String
    /// Kind-specific settings. prompt: ["prompt": "..."]; scheduleTrigger: ["schedule": "daily 09:00"];
    /// condition: ["match": "yes"]; output: ["label": "result"]. Strings so it round-trips cleanly to JSON/JS.
    var config: [String: String]
    var x: Double
    var y: Double

    init(id: String, kind: Kind, title: String, config: [String: String] = [:], x: Double = 0, y: Double = 0) {
        self.id = id; self.kind = kind; self.title = title; self.config = config; self.x = x; self.y = y
    }
}

struct ChainEdge: Codable, Equatable, Sendable {
    var from: String
    var to: String
    var label: String?          // "true"/"false" out of a condition; nil for a plain flow edge
    init(from: String, to: String, label: String? = nil) { self.from = from; self.to = to; self.label = label }
}
