import XCTest
@testable import AgentCore

private actor DecisionProbe {
    var payloads: [String] = []
    func append(_ value: String) { payloads.append(value) }
    func count() -> Int { payloads.count }
}

final class DecisionEngineTests: XCTestCase {
    func testAdvisoryOperationsSurviveReadOnlyFilteringButCreationDoesNotGainAuthority() throws {
        let engine = DecisionEngine(provider: "fixture", model: "fixture") { _, _ in DecisionInference(text: "") }
        let registry = ToolRegistry([DecideTool(engine: engine), DecisionTool(engine: engine), WriteFileTool()])
        for intent in [TaskBrief.Intent.chat, .review, .research, .plan, .delegate] {
            let narrowed = HeadlessAgentLoop.conversationalToolset(registry, intent: intent)
            XCTAssertNotNil(narrowed.tool(named: "decide")); XCTAssertNotNil(narrowed.tool(named: "decision_tool"))
            XCTAssertNil(narrowed.tool(named: "write_file"))
            XCTAssertFalse(HeadlessAgentLoop.isTrustedReadOnlyCall(registry: narrowed, tool: "decision_tool", args: ["action": "create"]))
            for action in ["get", "list", "run"] {
                XCTAssertTrue(HeadlessAgentLoop.isTrustedReadOnlyCall(registry: narrowed, tool: "decision_tool", args: ["action": action]))
            }
        }
        for text in ["Create a reusable decision_tool named triage", "Please save a decision tool called triage"] {
            XCTAssertTrue(DecisionToolRequest.matches(text))
            XCTAssertEqual(PromptCompiler.inferIntent(text), .build)
            let narrowed = HeadlessAgentLoop.conversationalToolset(registry, intent: .build, request: text)
            XCTAssertNil(narrowed.tool(named: "write_file"))
        }
        for text in ["Explain how to create a decision tool", "Review this decision tool", "Create an executable tool"] {
            XCTAssertFalse(DecisionToolRequest.matches(text))
        }
    }

    func testInvalidBackendConfigurationDoesNotSpendOrFallback() async throws {
        let budget = BudgetLedger(maxTokens: 100_000)
        let engine = DecisionEngine.configured(providers: ProviderRegistry(providers: []),
            binding: ProviderBinding(providerId: "missing", model: "missing"), budget: budget,
            environment: ["KIST_DECISION_BACKEND": "systemone", "KIST_DECISION_MODEL": "nimble", "KIST_DECISION_BASE_URL": "https://external.invalid"])
        do { _ = try await engine.evaluate(state: "test", questions: questions); XCTFail() } catch { }
        let spent = await budget.spentTokens(); XCTAssertEqual(spent, 0)
    }

    let questions: [String: Any] = [
        "route": ["type": "choice", "instructions": "Choose a team", "criteria": ["billing": "Refunds", "technical": "Bugs"]],
        "refund": ["type": "noul", "instructions": "Was a refund requested?"],
        "urgency": ["type": "score", "instructions": "Rate urgency", "criteria": ["Routine", "Soon", "Urgent"]]
    ]
    let answer = #"{"answers":{"route":{"probabilities":{"billing":0.9,"technical":0.1}},"refund":{"probabilities":{"true":0.8,"false":0.2}},"urgency":{"probabilities":{"0":0.1,"1":0.3,"2":0.6}}}}"#

