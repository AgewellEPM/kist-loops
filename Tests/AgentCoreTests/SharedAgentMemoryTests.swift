import XCTest
@testable import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class SharedAgentMemoryTests: XCTestCase {
    private var root: String = ""
    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "shared-agents-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        root = try XCTUnwrap(ToolContext.canonicalize(root))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: root) }

    private func identity(_ access: AgentMemoryAccess, run: String = "prior", parent: String? = nil) -> AgentRunIdentity {
        AgentRunIdentity(runID: run, parentRunID: parent, rootRunID: parent ?? run,
                         sessionID: access.sessionID, role: "researcher", project: access.project,
                         executionRoot: root)
    }
    private func loop(_ provider: MemoryScriptedProvider, context: ToolContext, tools: ToolRegistry = ToolRegistry([]),
                      max: Int = 4) -> HeadlessAgentLoop {
        HeadlessAgentLoop(providers: ProviderRegistry(providers: [provider], keyStore: MemoryNullKeys()),
                          providerId: provider.id, model: nil, tools: tools, context: context,
                          injectAskUser: false, toolMode: .text, maxIterations: max)
    }

    func testConcurrentImmutablePublicationAndPaginationRetainEveryEvent() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        let agent = identity(access)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    let reopened = AgentHistoryStore(project: access.project)
                    for event in 0..<20 {
                        try reopened.append(agent: agent, kind: "tool_finished", detail: "worker \(worker), event \(event)")
                    }
                }
            }
            try await group.waitForAll()
        }
        var cursor: String?, all: [AgentHistoryEvent] = []
        repeat {
            let page = try AgentHistoryStore(project: access.project).page(before: cursor, limit: 17)
            XCTAssertEqual(page.rejected, 0)
            XCTAssertEqual(page.events.map(\.id), page.events.map(\.id).sorted())
            all += page.events; cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(all.count, 160)
        XCTAssertEqual(Set(all.map(\.id)).count, 160)
        XCTAssertEqual(Set(all.map(\.detail)).count, 160)
    }

    func testToolHistoryFitsVisibleEnvelopeAndPaginationNeverSkipsRows() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        let agent = identity(access, run: "needle-run-unique")
        var expected = Set<String>()
        for index in 0..<24 {
            let event = try access.history.append(agent: agent, kind: "run_finished",
                detail: "success=\(index % 2 == 0); " + String(repeating: "🌿長いhistory\\\"", count: 160))
            expected.insert(event.id)
        }
        let context = ToolContext(projectRoot: root, agentMemory: access)
        var cursor: String?, seen = Set<String>(), pages = 0
        repeat {
            var args: [String: Any] = ["mode": "history", "run_id": agent.runID, "limit": 100]
            if let cursor { args["before"] = cursor }
            let result = try await SharedAgentMemoryTool().execute(arguments: args, context: context)
            XCTAssertTrue(result.success, result.output)
            XCTAssertLessThanOrEqual(result.output.utf8.count, SharedAgentMemoryTool.resultByteLimit)
            let body = HeadlessAgentLoop.toolObservationBody(raw: result.output, metadata: result.metadata, maxBytes: 8_000)
            XCTAssertFalse(body.contains("[TRUNCATED:"))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
            let rows = try XCTUnwrap(payload["results"] as? [[String: String]])
            XCTAssertEqual(rows.map { $0["event_id"]! }, rows.map { $0["event_id"]! }.sorted())
            for row in rows { XCTAssertTrue(seen.insert(row["event_id"]!).inserted) }
            cursor = payload["next_cursor"] as? String
            pages += 1
            XCTAssertLessThan(pages, 30)
            if pages >= 30 { break }
        } while cursor != nil
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(seen, expected)

        let search = try await SharedAgentMemoryTool().execute(arguments: [
            "mode": "history_search", "query": agent.runID, "limit": 100,
        ], context: context)
        XCTAssertTrue(search.success)
        XCTAssertLessThanOrEqual(search.output.utf8.count, SharedAgentMemoryTool.resultByteLimit)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(search.output.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(payload["results"] as? [[String: String]])
        XCTAssertFalse(rows.isEmpty, "run identifiers participate in raw history search")
        XCTAssertEqual(payload["result_window_limited"] as? Bool, true)
        XCTAssertGreaterThan(payload["results_omitted_from_page"] as? Int ?? 0, 0)
    }

    func testCrossProcessAppendsSurviveRestartWithoutLostHistory() throws {
        let environment = ProcessInfo.processInfo.environment
        if let destination = environment["KIST_MEMORY_TEST_WORKER_ROOT"],
           let index = environment["KIST_MEMORY_TEST_WORKER_INDEX"] {
            let access = try AgentMemoryAccess(projectRoot: destination)
            let agent = identity(access, run: "process-" + index)
            for item in 0..<20 {
                try access.history.append(agent: agent, kind: "tool_finished", detail: "process \(index) event \(item)")
            }
            return
        }
        var processes: [(Process, Pipe)] = []
        defer {
            for (process, _) in processes where process.isRunning {
                process.terminate()
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        for index in 0..<3 {
            let process = Process(), pipe = Pipe()
            #if os(macOS)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "AgentCoreTests.SharedAgentMemoryTests/testCrossProcessAppendsSurviveRestartWithoutLostHistory",
                                 Bundle(for: SharedAgentMemoryTests.self).bundleURL.path]
            #else
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["AgentCoreTests.SharedAgentMemoryTests/testCrossProcessAppendsSurviveRestartWithoutLostHistory"]
            #endif
            process.environment = environment.merging([
                "KIST_MEMORY_TEST_WORKER_ROOT": root, "KIST_MEMORY_TEST_WORKER_INDEX": String(index),
            ], uniquingKeysWith: { _, value in value })
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            processes.append((process, pipe))
        }
        let deadline = Date().addingTimeInterval(30)
        while processes.contains(where: { $0.0.isRunning }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        for (process, pipe) in processes {
            guard !process.isRunning else { XCTFail("history worker exceeded its deadline"); return }
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, output)
        }
        let reopened = try AgentMemoryAccess(projectRoot: root)
        let events = try reopened.history.page(limit: 100).events
        XCTAssertEqual(events.count, 60)
        XCTAssertEqual(Set(events.map(\.id)).count, 60)
        XCTAssertEqual(Set(events.map(\.detail)).count, 60)
    }

    func testRecallUsesOriginalEventTimeAndNeverRejuvenatesReads() throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        let agent = identity(access)
        let now = Date()
        let old = try access.history.append(agent: agent, kind: "tool_finished", detail: "ancientQuasarMarker",
                                            at: now.addingTimeInterval(-86_400 * 5_000))
        try access.history.append(agent: agent, kind: "tool_finished", detail: "futureQuasarMarker",
                                  at: now.addingTimeInterval(86_400))
        let recent = try access.history.append(agent: agent, kind: "tool_finished", detail: "freshQuasarMarker", at: now)
        try access.history.append(agent: agent, kind: "read_observation", detail: "ancientQuasarMarker copied by recall", at: now)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: old.locator))
        XCTAssertTrue(try access.recall(query: "ancientQuasarMarker", at: now).entries.isEmpty)
        XCTAssertTrue(try access.recall(query: "futureQuasarMarker", at: now).entries.isEmpty)
        XCTAssertEqual(try access.recall(query: "freshQuasarMarker", at: now).entries.first?.locator, recent.locator)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: old.locator)), bytes)
        XCTAssertEqual(try access.history.page().events.count, 4, "raw history is retained even when recall is ineligible")
    }

    func testCrossProjectRecallRequiresHostGrantAndScopesOnlyNarrow() throws {
        let foreign = root + "/foreign"
        try FileManager.default.createDirectory(atPath: foreign, withIntermediateDirectories: true)
        let other = try AgentMemoryAccess(projectRoot: foreign)
        try other.history.append(agent: identity(other), kind: "tool_finished", detail: "foreignOrchidMarker")
        let closed = try AgentMemoryAccess(projectRoot: root)
        XCTAssertThrowsError(try closed.recall(query: "foreignOrchidMarker", project: foreign))
        XCTAssertTrue(try closed.recall(query: "foreignOrchidMarker").entries.isEmpty)
        let allowed = try AgentMemoryAccess(projectRoot: root, authorizedReadRoots: [foreign])
        XCTAssertEqual(try allowed.recall(query: "foreignOrchidMarker", project: foreign).entries.count, 1)
        XCTAssertThrowsError(try allowed.narrowed(to: "project").recall(query: "foreignOrchidMarker", project: foreign))
        XCTAssertEqual(allowed.narrowed(to: "local").narrowed(to: "user").scope, .local)
    }

    func testCopiedForeignHistoryIsRejectedWithVisibleDegradation() throws {
        let foreign = root + "/foreign"
        try FileManager.default.createDirectory(atPath: foreign, withIntermediateDirectories: true)
        let other = try AgentMemoryAccess(projectRoot: foreign)
        let event = try other.history.append(agent: identity(other), kind: "tool_finished", detail: "forgedOrchidMarker")
        let access = try AgentMemoryAccess(projectRoot: root)
        let data = try Data(contentsOf: URL(fileURLWithPath: event.locator))
        _ = try ConfinedRoot(root: root).createDataIfMissing(event.relativePath, data, createParents: true)
        let recall = try access.recall(query: "forgedOrchidMarker")
        XCTAssertTrue(recall.entries.isEmpty)
        XCTAssertEqual(recall.rejectedHistoryRows, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + event.relativePath))
    }

    func testFreshLoopGetsSharedContextBeforeFirstCallAndPersistsCheckpoint() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        try access.history.append(agent: identity(access), kind: "tool_finished", detail: "orchidLaunchCode is azure-742")
        let provider = MemoryScriptedProvider([#"{"done":true,"summary":"The launch code is azure-742."}"#])
        let result = await loop(provider, context: ToolContext(projectRoot: root, agentMemory: access))
            .run(goal: "What was the orchidLaunchCode?")
        XCTAssertTrue(result.success, result.summary)
        let calls = await provider.state.calls
        XCTAssertTrue(calls.first?.contains("orchidLaunchCode is azure-742") ?? false)
        XCTAssertTrue(calls.first?.contains("[KIST_SHARED_AGENT_MEMORY_V1]") ?? false)
        let cp = try access.checkpoints.load(id: result.checkpointId)
        XCTAssertEqual(cp.agentIdentity?.project, access.project)
        XCTAssertEqual(cp.agentIdentity?.runID, result.checkpointId)
        XCTAssertTrue(try access.history.page().events.contains { $0.kind == "run_finished" && $0.agent.runID == result.checkpointId })
    }

    func testReadOnlyLoopCanActuallyCallSharedMemoryAndDiscoverAgents() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        try access.history.append(agent: identity(access), kind: "tool_finished", detail: "orchidLaunchCode is azure-742")
        let provider = MemoryScriptedProvider([
            #"{"tool":"shared_memory","parameters":{"query":"orchidLaunchCode"}}"#,
            #"{"tool":"list_agents","parameters":{"query":"orchid"}}"#,
            #"{"done":true,"summary":"Read memory and the current registry."}"#,
        ])
        let result = await loop(provider, context: ToolContext(projectRoot: root, agentMemory: access),
            tools: ToolRegistry([SharedAgentMemoryTool(), ListAgentsTool()])).run(goal: "Explain orchidLaunchCode from memory")
        XCTAssertTrue(result.success, result.summary)
        let reads = try access.history.page(limit: 100).events.filter { $0.kind == "read_observation" }
        XCTAssertEqual(reads.count, 2)
        XCTAssertTrue(reads.allSatisfy { $0.detail.contains("success=true") })
        XCTAssertTrue(reads.contains { $0.detail.contains("azure-742") })
    }

    func testAgentMetadataRequestCannotBecomeGeneralFileMutation() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        let provider = MemoryScriptedProvider([
            #"{"tool":"create_agent","parameters":{"name":"bounded-role","description":"Read orchid notes","instructions":"Report sources","tools":["read_file"]}}"#,
            #"{"tool":"write_file","parameters":{"path":"escape.swift","content":"forbidden"}}"#,
            #"{"done":true,"summary":"The role definition is registered."}"#,
        ])
        let tools = ToolRegistry([WriteFileTool(), CreateAgentTool(ceiling: ["read_file", "write_file"]), ListAgentsTool()])
        let request = "Create a reusable agent named bounded-role. Also write escape.swift."
        let scoped = HeadlessAgentLoop.conversationalToolset(tools, intent: .build, request: request)
        XCTAssertNotNil(scoped.tool(named: "create_agent"))
        XCTAssertNil(scoped.tool(named: "write_file"))
        _ = await loop(provider, context: ToolContext(projectRoot: root, agentMemory: access), tools: tools)
            .run(goal: request)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/agents/bounded-role.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/escape.swift"))
    }

    func testUnadmittedProviderRecordsRejectionWithoutInventingInferenceUsage() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        let budget = BudgetLedger(maxTokens: 1_000)
        let trace = TraceRecorder(traceId: "rejected-provider")
        let result = await HeadlessAgentLoop(providers: ProviderRegistry(providers: [], keyStore: MemoryNullKeys()),
            providerId: "unadmitted", model: nil, tools: ToolRegistry([]),
            context: ToolContext(projectRoot: root, agentMemory: access), injectAskUser: false,
            maxIterations: 2, budget: budget, traceRecorder: trace).run(goal: "Explain orchid history")
        XCTAssertFalse(result.success)
        let spent = await budget.spentTokens(), spans = await trace.all()
        XCTAssertEqual(spent, 0); XCTAssertTrue(spans.isEmpty)
        let events = try access.history.page(limit: 100).events
        XCTAssertTrue(events.contains { $0.kind == "failed" && $0.detail.contains("not admitted") })
        XCTAssertTrue(events.contains { $0.kind == "run_finished" && $0.detail.contains("success=false") })
        XCTAssertFalse(events.contains { $0.kind == "usage" })
    }

    func testGenericChildInheritsMemoryAndHasDurableParentLineage() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        try access.history.append(agent: identity(access), kind: "tool_finished", detail: "orchidLaunchCode is azure-742")
        let provider = MemoryScriptedProvider([
            #"{"tool":"spawn_agent","parameters":{"task":"Find the orchidLaunchCode from shared memory."}}"#,
            #"{"done":true,"summary":"orchidLaunchCode is azure-742"}"#,
            #"{"done":true,"summary":"The delegated answer is azure-742."}"#,
        ])
        let registry = ProviderRegistry(providers: [provider], keyStore: MemoryNullKeys())
        let spawn = SpawnAgentTool(providers: registry, providerId: provider.id, model: nil, baseTools: ToolRegistry([]))
        let trace = TraceRecorder(traceId: "shared-trace")
        let result = await HeadlessAgentLoop(providers: registry, providerId: provider.id, model: nil,
            tools: ToolRegistry([spawn]), context: ToolContext(projectRoot: root, agentMemory: access),
            injectAskUser: false, toolMode: .text, maxIterations: 4, traceRecorder: trace, traceRole: "assistant")
            .run(goal: "Delegate to one agent to find the orchidLaunchCode and return its answer.")
        XCTAssertTrue(result.success, result.summary)
        let starts = try access.history.page(limit: 200).events.filter { $0.kind == "run_started" }
        let child = try XCTUnwrap(starts.first { $0.agent.parentRunID == result.checkpointId })
        XCTAssertEqual(child.agent.rootRunID, "shared-trace")
        XCTAssertEqual(child.agent.sessionID, access.sessionID)
        XCTAssertEqual(try access.checkpoints.load(id: child.agent.runID).agentIdentity, child.agent)
        let calls = await provider.state.calls
        XCTAssertGreaterThanOrEqual(calls.count, 3)
        XCTAssertTrue(calls[1].contains("orchidLaunchCode is azure-742"))
        let spans = await trace.all().filter { $0.kind == .llmCall }
        XCTAssertEqual(spans.count, calls.count, "every child model call is accounted exactly once")
        XCTAssertEqual(Set(spans.compactMap(\.role)), ["assistant", "worker"])
        XCTAssertTrue(spans.allSatisfy { $0.traceId == "shared-trace" })
    }

    func testToolFreeSpecialistReceivesMemoryAndKeepsItsRole() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        try access.history.append(agent: identity(access), kind: "tool_finished", detail: "orchidLaunchCode is azure-742")
        let provider = MemoryScriptedProvider([#"{"done":true,"summary":"azure-742"}"#])
        let spawner = SpecialistSpawner(providers: ProviderRegistry(providers: [provider], keyStore: MemoryNullKeys()),
                                        baseTools: ToolRegistry([]), context: ToolContext(projectRoot: root, agentMemory: access),
                                        roleDefault: ProviderBinding(providerId: provider.id))
        let result = await spawner.run(specialist: SpecialistDefinition(name: "historian", description: "Recall history",
                                                                       systemPrompt: "Read the supplied context.", toolAllowlist: []),
                                       task: "Find orchidLaunchCode.")
        XCTAssertTrue(result.success, result.summary)
        XCTAssertEqual(try access.checkpoints.load(id: result.checkpointId).agentIdentity?.role, "historian")
        let calls = await provider.state.calls
        XCTAssertTrue(calls.first?.contains("orchidLaunchCode is azure-742") ?? false)
    }

    func testWorktreeRemovalLeavesSharedHistoryAndOriginalProjectIdentity() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        let worktree = root + "/isolated"
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        let provider = MemoryScriptedProvider([#"{"done":true,"summary":"isolatedOrchidFinding"}"#])
        let result = await loop(provider, context: ToolContext(projectRoot: worktree, agentMemory: access))
            .run(goal: "Explain this isolated task.")
        XCTAssertTrue(result.success, result.summary)
        try FileManager.default.removeItem(atPath: worktree)
        let reopened = try AgentMemoryAccess(projectRoot: root)
        let hit = try XCTUnwrap(reopened.history.page().events.first { $0.detail.contains("isolatedOrchidFinding") })
        XCTAssertTrue(hit.locator.hasPrefix(root + "/.kist/runs/"))
        let searched = try await SharedAgentMemoryTool().execute(arguments: ["mode": "history_search", "query": "isolatedOrchidFinding"],
                                                                  context: ToolContext(projectRoot: root, agentMemory: reopened))
        XCTAssertTrue(searched.output.contains("isolatedOrchidFinding"))
        let cp = try reopened.checkpoints.load(id: result.checkpointId)
        XCTAssertEqual(cp.agentIdentity?.executionRoot, worktree)
        XCTAssertEqual(cp.agentIdentity?.project, access.project)
    }

    func testResumeRetainsAgentIdentityAndRecordsContinuation() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        let initial = MemoryScriptedProvider(["unparseable reply"])
        let result = await loop(initial, context: ToolContext(projectRoot: root, agentMemory: access), max: 1)
            .run(goal: "Explain orchid recovery.")
        XCTAssertFalse(result.success)
        let cp = try access.checkpoints.load(id: result.checkpointId)
        let reopened = try AgentMemoryAccess(projectRoot: root)
        let next = MemoryScriptedProvider([#"{"done":true,"summary":"orchid recovery completed"}"#])
        let resumed = await loop(next, context: ToolContext(projectRoot: root, agentMemory: reopened)).resume(from: cp)
        XCTAssertTrue(resumed.success, resumed.summary)
        XCTAssertEqual(try reopened.checkpoints.load(id: cp.id).agentIdentity, cp.agentIdentity)
        XCTAssertTrue(try reopened.history.page().events.contains { $0.kind == "run_resumed" && $0.agent.runID == cp.id })
    }

    func testNoMemoryHostDoesNotReadOrCreateSharedStores() async throws {
        let provider = MemoryScriptedProvider([#"{"done":true,"summary":"Hello"}"#])
        let result = await loop(provider, context: ToolContext(projectRoot: root)).run(goal: "Hello")
        XCTAssertTrue(result.success, result.summary)
        let calls = await provider.state.calls
        XCTAssertFalse(calls.joined().contains("KIST_SHARED_AGENT_MEMORY"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.kist/runs/agent-history"))
    }

    func testUnsafeHistoryFailsBeforeAnyProviderCall() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        let target = root + "/redirect"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/.kist", withDestinationPath: target)
        let provider = MemoryScriptedProvider([#"{"done":true,"summary":"should not run"}"#])
        let result = await loop(provider, context: ToolContext(projectRoot: root, agentMemory: access)).run(goal: "Hello")
        XCTAssertFalse(result.success)
        let calls = await provider.state.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target), [])
    }

    func testCheckpointStoreCannotFollowReplacedProjectMetadataDirectory() throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        let outside = root + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/.kist", withDestinationPath: outside)
        let checkpoint = LoopCheckpoint(goal: "test", providerId: "stub", model: nil, projectRoot: root, messages: [])
        XCTAssertThrowsError(try access.checkpoints.save(checkpoint))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside), [])
    }

    func testResearchRecallRequiresOriginalClockAndContentBindingAndDoesNotRewriteManifest() throws {
        let now = Date()
        let access = try AgentMemoryAccess(projectRoot: root)
        let store = try ResearchRunStore(projectRoot: root, goal: "Orchid research", runID: "orchid", now: { now })
        try store.appendEvidence(kind: "web_search", title: "Search only", text: "snippetOnlyCanary")
        try store.appendEvidence(kind: "fetch_url", title: "Orchid manual", text: "orchidFetchedCanary describes request boundaries.",
                                 url: "https://example.org/orchid", metadata: ["status": "200", "fetch_status": "complete"])
        let manifest = try Data(contentsOf: URL(fileURLWithPath: store.manifestPath))
        let recall = try access.recall(query: "orchidFetchedCanary", at: now)
        XCTAssertTrue(recall.issues.isEmpty, recall.issues.joined(separator: "; "))
        XCTAssertTrue(recall.entries.first?.locator.hasSuffix("evidence.jsonl:L2") ?? false)
        XCTAssertTrue(try access.recall(query: "snippetOnlyCanary", at: now).entries.isEmpty)
        XCTAssertTrue(try access.recall(query: "orchidFetchedCanary", at: now.addingTimeInterval(86_400 * 5_000)).entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.manifestPath)), manifest)
        let evidence = try String(contentsOfFile: store.evidencePath, encoding: .utf8)
        try evidence.replacingOccurrences(of: "orchidFetchedCanary", with: "tamperedFetchCanary")
            .write(toFile: store.evidencePath, atomically: true, encoding: .utf8)
        let tampered = try access.recall(query: "tamperedFetchCanary", at: now)
        XCTAssertTrue(tampered.entries.isEmpty)
        XCTAssertTrue(tampered.issues.contains { $0.contains("unbound research fetch") })
    }

    func testAnsweringFromRecallDoesNotReageHistoricalSummary() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        let old = try access.history.append(agent: identity(access), kind: "run_finished", detail: "historicalOrchidCanary",
                                            at: Date().addingTimeInterval(-86_400 * 5_000))
        try access.history.append(agent: identity(access, run: "new-answer"), kind: "run_finished", detail: "historicalOrchidCanary")
        XCTAssertTrue(try access.recall(query: "historicalOrchidCanary").entries.isEmpty)
        let raw = try await SharedAgentMemoryTool().execute(arguments: ["mode": "history_search", "query": "historicalOrchidCanary"],
                                                            context: ToolContext(projectRoot: root, agentMemory: access))
        XCTAssertTrue(raw.output.contains(old.id))
        XCTAssertTrue(raw.output.contains("raw event; not current knowledge"))
    }

    func testHiddenReasoningExcludedAndOperationalSecretsMasked() throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        let agent = identity(access)
        let sink = AgentHistoryEventSink(downstream: NullEventSink(), access: access, health: AgentHistoryHealth())
        AgentExecutionScope.$current.withValue(agent) {
            sink.emit(.reasoningDelta("hidden-thought-canary"))
            sink.emit(.actionStarted(index: 1, tool: "shared_memory", description: "Read old evidence"))
            sink.emit(.actionFinished(index: 1, success: true, output: "oldEvidenceCanary", error: nil))
            sink.emit(.failed("test api_key=abcdefghijklmnopqrstuvwxyz123456"))
        }
        let page = try access.history.page()
        XCTAssertFalse(page.events.contains { $0.detail.contains("hidden-thought-canary") })
        XCTAssertTrue(page.events.contains { $0.detail.contains(SecretMasker.marker) })
        XCTAssertTrue(page.events.contains { $0.kind == "read_observation" })
        XCTAssertTrue(try access.recall(query: "oldEvidenceCanary").entries.isEmpty)
    }

    func testCreatedSpecialistCanDelegateWithinDepthAndLeafRetainsCreation() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        let context = ToolContext(projectRoot: root, agentMemory: access)
        let provider = MemoryScriptedProvider([
            #"{"tool":"spawn_agent","parameters":{"task":"Create a reusable agent named leaf-helper to explain orchid concurrency."}}"#,
            #"{"tool":"create_agent","parameters":{"name":"leaf-helper","description":"Explain orchid concurrency","instructions":"Explain the assigned concept in one sentence."}}"#,
            #"{"done":true,"summary":"Created leaf-helper."}"#,
            #"{"done":true,"summary":"The helper explained orchid concurrency."}"#,
        ])
        let providers = ProviderRegistry(providers: [provider], keyStore: MemoryNullKeys())
        let tools = AgentTeamTools.make(providers: providers, binding: ProviderBinding(providerId: provider.id),
                                       baseTools: ToolRegistry([]), context: context, maxIterations: 4, spawnLevels: 2)
        let created = await tools.execute(name: "create_agent", arguments: [
            "name": "coordinator", "description": "Delegate small questions", "instructions": "Use a helper for the assigned question.",
        ], context: context)
        XCTAssertTrue(created.success, created.error ?? "")
        let result = await tools.execute(name: "spawn_specialist", arguments: [
            "agent": "coordinator", "task": "Delegate to one helper to create a reusable agent named leaf-helper for explaining orchid concurrency.",
        ], context: context)
        XCTAssertTrue(result.success, result.error ?? result.output)
        let starts = try access.history.page(limit: 100).events.filter { $0.kind == "run_started" }
        let specialist = try XCTUnwrap(starts.first { $0.agent.role == "coordinator" })
        let leaf = try XCTUnwrap(starts.first { $0.agent.parentRunID == specialist.agent.runID })
        XCTAssertEqual(leaf.agent.rootRunID, specialist.agent.rootRunID)
        let createdLeaf = try XCTUnwrap(SpecialistRegistry(projectRoot: root, userDir: nil, claudeUserDir: nil).named("leaf-helper"))
        XCTAssertTrue(createdLeaf.toolAllowlist?.contains("create_agent") ?? false)
        XCTAssertFalse(createdLeaf.toolAllowlist?.contains("spawn_agent") ?? true)
        XCTAssertFalse(createdLeaf.toolAllowlist?.contains("spawn_specialist") ?? true)
        XCTAssertEqual(starts.count, 2, "the definition cannot replenish the leaf's delegation depth")
    }

    func testRecipientPhraseKeepsTheExplicitOperationAndNoChangeCeiling() {
        for (task, intent): (String, TaskBrief.Intent) in [
            ("write notes.txt with orchid", .build),
            ("create a reusable agent named orchid-helper", .build),
            ("explain how to write notes.txt", .chat),
            ("review the implementation", .review),
            ("write an implementation plan", .plan),
            ("write notes.txt, but no edits", .chat),
        ] {
            for recipient in ["to one helper to ",
                              "to one specialist historian using spawn_specialist: ",
                              "to historian with spawn_specialist(background=true) to "] {
                let grant = PromptCompiler.delegationGrant(for: "Delegate " + recipient + task)
                XCTAssertEqual(grant?.childIntent, intent, recipient + task)
                XCTAssertEqual(grant?.task, task)
            }
        }
    }

    func testFactoryCreationInWorktreePublishesOnlyToHostRegistryAndSurvivesCleanup() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        let worktree = root + "/worktree"
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        let context = ToolContext(projectRoot: worktree, agentMemory: access)
        let tools = AgentTeamTools.make(providers: ProviderRegistry(), binding: ProviderBinding(providerId: "stub"),
                                       baseTools: ToolRegistry([]), context: context, spawnLevels: 0)
        let created = await tools.execute(name: "create_agent", arguments: [
            "name": "durable-helper", "description": "Reusable helper", "instructions": "Explain one task.",
        ], context: context)
        XCTAssertTrue(created.success, created.error ?? "")
        XCTAssertTrue(created.output.contains(root + "/.kist/agents/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree + "/.kist/agents"))
        try FileManager.default.removeItem(atPath: worktree)
        XCTAssertNotNil(SpecialistRegistry(projectRoot: root, userDir: nil, claudeUserDir: nil).named("durable-helper"))
    }

    func testSpecialistToGenericDescendantKeepsApprovalFloor() async throws {
        let context = ToolContext(projectRoot: root)
        let provider = MemoryScriptedProvider([
            #"{"tool":"spawn_agent","parameters":{"task":"Write denied.txt containing orchid."}}"#,
            #"{"tool":"write_file","parameters":{"path":"denied.txt","content":"orchid"}}"#,
            #"{"done":true,"summary":"The write was denied."}"#,
            #"{"done":true,"summary":"The helper could not write."}"#,
        ])
        let providers = ProviderRegistry(providers: [provider], keyStore: MemoryNullKeys())
        let approvals = MemoryDenyInteractor()
        let tools = AgentTeamTools.make(providers: providers, binding: ProviderBinding(providerId: provider.id),
                                       baseTools: ToolRegistry([WriteFileTool()]), context: context, interactor: approvals,
                                       specialistApprovalTools: ["write_file"], maxIterations: 3, spawnLevels: 2)
        let created = await tools.execute(name: "create_agent", arguments: [
            "name": "coordinator", "description": "Delegate file tasks", "instructions": "Use a helper.",
        ], context: context)
        XCTAssertTrue(created.success, created.error ?? "")
        let result = await tools.execute(name: "spawn_specialist", arguments: [
            "agent": "coordinator", "task": "Delegate to one helper to write denied.txt containing orchid.",
        ], context: context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/denied.txt"))
        let count = await approvals.requests
        let calls = await provider.state.calls
        XCTAssertGreaterThan(count, 0, "the nested generic child must reach the inherited approval gate: \(result.output)\n\(calls.map { String($0.suffix(4000)) }.joined(separator: "\nCALL:\n"))")
    }

    func testPlannerAndCoderCallsReceiveMemoryAndRecordDistinctRoleLineage() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        try access.history.append(agent: identity(access), kind: "tool_finished", detail: "orchidLaunchCode is azure-742")
        let provider = MemoryScriptedProvider([
            #"{"goal":"write","steps":[{"id":"E1","intent":"write","tool":"write_file","arguments":{"path":"plan.txt","content":"azure-742"},"dependsOn":[]}]}"#,
            "Generated orchid content",
        ])
        let providers = ProviderRegistry(providers: [provider], keyStore: MemoryNullKeys())
        let context = ToolContext(projectRoot: root, agentMemory: access)
        let plan = PlanExecuteLoop(providers: providers, providerId: provider.id, model: nil,
                                   tools: ToolRegistry([WriteFileTool()]), context: context,
                                   requireApproval: false, verifyGoal: false)
        let result = await plan.run(goal: "Write plan.txt with the orchidLaunchCode.")
        XCTAssertTrue(result.success, result.message)
        let generated = try await GenerateTool(providers: providers, binding: ProviderBinding(providerId: provider.id))
            .execute(arguments: ["prompt": "Generate content mentioning the orchidLaunchCode."], context: context)
        XCTAssertTrue(generated.success, generated.error ?? "")
        let events = try access.history.page(limit: 100).events
        let planner = try XCTUnwrap(events.first { $0.kind == "model_request" && $0.agent.role == "planner" })
        XCTAssertEqual(planner.agent.parentRunID, result.checkpointId)
        XCTAssertTrue(events.contains { $0.kind == "model_response_advisory" && $0.agent.role == "coder" })
        let calls = await provider.state.calls
        XCTAssertTrue(calls.allSatisfy { $0.contains("orchidLaunchCode is azure-742") })
    }

    func testFleetPlannerAndCouncilRolesReceiveSameProjectHistory() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        try access.history.append(agent: identity(access), kind: "tool_finished", detail: "orchidLaunchCode is azure-742")
        let provider = MemoryScriptedProvider([
            #"[{"title":"Orchid","intent":"Write orchid notes","scopeGlobs":["Notes/*"]}]"#,
        ] + Array(repeating: "Orchid evidence is advisory.", count: 20))
        let providers = ProviderRegistry(providers: [provider], keyStore: MemoryNullKeys())
        let binding = ProviderBinding(providerId: provider.id)
        let plan = await FleetPlanner(providers: providers, binding: binding, agentMemory: access)
            .plan(goal: "Document orchidLaunchCode", scopeContext: "Notes/", maxAgents: 1)
        XCTAssertEqual(plan.count, 1)
        _ = await AICouncil(providers: providers, roles: RoleBindings(default: binding), agentMemory: access)
            .run(goal: "Discuss orchidLaunchCode")
        let calls = await provider.state.calls
        XCTAssertGreaterThan(calls.count, 3)
        XCTAssertTrue(calls.allSatisfy { $0.contains("orchidLaunchCode is azure-742") })
        let events = try access.history.page(limit: 100).events
        let council = try XCTUnwrap(events.first { $0.kind == "run_started" && $0.agent.role == "council" })
        XCTAssertTrue(events.contains { $0.agent.parentRunID == council.agent.runID && $0.kind == "model_response_advisory" })
    }

    func testPlanCoderUsageStillReachesDownstreamAndHistoryOnce() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        let provider = MemoryScriptedProvider([
            #"{"steps":[{"id":"G1","intent":"Generate orchid note","tool":"generate","arguments":{"prompt":"Explain orchidLaunchCode"}}]}"#,
            "Orchid note generated.",
        ])
        let providers = ProviderRegistry(providers: [provider], keyStore: MemoryNullKeys())
        let sink = MemoryRecordingSink()
        _ = await PlanExecuteLoop(providers: providers, providerId: provider.id, model: nil, tools: ToolRegistry([]),
            context: ToolContext(projectRoot: root, agentMemory: access), sink: sink,
            requireApproval: false, maxReplans: 0, verifyGoal: false).run(goal: "Explain orchidLaunchCode")
        let calls = await provider.state.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(sink.events.filter { if case .usage = $0 { return true }; return false }.count, 2)
        XCTAssertEqual(try access.history.page(limit: 100).events.filter { $0.kind == "usage" }.count, 2)
    }

    func testLateHistoryFailurePersistsFailedCheckpointAndReleasesLease() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        let historyPath = root + "/" + AgentHistoryStore.directory
        let sink = MemoryRecordingSink(onCompletion: {
            try? FileManager.default.moveItem(atPath: historyPath, toPath: historyPath + "-retained")
            try? Data("injected archive failure".utf8).write(to: URL(fileURLWithPath: historyPath))
        })
        let provider = MemoryScriptedProvider([#"{"done":true,"summary":"Answer before archive failure."}"#])
        let result = await HeadlessAgentLoop(providers: ProviderRegistry(providers: [provider], keyStore: MemoryNullKeys()),
            providerId: provider.id, model: nil, tools: ToolRegistry([]), context: ToolContext(projectRoot: root, agentMemory: access),
            sink: sink, injectAskUser: false, toolMode: .text, maxIterations: 2).run(goal: "Explain orchid history")
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.summary.contains("history durability failed"), result.summary)
        XCTAssertEqual(try access.checkpoints.load(id: result.checkpointId).status, .failed)
        let lease = try access.checkpoints.acquireRunLease(id: result.checkpointId)
        lease.release()
        let calls = await provider.state.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testCouncilEstimateIncludesInjectedMemoryOncePerProviderCall() async throws {
        let access = try AgentMemoryAccess(projectRoot: root)
        try access.history.append(agent: identity(access), kind: "tool_finished", detail: "orchidLaunchCode is azure-742")
        let provider = MemoryScriptedProvider(Array(repeating: "Council observation.", count: 20))
        let registry = ProviderRegistry(providers: [provider], keyStore: MemoryNullKeys())
        let trace = TraceRecorder(traceId: "council-estimate")
        let budget = BudgetLedger(maxTokens: 1_000_000)
        _ = await AICouncil(providers: registry, roles: RoleBindings(default: ProviderBinding(providerId: provider.id)),
                            recorder: trace, budget: budget, agentMemory: access).run(goal: "Discuss orchidLaunchCode")
        let calls = await provider.state.promptSizes
        let spans = await trace.all().filter { $0.kind == .llmCall }
        XCTAssertEqual(spans.count, calls.count)
        XCTAssertEqual(spans.map(\.promptTokens).sorted(), calls.map {
            TokenUsage.estimate(promptChars: $0, completionChars: 0).promptTokens
        }.sorted())
        XCTAssertTrue(spans.allSatisfy { $0.attributes?["usage.reported"] == "false" })
        let spent = await budget.spentTokens()
        XCTAssertEqual(spent, spans.reduce(0) { $0 + $1.totalTokens })
    }

    func testFleetHostIDAndParentSurviveDetachedWorkerLaunch() async throws {
        try initializeGitFixture()
        defer { cleanupGitFixtureWorktrees() }
        let access = try AgentMemoryAccess(projectRoot: root)
        let fleetID = UUID()
        let parent = try access.identity(runID: fleetID.uuidString, role: "fleet", executionRoot: root)
        let finished = expectation(description: "detached fleet worker finished")
        let spawner = InProcessAgentSpawner { _, worktree in
            defer { finished.fulfill() }
            do {
                let worker = try access.identity(runID: "fleet-worker", role: "worker", executionRoot: worktree.path)
                try access.history.append(agent: worker, kind: "run_started", detail: "Detached worker history")
            } catch { XCTFail("\(error)") }
            return "Recorded detached lineage"
        }
        let launch = await AgentExecutionScope.$current.withValue(parent) {
            await CaptainOrchestrator(spawner: spawner).launchFleet(goal: "Read fixture", repo: root,
                subtasks: [FleetSubtask(title: "Read", intent: "Read the fixture")], maxAgents: 1,
                baseDir: URL(fileURLWithPath: root + "/fleet-board"), nowEpoch: Date().timeIntervalSince1970,
                fleetID: fleetID)
        }
        XCTAssertEqual(launch.fleetID, fleetID)
        XCTAssertEqual(launch.launchedCount, 1)
        await fulfillment(of: [finished], timeout: 10)
        let worker = try XCTUnwrap(access.history.page().events.first { $0.agent.role == "worker" })
        XCTAssertEqual(worker.agent.parentRunID, fleetID.uuidString)
        XCTAssertEqual(worker.agent.rootRunID, fleetID.uuidString)
        XCTAssertEqual(worker.agent.sessionID, parent.sessionID)
    }

    func testParentDrainsItsUnjoinedBackgroundChildBeforeReleasingCheckpoint() async throws {
        try initializeGitFixture()
        defer { cleanupGitFixtureWorktrees() }
        let access = try AgentMemoryAccess(projectRoot: root)
        let childProvider = MemoryScriptedProvider(["unused"], delayNanos: 20_000_000_000)
        let providers = ProviderRegistry(providers: [childProvider], keyStore: MemoryNullKeys())
        let context = ToolContext(projectRoot: root, agentMemory: access)
        let registry = AsyncDelegationRegistry()
        let tools = AgentTeamTools.make(providers: providers, binding: ProviderBinding(providerId: childProvider.id),
            baseTools: ToolRegistry([]), context: context, spawnLevels: 1, delegationRegistry: registry)
        var checkpoint = LoopCheckpoint(goal: "Explain orchid history", providerId: childProvider.id, model: nil,
                                        projectRoot: root, messages: [ChatMessage(role: .user, content: "Explain orchid history")])
        let parent = identity(access, run: checkpoint.id)
        let launched = await AgentExecutionScope.$current.withValue(parent) {
            await tools.execute(name: "spawn_agent", arguments: ["task": "Explain orchid history", "background": true], context: context)
        }
        let handle = try XCTUnwrap(launched.metadata["delegation_handle"], launched.error ?? "")
        checkpoint.delegationHandles = [handle]
        for _ in 0..<100 {
            if !(await childProvider.state.calls).isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let parentProvider = MemoryScriptedProvider([#"{"done":true,"summary":"Parent ended before joining its child."}"#])
        let (outcome, _) = await loop(parentProvider, context: context, tools: tools).drive(checkpoint)
        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.summary.contains("Stopped and drained 1"), outcome.summary)
        let status = try await registry.snapshot(handleID: handle).status
        XCTAssertEqual(status, .cancelled)
        XCTAssertEqual(try access.checkpoints.load(id: checkpoint.id).status, .failed)
        let lease = try access.checkpoints.acquireRunLease(id: checkpoint.id)
        lease.release()
        let child = try XCTUnwrap(access.history.page(limit: 200).events.first { $0.kind == "cancelled" && $0.agent.parentRunID == checkpoint.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.agent.executionRoot))
        XCTAssertEqual(try gitFixture(["worktree", "list", "--porcelain"]).split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count, 1)
    }

    func testBackgroundGenericAndNamedAgentsKeepParentHistoryAndCleanEmptyWorktrees() async throws {
        try initializeGitFixture()
        defer { cleanupGitFixtureWorktrees() }
        let access = try AgentMemoryAccess(projectRoot: root)
        let parent = identity(access, run: "background-parent")
        try access.history.append(agent: identity(access), kind: "tool_finished", detail: "orchidLaunchCode is azure-742")
        for named in [false, true] {
            let provider = MemoryScriptedProvider([#"{"done":true,"summary":"Observed orchidLaunchCode azure-742 in shared context."}"#])
            let providers = ProviderRegistry(providers: [provider], keyStore: MemoryNullKeys())
            let registry = AsyncDelegationRegistry()
            let context = ToolContext(projectRoot: root, agentMemory: access)
            let tools = AgentTeamTools.make(providers: providers, binding: ProviderBinding(providerId: provider.id),
                                           baseTools: ToolRegistry([]), context: context, maxIterations: 3,
                                           spawnLevels: 1, delegationRegistry: registry)
            if named {
                let created = await tools.execute(name: "create_agent", arguments: [
                    "name": "background-reader", "description": "Read shared memory", "instructions": "Answer from shared context.",
                ], context: context)
                XCTAssertTrue(created.success, created.error ?? "")
            }
            var arguments: [String: Any] = ["task": "What was orchidLaunchCode?", "background": true]
            if named { arguments["agent"] = "background-reader" }
            let launched = await AgentExecutionScope.$current.withValue(parent) {
                await tools.execute(name: named ? "spawn_specialist" : "spawn_agent", arguments: arguments, context: context)
            }
            XCTAssertTrue(launched.success, launched.error ?? launched.output)
            let handle = try XCTUnwrap(launched.metadata["delegation_handle"])
            let result = try await registry.join(handleID: handle)
            let id = try XCTUnwrap(result.childCheckpointID)
            let checkpoint = try access.checkpoints.load(id: id)
            XCTAssertEqual(checkpoint.agentIdentity?.parentRunID, parent.runID)
            XCTAssertEqual(checkpoint.agentIdentity?.project, access.project)
            XCTAssertNotEqual(checkpoint.projectRoot, root)
            XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.projectRoot))
            XCTAssertTrue(try access.history.page(limit: 500).events.contains { $0.agent.runID == id && $0.kind == "run_finished" })
            let calls = await provider.state.calls
            XCTAssertTrue(calls.first?.contains("orchidLaunchCode is azure-742") ?? false)
        }
        XCTAssertEqual(try gitFixture(["worktree", "list", "--porcelain"]).split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count, 1)
    }

    func testBackgroundCancellationRetainsEventHistoryAndRemovesEmptyWorktree() async throws {
        try initializeGitFixture()
        defer { cleanupGitFixtureWorktrees() }
        let access = try AgentMemoryAccess(projectRoot: root)
        let provider = MemoryScriptedProvider([#"{"done":true,"summary":"should be cancelled"}"#], delayNanos: 20_000_000_000)
        let registry = AsyncDelegationRegistry()
        let providers = ProviderRegistry(providers: [provider], keyStore: MemoryNullKeys())
        let context = ToolContext(projectRoot: root, agentMemory: access)
        let tools = AgentTeamTools.make(providers: providers, binding: ProviderBinding(providerId: provider.id),
                                       baseTools: ToolRegistry([]), context: context, spawnLevels: 1, delegationRegistry: registry)
        let launched = await tools.execute(name: "spawn_agent", arguments: ["task": "Explain orchid cancellation.", "background": true], context: context)
        let handle = try XCTUnwrap(launched.metadata["delegation_handle"], launched.error ?? "")
        for _ in 0..<100 {
            if !(await provider.state.calls).isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await registry.cancel(handleID: handle)
        do { _ = try await registry.join(handleID: handle); XCTFail("cancelled delegation was accepted") }
        catch { XCTAssertTrue(String(describing: error).contains("cancel"), "join error: \(error)") }
        let history = try access.history.page(limit: 200).events
        let start = try XCTUnwrap(history.first { $0.kind == "run_started" })
        XCTAssertTrue(history.contains { $0.kind == "cancelled" && $0.agent.runID == start.agent.runID },
                      history.map { $0.kind + ": " + $0.detail }.joined(separator: "\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: start.agent.executionRoot))
        XCTAssertEqual(try gitFixture(["worktree", "list", "--porcelain"]).split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count, 1)
    }

    private func initializeGitFixture() throws {
        _ = try gitFixture(["init", "--quiet"])
        _ = try gitFixture(["config", "core.hooksPath", "/dev/null"])
        _ = try gitFixture(["config", "commit.gpgsign", "false"])
        try "Fixture\n".write(toFile: root + "/README.md", atomically: true, encoding: .utf8)
        _ = try gitFixture(["add", "README.md"])
        _ = try gitFixture(["-c", "user.name=Memory Test", "-c", "user.email=memory@example.invalid", "commit", "--quiet", "-m", "test fixture"])
    }

    @discardableResult private func gitFixture(_ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root] + arguments
        process.standardOutput = pipe; process.standardError = pipe
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
        ], uniquingKeysWith: { _, value in value })
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolError.execution("fixture git failed: \(output)") }
        return output
    }

    private func cleanupGitFixtureWorktrees() {
        guard let listing = try? gitFixture(["worktree", "list", "--porcelain"]) else { return }
        for line in listing.split(separator: "\n") where line.hasPrefix("worktree ") {
            let path = String(line.dropFirst("worktree ".count))
            if path != root { _ = try? gitFixture(["worktree", "remove", "--force", path]) }
        }
    }
}

private struct MemoryNullKeys: KeyStore { func key(forAccount account: String) -> String? { nil } }
private final class MemoryRecordingSink: RuntimeEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RuntimeEvent] = []
    private let onCompletion: (@Sendable () -> Void)?
    init(onCompletion: (@Sendable () -> Void)? = nil) { self.onCompletion = onCompletion }
    func emit(_ event: RuntimeEvent) {
        lock.lock(); recorded.append(event); lock.unlock()
        if case .completed = event { onCompletion?() }
    }
    var events: [RuntimeEvent] { lock.lock(); defer { lock.unlock() }; return recorded }
}
private final class MemoryScriptedProvider: ChatProvider, @unchecked Sendable {
    let id = "memory-scripted", name = "Memory Scripted", iconName = "cpu", requiresAPIKey = false
    let keyAccount = "memory-scripted", defaultModel = "memory-scripted-v1"
    let availableModels = [AIModel(id: "memory-scripted-v1")]
    let state: MemoryScriptedState
    let delayNanos: UInt64
    init(_ replies: [String], delayNanos: UInt64 = 0) { state = MemoryScriptedState(replies); self.delayNanos = delayNanos }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let reply = await state.next(messages, system: settings.systemPrompt)
        if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
        return AsyncThrowingStream { $0.yield(.delta(reply)); $0.finish() }
    }
}
private actor MemoryScriptedState {
    let replies: [String]
    var calls: [String] = []
    var promptSizes: [Int] = []
    init(_ replies: [String]) { self.replies = replies }
    func next(_ messages: [ChatMessage], system: String?) -> String {
        let index = calls.count
        calls.append((system ?? "") + "\n" + messages.map(\.content).joined(separator: "\n"))
        promptSizes.append((system ?? "").count + messages.reduce(0) { $0 + $1.content.count })
        return index < replies.count ? replies[index] : #"{"done":true,"summary":"script exhausted"}"#
    }
}

private actor MemoryDenyInteractor: RuntimeInteractor {
    var requests = 0
    func requestApproval(planSummary: String) async -> Bool { requests += 1; return false }
    func requestInput(question: String) async -> String { "" }
}
