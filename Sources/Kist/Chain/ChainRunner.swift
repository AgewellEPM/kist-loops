import Foundation

/// Executes a chain: start at the trigger, walk the graph, run each step. A `prompt` step runs a real
/// Kist turn via the injected `runStep` closure (so the engine stays decoupled + unit-testable); its
/// answer becomes the input to the next step (available as `{{input}}` / `{{last}}` in the next prompt).
/// A `condition` step routes to the "true"/"false" edge. `output` steps collect the final result.
///
/// v1 is a linear/branching walk (depth-first from the trigger), bounded so a bad graph can't loop forever.
struct ChainRunner {
    /// Runs one prompt and returns the model's answer. Real impl drives the agent loop; tests stub it.
    let runStep: (_ prompt: String) async -> String
    var maxSteps: Int = 50

    struct StepResult: Equatable {
        let nodeID: String
        let title: String
        let kind: ChainNode.Kind
        let input: String
        let output: String
    }
    struct RunResult: Equatable {
        let chainID: String
        let steps: [StepResult]
        let outputs: [String]        // collected `output`-node results
        var finalText: String { outputs.last ?? steps.last?.output ?? "" }
    }

    func run(_ chain: Chain, triggerInput: String = "") async -> RunResult {
        var steps: [StepResult] = []
        var outputs: [String] = []
        guard let trigger = chain.triggerNode else {
            return RunResult(chainID: chain.id, steps: [], outputs: [])
        }

        var current: ChainNode? = trigger
        var carried = triggerInput            // the value flowing between steps
        var visited = Set<String>()
        var budget = maxSteps

        while let node = current, budget > 0 {
            budget -= 1
            if visited.contains(node.id) { break }   // cycle guard
            visited.insert(node.id)

            let output: String
            switch node.kind {
            case .manualTrigger, .scheduleTrigger:
                output = carried                       // triggers just pass the incoming value through
            case .prompt:
                let prompt = Self.interpolate(node.config["prompt"] ?? "", input: carried)
                output = await runStep(prompt)
            case .condition:
                let match = (node.config["match"] ?? "").lowercased()
                let hit = !match.isEmpty && carried.lowercased().contains(match)
                output = hit ? "true" : "false"
            case .output:
                output = carried
                outputs.append(carried)
            }

            steps.append(StepResult(nodeID: node.id, title: node.title, kind: node.kind,
                                    input: carried, output: output))

            // Pick the next node. A condition follows the edge labeled with its result; everything else
            // follows the first outgoing edge.
            let outgoing = chain.edges(from: node.id)
            let next: ChainEdge?
            if node.kind == .condition {
                next = outgoing.first { ($0.label ?? "").lowercased() == output } ?? outgoing.first { $0.label == nil }
            } else {
                next = outgoing.first
            }
            // A condition's own output ("true"/"false") is control flow, not data — keep carrying the
            // real value; every other step's output becomes the next input.
            if node.kind != .condition { carried = output }
            current = next.flatMap { chain.node($0.to) }
        }

        return RunResult(chainID: chain.id, steps: steps, outputs: outputs)
    }

    /// Substitute the flowing value into a prompt. `{{input}}` / `{{last}}` → the previous step's output.
    static func interpolate(_ template: String, input: String) -> String {
        template
            .replacingOccurrences(of: "{{input}}", with: input)
            .replacingOccurrences(of: "{{last}}", with: input)
    }
}
