import XCTest
@testable import Kist

final class ChainTests: XCTestCase {
    private func node(_ id: String, _ kind: ChainNode.Kind, _ title: String, _ cfg: [String: String] = [:]) -> ChainNode {
        ChainNode(id: id, kind: kind, title: title, config: cfg)
    }

    func testValidateRequiresExactlyOneTriggerAndRealEdges() {
        var c = Chain(id: "c1", name: "x", nodes: [node("p", .prompt, "step", ["prompt": "hi"])], edges: [])
        XCTAssertTrue(c.validate().contains { $0.contains("no trigger") })
        c.nodes.insert(node("t", .manualTrigger, "start"), at: 0)
        c.edges = [ChainEdge(from: "t", to: "nope")]
        XCTAssertTrue(c.validate().contains { $0.contains("unknown node") })
        c.edges = [ChainEdge(from: "t", to: "p")]
        XCTAssertTrue(c.validate().isEmpty, "one trigger + real edges + prompt text = valid")
    }

    func testValidateFlagsEmptyPromptAndDoubleTrigger() {
        let c = Chain(id: "c", name: "x",
                      nodes: [node("t", .manualTrigger, "a"), node("t2", .manualTrigger, "b"),
                              node("p", .prompt, "empty", ["prompt": "  "])],
                      edges: [ChainEdge(from: "t", to: "p")])
        let probs = c.validate()
        XCTAssertTrue(probs.contains { $0.contains("more than one trigger") })
        XCTAssertTrue(probs.contains { $0.contains("no prompt text") })
    }

    func testStoreRoundTripAndFindByName() {
        let root = NSTemporaryDirectory() + "chain_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = ChainStore(projectRoot: root)
        let c = Chain(id: "c1", name: "Daily Email", nodes: [node("t", .manualTrigger, "start")], createdAt: 1, updatedAt: 2)
        XCTAssertTrue(store.save(c))
        XCTAssertEqual(store.load(id: "c1"), c)
        XCTAssertEqual(store.find("daily email")?.id, "c1")   // case-insensitive by name
        XCTAssertEqual(store.all().count, 1)
        XCTAssertTrue(store.delete(id: "c1"))
        XCTAssertNil(store.load(id: "c1"))
    }

    func testRunnerLinearPassesOutputToNextStepInput() async {
        // trigger → prompt(A) → prompt(B uses {{input}}) → output
        let chain = Chain(id: "c", name: "x",
                          nodes: [node("t", .manualTrigger, "start"),
                                  node("a", .prompt, "A", ["prompt": "greet"]),
                                  node("b", .prompt, "B", ["prompt": "echo {{input}}"]),
                                  node("o", .output, "done")],
                          edges: [ChainEdge(from: "t", to: "a"), ChainEdge(from: "a", to: "b"),
                                  ChainEdge(from: "b", to: "o")])
        let runner = ChainRunner(runStep: { p in p == "greet" ? "hello" : "ran: \(p)" })
        let r = await runner.run(chain)
        // step B's prompt had {{input}} replaced with "hello" (A's output)
        XCTAssertTrue(r.steps.contains { $0.nodeID == "b" && $0.output == "ran: echo hello" })
        XCTAssertEqual(r.finalText, "ran: echo hello")
    }

    func testRunnerConditionRoutesTrueFalseEdges() async {
        // trigger → prompt → condition(match:"yes") → true→outT / false→outF
        let chain = Chain(id: "c", name: "x",
                          nodes: [node("t", .manualTrigger, "start"),
                                  node("p", .prompt, "ask", ["prompt": "ask"]),
                                  node("c", .condition, "has yes?", ["match": "yes"]),
                                  node("y", .output, "YES branch"),
                                  node("n", .output, "NO branch")],
                          edges: [ChainEdge(from: "t", to: "p"), ChainEdge(from: "p", to: "c"),
                                  ChainEdge(from: "c", to: "y", label: "true"),
                                  ChainEdge(from: "c", to: "n", label: "false")])
        let yes = await ChainRunner(runStep: { _ in "the answer is yes" }).run(chain)
        XCTAssertTrue(yes.steps.contains { $0.nodeID == "y" }, "matching text takes the true edge")
        XCTAssertFalse(yes.steps.contains { $0.nodeID == "n" })
        let no = await ChainRunner(runStep: { _ in "nope" }).run(chain)
        XCTAssertTrue(no.steps.contains { $0.nodeID == "n" }, "non-matching text takes the false edge")
    }

    func testServerServesCanvasAndAPIRoundTrip() async throws {
        let root = NSTemporaryDirectory() + "chainsrv_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = ChainStore(projectRoot: root)
        let server = ChainServer(store: store, runChain: { c in ChainRunner.RunResult(chainID: c.id, steps: [], outputs: []) })
        guard let url = try XCTUnwrap(server.start()) as URL? else { return XCTFail("server didn't start") }
        defer { server.stop() }

        let (page, _) = try await URLSession.shared.data(from: url)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("KIST CHAINS"), "GET / serves the canvas")

        let (empty, _) = try await URLSession.shared.data(from: url.appendingPathComponent("api/chains"))
        XCTAssertEqual(String(decoding: empty, as: UTF8.self).trimmingCharacters(in: .whitespaces), "[]")

        var req = URLRequest(url: url.appendingPathComponent("api/chain")); req.httpMethod = "POST"
        req.httpBody = try JSONEncoder().encode(Chain(id: "", name: "T", nodes: [node("t", .manualTrigger, "s")]))
        let (saved, _) = try await URLSession.shared.data(for: req)
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains("\"ok\":true"), "POST /api/chain saves")
        XCTAssertEqual(store.all().count, 1, "the chain persisted through the HTTP layer")
    }

    func testRunnerCycleGuardStopsRunaway() async {
        let chain = Chain(id: "c", name: "x",
                          nodes: [node("t", .manualTrigger, "start"), node("a", .prompt, "A", ["prompt": "x"])],
                          edges: [ChainEdge(from: "t", to: "a"), ChainEdge(from: "a", to: "a")])  // self-loop
        let r = await ChainRunner(runStep: { _ in "y" }).run(chain)
        XCTAssertLessThanOrEqual(r.steps.count, 3, "a cycle must not run forever")
    }
}