    func testAllThreeTypesAndCacheBindTheExactStateAndQuestions() async throws {
        let probe = DecisionProbe(); let response = answer
        let trace = TraceRecorder(traceId: "decision-cache")
        let engine = DecisionEngine(provider: "fixture", model: "fixed", recorder: trace) { payload, _ in
            await probe.append(payload); return DecisionInference(text: response, usage: TokenUsage(promptTokens: 55, completionTokens: 20))
        }
        let first = try await engine.evaluate(state: ["ticket": "Refund please"], questions: questions)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.output.utf8)) as? [String: Any])
        let answers = try XCTUnwrap(body["answers"] as? [String: [String: Any]])
        XCTAssertEqual(answers["route"]?["choice"] as? String, "billing")
        XCTAssertEqual(answers["refund"]?["noul"] as? Double, 0.8)
        XCTAssertEqual(try XCTUnwrap(answers["urgency"]?["score"] as? Double), 1.5, accuracy: 1e-12)
        XCTAssertEqual(body["probability_source"] as? String, "model_estimate")
        XCTAssertEqual(body["advisory"] as? Bool, true)
        let cached = try await engine.evaluate(state: ["ticket": "Refund please"], questions: questions)
        XCTAssertEqual(cached.metadata["cached"], "true")
        let count = await probe.count(); XCTAssertEqual(count, 1)
        _ = try await engine.evaluate(state: ["ticket": "App crashes"], questions: questions)
        let changed = await probe.count(); XCTAssertEqual(changed, 2)
        let spans = await trace.all()
        XCTAssertEqual(spans.count, 2, "cached judgments do not manufacture model calls")
        XCTAssertEqual(spans.reduce(0) { $0 + $1.totalTokens }, 150)
    }

    func testMalformedBatchAndFalseConfidenceCannotProduceTrustedDecision() async throws {
        for response in ["not JSON", #"{"answers":{}}"#,
            #"{"answers":{"route":{"probabilities":{"billing":true,"technical":false}}}}"#,
            #"{"answers":{"route":{"probabilities":{"billing":0.9,"technical":0.9}}}}"#,
            #"{"answers":{"route":{"probabilities":{"billing":1,"execute_shell":0}}}}"#] {
            let engine = DecisionEngine(provider: "fixture", model: "fixed") { _, _ in DecisionInference(text: response) }
            do { _ = try await engine.evaluate(state: "evidence", questions: ["route": questions["route"]!]); XCTFail("accepted malformed answer") }
            catch { }
        }
    }

    func testBudgetRefusesBeforeInferenceAndChargesMalformedOutput() async throws {
        let probe = DecisionProbe(); let response = answer
        let budget = BudgetLedger(maxTokens: 1)
        let engine = DecisionEngine(provider: "fixture", model: "fixed", budget: budget) { payload, _ in
            await probe.append(payload); return DecisionInference(text: response)
        }
        let result = try await engine.evaluate(state: "x", questions: questions)
        XCTAssertFalse(result.success)
        let count = await probe.count(); XCTAssertEqual(count, 0)
        let paid = BudgetLedger(maxTokens: 100_000)
        let bad = DecisionEngine(provider: "fixture", model: "fixed", budget: paid) { _, _ in
            DecisionInference(text: "malformed", usage: TokenUsage(promptTokens: 81, completionTokens: 9))
        }
        do { _ = try await bad.evaluate(state: "x", questions: questions); XCTFail() } catch { }
        let spent = await paid.spentTokens(); XCTAssertEqual(spent, 90)
        let unpriced = DecisionEngine(provider: "unpriced", model: "fixed", budget: BudgetLedger(maxUSD: 1)) { _, _ in
            XCTFail("a dollar-only cap cannot authorize unpriced inference"); return DecisionInference(text: "")
        }
        let refused = try await unpriced.evaluate(state: "x", questions: questions)
        XCTAssertFalse(refused.success); XCTAssertTrue(refused.diagnosticText.contains("cannot price"))
    }

    func testInputLimitsAndQuestionSchemasRejectBeforeInference() async throws {
        let engine = DecisionEngine(provider: "fixture", model: "fixed") { _, _ in XCTFail("must not call provider"); return DecisionInference(text: "") }
        for invalid in [[:], ["q": ["type": "shell", "instructions": "run"]],
                        ["q": ["type": "choice", "instructions": "pick", "criteria": ["only": "one"]]],
                        ["../escape": questions["refund"]!]] as [[String: Any]] {
            do { _ = try await engine.evaluate(state: "x", questions: invalid); XCTFail() } catch { }
        }
        do { _ = try await engine.evaluate(state: String(repeating: "z", count: 70_000), questions: questions); XCTFail() } catch { }
        do { _ = try await engine.evaluate(state: ["x": Double.infinity], questions: questions); XCTFail() } catch { }
    }

    func testRequestCeilingAllowsCachedCallsButNoNewInference() async throws {
        let response = answer
        let engine = DecisionEngine(provider: "fixture", model: "fixed", maxCalls: 1) { _, _ in DecisionInference(text: response) }
        _ = try await engine.evaluate(state: "a", questions: questions)
        let cached = try await engine.evaluate(state: "a", questions: questions)
        let denied = try await engine.evaluate(state: "b", questions: questions)
        XCTAssertTrue(cached.success); XCTAssertFalse(denied.success)
    }

    func testGeneratedToolPersistsAndRunsThroughRegistryAfterReload() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let context = ToolContext(projectRoot: temporary.resolvingSymlinksInPath().path)
        let response = answer
        let engine = DecisionEngine(provider: "fixture", model: "fixed") { _, _ in DecisionInference(text: response) }
        let tools = ToolRegistry([DecisionTool(engine: engine), DecideTool(engine: engine)])
        let created = await tools.execute(name: "decision_tool", arguments: ["action": "create", "name": "triage", "questions": questions], context: context)
        XCTAssertTrue(created.success, created.diagnosticText)
        let saved = try String(contentsOfFile: context.projectRoot + "/.kist/decision-tools/triage.json", encoding: .utf8)
        XCTAssertEqual(created.metadata["sha256"], DecisionEngine.hash(saved))
        let effect = ToolEffectCatalog.observe(tool: "decision_tool", arguments: ["action": "create"], outcomeMetadata: created.metadata)
        XCTAssertTrue(ToolEffectCatalog.knownMutationTools.contains("decision_tool"), "governed workspace identity applies to definition saves")
        XCTAssertTrue(effect.confirmsMutation); XCTAssertFalse(effect.requiresBuildVerification)
        let savedAgain = await tools.execute(name: "decision_tool", arguments: ["action": "create", "name": "triage", "questions": questions], context: context)
        XCTAssertEqual(savedAgain.metadata["written"], "true")
        XCTAssertEqual(savedAgain.metadata["sha256"], created.metadata["sha256"])
        XCTAssertTrue(ToolEffectCatalog.observe(tool: "decision_tool", arguments: ["action": "create"], outcomeMetadata: savedAgain.metadata).confirmsMutation)
        let reloaded = ToolRegistry([DecisionTool(engine: engine)])
        let run = await reloaded.execute(name: "decision_tool", arguments: ["action": "run", "name": "triage", "state": ["ticket": "Refund"]], context: context)
        XCTAssertTrue(run.success, run.diagnosticText); XCTAssertTrue(run.output.contains("billing"))
        let escaped = await tools.execute(name: "decision_tool", arguments: ["action": "create", "name": "../escape", "questions": questions], context: context)
        XCTAssertFalse(escaped.success)
        let invalid = await tools.execute(name: "decide", arguments: ["state": ["text": "x"], "questions": questions, "endpoint": "https://evil.test"], context: context)
        XCTAssertFalse(invalid.success)
        let contract = ToolContractBook.render(tools: tools)
        XCTAssertTrue(contract.contains("## decide")); XCTAssertTrue(contract.contains("create, get, list, run"))
        XCTAssertTrue(contract.contains("criteria")); XCTAssertTrue(contract.contains("instructions: string"))
        XCTAssertEqual(ReversibilityClassifier.assess(tool: "decision_tool", args: ["action": "create"], projectRoot: context.projectRoot), .mutating)
    }

    func testOllamaNativeRequestAndResponseUseRealProtocolShapes() throws {
        let client = try SystemOneDecisionClient(model: "nimble")
        let payload = try DecisionEngine.json(["state": ["text": "Refund"], "questions": [
            "refund": ["type": "noul", "instructions": "Refund?", "options": ["true": "Yes", "false": "No"]],
            "priority": ["type": "score", "instructions": "Urgency", "options": ["0": "Routine", "1": "Urgent"]]]])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: client.requestBody(payload)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "nimble")
        let questions = try XCTUnwrap(body["questions"] as? [String: [String: Any]])
        XCTAssertEqual(questions["priority"]?["criteria"] as? [String], ["Routine", "Urgent"])
        let inference = try client.decode(Data(#"{"model":"nimble","answers":{"refund":{"type":"noul","noul":0.8}},"usage":{"input_tokens":12,"output_tokens":1}}"#.utf8))
        XCTAssertEqual(inference.usage.total, 13); XCTAssertTrue(inference.text.contains("probabilities"))
        for url in ["https://evil.test", "http://127.0.0.1.evil.test", "http://user@127.0.0.1", "http://localhost/path"] {
            XCTAssertThrowsError(try SystemOneDecisionClient(baseURL: url, model: "nimble"))
        }
        XCTAssertThrowsError(try client.decode(Data(#"{"model":"other","answers":{}}"#.utf8)))
        for value in ["true", "-1", "1.1", "\"invalid\""] {
            XCTAssertThrowsError(try client.decode(Data("{\"model\":\"nimble\",\"answers\":{\"q\":{\"type\":\"noul\",\"noul\":\(value)}}}".utf8)))
            XCTAssertThrowsError(try client.decode(Data("{\"model\":\"nimble\",\"answers\":{},\"usage\":{\"input_tokens\":\(value)}}".utf8)))
        }
        XCTAssertThrowsError(try SystemOneDecisionClient(model: "nimble\n"))
        XCTAssertFalse(DecisionQuestion.validName("triage\n"))
        XCTAssertThrowsError(try client.decode(Data(repeating: 32, count: 128 * 1024 + 1)))
    }

    func testNestedAdmissionFailureDoesNotChargeUnsentInferenceButRetryFailureDoes() async throws {
        for consumeFirst in [false, true] {
            let ledger = BudgetLedger(maxTokens: 100_000)
            let requests = ProviderRequestBudget(limit: consumeFirst ? 1 : 0)
            let engine = DecisionEngine(provider: "fixture", model: "fixture", budget: ledger) { _, _ in
                if consumeFirst { try await requests.admit() }
                try await requests.admit()
                XCTFail("exhausted request must not run"); return DecisionInference(text: "")
            }
            do {
                _ = try await DecisionRequestScope.$budget.withValue(requests) {
                    try await engine.evaluate(state: "x", questions: questions)
                }
                XCTFail("exhausted request accepted")
            } catch is ProviderRequestBudgetError { }
            let spent = await ledger.spentTokens()
            XCTAssertEqual(spent > 0, consumeFirst)
        }
    }
}
