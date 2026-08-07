import XCTest
@testable import AgentCore

/// The offline COBOL specialist tool (Phase D, 2026-08-07): a strong agent calls this to get COBOL
/// from the local cobol-jeeves model, since that model writes COBOL but can't drive the agent loop.
final class CobolGenerateToolTests: XCTestCase {

    func testMetadataAndContract() {
        let tool = CobolGenerateTool(providers: ProviderRegistry(providers: ProviderCatalog.all,
                                                                 keyStore: NullKeyStoreForCobolTool()))
        XCTAssertEqual(tool.name, "cobol_generate")
        XCTAssertTrue(tool.description.lowercased().contains("cobol"))
        XCTAssertTrue(tool.description.lowercased().contains("offline"))
        XCTAssertTrue(tool.parameters.contains { $0.name == "request" && $0.required })
        XCTAssertTrue(tool.parameters.contains { $0.name == "existing" && !$0.required })
    }

    func testMissingRequestFailsClearly() async throws {
        let tool = CobolGenerateTool(providers: ProviderRegistry(providers: ProviderCatalog.all,
                                                                 keyStore: NullKeyStoreForCobolTool()))
        let r = try await tool.execute(arguments: [:], context: ToolContext(projectRoot: NSTemporaryDirectory()))
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? r.output).contains("request"))
    }

    // Fence-stripping: the model is told not to fence, but small models sometimes do.
    func testStripCodeFences() {
        let fenced = "```cobol\nIDENTIFICATION DIVISION.\nPROGRAM-ID. HELLO.\n```"
        let out = CobolGenerateTool.stripCodeFences(fenced)
        XCTAssertTrue(out.contains("IDENTIFICATION DIVISION."))
        XCTAssertFalse(out.contains("```"))
        XCTAssertFalse(out.contains("cobol\n"), "the language tag line must be dropped")
        // No fences → unchanged.
        let plain = "IDENTIFICATION DIVISION.\nSTOP RUN."
        XCTAssertEqual(CobolGenerateTool.stripCodeFences(plain), plain)
    }

    // Pins the specialist stays OFFLINE — it must target the `cobol` provider and never fall back to cloud.
    func testTargetsCobolProviderNoFallback() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: repo.appendingPathComponent("Sources/AgentCore/Tools/CobolGenerateTool.swift"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("providerId: \"cobol\""), "must call the offline cobol provider")
        XCTAssertTrue(src.contains("allowFallback: false"), "must NOT silently fall back to a cloud model")
    }

    // Source pin: it's registered in the default tool set so a driving agent can actually call it.
    func testRegisteredInToolSet() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: repo.appendingPathComponent("Sources/Kist/KistRunner+Tools.swift"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("CobolGenerateTool(providers: registry)"),
                      "the COBOL specialist tool must be wired into the agent's tool set")
    }
}

private struct NullKeyStoreForCobolTool: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}
