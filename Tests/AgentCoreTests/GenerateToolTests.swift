import XCTest
import Foundation
@testable import AgentCore

/// The LLM-backed `generate` tool: produces content via the bound (coder) vendor, captured like any
/// tool output so a later step can ${ref} it.
final class GenerateToolTests: XCTestCase {

    private var root: String!
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "gen-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(atPath: root) } }

    private func tool(_ response: String, providerId: String = "gen") -> GenerateTool {
        let registry = ProviderRegistry(providers: [GenScriptedProvider(id: providerId, response: response)], keyStore: GenNullKeys())
        return GenerateTool(providers: registry, binding: ProviderBinding(providerId: providerId))
    }

    func testGeneratesContentFromBoundProvider() async throws {
        let result = try await tool("def add(a, b):\n    return a + b").execute(
            arguments: ["prompt": "write a python add function"], context: ToolContext(projectRoot: root))
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("return a + b"))
        XCTAssertEqual(result.metadata["provider"], "gen")
    }

    func testTrimsWhitespace() async throws {
        let result = try await tool("\n\n  hello  \n").execute(arguments: ["prompt": "x"], context: ToolContext(projectRoot: root))
        XCTAssertEqual(result.output, "hello")
    }

    // 2026-08-04 dogfood: generate returned ```asm\n<code>\n``` and write_file wrote the backticks,
    // so nasm choked on line 1. A sole surrounding fence must be unwrapped before the output is used.
    func testStripsSoleCodeFenceSoFilesArentCorrupted() async throws {
        let fenced = "```asm\norg 100h\nmov ah, 09h\nint 21h\n```"
        let result = try await tool(fenced).execute(arguments: ["prompt": "x"], context: ToolContext(projectRoot: root))
        XCTAssertEqual(result.output, "org 100h\nmov ah, 09h\nint 21h")
        XCTAssertFalse(result.output.contains("```"), "no fence backticks may reach the written file")
    }

    func testUnwrapSoleCodeFenceEdgeCases() {
        // Plain fence, no lang tag.
        XCTAssertEqual(GenerateTool.unwrapSoleCodeFence("```\nx=1\n```"), "x=1")
        // Not wrapped → untouched.
        XCTAssertEqual(GenerateTool.unwrapSoleCodeFence("just prose"), "just prose")
        // Prose CONTAINING a fenced sample (two interior fences) → left intact, not mangled.
        let prose = "Here is code:\n```py\nx=1\n```\nThat's it."
        XCTAssertEqual(GenerateTool.unwrapSoleCodeFence(prose), prose)
        // Inner backticks/content survive; only the outer fence is stripped.
        XCTAssertEqual(GenerateTool.unwrapSoleCodeFence("```bash\necho `date`\n```"), "echo `date`")
    }

    func testEmptyOutputIsFailure() async throws {
        let result = try await tool("   \n  ").execute(arguments: ["prompt": "x"], context: ToolContext(projectRoot: root))
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("empty") ?? false)
    }

    func testMissingPromptThrows() async {
        do {
            _ = try await tool("x").execute(arguments: [:], context: ToolContext(projectRoot: root))
            XCTFail("expected missingParameter")
        } catch let e as ToolError {
            if case .missingParameter("prompt") = e {} else { XCTFail("wrong error: \(e)") }
        } catch { XCTFail("wrong error type: \(error)") }
    }

    func testProviderErrorBecomesFailure() async throws {
        let registry = ProviderRegistry(providers: [GenFailingProvider()], keyStore: GenNullKeys())
        let t = GenerateTool(providers: registry, binding: ProviderBinding(providerId: "genfail"))
        let result = try await t.execute(arguments: ["prompt": "x"], context: ToolContext(projectRoot: root))
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("generate failed") ?? false)
    }

    func testSchema() {
        let t = GenerateTool(providers: ProviderRegistry(providers: [], keyStore: GenNullKeys()),
                             binding: ProviderBinding(providerId: "x"))
        XCTAssertEqual(t.name, "generate")
        XCTAssertEqual(t.parameters.first?.name, "prompt")
        XCTAssertTrue(t.parameters.first?.required ?? false)
    }
}

private struct GenNullKeys: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

private struct GenScriptedProvider: ChatProvider {
    let id: String; let name = "Gen", iconName = "cpu"
    let requiresAPIKey = false; var keyAccount: String { id }; let defaultModel = "g1"
    let availableModels = [AIModel(id: "g1")]
    let response: String
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { c in c.yield(.delta(response)); c.finish() }
    }
}

private struct GenFailingProvider: ChatProvider {
    let id = "genfail", name = "Fail", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "genfail", defaultModel = "x"
    let availableModels = [AIModel(id: "x")]
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        throw AIProviderError.transport("boom")
    }
}
